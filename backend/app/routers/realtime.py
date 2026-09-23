"""Dashboard en tiempo real — WebSocket + recálculo bajo demanda.

* ``WS /ws/dashboard`` — push ``acta.actualizada`` a cada dashboard
  conectado tras cada CREAR/MODIFICAR del Digitador Global (ver
  ``app/services/dashboard_events.py``).
* ``POST /api/realtime/recalcular`` — recalcula el resumen nacional,
  invalida el cache y broadcastea la nueva versión (reconciliación por
  polling cuando el WS se cae).
* ``GET /api/realtime/estado`` — versión actual (polling ligero).
"""
from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.core.auth import usuario_actual
from app.core.database import get_db
from app.core.models import ActaMetadata, Record, Table, Usuario
from app.services import dashboard_events as bus

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/realtime", tags=["realtime"])


def _resumen_nacional(db: Session) -> dict[str, Any]:
    """Resumen nacional mínimo para el evento (sin filtro ubigeo)."""
    mesas = db.query(Table).all()
    procesadas = [t for t in mesas if t.processed and not t.requires_review]
    observadas = [t for t in mesas if t.requires_review]
    pids = [t.id for t in procesadas]
    habiles = sum(t.electores_habiles or 0 for t in procesadas)
    votos = (
        db.query(func.coalesce(func.sum(Record.votes), 0))
        .filter(Record.table_id.in_(pids)).scalar() if pids else 0
    ) or 0
    meta = (
        db.query(
            func.coalesce(func.sum(ActaMetadata.votos_blancos), 0),
            func.coalesce(func.sum(ActaMetadata.votos_nulos), 0),
            func.coalesce(func.sum(ActaMetadata.votos_impugnados), 0),
        )
        .filter(ActaMetadata.table_id.in_(pids)).first()
        if pids else (0, 0, 0)
    )
    blancos, nulos, impug = (int(x or 0) for x in meta)
    total = len(mesas)
    return {
        "total_mesas": total,
        "actas_normales": len(procesadas),
        "actas_observadas": len(observadas),
        "avance_pct": round(100.0 * len(procesadas) / total, 2) if total else 0.0,
        "participacion_pct": round(100.0 * (votos + blancos + nulos + impug) / habiles, 2)
        if habiles else 0.0,
        "votos_validos": int(votos),
        "votos_blancos": blancos,
        "votos_nulos": nulos,
        "votos_impugnados": impug,
    }


@router.get("/estado")
def estado(db: Session = Depends(get_db), usuario: Usuario = Depends(usuario_actual)):
    """Versión actual del cómputo (polling fallback del WebSocket)."""
    _ = usuario
    resumen = bus.obtener_resumen_cacheado() or _resumen_nacional(db)
    base = bus.estado_dashboard(
        actas_procesadas=int(resumen.get("actas_normales", 0)),
        actas_observadas=int(resumen.get("actas_observadas", 0)),
        avance_pct=float(resumen.get("avance_pct", 0.0)),
    )
    return {**base, "resumen": resumen, "suscriptores": bus.n_suscriptores()}


@router.post("/recalcular")
async def recalcular(
    db: Session = Depends(get_db), usuario: Usuario = Depends(usuario_actual)
):
    """Recalcula el resumen nacional y lo broadcastea a los dashboards.

    Cualquier rol autenticado puede dispararlo (el dashboard lo llama tras
    reconectar); la mutación de actas sigue restringida al Digitador Global.
    """
    resumen = _resumen_nacional(db)
    resultado = await bus.emitir_evento_acta(
        acta_id=0,
        numero_mesa="------",
        accion="RECALCULO",
        usuario_email=usuario.email,
        resumen=resumen,
    )
    return {
        "ok": True,
        "version": resultado["evento"]["version"],
        "alcance": "nacional",
        "resumen": resumen,
        "broadcast_a": resultado["broadcast_a"],
    }


async def websocket_dashboard(websocket: WebSocket) -> None:
    """WS /ws/dashboard — push de ``acta.actualizada`` (sin auth por query).

    El token viaja como ``?token=<bearer>`` porque el WS del navegador no
    manda headers. Se valida igual que el Bearer HTTP y se cierra con 4401
    si es inválido. Registrado en ``main.py`` (fuera del APIRouter porque
    FastAPI ancla los WS a la app).
    """
    from app.core.auth import resolver_token

    token = websocket.query_params.get("token", "")
    await websocket.accept()
    cola = bus.suscribir()
    try:
        # Validación perezosa: resuelve el token contra una sesión corta.
        from app.core.database import SessionLocal

        db = SessionLocal()
        try:
            valido = resolver_token(db, token) is not None
        finally:
            db.close()
        if not token or not valido:
            await websocket.send_json({"tipo": "error", "detalle": "token inválido"})
            await websocket.close(code=4401)
            return
        await websocket.send_json(
            {"tipo": "hola", "version": bus.version_actual(),
             "suscriptores": bus.n_suscriptores()}
        )
        while True:
            try:
                evento = await asyncio.wait_for(cola.get(), timeout=30.0)
                await websocket.send_json(evento)
            except asyncio.TimeoutError:
                await websocket.send_json(
                    {"tipo": "latido", "version": bus.version_actual()})
    except WebSocketDisconnect:
        pass
    finally:
        bus.desuscribir(cola)
