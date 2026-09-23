"""Auditoría obligatoria del Digitador Global.

Cada CREAR / MODIFICAR de un acta persiste una fila append-only en
``acta_auditoria_global`` con: ID usuario, email, rol, IP, timestamp
(``created_at`` automático), valores anteriores en JSON y valores nuevos en
JSON. La tabla jamás se actualiza ni se borra desde la API.
"""
from __future__ import annotations

import json
import logging
from typing import Any

from fastapi import Request
from sqlalchemy.orm import Session

from app.core.models import ActaAuditoriaGlobal, Usuario

logger = logging.getLogger(__name__)


def ip_de_request(request: Request | None) -> str | None:
    """IP del cliente (respeta X-Forwarded-For tras un proxy)."""
    if request is None:
        return None
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()[:45] or None
    if request.client:
        return request.client.host[:45]
    return None


def _a_json(valor: Any) -> str:
    """Serializa a JSON compacto; ante tipos exóticos usa str()."""
    try:
        return json.dumps(valor, ensure_ascii=False, default=str)
    except (TypeError, ValueError):
        return json.dumps({"repr": str(valor)}, ensure_ascii=False)


def _de_json(texto: str | None) -> dict:
    """Deserializa el JSON guardado (tolerante a filas antiguas)."""
    if not texto:
        return {}
    try:
        data = json.loads(texto)
        return data if isinstance(data, dict) else {"valor": data}
    except (TypeError, ValueError):
        return {"raw": str(texto)}


def snapshot_acta(valores: dict[str, Any]) -> dict[str, Any]:
    """Normaliza un snapshot del acta para el diff de auditoría."""
    return {k: v for k, v in (valores or {}).items() if v is not None}


def registrar_auditoria_acta(
    db: Session,
    *,
    acta_id: int,
    numero_mesa: str,
    accion: str,
    usuario: Usuario,
    valores_anteriores: dict[str, Any],
    valores_nuevos: dict[str, Any],
    motivo: str | None,
    request: Request | None = None,
) -> ActaAuditoriaGlobal:
    """INSERT append-only en ``acta_auditoria_global`` (hace flush, no commit).

    Lanza ``ValueError`` si la acción no es CREAR/MODIFICAR: el llamador lo
    convierte en 422. El commit lo hace el endpoint junto con el acta para
    que acta + auditoría sean atómicas.
    """
    accion_norm = (accion or "").upper()
    if accion_norm not in ("CREAR", "MODIFICAR"):
        raise ValueError(f"acción de auditoría inválida: {accion!r}")

    fila = ActaAuditoriaGlobal(
        acta_id=acta_id,
        numero_mesa=numero_mesa,
        accion=accion_norm,
        usuario_id=usuario.id,
        usuario_email=usuario.email,
        usuario_rol=usuario.rol,
        ip=ip_de_request(request),
        valores_anteriores=_a_json(snapshot_acta(valores_anteriores)),
        valores_nuevos=_a_json(snapshot_acta(valores_nuevos)),
        motivo=(motivo or "")[:1000] or None,
    )
    db.add(fila)
    db.flush()
    logger.info(
        "auditoría acta %s (%s) %s por %s desde %s",
        acta_id, numero_mesa, accion_norm, usuario.email, fila.ip,
    )
    return fila


def serializar_auditoria(fila: ActaAuditoriaGlobal) -> dict[str, Any]:
    """Fila de auditoría → dict JSON para la API."""
    return {
        "id": fila.id,
        "acta_id": fila.acta_id,
        "numero_mesa": fila.numero_mesa,
        "accion": fila.accion,
        "usuario_id": fila.usuario_id,
        "usuario_email": fila.usuario_email,
        "usuario_rol": fila.usuario_rol,
        "ip": fila.ip,
        "valores_anteriores": _de_json(fila.valores_anteriores),
        "valores_nuevos": _de_json(fila.valores_nuevos),
        "motivo": fila.motivo,
        "created_at": fila.created_at.isoformat() if fila.created_at else None,
    }
