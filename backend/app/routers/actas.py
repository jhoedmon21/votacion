"""Actas API router."""
import logging
from pathlib import Path
from uuid import uuid4

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from sqlalchemy.orm import Session

from app.core.auth import (alcance_ubigeos, es_rol_global, requerir_rol,
                           usuario_actual, validar_alcance_venue,
                           venues_en_alcance)
from app.core.database import SessionLocal, get_db
from app.core.models import (ActaMetadata, ActaRechazo, AsignacionPersonero,
                             ConsejeroCandidate, DistrictCandidate,
                             ProvincialCandidate, Record, RegionalCandidate,
                             ROLES_SISTEMA, Table, Usuario, Venue)
from app.core.schemas import (ActaParseResult, ActaUpdate, ActaUpdatePayload,
                              ActaValidacionIn)
from app.core.ubigeo import candidatos_del_ambito, ubigeo_de_nivel
from app.core.ubigeo_catalogo import UBIGEO_DISTRITO, UBIGEO_PROVINCIA
from app.services.acta_validator import ColumnaActa, validar_acta
from app.services.processor import (CLAVE_A_NIVEL, NIVELES_ACTA,
                                    asignar_pie_acta, ensure_seed_data,
                                    obtener_metadata, save_acta,
                                    sincronizar_consolidado_pie,
                                    validar_cierre_acta)
from app.services.storage import storage_service
from app.services.vision import parse_acta

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/actas", tags=["actas"])

CANDIDATE_MODELS = {
    "district": DistrictCandidate,
    "provincial": ProvincialCandidate,
    "consejero": ConsejeroCandidate,
    "regional": RegionalCandidate,
}

# Quién puede cargar y corregir actas del prototipo
# DELEGADO_MESA carga como el PERSONERO (rol del brief para el local de votación)
# DIGITADOR_GLOBAL crea/rectifica a nivel nacional (bypass ubigeo + auditoría).
ROLES_CAPTURA = ("SUPER_ADMIN", "DIGITADOR_GLOBAL", "RESPONSABLE_DISTRITAL", "DELEGADO_MESA", "PERSONERO")
ROLES_RECTIFICACION = ("SUPER_ADMIN", "DIGITADOR_GLOBAL", "COORD_PROVINCIAL", "RESPONSABLE_DISTRITAL")
ROLES_SUPERVISION = ROLES_SISTEMA  # todos pueden consultar


def _ranking(db: Session, table_id: int, candidate_type: str) -> list[dict]:
    """Oferta completa de un nivel para el acta, con los votos digitados.

    Devuelve TODAS las organizaciones del ámbito del local (no sólo las que
    tienen registro): una fila sin votos va con ``votes: 0``. Así el modal de
    edición siempre hidrata las 4 secciones — antes, un acta registrada en
    ceros no tenía registros y el modal quedaba sin filas que editar.
    """
    model = CANDIDATE_MODELS[candidate_type]
    fila = (
        db.query(Venue.ubigeo)
        .join(Table, Table.venue_id == Venue.id)
        .filter(Table.id == table_id)
        .first()
    )
    ambito = ubigeo_de_nivel(fila[0] if fila else "", candidate_type)
    oferta = list(candidatos_del_ambito(db, model, ambito).all())
    votos = {
        r.candidate_id: (r.votes or 0)
        for r in db.query(Record)
        .filter(Record.table_id == table_id, Record.candidate_type == candidate_type)
        .all()
    }
    ranking = [
        {
            "candidate_id": c.sort_order,
            "name": c.name,
            "party": c.party,
            "color": c.color,
            "votes": votos.get(c.id, 0),
            "symbol": c.symbol,
            "photo_url": c.photo_url,
        }
        for c in oferta
    ]
    ranking.sort(key=lambda item: item["candidate_id"])
    return ranking


def _digitador_de_mesa(db: Session, mesa_id: int) -> str | None:
    """Nombre del personero TITULAR más reciente de la mesa (digitador)."""
    from sqlalchemy import desc as _desc

    asig = (
        db.query(AsignacionPersonero)
        .filter(AsignacionPersonero.mesa_id == mesa_id,
                AsignacionPersonero.tipo == "TITULAR")
        .order_by(AsignacionPersonero.created_at.desc(), _desc(AsignacionPersonero.id))
        .first()
    )
    if asig is None:
        return None
    u = db.query(Usuario).filter(Usuario.id == asig.usuario_id).first()
    if u is None:
        return None
    return f"{u.nombres} {u.apellidos}".strip() or u.email


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
        # Nota de cierre (R1): el descuadre contra el papel, si lo hay.
        "observacion": table.observacion,
        "votos_distrital": _ranking(db, table.id, "district"),
        "votos_provincial": _ranking(db, table.id, "provincial"),
        "votos_consejero": _ranking(db, table.id, "consejero"),
        "votos_regional": _ranking(db, table.id, "regional"),
        "votos_blancos": meta.votos_blancos if meta else 0,
        "votos_nulos": meta.votos_nulos if meta else 0,
        "votos_impugnados": meta.votos_impugnados if meta else 0,
        "total_electores": meta.total_electores if meta else 0,
        "total_votantes": meta.total_votantes if meta else None,
        # Pie POR COLUMNA (norma ONPE) para el modal de edición.
        "blancos_distrital": meta.blancos_distrital if meta else 0,
        "nulos_distrital": meta.nulos_distrital if meta else 0,
        "impugnados_distrital": meta.impugnados_distrital if meta else 0,
        "blancos_provincial": meta.blancos_provincial if meta else 0,
        "nulos_provincial": meta.nulos_provincial if meta else 0,
        "impugnados_provincial": meta.impugnados_provincial if meta else 0,
        "blancos_consejero": meta.blancos_consejero if meta else 0,
        "nulos_consejero": meta.nulos_consejero if meta else 0,
        "impugnados_consejero": meta.impugnados_consejero if meta else 0,
        "blancos_regional": meta.blancos_regional if meta else 0,
        "nulos_regional": meta.nulos_regional if meta else 0,
        "impugnados_regional": meta.impugnados_regional if meta else 0,
        # Bloque de auditoría de la ficha: quién digitó, cuándo y qué
        # incidencias del sistema quedaron registradas para esta mesa.
        "digitador": _digitador_de_mesa(db, table.id),
        "actualizada_en": (table.updated_at.isoformat() if table.updated_at else None),
        "incidencias": [
            {"regla": r.regla, "mensaje": r.mensaje,
             "fecha": (r.created_at.isoformat() if r.created_at else None)}
            for r in db.query(ActaRechazo)
            .filter(ActaRechazo.numero_mesa == table.numero_mesa)
            .order_by(ActaRechazo.created_at.desc()).limit(6).all()
        ],
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


def _registrar_rechazo(db: Session, *, numero_mesa: str, tipo_eleccion: str,
                       regla: str, mensaje: str, usuario: Usuario | None) -> None:
    """Deja constancia de un intento de registro rechazado (log R0-R6).

    Escribe en SU PROPIA sesión: al llegar aquí el request ya aplicó votos a
    medias y hacer commit sobre esa sesión los persistiría pese al rechazo.
    Nunca interrumpe el flujo: si el log falla, el rechazo sigue ocurriendo.
    """
    try:
        with SessionLocal() as log_db:
            log_db.add(ActaRechazo(
                numero_mesa=numero_mesa or "?", tipo_eleccion=tipo_eleccion,
                regla=regla, mensaje=(mensaje or "")[:400],
                usuario_email=usuario.email if usuario else None,
            ))
            log_db.commit()
    except Exception:  # noqa: BLE001 — el log no debe romper el rechazo
        logger.warning("No se pudo registrar el rechazo de acta (%s)", regla)


def _ubigeo_del_ambito(db: Session, table_id: int, nivel: str) -> str:
    """Ubigeo que le corresponde a una mesa para un nivel de elección."""
    fila = (
        db.query(Venue.ubigeo)
        .join(Table, Table.venue_id == Venue.id)
        .filter(Table.id == table_id)
        .first()
    )
    return ubigeo_de_nivel(fila[0] if fila else "", nivel)


def _votos_snapshot(db: Session, table_id: int) -> dict:
    """Votos por nivel indexados por CASILLA (sort_order), igual que los ve
    el digitador en el formulario — no por id interno de BD. Así el diff
    del historial de auditoría es legible para un humano.
    """
    out: dict[str, dict[str, int]] = {}
    for tipo, modelo in CANDIDATE_MODELS.items():
        ambito = _ubigeo_del_ambito(db, table_id, tipo)
        casillas = {
            c.id: str(c.sort_order)
            for c in candidatos_del_ambito(db, modelo, ambito).all()
        }
        filas: dict[str, int] = {}
        for r in db.query(Record).filter(
            Record.table_id == table_id, Record.candidate_type == tipo
        ).all():
            casilla = casillas.get(r.candidate_id)
            if casilla is not None:
                filas[casilla] = r.votes or 0
        out[tipo] = filas
    return out


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
    """Create or update the non-candidate metadata of an acta.

    Sólo acepta columnas REALES de ``acta_metadata``: un ``setattr`` con un
    nombre inexistente crea un atributo Python transitorio que SQLAlchemy
    nunca persiste (y encubre bugs del llamador). El pie de votos por nivel
    NO pasa por aquí: usa ``services.processor.asignar_pie_acta``, el único
    punto de escritura del pie y su consolidado.
    """
    validas = {
        c.name for c in ActaMetadata.__table__.columns
        if c.name not in ("id", "table_id", "created_at", "updated_at")
    }
    meta = obtener_metadata(db, table_id)
    for key, value in fields.items():
        if value is None:
            continue
        if key not in validas:
            logger.warning("_upsert_metadata: campo ignorado %r (no es columna)", key)
            continue
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
        # La imagen se normaliza antes de guardar: EXIF → RGB → máx. 1600 px
        # → WebP de alta calidad (peso mínimo, legibilidad intacta).
        # FOTO SIEMPRE ACEPTADA: si falla el procesamiento se guarda el
        # original — la evidencia nunca se rechaza por compresión.
        try:
            from app.services.imagen_acta import procesar_acta
            tmp_path = procesar_acta(tmp_path)[0]
        except Exception:  # noqa: BLE001 — formato exótico/corrupta: respaldo
            logger.warning("Foto sin procesar (se guarda original): %s", file.filename)
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
            "votos_provincial": [v.model_dump() for v in result.votos_provincial],
            "votos_consejero": [v.model_dump() for v in result.votos_consejero],
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

    Revalida con las mismas reglas que ``/validar``. Un descuadre R1 (suma ≠
    votantes) ya NO rechaza el acta: se guarda igual pero queda OBSERVADA
    (requires_review) y fuera del cómputo hasta que el coordinador la
    resuelva. Los bloqueantes de verdad (duplicidad, tope del padrón,
    negativos, ilegible) siguen respondiendo 409.
    """
    ensure_seed_data(db)

    tipo_registro = {"DISTRITAL": "district", "PROVINCIAL": "provincial",
                     "CONSEJERO": "consejero", "REGIONAL": "regional"}
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

    # R5 estricta: la foto del acta es obligatoria — sin evidencia no hay
    # registro (la PWA la sube antes vía /v1/actas/foto).
    if not payload.foto_presente and not payload.image_url:
        raise HTTPException(
            status_code=422,
            detail=(
                "FALTA CARGAR ACTA: la fotografía del acta física es obligatoria. "
                "Tómela en el local y adjúntela antes de enviar."
            ),
        )

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

    # Puerta de la regla de negocio: sólo los BLOQUEANTES (duplicidad, tope
    # del padrón, negativos, ilegible) rechazan el envío con 409. El descuadre
    # R1 (suma ≠ votantes) NO se rechaza: el acta se registra tal cual está
    # el papel y queda OBSERVADA (requires_review) con su nota de descuadre
    # — fuera del cómputo hasta que el coordinador la resuelva.
    if resultado.bloqueantes:
        raise HTTPException(
            status_code=409,
            detail={
                "mensaje": (
                    "NO COINCIDEN LOS DATOS: la suma de votos no cuadra con el "
                    "total de votos emitidos. Corrige los números antes de guardar."
                ),
                "estado_sugerido": resultado.estado_sugerido,
                "diferencia": resultado.diferencia,
                "hallazgos": [h.to_dict() for h in resultado.hallazgos],
            },
        )

    # El padrón digitado queda en la mesa (fija el tope R2 de la plantilla).
    if payload.electores_habiles:
        table.electores_habiles = payload.electores_habiles
    table.ocr_confidence = None  # digitación manual, sin OCR
    db.flush()

    modelos = {
        "district": (DistrictCandidate, "district"),
        "provincial": (ProvincialCandidate, "provincial"),
        "consejero": (ConsejeroCandidate, "consejero"),
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

    # El acta REGIONAL imprime DOS columnas independientes (GOBERNADOR_VICE y
    # CONSEJEROS). La de consejeros regionales se elige POR PROVINCIA, así que
    # sus votos se persisten en el nivel propio ``consejero`` (mismo ámbito
    # provincial), no junto a los del gobernador.
    ofertas = {clave: (partido_a_candidato, orden_a_candidato)}
    if tipo == "REGIONAL":
        cons = list(candidatos_del_ambito(
            db, ConsejeroCandidate, ubigeo_de_nivel(venue.ubigeo, "consejero")).all())
        ofertas["consejero"] = (
            {c.party: c for c in cons if c.party},
            {str(c.sort_order): c for c in cons},
        )

    columna_principal = resultado.columna_principal
    no_mapeados: list[str] = []
    for columna in payload.columnas:
        col = columna.columna.upper()
        if col == "CONSEJEROS" and "consejero" in ofertas:
            destino = "consejero"
        elif col != columna_principal:
            continue  # el conteo oficial del acta sale de la columna principal
        else:
            destino = clave
        partido_a_cand, orden_a_cand = ofertas[destino]
        for clave_voto, votos in columna.votos.items():
            candidato = partido_a_cand.get(clave_voto) or orden_a_cand.get(str(clave_voto))
            if candidato is None:
                no_mapeados.append(str(clave_voto))
                continue
            registro = (
                db.query(Record)
                .filter(
                    Record.table_id == table.id,
                    Record.candidate_type == destino,
                    Record.candidate_id == candidato.id,
                )
                .first()
            )
            if registro is None:
                db.add(
                    Record(
                        table_id=table.id,
                        candidate_type=destino,
                        candidate_id=candidato.id,
                        votes=int(votos),
                        verified=True,
                    )
                )
            else:
                registro.votes = int(votos)
                registro.verified = True

    # Pie POR COLUMNA (norma ONPE), único origen de verdad: el pie del
    # papel se persiste en las columnas del nivel correspondiente y el
    # consolidado histórico se reconstruye desde ellas (asignar_pie_acta).
    # El acta regional trae DOS columnas: GOBERNADOR_VICE (nivel regional)
    # y CONSEJEROS (nivel consejero) — antes el pie de consejeros se perdía.
    principal = next(
        (c for c in payload.columnas if c.columna.upper() == columna_principal), None
    )
    meta = obtener_metadata(db, table.id)
    if payload.electores_habiles:
        meta.total_electores = payload.electores_habiles
    if principal is not None:
        meta.total_votantes = principal.total_votantes or 0
        nivel_principal = CLAVE_A_NIVEL[clave_tipo]
        asignar_pie_acta(
            db, table.id, nivel_principal,
            blancos=principal.votos_blancos, nulos=principal.votos_nulos,
            impugnados=principal.votos_impugnados,
        )
    secundaria = next(
        (c for c in payload.columnas
         if c.columna.upper() == "CONSEJEROS" and clave_tipo == "regional"),
        None,
    )
    if secundaria is not None:
        asignar_pie_acta(
            db, table.id, "consejero",
            blancos=secundaria.votos_blancos, nulos=secundaria.votos_nulos,
            impugnados=secundaria.votos_impugnados,
            sincronizar=False,  # el consolidado sigue a la columna principal
        )

    # Validación de cierre PRE-COMMIT (R1): la suma física de cada columna
    # contra el total del papel. Un descuadre no rechaza: el acta queda
    # OBSERVADA con la nota para el coordinador, sin duplicar contadores.
    columnas_cierre: list[dict] = []
    for col in (principal, secundaria):
        if col is None:
            continue
        columnas_cierre.append({
            "nombre": col.columna.upper(),
            "validos": sum(int(v) for v in col.votos.values()),
            "blancos": col.votos_blancos or 0,
            "nulos": col.votos_nulos or 0,
            "impugnados": col.votos_impugnados or 0,
            "papel": col.total_votantes or 0,
        })
    cierre = validar_cierre_acta(table, columnas=columnas_cierre)

    db.commit()
    db.refresh(table)

    return {
        "acta_id": table.id,
        "numero_mesa": table.numero_mesa,
        "estado": table.status,
        "cuadre": cierre,
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


@router.get("/{acta_id}/auditoria")
def get_auditoria_acta(acta_id: int, db: Session = Depends(get_db),
                       usuario: Usuario = Depends(usuario_actual)):
    """Historial de ediciones del acta (huella de auditoría).

    Devuelve cada intervención MODIFICAR/CREAR con usuario, rol, timestamp,
    IP, motivo y los valores anteriores/nuevos (JSON) para mostrar el diff
    en la ficha. Respeta el alcance territorial de quien consulta.
    """
    from app.core.models import ActaAuditoriaGlobal

    table = db.query(Table).filter(Table.id == acta_id).first()
    if table is None:
        raise HTTPException(status_code=404, detail=f"Acta {acta_id} no encontrada")
    _verificar_venue_en_alcance(db, usuario, table.venue_id)
    filas = (
        db.query(ActaAuditoriaGlobal)
        .filter(ActaAuditoriaGlobal.acta_id == acta_id)
        .order_by(ActaAuditoriaGlobal.created_at.desc())
        .limit(30)
        .all()
    )

    import json as _json

    def _safe_json(txt: str | None) -> dict:
        try:
            d = _json.loads(txt or "{}")
            return d if isinstance(d, dict) else {}
        except Exception:  # noqa: BLE001 — huella corrupta no rompe la ficha
            return {}

    return {
        "acta_id": acta_id,
        "numero_mesa": table.numero_mesa,
        "total": len(filas),
        "items": [
            {
                "id": f.id,
                "accion": f.accion,
                "usuario": f.usuario_email,
                "rol": f.usuario_rol,
                "ip": f.ip,
                "motivo": f.motivo,
                "fecha": (f.created_at.isoformat() if f.created_at else None),
                "antes": _safe_json(f.valores_anteriores),
                "despues": _safe_json(f.valores_nuevos),
            }
            for f in filas
        ],
    }


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

    # R5 estricta también en la rectificación: una corrección sin la foto del
    # acta no es verificable. Sólo se permite si ya tiene imagen o si la
    # corrección adjunta una (el modal la sube vía /v1/actas/foto).
    if not (table.image_url or payload.image_url):
        raise HTTPException(
            status_code=422,
            detail=(
                "FALTA CARGAR ACTA: adjunte la fotografía del acta física antes de "
                "guardar la corrección. Es obligatoria como evidencia."
            ),
        )

    # Snapshot previo para la auditoría (cabecera + votos + conteos).
    meta_prev = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
    antes = {
        "numero_mesa": table.numero_mesa, "status": table.status,
        "processed": bool(table.processed),
        "requires_review": bool(table.requires_review),
        "ocr_confidence": table.ocr_confidence, "image_url": table.image_url,
        "observacion": table.observacion,
        "votos_blancos": meta_prev.votos_blancos if meta_prev else 0,
        "votos_nulos": meta_prev.votos_nulos if meta_prev else 0,
        "votos_impugnados": meta_prev.votos_impugnados if meta_prev else 0,
        "total_electores": meta_prev.total_electores if meta_prev else None,
        "total_votantes": meta_prev.total_votantes if meta_prev else None,
        "votos": _votos_snapshot(db, table.id),
    }
    # Trazabilidad: toda rectificación de un acta OBSERVADA exige motivo.
    # La petición llega ANTES de aplicar cambios, así que el estado previo
    # aún está vivo en la sesión.
    estaba_observada = bool(table.requires_review)
    motivo_edicion = (payload.motivo or "").strip()
    if estaba_observada and not motivo_edicion:
        raise HTTPException(
            status_code=422,
            detail={
                "mensaje": (
                    "MOTIVO REQUERIDO: el acta está OBSERVADA; indique la "
                    "justificación de la modificación antes de guardar."
                ),
                "regla": "MOTIVO_OBLIGATORIO",
            },
        )

    if payload.numero_mesa:
        table.numero_mesa = payload.numero_mesa
    if payload.image_url:
        table.image_url = payload.image_url
    # Métricas del procesamiento WebP (si el cliente las trae).
    metricas = {k: v for k, v in (
        ("image_peso_original_kb", payload.image_peso_original_kb),
        ("image_peso_final_kb", payload.image_peso_final_kb),
    ) if v is not None}
    if metricas:
        _upsert_metadata(db, table.id, **metricas)
    if payload.ocr_confidence is not None:
        table.ocr_confidence = payload.ocr_confidence

    _apply_votes(db, table.id, "district", payload.votos_distrital)
    _apply_votes(db, table.id, "provincial", payload.votos_provincial)
    _apply_votes(db, table.id, "consejero", payload.votos_consejero)
    _apply_votes(db, table.id, "regional", payload.votos_regional)

    # ---- Pie por columna (norma ONPE): ÚNICO origen de verdad ----
    # Resolución EFECTIVA por nivel antes de persistir: lo explícito del
    # payload; si el nivel se digitó sin pie propio (modal rápido que envía
    # el consolidado), ese consolidado ES su pie; un nivel ausente conserva
    # el persistido (un PUT parcial no pisa con ceros lo ya digitado).
    # La validación y la persistencia usan ESTOS mismos números: antes el
    # cuadre se validaba con unos valores y se persistían otros.
    # obtener_metadata (con flush) evita duplicar filas de metadata cuando
    # el PUT parcial ya la creó más arriba sin flush (autoflush=False).
    _meta_efectiva = obtener_metadata(db, table.id)

    def _pie_persistido(nivel: str) -> tuple[int, int, int]:
        if _meta_efectiva is None:
            return 0, 0, 0
        b = getattr(_meta_efectiva, f"blancos_{nivel}", 0) or 0
        n = getattr(_meta_efectiva, f"nulos_{nivel}", 0) or 0
        i = getattr(_meta_efectiva, f"impugnados_{nivel}", 0) or 0
        if b + n + i == 0:  # acta histórica sin pie por columna
            b = _meta_efectiva.votos_blancos or 0
            n = _meta_efectiva.votos_nulos or 0
            i = _meta_efectiva.votos_impugnados or 0
        return b, n, i

    _genericos = (payload.votos_blancos, payload.votos_nulos,
                  payload.votos_impugnados)
    _hay_generico = any(v is not None for v in _genericos)
    _digitados_sin_pie = [
        nivel for nivel, lista in (
            ("distrital", payload.votos_distrital),
            ("provincial", payload.votos_provincial),
            ("consejero", payload.votos_consejero),
            ("regional", payload.votos_regional),
        )
        if lista and all(getattr(payload, f"{_p}_{nivel}") is None
                         for _p in ("blancos", "nulos", "impugnados"))
    ]

    _pie: dict[str, tuple[int, int, int]] = {}
    _pie_a_persistir: dict[str, tuple[int, int, int]] = {}
    for _nivel in NIVELES_ACTA:
        _b = getattr(payload, f"blancos_{_nivel}", None)
        _n = getattr(payload, f"nulos_{_nivel}", None)
        _i = getattr(payload, f"impugnados_{_nivel}", None)
        if _b is None and _n is None and _i is None:
            if (_hay_generico and len(_digitados_sin_pie) == 1
                    and _nivel == _digitados_sin_pie[0]):
                # Modal rápido: el pie del formulario es el pie del nivel
                # digitado (contrato histórico del payload).
                _b, _n, _i = _genericos
            else:
                _pie[_nivel] = _pie_persistido(_nivel)
                continue  # nivel ausente: se conserva el pie persistido
        _pie[_nivel] = (_b or 0, _n or 0, _i or 0)
        _pie_a_persistir[_nivel] = _pie[_nivel]

    # Persistencia del pie por nivel (única vía: asignar_pie_acta). El
    # consolidado histórico se RECONSTRUYE desde las columnas por nivel —
    # nunca se asigna en paralelo desde el payload (doble escritura).
    for _nivel, (_b, _n, _i) in _pie_a_persistir.items():
        asignar_pie_acta(db, table.id, _nivel, blancos=_b, nulos=_n,
                         impugnados=_i, sincronizar=False)
    if _pie_a_persistir:
        sincronizar_consolidado_pie(db, obtener_metadata(db, table.id))

    _upsert_metadata(
        db,
        table.id,
        total_electores=payload.total_electores,
        total_votantes=payload.total_votantes,
    )

    # La suma de votos debe cuadrar contra los VOTANTES que sufragaron
    # (cabecera del acta), no contra los electores hábiles. Un descuadre no
    # impide registrar: el acta queda OBSERVADA para revisión del
    # coordinador. R2 (más votantes que electores) sí bloquea.
    # Integridad sobre los valores EFECTIVOS (payload si viene; si no, los
    # ya persistidos): en un PUT parcial los campos ausentes no son cero.

    def _suma_nivel(lista_payload, tipo: str) -> int:
        """Suma del nivel: la del payload si viene; si no, la persistida."""
        if lista_payload is not None:
            return sum(v.votes for v in lista_payload)
        return sum(
            r.votes or 0
            for r in db.query(Record)
            .filter(Record.table_id == table.id, Record.candidate_type == tipo)
            .all()
        )

    votantes = (
        payload.total_votantes
        if payload.total_votantes is not None
        else (_meta_efectiva.total_votantes or 0 if _meta_efectiva else 0)
    )
    # Regla ONPE por COLUMNA: cada nivel tiene su propio pie (blancos,
    # nulos, impugnados) y cuadra independientemente con los votantes de la
    # cabecera. El pie EFECTIVO ya quedó resuelto por nivel en ``_pie``.
    def _otros_de(nivel: str, lista_payload) -> int:
        """Blancos+nulos+impugnados efectivos del nivel (resueltos arriba)."""
        _b, _n, _i = _pie.get(nivel, (0, 0, 0))
        return _b + _n + _i

    def _nivel_activo(tipo: str, lista_payload) -> bool:
        """El nivel participa del cuadre si fue enviado (con oferta) o ya
        tiene registros. Una lista VACÍA no activa: muchas mesas no tienen
        oferta distrital y el editor la envía como [] — tratarla como activa
        con suma 0 producía 409 falsos de descuadre al guardar."""
        if lista_payload is not None:
            return len(lista_payload) > 0
        return (
            db.query(Record.id)
            .filter(Record.table_id == table.id, Record.candidate_type == tipo)
            .first()
            is not None
        )

    _columnas = {
        "district": (_suma_nivel(payload.votos_distrital, "district"),
                     _otros_de("distrital", payload.votos_distrital),
                     payload.votos_distrital),
        "provincial": (_suma_nivel(payload.votos_provincial, "provincial"),
                       _otros_de("provincial", payload.votos_provincial),
                       payload.votos_provincial),
        "consejero": (_suma_nivel(payload.votos_consejero, "consejero"),
                      _otros_de("consejero", payload.votos_consejero),
                      payload.votos_consejero),
        "regional": (_suma_nivel(payload.votos_regional, "regional"),
                     _otros_de("regional", payload.votos_regional),
                     payload.votos_regional),
    }
    # Sólo cuadran las columnas ACTIVAS (enviadas en el PUT o con registros
    # persistidos): una rectificación parcial no exige niveles ausentes.
    _activas = {
        k: votos + otros
        for k, (votos, otros, lista) in _columnas.items()
        if _nivel_activo(k, lista)
    }
    suma_total = max(_activas.values()) if _activas else 0
    # R2 SIEMPRE contra el padrón REAL de la mesa (tables.electores_habiles,
    # fuente ONPE): la metadata puede estar vacía/vieja o el formulario traer
    # otro valor; un acta con votantes > padrón es imposible y se bloquea.
    excede_padron = bool(
        (table.electores_habiles or 0) and votantes > table.electores_habiles
    )
    # R0: acta vacía — todo en ceros no es un acta registrable (0 = 0 cuadra,
    # pero nadie digitó los votos del papel).
    acta_vacia = votantes == 0 and suma_total == 0

    # R6 — Concentración atípica (>90% de los votos válidos de una columna
    # en una sola organización): exige reconfirmación contra el acta física.
    if not payload.confirmado_atipico and not payload.forzar_revision:
        for _nivel, _lista in (("distrital", payload.votos_distrital),
                               ("provincial", payload.votos_provincial),
                               ("consejero", payload.votos_consejero),
                               ("regional", payload.votos_regional)):
            _lista = _lista or []
            _total_nivel = sum(v.votes for v in _lista)
            if _total_nivel <= 0:
                continue
            _maximo = max(v.votes for v in _lista)
            if _maximo > 0.9 * _total_nivel:
                _registrar_rechazo(db, numero_mesa=table.numero_mesa,
                                   tipo_eleccion="RECTIFICACION",
                                   regla="R6_CONCENTRACION",
                                   mensaje=f"max={_maximo} de {_total_nivel} en {_nivel}",
                                   usuario=usuario)
                raise HTTPException(
                    status_code=409,
                    detail={
                        "mensaje": (
                            f"VOTOS INUSUALES: la organización líder concentra "
                            f"{_maximo} de {_total_nivel} votos válidos de la "
                            f"columna {_nivel} "
                            f"({round(100 * _maximo / _total_nivel, 1)}%). "
                            "Verifique contra el acta física y confirme la "
                            "digitación."
                        ),
                        "regla": "R6_CONCENTRACION",
                        "requiere_confirmacion": True,
                    },
                )

    # R1 conocido — Control de calidad: enviar a Revisión / Acta Observada
    # en lugar de guardar (el digitador reconoce el descuadre del papel).
    if payload.forzar_revision:
        table.processed = False
        table.requires_review = True
        table.status = "requires_review"
        table.observacion = (
            f"Enviada a Revisión (control de calidad): {motivo_edicion}"
            if motivo_edicion
            else "Enviada a Revisión (control de calidad)"
        )
        db.flush()
        db.commit()
        db.refresh(table)
        return _serialize_acta(db, table)

    if acta_vacia:
        _registrar_rechazo(db, numero_mesa=table.numero_mesa,
                           tipo_eleccion="RECTIFICACION", regla="R0_ACTA_VACIA",
                           mensaje="Acta en ceros", usuario=usuario)
        raise HTTPException(
            status_code=409,
            detail={
                "mensaje": (
                    "ACTA VACÍA: no se registró ningún voto (todo en ceros). "
                    "Verifique contra el acta física y digite los totales reales "
                    "antes de guardar."
                ),
                "regla": "R0_ACTA_VACIA",
            },
        )

    # R2 (más votantes que electores hábiles) es físicamente IMPOSIBLE: es
    # el único descuadre que sigue rechazándose con 409 — un acta así no se
    # registra ni observa: se corrige contra el papel.
    if excede_padron:
        _registrar_rechazo(db, numero_mesa=table.numero_mesa,
                           tipo_eleccion="RECTIFICACION",
                           regla="R2_TOPE_ELECTORES",
                           mensaje=f"suma={suma_total} vs votantes={votantes}",
                           usuario=usuario)
        raise HTTPException(
            status_code=409,
            detail={
                "mensaje": (
                    f"MESA DESCUADRADA — IMPOSIBLE: los votantes que sufragaron "
                    f"({votantes}) superan los electores hábiles del padrón "
                    f"({table.electores_habiles}); excedente de "
                    f"{votantes - (table.electores_habiles or 0)} votos. Verifique "
                    "el acta física."
                ),
                "diferencia": votantes - suma_total,
                "suma": suma_total,
                "votantes": votantes,
            },
        )

    # Validación de cierre PRE-COMMIT (R1/R7, norma ONPE): la suma física
    # de cada columna activa (votos válidos + SU pie) contra los votantes
    # del papel. Un descuadre NO rechaza: los contadores ya persistidos se
    # conservan tal cual y el acta queda OBSERVADA con la nota del descuadre
    # para el coordinador. La promoción a contabilizada sólo ocurre con
    # ``verified`` (rectificación final del flujo).
    _etiqueta_cierre = {"district": "Distrital", "provincial": "Provincial",
                        "consejero": "Consejeros", "regional": "Regional"}
    columnas_cierre: list[dict] = []
    for _clave, (_votos_nivel, _otros_nivel, _lista) in _columnas.items():
        if not _nivel_activo(_clave, _lista):
            continue
        _nivel = CLAVE_A_NIVEL[_clave]
        _b, _n, _i = _pie.get(_nivel, (0, 0, 0))
        columnas_cierre.append({
            "nombre": _etiqueta_cierre[_clave],
            "validos": _votos_nivel,
            "blancos": _b, "nulos": _n, "impugnados": _i,
            "papel": votantes,
        })
    cierre = validar_cierre_acta(
        table,
        total_papel=votantes,
        columnas=columnas_cierre or None,
        marcar_procesada=payload.verified,
    )
    db.flush()

    # Auditoría UNIVERSAL (append-only, atómica con el acta): toda edición
    # deja huella con usuario, timestamp, valores anteriores vs. nuevos y
    # motivo (obligatorio si el acta estaba observada).
    meta_new = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
    despues = {
        **antes,
        "numero_mesa": table.numero_mesa, "status": table.status,
        "processed": bool(table.processed),
        "requires_review": bool(table.requires_review),
        "ocr_confidence": table.ocr_confidence, "image_url": table.image_url,
        "observacion": table.observacion,
        "votos_blancos": meta_new.votos_blancos if meta_new else 0,
        "votos_nulos": meta_new.votos_nulos if meta_new else 0,
        "votos_impugnados": meta_new.votos_impugnados if meta_new else 0,
        "total_electores": meta_new.total_electores if meta_new else None,
        "total_votantes": meta_new.total_votantes if meta_new else None,
        "votos": _votos_snapshot(db, table.id),
    }
    if despues != antes:
        _auditar(db, acta_id=table.id, numero_mesa=table.numero_mesa,
                 accion="MODIFICAR", usuario=usuario,
                 valores_anteriores=antes, valores_nuevos=despues,
                 motivo=motivo_edicion or "rectificación vía PUT /api/actas/{id}",
                 request=request)

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
    respuesta = _serialize_acta(db, table)
    respuesta["cuadre"] = cierre
    return respuesta


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

    table.ocr_confidence = payload.ocr_confidence
    table.image_url = payload.image_url

    # Nivel cuyo pie escribe el registro: el que traiga votos digitados
    # (el modal rápido digita DISTRITAL; el formulario por pestañas, el activo).
    _nivel_digitado = next(
        (_n for _n, _l in (("distrital", payload.votos_distrital),
                           ("provincial", payload.votos_provincial),
                           ("consejero", payload.votos_consejero),
                           ("regional", payload.votos_regional)) if _l),
        None,
    )

    _apply_votes(db, table.id, "district", payload.votos_distrital)
    _apply_votes(db, table.id, "provincial", payload.votos_provincial)
    _apply_votes(db, table.id, "consejero", payload.votos_consejero)
    _apply_votes(db, table.id, "regional", payload.votos_regional)

    # Pie POR COLUMNA (norma ONPE), único origen de verdad: el formulario
    # digita UN nivel y envía su pie como votos_blancos/nulos/impugnados
    # (los campos por nivel de ActaUpdate son default 0, no None), así que
    # el pie del nivel digitado es el del formulario salvo que traiga pie
    # específico. El consolidado se reconstruye desde las columnas por
    # nivel. Antes la asignación iteraba los CARACTERES del nombre del
    # nivel (blancos_d, blancos_i, …) creando atributos fantasma que
    # SQLAlchemy nunca persistía.
    for _nivel, _lista in (("distrital", payload.votos_distrital),
                           ("provincial", payload.votos_provincial),
                           ("consejero", payload.votos_consejero),
                           ("regional", payload.votos_regional)):
        if not _lista:
            continue
        _b = getattr(payload, f"blancos_{_nivel}", 0) or 0
        _n = getattr(payload, f"nulos_{_nivel}", 0) or 0
        _i = getattr(payload, f"impugnados_{_nivel}", 0) or 0
        if _b + _n + _i == 0 and _nivel == _nivel_digitado:
            _b = payload.votos_blancos or 0
            _n = payload.votos_nulos or 0
            _i = payload.votos_impugnados or 0
        asignar_pie_acta(db, table.id, _nivel, blancos=_b, nulos=_n,
                         impugnados=_i,
                         sincronizar=_nivel == _nivel_digitado)

    if _nivel_digitado is None and (
        payload.votos_blancos or payload.votos_nulos or payload.votos_impugnados
    ):
        # Sin nivel digitado no hay columna a la que pertenezca el pie: se
        # alimenta sólo el consolidado (mismo criterio que el flujo OCR).
        _meta_sin_nivel = obtener_metadata(db, table.id)
        _meta_sin_nivel.votos_blancos = payload.votos_blancos or 0
        _meta_sin_nivel.votos_nulos = payload.votos_nulos or 0
        _meta_sin_nivel.votos_impugnados = payload.votos_impugnados or 0

    _upsert_metadata(
        db,
        table.id,
        total_electores=payload.total_electores,
        total_votantes=payload.total_votantes,
    )

    # Misma regla de cierre que en PUT: CADA columna cuadra independientemente
    # contra los votantes de la cabecera. Un descuadre R1 ya no rechaza: el
    # acta se registra OBSERVADA con su nota (fuera del cómputo hasta que
    # el coordinador la resuelva). R0/R2 siguen siendo bloqueantes.
    votantes = payload.total_votantes or 0

    def _pie_nivel(nivel: str) -> int:
        return ((getattr(payload, f"blancos_{nivel}", 0) or 0)
                + (getattr(payload, f"nulos_{nivel}", 0) or 0)
                + (getattr(payload, f"impugnados_{nivel}", 0) or 0))

    pie_generico = ((payload.votos_blancos or 0) + (payload.votos_nulos or 0)
                    + (payload.votos_impugnados or 0))
    # Cada columna activa = votos + SU pie. Si el nivel digitado no trae pie
    # específico, se usa el genérico del formulario (así lo envían el modal
    # rápido y el formulario por pestañas).
    sumas_columna: dict[str, int] = {}
    for _clave, _nivel, _lista in (
        ("district", "distrital", payload.votos_distrital),
        ("provincial", "provincial", payload.votos_provincial),
        ("consejero", "consejero", payload.votos_consejero),
        ("regional", "regional", payload.votos_regional),
    ):
        if not _lista:
            continue
        pie = _pie_nivel(_nivel)
        if pie == 0 and _nivel == _nivel_digitado:
            pie = pie_generico
        sumas_columna[_clave] = sum(v.votes for v in _lista) + pie
    activas = {k: s for k, s in sumas_columna.items() if s > 0}
    suma_total = max(activas.values()) if activas else 0
    # R2 SIEMPRE contra el padrón REAL de la mesa (tables.electores_habiles,
    # fuente ONPE), no contra el valor que traiga el formulario.
    excede_padron = bool(
        (table.electores_habiles or 0) and votantes > table.electores_habiles
    )
    acta_vacia = votantes == 0 and suma_total == 0

    def _rechazo(regla: str, mensaje: str, detalle: dict) -> HTTPException:
        # Log de rechazos en SU PROPIA sesión: la del request tiene cambios a
        # medias (records de _apply_votes) y hacer commit aquí los persistía
        # incompletos. Nunca rompe el rechazo.
        try:
            with SessionLocal() as log_db:
                log_db.add(ActaRechazo(
                    numero_mesa=table.numero_mesa, tipo_eleccion="REGISTRO",
                    regla=regla, mensaje=(mensaje or "")[:400],
                    usuario_email=usuario.email,
                ))
                log_db.commit()
        except Exception:  # noqa: BLE001
            logger.warning("No se pudo registrar el rechazo de acta (%s)", regla)
        return HTTPException(status_code=409, detail={"mensaje": mensaje, **detalle})

    # R6 — Concentración atípica: una organización con >90% de los votos
    # válidos exige reconfirmación contra el acta física (checkbox del modal)
    # salvo que el digitador ya la haya enviado a Revisión.
    if not payload.confirmado_atipico and not payload.forzar_revision:
        # Votos VÁLIDOS por organización (sin blancos/nulos/impugnados): la
        # concentración se mide por CANDIDATO dentro de cada columna activa.
        for _nivel, _lista in (("distrital", payload.votos_distrital),
                               ("provincial", payload.votos_provincial),
                               ("consejero", payload.votos_consejero),
                               ("regional", payload.votos_regional)):
            _lista = _lista or []
            _total_nivel = sum(v.votes for v in _lista)
            if _total_nivel <= 0:
                continue
            _maximo = max(v.votes for v in _lista)
            if _maximo > 0.9 * _total_nivel:
                raise _rechazo(
                    "R6_CONCENTRACION",
                    f"VOTOS INUSUALES: la organización líder concentra "
                    f"{_maximo} de {_total_nivel} votos válidos de la columna "
                    f"{_nivel} ({round(100 * _maximo / _total_nivel, 1)}%). "
                    "Verifique contra el acta física y confirme la digitación.",
                    {"regla": "R6_CONCENTRACION", "requiere_confirmacion": True},
                )

    # R1 conocido — Control de calidad: enviar a Revisión / Acta Observada
    # en lugar de guardar (el digitador reconoce el descuadre del papel).
    if payload.forzar_revision:
        table.processed = False
        table.requires_review = True
        table.status = "requires_review"
        table.observacion = "Enviada a Revisión (control de calidad)"
        db.flush()
        db.commit()
        db.refresh(table)
        return _serialize_acta(db, table)

    if acta_vacia:
        raise _rechazo(
            "R0_ACTA_VACIA",
            "ACTA VACÍA: no se registró ningún voto (todo en ceros). Verifique "
            "contra el acta física y digite los totales reales antes de guardar.",
            {"regla": "R0_ACTA_VACIA"},
        )
    # R2 (votantes > padrón) es físicamente imposible: sigue bloqueando.
    if excede_padron:
        raise _rechazo(
            "R2_TOPE_ELECTORES",
            f"MESA DESCUADRADA — IMPOSIBLE: los votantes que sufragaron "
            f"({votantes}) superan los electores hábiles del padrón "
            f"({table.electores_habiles}); excedente de "
            f"{votantes - (table.electores_habiles or 0)} votos. Verifique "
            "el acta física.",
            {
                "regla": "R2_TOPE_ELECTORES",
                "diferencia": votantes - suma_total,
                "suma": suma_total,
                "votantes": votantes,
            },
        )

    # Validación de cierre PRE-COMMIT (R1/R7, norma ONPE): la suma física
    # de cada columna activa contra los votantes del papel. Un descuadre NO
    # rechaza: el acta queda OBSERVADA con la nota del descuadre, sin
    # duplicar contadores (los votos y el pie ya se persistieron UNA vez).
    _etiqueta_cierre = {"district": "Distrital", "provincial": "Provincial",
                        "consejero": "Consejeros", "regional": "Regional"}
    columnas_cierre: list[dict] = []
    for _clave, _nivel, _lista in (
        ("district", "distrital", payload.votos_distrital),
        ("provincial", "provincial", payload.votos_provincial),
        ("consejero", "consejero", payload.votos_consejero),
        ("regional", "regional", payload.votos_regional),
    ):
        if not _lista:
            continue
        _b, _n, _i = (
            (getattr(payload, f"blancos_{_nivel}", None) or 0),
            (getattr(payload, f"nulos_{_nivel}", None) or 0),
            (getattr(payload, f"impugnados_{_nivel}", None) or 0),
        )
        if _b + _n + _i == 0 and _nivel == _nivel_digitado:
            _b, _n, _i = (payload.votos_blancos or 0, payload.votos_nulos or 0,
                          payload.votos_impugnados or 0)
        columnas_cierre.append({
            "nombre": _etiqueta_cierre[_clave],
            "validos": sum(v.votes for v in _lista),
            "blancos": _b, "nulos": _n, "impugnados": _i,
            "papel": votantes,
        })
    cierre = validar_cierre_acta(
        table,
        votos_blancos=payload.votos_blancos,
        votos_nulos=payload.votos_nulos,
        votos_impugnados=payload.votos_impugnados,
        total_papel=votantes,
        columnas=columnas_cierre or None,
    )
    db.flush()

    db.commit()
    db.refresh(table)

    # Return the created acta in the same shape as the review list, con el
    # diagnóstico del cierre (detalle del descuadre, si lo hay).
    respuesta = _serialize_acta(db, table)
    respuesta["cuadre"] = cierre
    return respuesta
