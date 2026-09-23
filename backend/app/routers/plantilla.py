"""Plantilla dinámica de acta — GET /api/actas/plantilla.

Consolida la oferta electoral oficial (cargada por el crawler del JNE vía
``load_jne_data``) con los datos de la mesa consultada, para que el formulario
de captura pinte el acta digital de los tres niveles sin hardcodear candidatos.
El contrato de salida está especificado en ``docs/schemas/plantilla-acta-v1.schema.json``.
"""
from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from app.core.auth import alcance_ubigeos, es_rol_global, requerir_rol
from app.core.database import get_db
from app.core.models import (ActaMetadata, AsignacionPersonero,
                             DistrictCandidate, ProvincialCandidate,
                             Record, RegionalCandidate, ROLES_SISTEMA, Table, Venue)
from app.core.ubigeo import candidatos_del_ambito, ubigeo_de_nivel

router = APIRouter(prefix="/api/actas", tags=["actas"])

# Nivel del prototipo -> modelo de candidatos
MODELOS = {
    "district": DistrictCandidate,
    "provincial": ProvincialCandidate,
    "regional": RegionalCandidate,
}

ETIQUETAS = {
    "district": "Alcalde y Regidores del distrito",
    "provincial": "Alcalde y Regidores de la provincia",
    "regional": "Gobernador Regional y Consejeros",
}

# Clave interna del prototipo -> tipo_eleccion del contrato (enum del esquema)
NIVEL_A_TIPO = {
    "district": "DISTRITAL",
    "provincial": "PROVINCIAL",
    "regional": "REGIONAL",
}

# Estados en los que el acta puede ser corregida (ver REGLAS_DE_NEGOCIO.md):
EDITABLES = ("PENDIENTE", "DIGITADA", "OBSERVADA")

# El prototipo SQLite usa estados en inglés; el esquema PostgreSQL, el enum
# estado_acta en español. Se normaliza aquí para que el contrato no dependa
# de la base que corre por detrás.
ESTADO_A_ENUM = {
    "PENDING": "PENDIENTE",
    "DIGITADA": "DIGITADA",
    "REQUIRES_REVIEW": "OBSERVADA",
    "OBSERVADA": "OBSERVADA",
    "PROCESSED": "CONTABILIZADA",
    "CONTABILIZADA": "CONTABILIZADA",
    "VALIDATED": "CONTABILIZADA",
    "ANULADA": "ANULADA",
}


def _estado_enum(status: str | None) -> str:
    return ESTADO_A_ENUM.get((status or "").upper(), (status or "PENDIENTE").upper())


def _oferta_del_ambito(db: Session, nivel: str, ambito: str) -> list[dict]:
    """Organizaciones del ámbito en el orden del acta (sort_order)."""
    model = MODELOS[nivel]
    return [
        {
            "numero": c.sort_order,
            "nombre": c.party or c.name,
            "candidato": c.name,
            "logo_url": c.symbol,
            "color": c.color,
            "photo_url": c.photo_url,
        }
        for c in candidatos_del_ambito(db, model, ambito).order_by(model.sort_order).all()
    ]


def _votos_digitados(db: Session, table_id: int, nivel: str, ambito: str) -> dict[int, int]:
    """Votos ya registrados de la mesa, indexados por sort_order de la org."""
    id_a_sort = {
        c.id: c.sort_order
        for c in candidatos_del_ambito(db, MODELOS[nivel], ambito).all()
    }
    votos: dict[int, int] = {}
    for row in (
        db.query(Record)
        .filter(Record.table_id == table_id, Record.candidate_type == nivel)
        .all()
    ):
        sort_order = id_a_sort.get(row.candidate_id)
        if sort_order is not None:
            votos[sort_order] = row.votes or 0
    return votos


@router.get("/plantilla")
def plantilla_de_acta(
    numero_mesa: str = Query(..., min_length=6, max_length=6, pattern="^[0-9]{6}$"),
    db: Session = Depends(get_db),
    usuario=Depends(requerir_rol(*ROLES_SISTEMA)),
):
    """Plantilla del acta digital para una mesa: las tres elecciones y su oferta.

    Fuente única del formulario ``ActaIngresoForm``. Si la mesa ya tiene acta,
    incluye ``acta_existente`` con los votos digitados para prellenar el
    formulario (idempotencia de la cola offline: el reintento trae la misma
    plantilla en lugar de duplicar el acta).
    """
    table = db.query(Table).filter(Table.numero_mesa == numero_mesa).first()
    if table is None:
        raise HTTPException(
            status_code=404,
            detail=f"Mesa {numero_mesa} no encontrada en el padrón de locales",
        )

    venue = db.query(Venue).filter(Venue.id == table.venue_id).first()
    if venue is None:
        raise HTTPException(status_code=500, detail=f"Mesa {numero_mesa} sin local asignado")

    # Visibilidad por ubigeo: un digitador sólo abre plantillas de su
    # jurisdicción (rol global ve todo el país). El PERSONERO/DELEGADO
    # además sólo abre SUS mesas asignadas: no curiosea otras mesas.
    if not es_rol_global(usuario):
        ubigeos = alcance_ubigeos(usuario)
        prefijos = sorted({(u or "").rstrip("0") or u for u in ubigeos})
        if not prefijos or not any(
            (venue.ubigeo or "").startswith(p) for p in prefijos
        ):
            raise HTTPException(
                status_code=403,
                detail=f"La mesa {numero_mesa} está fuera de tu alcance territorial",
            )
    if usuario.rol in ("PERSONERO", "DELEGADO_MESA"):
        propia = (
            db.query(AsignacionPersonero.id)
            .filter(AsignacionPersonero.usuario_id == usuario.id,
                    AsignacionPersonero.mesa_id == table.id)
            .first()
        )
        if propia is None:
            raise HTTPException(
                status_code=403,
                detail=f"La mesa {numero_mesa} no te está asignada",
            )

    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()

    tiene_captura = table.processed or meta is not None
    acta_existente = None
    if tiene_captura:
        estado = _estado_enum(table.status)
        acta_existente = {
            "id": table.id,
            "estado": estado,
            "editable": estado in EDITABLES,
        }

    elecciones = []
    # Orden oficial de la jornada: 1º Regional, 2º Provincial, 3º Distrital.
    for nivel in ("regional", "provincial", "district"):
        ambito = ubigeo_de_nivel(venue.ubigeo, nivel)
        organizaciones = _oferta_del_ambito(db, nivel, ambito)
        if not organizaciones:
            # Ámbito sin oferta cargada (p. ej. prototipo sólo Paucarpata):
            # no se ofrece la elección en el formulario.
            continue
        votos = _votos_digitados(db, table.id, nivel, ambito) if tiene_captura else {}
        for org in organizaciones:
            org["votos"] = votos.get(org["numero"])

        elecciones.append({
            "tipo_eleccion": NIVEL_A_TIPO[nivel],
            "cargos": ETIQUETAS[nivel],
            # El prototipo consolida cada elección en una sola columna (el
            # dashboard computa por organización). El acta física real tiene
            # dos; el modelo PostgreSQL (acta_columnas) ya las soporta.
            "columnas": [{
                "columna": "GOBERNADOR_VICE" if nivel == "regional" else "ALCALDE",
                "etiqueta": (
                    "GOBERNADOR Y VICEGOBERNADOR REGIONAL" if nivel == "regional" else "ALCALDE"
                ),
                "es_principal": True,
                "total_votantes_papel": None,
                "votos_blancos": None,
                "votos_nulos": None,
                "votos_impugnados": None,
                "organizaciones": organizaciones,
            }],
        })

    # electores_habiles: padrón de la mesa (distribución ONPE). Se prefiere el
    # valor del padrón; si la mesa aún no lo tiene, se usa lo digitado antes.
    return {
        "numero_mesa": table.numero_mesa,
        "local": {
            "id": venue.id,
            "nombre": venue.name,
            "direccion": venue.address,
            "sector": venue.sector,
            "latitud": venue.latitude,
            "longitud": venue.longitude,
        },
        "ubigeo_distrito": venue.ubigeo,
        "electores_habiles": table.electores_habiles or (meta.total_electores if meta else None),
        "acta_existente": acta_existente,
        "elecciones": elecciones,
        "generada_en": datetime.now(timezone.utc).isoformat(),
    }
