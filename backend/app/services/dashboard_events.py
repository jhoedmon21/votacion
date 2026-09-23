"""Bus de eventos del dashboard en tiempo real.

Cada vez que el Digitador Global crea o rectifica un acta se llama a
:func:`emitir_evento_acta`, que:

1. Invalida el cache del resumen nacional (``_RESUMEN_CACHE``).
2. Incrementa la versión monotónica del cómputo.
3. Hace broadcast del evento a todos los WebSocket suscritos
   (``/ws/dashboard``) con el diff y el resumen recalculado.

Diseño deliberadamente sin dependencias externas (sin Redis): el estado vive
en memoria del proceso uvicorn. Con múltiples workers, cada worker emite a
sus propios suscriptores y el endpoint ``POST /api/realtime/recalcular``
sirve como reconciliación por polling. Para producción multi-nodo, sustituir
``_SUSCRIPTORES`` por Redis Pub/Sub sin cambiar la firma pública.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger(__name__)

# Versión monotónica del cómputo: cada acta la incrementa en 1.
_VERSION: int = 0
_ACTUALIZADO_EN: str | None = None

# Cache del resumen nacional (se invalida en cada evento).
_RESUMEN_CACHE: dict[str, Any] | None = None

# Suscriptores WebSocket vivos (asyncio.Queue por conexión).
_SUSCRIPTORES: set["asyncio.Queue[dict[str, Any]]"] = set()


def version_actual() -> int:
    """Versión actual del cómputo (para polling del dashboard)."""
    return _VERSION


def estado_dashboard(
    actas_procesadas: int = 0,
    actas_observadas: int = 0,
    avance_pct: float = 0.0,
) -> dict[str, Any]:
    """Estado ligero del cómputo (lo sirve GET /api/realtime/estado)."""
    return {
        "version": _VERSION,
        "actualizado_en": _ACTUALIZADO_EN,
        "actas_procesadas": actas_procesadas,
        "actas_observadas": actas_observadas,
        "avance_pct": avance_pct,
    }


def invalidar_cache_resumen() -> None:
    """Invalida el resumen nacional cacheado (llamar tras cada acta)."""
    global _RESUMEN_CACHE
    _RESUMEN_CACHE = None


def obtener_resumen_cacheado() -> dict[str, Any] | None:
    """Resumen nacional cacheado, si existe."""
    return _RESUMEN_CACHE


def guardar_resumen_cacheado(resumen: dict[str, Any]) -> None:
    """Guarda el resumen nacional recién calculado."""
    global _RESUMEN_CACHE
    _RESUMEN_CACHE = dict(resumen)


def suscribir() -> "asyncio.Queue[dict[str, Any]]":
    """Registra un suscriptor WebSocket; devuelve su cola de eventos."""
    cola: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=100)
    _SUSCRIPTORES.add(cola)
    return cola


def desuscribir(cola: "asyncio.Queue[dict[str, Any]]") -> None:
    """Elimina un suscriptor (al cerrar el WebSocket)."""
    _SUSCRIPTORES.discard(cola)


def n_suscriptores() -> int:
    """N° de dashboards conectados (para el payload de recálculo)."""
    return len(_SUSCRIPTORES)


async def emitir_evento_acta(
    *,
    acta_id: int,
    numero_mesa: str,
    accion: str,
    usuario_email: str,
    resumen: dict[str, Any],
) -> dict[str, Any]:
    """Emite el evento ``acta.actualizada`` y lo broadcastea al dashboard.

    Retorna el evento emitido (con la nueva versión). Nunca lanza: si un
    suscriptor tiene la cola llena se lo salta y sigue con los demás, para
    que un dashboard lento no bloquee el cómputo.
    """
    global _VERSION, _ACTUALIZADO_EN
    _VERSION += 1
    _ACTUALIZADO_EN = datetime.now(timezone.utc).isoformat()
    invalidar_cache_resumen()
    guardar_resumen_cacheado(resumen)

    evento: dict[str, Any] = {
        "tipo": "acta.actualizada",
        "version": _VERSION,
        "actualizado_en": _ACTUALIZADO_EN,
        "acta_id": acta_id,
        "numero_mesa": numero_mesa,
        "accion": accion,
        "por": usuario_email,
        "alcance": "nacional",
        "resumen": resumen,
    }
    entregados = 0
    for cola in list(_SUSCRIPTORES):
        try:
            cola.put_nowait(evento)
            entregados += 1
        except asyncio.QueueFull:
            logger.warning("suscriptor dashboard lento: evento v%s descartado", _VERSION)
    logger.info(
        "dashboard v%s: acta %s (%s) -> broadcast a %s/%s",
        _VERSION, acta_id, accion, entregados, len(_SUSCRIPTORES),
    )
    return {"evento": evento, "broadcast_a": entregados}
