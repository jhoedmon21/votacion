"""Digitador Global — CRUD nacional de actas con auditoría obligatoria.

* Alcance nacional: omite todo filtro ubigeo (ver ``es_rol_global`` /
  ``omitir_scope_geografico`` en ``app/core/auth.py``) y puede rectificar
  actas en cualquier estado de bloqueo (``processed`` / ``requires_review``).
* Auditoría obligatoria: cada CREAR/MODIFICAR INSERTA en
  ``acta_auditoria_global`` (usuario, IP, timestamp, antes/después en JSON).
* Tiempo real: tras cada mutación emite ``acta.actualizada`` al dashboard
  (WebSocket + invalidación de cache) vía ``dashboard_events``.

Sólo ``DIGITADOR_GLOBAL`` y ``SUPER_ADMIN`` (ver ``requerir_rol``).
"""
from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.orm import Session

from app.core.auth import requerir_rol
from app.core.database import get_db
from app.core.models import (ActaAuditoriaGlobal, ActaMetadata,
                              DistrictCandidate, ProvincialCandidate, Record,
                              RegionalCandidate, Table, Usuario, Venue)
from app.core.schemas import (ActaAuditoriaOut, DigitadorActaCrearIn,
                               DigitadorActaRectificarIn)
from app.core.ubigeo import candidatos_del_ambito, ubigeo_de_nivel
from app.services import dashboard_events as bus
from app.services.auditoria_actas import (ip_de_request,
                                           registrar_auditoria_acta,
                                           serializar_auditoria)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/digitador", tags=["digitador-global"])

# Sólo el rol nacional crea/rectifica sin filtro territorial.
ROL_NACIONAL = ("DIGITADOR_GLOBAL", "SUPER_ADMIN")

CANDIDATE_MODELS = {
    "district": DistrictCandidate,
    "provincial": ProvincialCandidate,
    "regional": RegionalCandidate,
}


# ---------------------------------------------------------------------------
# Helpers de snapshot (antes/después en JSON para la auditoría)
# ---------------------------------------------------------------------------

def _snapshot_votos(db: Session, table_id: int) -> dict[str, Any]:
    """Foto actual de votos + conteos del acta (para el diff de auditoría)."""
    filas = db.query(Record).filter(Record.table_id == table_id).all()
    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table_id).first()
    return {
        "votos": sorted(
            ({"tipo": r.candidate_type, "candidate_id": r.candidate_id,
              "votos": r.votes or 0, "verificado": bool(r.verified)} for r in filas),
            key=lambda x: (x["tipo"], x["candidate_id"]),
        ),
        "votos_blancos": meta.votos_blancos if meta else 0,
        "votos_nulos": meta.votos_nulos if meta else 0,
        "votos_impugnados": meta.votos_impugnados if meta else 0,
        "total_electores": meta.total_electores if meta else None,
    }


def _snapshot_tabla(table: Table | None) -> dict[str, Any]:
    """Foto de la cabecera de la mesa (estado de bloqueo incluido)."""
    if table is None:
        return {"existe": False}
    return {
        "existe": True,
        "id": table.id,
        "numero_mesa": table.numero_mesa,
        "venue_id": table.venue_id,
        "status": table.status,
        "processed": bool(table.processed),
        "requires_review": bool(table.requires_review),
        "ocr_confidence": table.ocr_confidence,
        "image_url": table.image_url,
    }


def _aplicar_votos_nivel(
    db: Session, table_id: int, nivel: str, votos: list | None
) -> int:
    """Upsert de votos de un nivel acotado al ámbito del local.

    Retorna el n° de filas tocadas. Ignora posiciones fuera de la oferta del
    ámbito (mismo filtro anti-homónimos que ``actas._apply_votes``).
    """
    if not votos:
        return 0
    venue_ubigeo = (
        db.query(Venue.ubigeo).join(Table, Table.venue_id == Venue.id)
        .filter(Table.id == table_id).scalar() or ""
    )
    ambito = ubigeo_de_nivel(venue_ubigeo, nivel)
    id_por_orden = {
        c.sort_order: c.id
        for c in candidatos_del_ambito(db, CANDIDATE_MODELS[nivel], ambito).all()
    }
    tocadas = 0
    for item in votos:
        orden = item["candidate_id"] if isinstance(item, dict) else item.candidate_id
        votos_n = item["votes"] if isinstance(item, dict) else item.votes
        cid = id_por_orden.get(orden)
        if cid is None:
            continue
        reg = (
            db.query(Record)
            .filter(Record.table_id == table_id,
                    Record.candidate_type == nivel,
                    Record.candidate_id == cid).first()
        )
        if reg is None:
            db.add(Record(table_id=table_id, candidate_type=nivel,
                          candidate_id=cid, votes=int(votos_n or 0), verified=True))
        else:
            reg.votes = int(votos_n or 0)
            reg.verified = True
        tocadas += 1
    return tocadas


def _resumen_nacional_minimo(db: Session) -> dict[str, Any]:
    """Resumen nacional ligero para el evento del dashboard."""
    from sqlalchemy import func

    mesas = db.query(Table).all()
    proc = [t for t in mesas if t.processed and not t.requires_review]
    obs = [t for t in mesas if t.requires_review]
    total = len(mesas)
    return {
        "total_mesas": total,
        "actas_normales": len(proc),
        "actas_observadas": len(obs),
        "avance_pct": round(100.0 * len(proc) / total, 2) if total else 0.0,
    }


async def _emitir_recalculo(
    *, db: Session, acta_id: int, numero_mesa: str,
    accion: str, usuario: Usuario,
) -> dict[str, Any]:
    """Dispara la recalculación de métricas en tiempo real (WS + cache)."""
    resumen = _resumen_nacional_minimo(db)
    resultado = await bus.emitir_evento_acta(
        acta_id=acta_id, numero_mesa=numero_mesa, accion=accion,
        usuario_email=usuario.email, resumen=resumen,
    )
    return {"version": resultado["evento"]["version"],
            "broadcast_a": resultado["broadcast_a"], "resumen": resumen}


def _serializar_acta(db: Session, table: Table) -> dict[str, Any]:
    """Acta completa (misma forma que GET /api/actas/{id})."""
    venue = db.query(Venue).filter(Venue.id == table.venue_id).first()
    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
    return {
        "id": table.id, "numero_mesa": table.numero_mesa, "status": table.status,
        "processed": bool(table.processed),
        "requires_review": bool(table.requires_review),
        "ocr_confidence": table.ocr_confidence, "image_url": table.image_url,
        "venue_id": table.venue_id, "venue_name": venue.name if venue else None,
        "venue_ubigeo": venue.ubigeo if venue else None,
        "votos_blancos": meta.votos_blancos if meta else 0,
        "votos_nulos": meta.votos_nulos if meta else 0,
        "votos_impugnados": meta.votos_impugnados if meta else 0,
        "total_electores": meta.total_electores if meta else None,
    }


# ---------------------------------------------------------------------------
# CREAR — asigna el acta al sistema sin filtro territorial
# ---------------------------------------------------------------------------

@router.post("/actas", status_code=201)
async def crear_acta_global(
    payload: DigitadorActaCrearIn,
    request: Request,
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(requerir_rol(*ROL_NACIONAL)),
):
    """CREAR cualquier acta a nivel nacional (bypass ubigeo + auditoría).

    Si la mesa ya existe en el padrón se reutiliza su local real; si no
    existe, se crea la mesa en ``venue_id`` (o el primer venue del sistema).
    """
    from app.services.processor import ensure_seed_data

    ensure_seed_data(db)
    # Bypass geográfico: el venue se acepta tal cual, sin validar alcance.
    table = db.query(Table).filter(Table.numero_mesa == payload.numero_mesa).first()
    antes = {**_snapshot_tabla(table),
             **(_snapshot_votos(db, table.id) if table else {})}
    accion = "CREAR" if table is None else "MODIFICAR"

    if table is None:
        venue_id = payload.venue_id
        if venue_id is None:
            venue = db.query(Venue).order_by(Venue.id).first()
            if venue is None:
                # Base nacional vacía: el Digitador Global puede fundar el
                # padrón (alcance nacional, sin jurisdicción previa).
                venue = Venue(name="LOCAL NACIONAL — DIGITADOR GLOBAL",
                              sector="NACIONAL", address="—",
                              latitude=-9.19, longitude=-75.0152,
                              ubigeo="040000", total_tables=0)
                db.add(venue)
                db.flush()
            venue_id = venue.id
        elif db.query(Venue).filter(Venue.id == venue_id).first() is None:
            raise HTTPException(status_code=404,
                                detail=f"Local {venue_id} no existe")
        table = Table(numero_mesa=payload.numero_mesa, venue_id=venue_id,
                      processed=True, status="processed", requires_review=False)
        db.add(table)
        db.flush()

    # Rectifica cabecera y contenido (sin importar el bloqueo previo).
    table.processed = True
    table.requires_review = False
    table.status = "processed"
    if payload.ocr_confidence is not None:
        table.ocr_confidence = payload.ocr_confidence
    if payload.image_url is not None:
        table.image_url = payload.image_url
    _aplicar_votos_nivel(db, table.id, "district", payload.votos_distrital)
    _aplicar_votos_nivel(db, table.id, "provincial", payload.votos_provincial)
    _aplicar_votos_nivel(db, table.id, "regional", payload.votos_regional)
    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
    if meta is None:
        meta = ActaMetadata(table_id=table.id)
        db.add(meta)
    meta.votos_blancos = payload.votos_blancos
    meta.votos_nulos = payload.votos_nulos
    meta.votos_impugnados = payload.votos_impugnados
    if payload.total_electores is not None:
        meta.total_electores = payload.total_electores
    db.flush()

    despues = {**_snapshot_tabla(table), **_snapshot_votos(db, table.id)}
    try:
        auditoria = registrar_auditoria_acta(
            db, acta_id=table.id, numero_mesa=table.numero_mesa, accion=accion,
            usuario=usuario, valores_anteriores=antes, valores_nuevos=despues,
            motivo=payload.motivo or "carga nacional del Digitador Global",
            request=request,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    db.commit()
    db.refresh(table)

    realtime = await _emitir_recalculo(
        db=db, acta_id=table.id, numero_mesa=table.numero_mesa,
        accion=accion, usuario=usuario)
    logger.info("digitador %s %s mesa %s (acta %s) desde %s",
                usuario.email, accion, table.numero_mesa, table.id,
                ip_de_request(request))
    return {"acta": _serializar_acta(db, table),
            "auditoria_id": auditoria.id, "realtime": realtime}


# ---------------------------------------------------------------------------
# MODIFICAR — rectifica votos, conteos, observaciones y desbloquea
# ---------------------------------------------------------------------------

@router.patch("/actas/{acta_id}")
async def rectificar_acta_global(
    acta_id: int,
    payload: DigitadorActaRectificarIn,
    request: Request,
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(requerir_rol(*ROL_NACIONAL)),
):
    """MODIFICAR cualquier acta sin importar ubicación o bloqueo.

    Rectifica votos por nivel, blancos/nulos/impugnados, observaciones y,
    con ``forzar_desbloqueo=true``, reabre un acta bloqueada
    (``processed``/``requires_review``) para su corrección.
    """
    table = db.query(Table).filter(Table.id == acta_id).first()
    if table is None:
        raise HTTPException(status_code=404, detail=f"Acta {acta_id} no encontrada")
    antes = {**_snapshot_tabla(table), **_snapshot_votos(db, table.id)}

    tocadas = 0
    tocadas += _aplicar_votos_nivel(db, table.id, "district", payload.votos_distrital)
    tocadas += _aplicar_votos_nivel(db, table.id, "provincial", payload.votos_provincial)
    tocadas += _aplicar_votos_nivel(db, table.id, "regional", payload.votos_regional)

    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
    if meta is None:
        meta = ActaMetadata(table_id=table.id)
        db.add(meta)
    if payload.votos_blancos is not None:
        meta.votos_blancos = payload.votos_blancos
    if payload.votos_nulos is not None:
        meta.votos_nulos = payload.votos_nulos
    if payload.votos_impugnados is not None:
        meta.votos_impugnados = payload.votos_impugnados
    if payload.total_electores is not None:
        meta.total_electores = payload.total_electores
    if payload.ocr_confidence is not None:
        table.ocr_confidence = payload.ocr_confidence
    if payload.image_url is not None:
        table.image_url = payload.image_url
    if payload.observacion is not None and hasattr(table, "observacion"):
        table.observacion = payload.observacion  # type: ignore[attr-defined]
    if payload.forzar_desbloqueo:
        # Reabre el acta bloqueada para rectificarla y la deja contabilizada.
        table.processed = True
        table.requires_review = False
        table.status = "processed"
    db.flush()

    despues = {**_snapshot_tabla(table), **_snapshot_votos(db, table.id),
               "filas_votos_tocadas": tocadas,
               "observacion": payload.observacion}
    try:
        auditoria = registrar_auditoria_acta(
            db, acta_id=table.id, numero_mesa=table.numero_mesa, accion="MODIFICAR",
            usuario=usuario, valores_anteriores=antes, valores_nuevos=despues,
            motivo=payload.motivo, request=request,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    db.commit()
    db.refresh(table)

    realtime = await _emitir_recalculo(
        db=db, acta_id=table.id, numero_mesa=table.numero_mesa,
        accion="MODIFICAR", usuario=usuario)
    logger.info("digitador %s MODIFICAR acta %s (mesa %s, %s filas) desde %s",
                usuario.email, table.id, table.numero_mesa, tocadas,
                ip_de_request(request))
    return {"acta": _serializar_acta(db, table),
            "auditoria_id": auditoria.id, "realtime": realtime}


# ---------------------------------------------------------------------------
# Auditoría — historial append-only del acta
# ---------------------------------------------------------------------------

@router.get("/actas/{acta_id}/auditoria", response_model=list[ActaAuditoriaOut])
def historial_acta(
    acta_id: int,
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(requerir_rol(*ROL_NACIONAL)),
):
    """Historial de auditoría de un acta (antes/después en JSON)."""
    _ = usuario
    filas = (
        db.query(ActaAuditoriaGlobal)
        .filter(ActaAuditoriaGlobal.acta_id == acta_id)
        .order_by(ActaAuditoriaGlobal.created_at.desc()).all()
    )
    return [serializar_auditoria(f) for f in filas]


@router.get("/auditoria", response_model=list[ActaAuditoriaOut])
def auditoria_reciente(
    limite: int = Query(default=50, ge=1, le=200),
    numero_mesa: str | None = Query(default=None, min_length=6, max_length=6),
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(requerir_rol(*ROL_NACIONAL)),
):
    """Auditoría reciente nacional, opcionalmente filtrada por mesa."""
    _ = usuario
    q = db.query(ActaAuditoriaGlobal).order_by(ActaAuditoriaGlobal.created_at.desc())
    if numero_mesa:
        q = q.filter(ActaAuditoriaGlobal.numero_mesa == numero_mesa)
    return [serializar_auditoria(f) for f in q.limit(limite).all()]
