"""Ingesta oficial de la jornada — POST /api/ingesta/jornada.

Implementa el contrato ``docs/schemas/ingesta-jornada-v1.schema.json``: recibe
en un solo documento la NÓMINA (organizaciones políticas y candidatos inscritos
por ámbito, que construye el acta digital de los tres niveles) y la
DISTRIBUCIÓN (locales de votación y mesas con su padrón de electores hábiles).

Mapeo al prototipo (SQLite):
  * Cada organización con candidato principal INSCRITO se publica como una fila
    de la tabla de candidatos de su ámbito (``party`` = organización,
    ``name`` = candidato principal, ``sort_order`` = posición en el acta).
    Es el mismo mapeo que ``load_jne_data``: el upsert es por
    ``(ubigeo, party)`` preservando el id, así los votos ya registrados
    (``records.candidate_id``) nunca se rompen.
  * Cada local se publica como ``Venue`` (upsert por ``(ubigeo, nombre)``) y
    cada mesa como ``Table`` (``numero_mesa`` único global: si ya existe no se
    toca). Sin la mesa en el padrón, ``GET /api/actas/plantilla`` responde 404
    y el formulario no puede digitara: la distribución es requisito previo.

Permisos: SUPER_ADMIN (toda la región) o COORD_PROVINCIAL cuyo alcance cubra
TODOS los ubigeos del documento (nómina y distribución). Un coordinador no
puede publicar ámbitos fuera de su provincia.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.core.auth import (alcance_ubigeos, es_rol_global, requerir_rol,
                            usuario_actual)
from app.core.database import get_db
from app.core.models import (DistrictCandidate, ProvincialCandidate,
                              RegionalCandidate, Table, Usuario, Venue)
from app.core.schemas import IngestaJornadaPayload, IngestaResultado
from app.core.ubigeo import nivel_desde_tipo

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/ingesta", tags=["ingesta"])

MODELOS = {
    "district": DistrictCandidate,
    "provincial": ProvincialCandidate,
    "regional": RegionalCandidate,
}

# Sólo compite quien está en carrera (misma regla que load_jne_data).
ESTADO_EN_CARRERA = "INSCRITO"


def _ubigeo_en_alcance(ubigeo: str, prefijos: list[str]) -> bool:
    """El ubigeo cae dentro de alguno de los prefijos del alcance."""
    return any((ubigeo or "").startswith(p) for p in prefijos)


@router.post("/jornada", response_model=IngestaResultado)
def ingerir_jornada(
    payload: IngestaJornadaPayload,
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(requerir_rol("SUPER_ADMIN", "COORD_PROVINCIAL")),
):
    """Publica nómina y distribución oficiales para la jornada electoral.

    Idempotente: reenviar el mismo documento actualiza nombres, fotos y logos
    sin duplicar candidatos, locales ni mesas, y sin tocar votos existentes.
    """
    if (payload.jornada.departamento or "").upper() != "AREQUIPA":
        raise HTTPException(
            status_code=422,
            detail="La ingesta sólo admite departamento AREQUIPA",
        )

    # ---- Alcance territorial (COORD_PROVINCIAL no publica fuera de su provincia)
    # El rol global omite el scope geográfico (SUPER_ADMIN y DIGITADOR_GLOBAL).
    if not es_rol_global(usuario):
        ubigeos = alcance_ubigeos(usuario)
        if not ubigeos:
            raise HTTPException(status_code=403, detail="Rol territorial sin alcance asignado")
        prefijos = sorted({(u or "").rstrip("0") or u for u in ubigeos})
        fuera = sorted({
            u for u in (
                [a.ubigeo for a in payload.nomina]
                + [loc.ubigeo for loc in payload.distribucion]
            ) if not _ubigeo_en_alcance(u, prefijos)
        })
        if fuera:
            raise HTTPException(
                status_code=403,
                detail=f"Ubigeos fuera de tu alcance: {', '.join(fuera)}",
            )

    resultado = IngestaResultado()

    # ---- 1. Nómina: organizaciones y candidatos por ámbito
    for ambito in payload.nomina:
        nivel = nivel_desde_tipo(ambito.tipo_eleccion)
        if nivel is None or nivel not in MODELOS:
            raise HTTPException(
                status_code=422,
                detail=f"tipo_eleccion inválido: {ambito.tipo_eleccion}",
            )
        modelo = MODELOS[nivel]
        resultado.ambitos += 1

        for org in ambito.organizaciones:
            resultado.organizaciones += 1
            # Candidato principal: el de menor número que siga en carrera.
            # Sin principal INSCRITO la organización no figura en el acta.
            en_carrera = sorted(
                (c for c in org.candidatos if c.estado == ESTADO_EN_CARRERA),
                key=lambda c: c.numero,
            )
            if not en_carrera:
                resultado.candidatos_omitidos += len(org.candidatos)
                continue
            principal = en_carrera[0]
            nombre = principal.nombre_completo or f"{principal.nombres} {principal.apellidos}".strip()

            fila = (
                db.query(modelo)
                .filter(modelo.ubigeo == ambito.ubigeo, modelo.party == org.organizacionPolitica)
                .first()
            )
            if fila is None:
                fila = modelo(
                    name=nombre,
                    party=org.organizacionPolitica,
                    ubigeo=ambito.ubigeo,
                    color=org.color_hex or "#6b7280",
                    symbol=org.logo_url,
                    photo_url=principal.foto_url,
                    sort_order=org.numero,
                )
                db.add(fila)
            else:
                fila.name = nombre
                fila.sort_order = org.numero
                if org.logo_url:
                    fila.symbol = org.logo_url
                if principal.foto_url:
                    fila.photo_url = principal.foto_url
                if org.color_hex:
                    fila.color = org.color_hex
            resultado.candidatos += 1

    # ---- 2. Distribución: locales y mesas (padrón del formulario)
    for local in payload.distribucion:
        venue = (
            db.query(Venue)
            .filter(Venue.ubigeo == local.ubigeo, Venue.name == local.nombre)
            .first()
        )
        if venue is None:
            venue = Venue(
                name=local.nombre,
                sector=local.referencia or "",
                address=local.direccion,
                latitude=local.latitud if local.latitud is not None else 0.0,
                longitude=local.longitud if local.longitud is not None else 0.0,
                ubigeo=local.ubigeo,
                total_tables=0,
            )
            db.add(venue)
            db.flush()
        else:
            if local.direccion:
                venue.address = local.direccion
            if local.latitud is not None:
                venue.latitude = local.latitud
            if local.longitud is not None:
                venue.longitude = local.longitud
        resultado.locales += 1

        for mesa in local.mesas:
            existe = db.query(Table).filter(Table.numero_mesa == mesa.numero_mesa).first()
            if existe is not None:
                resultado.mesas_existentes += 1
                continue
            # El padrón de electores queda en la mesa (tope de la regla R2
            # que lee GET /api/actas/plantilla); el acta digitada lo replica
            # en ActaMetadata.
            db.add(Table(
                numero_mesa=mesa.numero_mesa,
                venue_id=venue.id,
                electores_habiles=mesa.electores_habiles,
            ))
            resultado.mesas += 1

        venue.total_tables = db.query(Table).filter(Table.venue_id == venue.id).count()

    db.commit()
    logger.info(
        "ingesta jornada %s: %d ámbitos, %d candidatos, %d locales, %d mesas "
        "(por %s)",
        payload.jornada.fecha, resultado.ambitos, resultado.candidatos,
        resultado.locales, resultado.mesas, usuario.email,
    )
    return resultado


@router.get("/estado")
def estado_ingesta(
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(usuario_actual),
):
    """Cobertura actual de la ingesta: ámbitos con oferta y mesas en padrón."""
    _ = usuario
    return {
        "regional": db.query(RegionalCandidate).count(),
        "provincial_ambitos": db.query(ProvincialCandidate.ubigeo).distinct().count(),
        "provincial": db.query(ProvincialCandidate).count(),
        "distrital_ambitos": db.query(DistrictCandidate.ubigeo).distinct().count(),
        "distrital": db.query(DistrictCandidate).count(),
        "locales": db.query(Venue).count(),
        "mesas": db.query(Table).count(),
    }
