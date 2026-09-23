"""Actas API router."""
import logging
from pathlib import Path
from uuid import uuid4

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from sqlalchemy.orm import Session

from app.core.auth import (alcance_ubigeos, es_rol_global, requerir_rol,
                           usuario_actual, validar_alcance_venue,
                           venues_en_alcance)
from app.core.database import get_db
from app.core.models import (ActaMetadata, DistrictCandidate,
                             ProvincialCandidate, Record, RegionalCandidate,
                             ROLES_SISTEMA, Table, Usuario, Venue)
from app.core.schemas import (ActaParseResult, ActaUpdate, ActaUpdatePayload,
                              ActaValidacionIn)
from app.core.ubigeo import candidatos_del_ambito, ubigeo_de_nivel
from app.core.ubigeo_catalogo import UBIGEO_DISTRITO, UBIGEO_PROVINCIA
from app.services.acta_validator import ColumnaActa, validar_acta
from app.services.processor import ensure_seed_data, save_acta
from app.services.storage import storage_service
from app.services.vision import parse_acta

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/actas", tags=["actas"])

CANDIDATE_MODELS = {
    "district": DistrictCandidate,
    "provincial": ProvincialCandidate,
    "regional": RegionalCandidate,
}

# Quién puede cargar y corregir actas del prototipo
# DELEGADO_MESA carga como el PERSONERO (rol del brief para el local de votación)
# DIGITADOR_GLOBAL crea/rectifica a nivel nacional (bypass ubigeo + auditoría).
ROLES_CAPTURA = ("SUPER_ADMIN", "DIGITADOR_GLOBAL", "RESPONSABLE_DISTRITAL", "DELEGADO_MESA", "PERSONERO")
ROLES_RECTIFICACION = ("SUPER_ADMIN", "DIGITADOR_GLOBAL", "COORD_PROVINCIAL", "RESPONSABLE_DISTRITAL")
ROLES_SUPERVISION = ROLES_SISTEMA  # todos pueden consultar


def _ranking(db: Session, table_id: int, candidate_type: str) -> list[dict]:
    """Votes recorded for one acta, enriched with candidate info."""
    model = CANDIDATE_MODELS[candidate_type]
    candidates = {c.id: c for c in db.query(model).all()}
    rows = (
        db.query(Record)
        .filter(Record.table_id == table_id, Record.candidate_type == candidate_type)
        .all()
    )
    ranking = []
    for row in rows:
        candidate = candidates.get(row.candidate_id)
        if candidate is None:
            continue
        ranking.append({
            "candidate_id": candidate.sort_order,
            "name": candidate.name,
            "party": candidate.party,
            "color": candidate.color,
            "votes": row.votes or 0,
            "symbol": candidate.symbol,
            "photo_url": candidate.photo_url,
        })
    ranking.sort(key=lambda item: item["candidate_id"])
    return ranking


def _serialize_acta(db: Session, table: Table) -> dict:
    """Full acta payload shared by the review list, detail and save endpoints."""
    venue = db.query(Venue).filter(Venue.id == table.venue_id).first()
    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
    return {
        "id": table.id,
        "numero_mesa": table.numero_mesa,
        "status": table.status,
        "requires_review": bool(table.requires_review),
        "ocr_confidence": table.ocr_confidence,
        "image_url": table.image_url,
        "venue_id": table.venue_id,
        "venue_name": venue.name if venue else None,
        "sector": venue.sector if venue else None,
        "latitude": venue.latitude if venue else None,
        "longitude": venue.longitude if venue else None,
        # Ubicación real del acta: sin esto el detalle no sabía en qué distrito
        # estaba la mesa (el modal mostraba "Paucarpata" escrito a mano).
        "ubigeo": (venue.ubigeo if venue else None) or "",
        "distrito": UBIGEO_DISTRITO.get((venue.ubigeo if venue else None) or "", ""),
        "provincia": UBIGEO_PROVINCIA.get((venue.ubigeo if venue else None) or "", ""),
        "electores_habiles": table.electores_habiles,
        "votos_distrital": _ranking(db, table.id, "district"),
        "votos_provincial": _ranking(db, table.id, "provincial"),
        "votos_regional": _ranking(db, table.id, "regional"),
        "votos_blancos": meta.votos_blancos if meta else 0,
        "votos_nulos": meta.votos_nulos if meta else 0,
        "votos_impugnados": meta.votos_impugnados if meta else 0,
        "total_electores": meta.total_electores if meta else 0,
    }


def _mesa_con_acta(db: Session, numero_mesa: str | None, clave_tipo: str) -> bool:
    """R4 real: la mesa ya tiene un acta registrada PARA ESTE TIPO de elección.

    Las filas de ``tables`` son el padrón (todas las mesas existen desde la
    ingesta/seed): lo que marca duplicado es tener votos persistidos
    (``records``) de ese nivel, no la mera existencia de la mesa.
    """
    if not numero_mesa:
        return False
    table = db.query(Table).filter(Table.numero_mesa == numero_mesa).first()
    if table is None:
        return False
    return (
        db.query(Record)
        .filter(Record.table_id == table.id, Record.candidate_type == clave_tipo)
        .first()
        is not None
    )


def _ubigeo_del_ambito(db: Session, table_id: int, nivel: str) -> str:
    """Ubigeo que le corresponde a una mesa para un nivel de elección."""
    fila = (
        db.query(Venue.ubigeo)
        .join(Table, Table.venue_id == Venue.id)
        .filter(Table.id == table_id)
        .first()
    )
    return ubigeo_de_nivel(fila[0] if fila else "", nivel)


def _apply_votes(db: Session, table_id: int, candidate_type: str, votes_list) -> None:
    """Upsert vote records for one candidate type. Accepts raw vote lists.

    La oferta se acota al ámbito del local: ``sort_order`` es la posición de la
    organización en el acta, así que sin el filtro dos distritos con el mismo
    partido compartirían llave y los votos caerían en el ámbito vecino.
    """
    if not votes_list:
        return
    ambito = _ubigeo_del_ambito(db, table_id, candidate_type)
    id_map = {
        c.sort_order: c.id
        for c in candidatos_del_ambito(db, CANDIDATE_MODELS[candidate_type], ambito).all()
    }

    def _votes(item) -> int:
        return item["votes"] if isinstance(item, dict) else item.votes

    def _sort_order(item) -> int:
        return item["candidate_id"] if isinstance(item, dict) else item.candidate_id

    for item in votes_list:
        candidate_id = id_map.get(_sort_order(item))
        if candidate_id is None:
            continue
        record = (
            db.query(Record)
            .filter(
                Record.table_id == table_id,
                Record.candidate_type == candidate_type,
                Record.candidate_id == candidate_id,
            )
            .first()
        )
        if record is None:
            db.add(
                Record(
                    table_id=table_id,
                    candidate_type=candidate_type,
                    candidate_id=candidate_id,
                    votes=_votes(item),
                )
            )
        else:
            record.votes = _votes(item)


def venues_en_alcance_ids(db: Session, usuario: Usuario) -> list[int] | None:
    """Ids de venues visibles. None = todos (rol global: nacional)."""
    if es_rol_global(usuario):
        return None
    filas = venues_en_alcance(db, usuario).all()
    return [v.id for v in filas]


def _verificar_venue_en_alcance(db: Session, usuario: Usuario, venue_id: int | None) -> None:
    """Aplica el alcance territorial al venue del acta cuando aplica.

    El rol global (DIGITADOR_GLOBAL / SUPER_ADMIN) omite el scope geográfico.
    """
    if venue_id is None or es_rol_global(usuario):
        return
    ubigeos = alcance_ubigeos(usuario)
    if not ubigeos:
        raise HTTPException(status_code=403, detail="Rol territorial sin alcance asignado")
    venue = db.query(Venue).filter(Venue.id == venue_id).first()
    if venue is not None and (venue.ubigeo or "") not in ubigeos:
        raise HTTPException(
            status_code=403,
            detail=f"El local '{venue.name}' está fuera de tu alcance territorial",
        )


def _upsert_metadata(db: Session, table_id: int, **fields) -> ActaMetadata:
    """Create or update the non-candidate metadata of an acta."""
    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table_id).first()
    if meta is None:
        meta = ActaMetadata(table_id=table_id)
        db.add(meta)
    for key, value in fields.items():
        if value is not None:
            setattr(meta, key, value)
    return meta


async def _save_upload(file: UploadFile) -> Path:
    """Persist an uploaded file into ./tmp and return its path."""
    tmp_dir = Path("./tmp")
    tmp_dir.mkdir(exist_ok=True)
    suffix = Path(file.filename or "acta.jpg").suffix or ".jpg"
    tmp_path = tmp_dir / f"acta_{uuid4().hex}{suffix}"
    tmp_path.write_bytes(await file.read())
    return tmp_path


def _parse_and_store(db: Session, tmp_path: Path) -> tuple[ActaParseResult, Table]:
    """Run OCR on a local image, store it and persist the acta."""
    result = parse_acta(str(tmp_path))
    image_url = storage_service.upload(str(tmp_path))
    table = save_acta(db, result, image_url)
    return result, table


@router.post("/process")
async def process_acta(file: UploadFile = File(...), db: Session = Depends(get_db),
                       usuario: Usuario = Depends(requerir_rol(*ROLES_CAPTURA))):
    """Upload an acta image: run OCR, persist it and return the stored acta.

    Requiere rol de captura; el acta queda en el venue del alcance del usuario.
    """
    ensure_seed_data(db)
    tmp_path = await _save_upload(file)
    try:
        result, table = _parse_and_store(db, tmp_path)
        _verificar_venue_en_alcance(db, usuario, table.venue_id)
        payload = _serialize_acta(db, table)
        payload["ocr_confidence"] = result.ocr_confidence
        return payload
    except Exception as e:  # noqa: BLE001
        logger.error("Acta processing failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        tmp_path.unlink(missing_ok=True)


@router.post("/ocr")
async def ocr_acta(file: UploadFile = File(...)):
    """
    Run OCR on an acta image and return extracted data with confidence.
    Does NOT save to database.
    """
    tmp_path = await _save_upload(file)
    try:
        result = parse_acta(str(tmp_path))
        image_url = storage_service.upload(str(tmp_path))
        return {
            "numero_mesa": result.numero_mesa,
            "votos_distrital": [v.model_dump() for v in result.votos_distrital],
            "votos_regional": [v.model_dump() for v in result.votos_regional],
            "votos_blancos": result.votos_blancos,
            "votos_nulos": result.votos_nulos,
            "votos_impugnados": result.votos_impugnados,
            "ocr_confidence": result.ocr_confidence,
            "image_url": image_url,
        }
    except Exception as e:  # noqa: BLE001
        logger.error("OCR processing failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        tmp_path.unlink(missing_ok=True)


@router.post("/validar")
def validar_acta_endpoint(payload: ActaValidacionIn, db: Session = Depends(get_db),
                          usuario: Usuario = Depends(usuario_actual)):
    """Valida un acta contra las reglas matemáticas de la ONPE sin guardarla.

    Lo llama la PWA móvil en cada tecleo (validación en tiempo real) y antes de
    enviar. La mesa debe estar en el padrón y dentro del alcance del usuario;
    la duplicidad (R4) se detecta contra votos ya persistidos de ese nivel.
    """
    from app.core.ubigeo import nivel_desde_tipo as _nivel_desde_tipo
    clave = _nivel_desde_tipo(payload.tipo_eleccion) or ""
    if payload.numero_mesa:
        tabla = db.query(Table).filter(Table.numero_mesa == payload.numero_mesa).first()
        if tabla is None:
            raise HTTPException(
                status_code=404,
                detail=f"Mesa {payload.numero_mesa} no está en el padrón de locales",
            )
        _verificar_venue_en_alcance(db, usuario, tabla.venue_id)
    acta_ya_registrada = _mesa_con_acta(db, payload.numero_mesa, clave)

    columnas = [
        ColumnaActa(
            columna=c.columna.upper(),
            votos={str(k): int(v) for k, v in c.votos.items()},
            votos_blancos=c.votos_blancos,
            votos_nulos=c.votos_nulos,
            votos_impugnados=c.votos_impugnados,
            total_votantes=c.total_votantes,
        )
        for c in payload.columnas
    ]

    try:
        resultado = validar_acta(
            tipo_eleccion=payload.tipo_eleccion,
            electores_habiles=payload.electores_habiles,
            columnas=columnas,
            foto_presente=payload.foto_presente,
            acta_ya_registrada=acta_ya_registrada,
            foto_repetida=payload.foto_repetida,
            ilegible=payload.ilegible,
            firmas_completas=payload.firmas_completas,
            diferencia_manual=payload.diferencia_manual,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    return resultado.to_dict()


@router.post("/movil")
def registrar_acta_movil(payload: ActaValidacionIn, db: Session = Depends(get_db),
                         usuario: Usuario = Depends(requerir_rol(*ROLES_CAPTURA))):
    """Registra el acta digitada en la PWA móvil.

    Vuelve a validar con la misma autoridad que ``/validar``: si el acta no
    cuadra, responde 409 y **no** entra al cómputo (queda para el
    RESPONSABLE_DISTRITAL como acta observada). Si cuadra, persiste los votos
    por organización política y el acta pasa a contar en el dashboard.
    """
    ensure_seed_data(db)

    tipo_registro = {"DISTRITAL": "district", "PROVINCIAL": "provincial", "REGIONAL": "regional"}
    tipo = payload.tipo_eleccion.upper()
    if tipo not in tipo_registro:
        raise HTTPException(status_code=422, detail=f"Tipo de elección inválido: {payload.tipo_eleccion}")
    clave_tipo = tipo_registro[tipo]

    # La mesa debe existir en el padrón (ingesta de distribución o seed
    # regional): el acta queda en SU local real, no en el primero de la base.
    # El alcance se valida ANTES de la matemática para no filtrar datos de
    # jurisdicciones ajenas (403 precede a 409).
    table = (
        db.query(Table).filter(Table.numero_mesa == payload.numero_mesa).first()
        if payload.numero_mesa
        else None
    )
    if table is None:
        raise HTTPException(
            status_code=404,
            detail=f"Mesa {payload.numero_mesa} no está en el padrón de locales",
        )
    venue = validar_alcance_venue(db, usuario, table.venue_id)

    # Presencia + asignación: el personero registra sólo sus mesas con
    # check-in GPS válido en el local.
    from app.routers.campo import exigir_asignacion, exigir_presencia
    exigir_asignacion(db, usuario, table.id, payload.numero_mesa or "")
    exigir_presencia(db, usuario, venue.id)

    acta_ya_registrada = _mesa_con_acta(db, payload.numero_mesa, clave_tipo)

    columnas = [
        ColumnaActa(
            columna=c.columna.upper(),
            votos={str(k): int(v) for k, v in c.votos.items()},
            votos_blancos=c.votos_blancos,
            votos_nulos=c.votos_nulos,
            votos_impugnados=c.votos_impugnados,
            total_votantes=c.total_votantes,
        )
        for c in payload.columnas
    ]

    resultado = validar_acta(
        tipo_eleccion=payload.tipo_eleccion,
        electores_habiles=payload.electores_habiles,
        columnas=columnas,
        foto_presente=payload.foto_presente,
        acta_ya_registrada=acta_ya_registrada,
        foto_repetida=payload.foto_repetida,
        ilegible=payload.ilegible,
        firmas_completas=payload.firmas_completas,
    )

    # Puerta de la regla de negocio: un acta inconsistente no se contabiliza.
    if not resultado.puede_enviar:
        raise HTTPException(
            status_code=409,
            detail={
                "mensaje": "Acta no contabilizada: quedó OBSERVADA para revisión del coordinador.",
                "estado_sugerido": resultado.estado_sugerido,
                "diferencia": resultado.diferencia,
                "hallazgos": [h.to_dict() for h in resultado.hallazgos],
            },
        )

    # El padrón digitado queda en la mesa (fija el tope R2 de la plantilla).
    if payload.electores_habiles:
        table.electores_habiles = payload.electores_habiles
    table.processed = True
    table.requires_review = False
    table.status = "processed"
    table.ocr_confidence = None  # digitación manual, sin OCR
    db.flush()

    modelos = {
        "district": (DistrictCandidate, "district"),
        "provincial": (ProvincialCandidate, "provincial"),
        "regional": (RegionalCandidate, "regional"),
    }
    modelo, clave = modelos[tipo_registro[tipo]]
    # Sólo compiten las organizaciones del ámbito de este local. El nombre de
    # un partido se repite entre distritos (AHORA NACION - AN compite en 68),
    # así que sin este filtro el acta de un distrito sumaría al de otro.
    # La clave del voto llega como posición en el acta (sort_order, lo que
    # envía el formulario) o como nombre del partido: se aceptan ambas.
    oferta = list(candidatos_del_ambito(
        db, modelo, ubigeo_de_nivel(venue.ubigeo, clave)).all())
    partido_a_candidato = {c.party: c for c in oferta if c.party}
    orden_a_candidato = {str(c.sort_order): c for c in oferta}

    columna_principal = resultado.columna_principal
    no_mapeados: list[str] = []
    for columna in payload.columnas:
        if columna.columna.upper() != columna_principal:
            continue  # el conteo oficial del acta sale de la columna principal
        for clave_voto, votos in columna.votos.items():
            candidato = partido_a_candidato.get(clave_voto) or orden_a_candidato.get(str(clave_voto))
            if candidato is None:
                no_mapeados.append(str(clave_voto))
                continue
            registro = (
                db.query(Record)
                .filter(
                    Record.table_id == table.id,
                    Record.candidate_type == clave,
                    Record.candidate_id == candidato.id,
                )
                .first()
            )
            if registro is None:
                db.add(
                    Record(
                        table_id=table.id,
                        candidate_type=clave,
                        candidate_id=candidato.id,
                        votes=int(votos),
                        verified=True,
                    )
                )
            else:
                registro.votes = int(votos)
                registro.verified = True

    principal = next(
        (c for c in payload.columnas if c.columna.upper() == columna_principal), None
    )
    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
    if meta is None:
        meta = ActaMetadata(table_id=table.id)
        db.add(meta)
    if principal is not None:
        meta.votos_blancos = principal.votos_blancos
        meta.votos_nulos = principal.votos_nulos
        meta.votos_impugnados = principal.votos_impugnados
        meta.total_electores = payload.electores_habiles

    db.commit()
    db.refresh(table)

    return {
        "acta_id": table.id,
        "numero_mesa": table.numero_mesa,
        "estado": table.status,
        "validacion": resultado.to_dict(),
        "organizaciones_no_mapeadas": no_mapeados,
    }


@router.get("/review")
def list_review_actas(db: Session = Depends(get_db),
                      usuario: Usuario = Depends(usuario_actual)):
    """Actas flagged for manual review (OCR confidence below threshold).

    Visibles sólo dentro del alcance territorial del usuario.
    """
    ensure_seed_data(db)
    venues_ok = venues_en_alcance_ids(db, usuario)
    tables = (
        db.query(Table)
        .filter(Table.requires_review == True)  # noqa: E712
        .filter(Table.venue_id.in_(venues_ok) if venues_ok is not None else Table.id > 0)
        .order_by(Table.numero_mesa)
        .all()
    )
    return [_serialize_acta(db, t) for t in tables]


@router.get("/{acta_id}")
def get_acta(acta_id: int, db: Session = Depends(get_db),
             usuario: Usuario = Depends(usuario_actual)):
    """Full detail of a single acta (respetando el alcance territorial)."""
    table = db.query(Table).filter(Table.id == acta_id).first()
    if table is None:
        raise HTTPException(status_code=404, detail=f"Acta {acta_id} no encontrada")
    _verificar_venue_en_alcance(db, usuario, table.venue_id)
    return _serialize_acta(db, table)


@router.put("/{acta_id}")
async def update_acta(acta_id: int, payload: ActaUpdatePayload,
                      request: Request, db: Session = Depends(get_db),
                      usuario: Usuario = Depends(requerir_rol(*ROLES_RECTIFICACION))):
    """Validate / correct an acta and persist the reviewed vote counts.

    El PERSONERO sube actas pero no las corrige/valida. El alcance
    territorial aplica a todos salvo rol global (DIGITADOR_GLOBAL /
    SUPER_ADMIN), que rectifica cualquier acta en cualquier estado de
    bloqueo. Toda intervención del Digitador Global queda auditada y dispara
    el recálculo del dashboard en tiempo real.
    """
    from app.services import dashboard_events as _bus
    from app.services.auditoria_actas import registrar_auditoria_acta as _auditar

    table = db.query(Table).filter(Table.id == acta_id).first()
    if table is None:
        raise HTTPException(status_code=404, detail=f"Acta {acta_id} no encontrada")
    _verificar_venue_en_alcance(db, usuario, table.venue_id)

    # Snapshot previo para la auditoría (cabecera + votos + conteos).
    meta_prev = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
    antes = {
        "numero_mesa": table.numero_mesa, "status": table.status,
        "processed": bool(table.processed),
        "requires_review": bool(table.requires_review),
        "ocr_confidence": table.ocr_confidence, "image_url": table.image_url,
        "votos_blancos": meta_prev.votos_blancos if meta_prev else 0,
        "votos_nulos": meta_prev.votos_nulos if meta_prev else 0,
        "votos_impugnados": meta_prev.votos_impugnados if meta_prev else 0,
        "total_electores": meta_prev.total_electores if meta_prev else None,
    }

    if payload.numero_mesa:
        table.numero_mesa = payload.numero_mesa
    if payload.image_url:
        table.image_url = payload.image_url
    if payload.ocr_confidence is not None:
        table.ocr_confidence = payload.ocr_confidence

    _apply_votes(db, table.id, "district", payload.votos_distrital)
    _apply_votes(db, table.id, "provincial", payload.votos_provincial)
    _apply_votes(db, table.id, "regional", payload.votos_regional)

    _upsert_metadata(
        db,
        table.id,
        votos_blancos=payload.votos_blancos,
        votos_nulos=payload.votos_nulos,
        votos_impugnados=payload.votos_impugnados,
        total_electores=payload.total_electores,
    )

    if payload.verified:
        table.processed = True
        table.requires_review = False
        table.status = "processed"

    db.flush()

    # Auditoría obligatoria del rol nacional (append-only, atómica con el acta).
    if es_rol_global(usuario) and usuario.rol == "DIGITADOR_GLOBAL":
        meta_new = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
        despues = {
            **antes,
            "numero_mesa": table.numero_mesa, "status": table.status,
            "processed": bool(table.processed),
            "requires_review": bool(table.requires_review),
            "ocr_confidence": table.ocr_confidence, "image_url": table.image_url,
            "votos_blancos": meta_new.votos_blancos if meta_new else 0,
            "votos_nulos": meta_new.votos_nulos if meta_new else 0,
            "votos_impugnados": meta_new.votos_impugnados if meta_new else 0,
            "total_electores": meta_new.total_electores if meta_new else None,
            "payload": payload.model_dump(),
        }
        _auditar(db, acta_id=table.id, numero_mesa=table.numero_mesa,
                 accion="MODIFICAR", usuario=usuario,
                 valores_anteriores=antes, valores_nuevos=despues,
                 motivo="rectificación vía PUT /api/actas/{id}", request=request)

    db.commit()
    db.refresh(table)

    # Recálculo en tiempo real tras la rectificación nacional.
    if usuario.rol == "DIGITADOR_GLOBAL":
        mesas = db.query(Table).all()
        proc = sum(1 for t in mesas if t.processed and not t.requires_review)
        total = len(mesas)
        await _bus.emitir_evento_acta(
            acta_id=table.id, numero_mesa=table.numero_mesa, accion="MODIFICAR",
            usuario_email=usuario.email,
            resumen={"total_mesas": total, "actas_normales": proc,
                     "avance_pct": round(100.0 * proc / total, 2) if total else 0.0},
        )
    return _serialize_acta(db, table)


@router.post("")
async def create_acta(payload: ActaUpdate, db: Session = Depends(get_db),
                      usuario: Usuario = Depends(requerir_rol(*ROLES_CAPTURA))):
    """
    Save a validated acta (with metadata) to the database.
    Expects the payload to include image_url (from OCR step) and validated vote counts.
    """
    ensure_seed_data(db)

    # We need to associate the acta with a venue. For simplicity, assign to first venue.
    # In a real app, you might have venue info from the OCR or user selection.
    venue = db.query(Venue).first()
    if not venue:
        raise HTTPException(status_code=500, detail="No venues configured")
    venue = validar_alcance_venue(db, usuario, venue.id)

    table = db.query(Table).filter(Table.numero_mesa == payload.numero_mesa).first()
    if table is None:
        table = Table(numero_mesa=payload.numero_mesa, venue_id=venue.id)
        db.add(table)
        db.flush()

    table.processed = True
    table.requires_review = False
    table.status = "processed"
    table.ocr_confidence = payload.ocr_confidence
    table.image_url = payload.image_url
    db.flush()

    _apply_votes(db, table.id, "district", payload.votos_distrital)
    _apply_votes(db, table.id, "provincial", payload.votos_provincial)
    _apply_votes(db, table.id, "regional", payload.votos_regional)

    _upsert_metadata(
        db,
        table.id,
        votos_blancos=payload.votos_blancos,
        votos_nulos=payload.votos_nulos,
        votos_impugnados=payload.votos_impugnados,
        total_electores=payload.total_electores,
    )

    db.commit()
    db.refresh(table)

    # Return the created acta in the same shape as the review list
    return _serialize_acta(db, table)
