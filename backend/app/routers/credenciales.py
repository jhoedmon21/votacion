"""Credenciales de personeros — Fuerza Arequipeña.

* ``GET /api/v1/personeros/{id}/credencial-data`` — ficha lista para la
  plantilla (datos + asignación + QR firmado + QR en data URL).
* ``GET /api/v1/personeros/{id}/credencial.pdf`` — fotocheck 90×140 mm.
* ``GET /api/v1/personeros/credencial/distrito?ubigeo=`` — bulk del distrito.
* ``GET /api/v1/personeros/credencial/distrito.pdf?ubigeo=`` — PDF multipágina.
* ``POST /api/v1/personeros/verificar-qr`` — el Digitador Global escanea el
  QR y valida firma + asignación vigente en la mesa.

Visibilidad: rol global ve todo; gestores ven su alcance; cada personero ve
lo suyo. La verificación la puede usar cualquier rol autenticado.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy.orm import Session

from app.core.auth import alcance_ubigeos, es_rol_global, requerir_rol, usuario_actual
from app.core.database import get_db
from app.core.models import (AsignacionPersonero, Table, Usuario, Venue)
from app.core.schemas import (V1CredencialBulkOut, V1CredencialOut,
                               V1QrVerificarIn, V1QrVerificarOut)
from app.services import credenciales as SVC

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/personeros", tags=["credenciales"])

ROLES_GESTORES_CRED = ("SUPER_ADMIN", "DIGITADOR_GLOBAL", "COORD_PROVINCIAL",
                       "RESPONSABLE_DISTRITAL", "COORD_LOCAL")


def _puede_ver(solicitante: Usuario, objetivo: Usuario) -> None:
    """403 si el solicitante no puede ver la credencial del objetivo."""
    if solicitante.id == objetivo.id or es_rol_global(solicitante):
        return
    if solicitante.rol not in ROLES_GESTORES_CRED:
        raise HTTPException(status_code=403,
                            detail="Sin permiso para ver credenciales ajenas")
    prefijos = sorted({(u or "").rstrip("0") or u
                       for u in alcance_ubigeos(solicitante)})
    if not prefijos or not any(
            _en_alcance(a, prefijos) for a in alcance_ubigeos(objetivo)):
        raise HTTPException(status_code=403,
                            detail="Personero fuera de tu alcance territorial")


def _en_alcance(ubigeo: str, prefijos: list[str]) -> bool:
    return any((ubigeo or "").startswith(p) for p in prefijos)


def _ficha_o_404(db: Session, usuario_id: int, mesa: str | None) -> dict:
    try:
        return SVC.datos_credencial(db, usuario_id, mesa)
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.get("/credencial/distrito", response_model=V1CredencialBulkOut)
def credenciales_distrito(
    ubigeo: str = Query(..., min_length=6, max_length=6),
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(requerir_rol(*ROLES_GESTORES_CRED)),
):
    """Bulk del distrito: una credencial por personero con mesa en el ubigeo."""
    from app.core.ubigeo_catalogo import UBIGEO_DISTRITO

    if not es_rol_global(usuario):
        prefijos = sorted({(u or "").rstrip("0") or u
                           for u in alcance_ubigeos(usuario)})
        if not any((ubigeo or "").startswith(p) for p in prefijos):
            raise HTTPException(status_code=403, detail="Distrito fuera de tu alcance")
    distrito = UBIGEO_DISTRITO.get(ubigeo, ubigeo)
    mesas_ids = [t.id for t in db.query(Table.id)
                 .join(Venue, Venue.id == Table.venue_id)
                 .filter(Venue.ubigeo == ubigeo).all()]
    uids = sorted({a.usuario_id for a in db.query(AsignacionPersonero)
                   .filter(AsignacionPersonero.mesa_id.in_(mesas_ids)).all()}
                  ) if mesas_ids else []
    credenciales = []
    for uid in uids:
        obj = db.get(Usuario, uid)
        if obj is None or obj.rol not in ("PERSONERO", "DELEGADO_MESA"):
            continue
        try:
            credenciales.append(V1CredencialOut(**SVC.datos_credencial(db, uid)))
        except LookupError:
            continue
    # Una credencial por (personero, mesa del distrito): si tiene varias,
    # se emiten las que caen en el ubigeo pedido.
    logger.info("bulk credenciales %s: %d (por %s)", ubigeo, len(credenciales),
                usuario.email)
    return V1CredencialBulkOut(ubigeo=ubigeo, distrito=distrito,
                               total=len(credenciales), credenciales=credenciales)


@router.get("/credencial/distrito.pdf")
def credenciales_distrito_pdf(
    ubigeo: str = Query(..., min_length=6, max_length=6),
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(requerir_rol(*ROLES_GESTORES_CRED)),
):
    """PDF multipágina del distrito (90×140 mm por credencial, listo 300 DPI)."""
    bulk = credenciales_distrito(ubigeo=ubigeo, db=db, usuario=usuario)
    if not bulk.total:
        raise HTTPException(status_code=404,
                            detail=f"Sin personeros asignados en {ubigeo}")
    pdf = SVC.pdf_credenciales_bulk([c.model_dump() for c in bulk.credenciales])
    return Response(content=pdf, media_type="application/pdf",
                    headers={"Content-Disposition":
                             f"attachment; filename=credenciales-{ubigeo}.pdf"})


@router.post("/verificar-qr", response_model=V1QrVerificarOut)
def verificar_qr(payload: V1QrVerificarIn,
                 db: Session = Depends(get_db),
                 usuario: Usuario = Depends(usuario_actual)):
    """Valida un QR escaneado: firma + asignación vigente en la mesa."""
    valida, dni, mesa, motivo = SVC.verificar_qr(payload.qr)
    if not valida:
        logger.warning("QR rechazado (%s) por %s", motivo, usuario.email)
        return V1QrVerificarOut(valida=False, motivo=motivo, dni=dni,
                                numero_mesa=mesa)
    persona = db.query(Usuario).filter(Usuario.dni == dni).first()
    table = db.query(Table).filter(Table.numero_mesa == mesa).first()
    if persona is None or table is None:
        return V1QrVerificarOut(valida=False, motivo="DNI o mesa fuera del padrón",
                                dni=dni, numero_mesa=mesa)
    asig = (db.query(AsignacionPersonero)
            .filter(AsignacionPersonero.usuario_id == persona.id,
                    AsignacionPersonero.mesa_id == table.id)
            .order_by(AsignacionPersonero.created_at.desc()).first())
    if asig is None or asig.estado in ("RETIRADO", "INHABILITADO"):
        return V1QrVerificarOut(valida=False, motivo="sin asignación vigente",
                                dni=dni, numero_mesa=mesa,
                                personero=persona.nombre_completo)
    venue = db.get(Venue, table.venue_id)
    from app.core.ubigeo_catalogo import UBIGEO_DISTRITO

    logger.info("QR ok: %s mesa %s (verificado por %s)", dni, mesa, usuario.email)
    return V1QrVerificarOut(
        valida=True, motivo=f"{asig.tipo} · {asig.estado}", dni=dni,
        numero_mesa=mesa, personero=persona.nombre_completo,
        local=venue.name if venue else "",
        distrito=UBIGEO_DISTRITO.get(venue.ubigeo if venue else "", ""))


@router.get("/{usuario_id}/credencial-data", response_model=V1CredencialOut)
def credencial_data(usuario_id: int, mesa: str | None = Query(default=None),
                    db: Session = Depends(get_db),
                    usuario: Usuario = Depends(usuario_actual)):
    """Ficha de credencial de un personero (para la plantilla + QR)."""
    objetivo = db.get(Usuario, usuario_id)
    if objetivo is None:
        raise HTTPException(status_code=404, detail="Personero no encontrado")
    _puede_ver(usuario, objetivo)
    return V1CredencialOut(**_ficha_o_404(db, usuario_id, mesa))


@router.get("/{usuario_id}/credencial.pdf")
def credencial_pdf(usuario_id: int, mesa: str | None = Query(default=None),
                   db: Session = Depends(get_db),
                   usuario: Usuario = Depends(usuario_actual)):
    """Fotocheck PDF individual 90×140 mm (300 DPI, listo para imprimir)."""
    objetivo = db.get(Usuario, usuario_id)
    if objetivo is None:
        raise HTTPException(status_code=404, detail="Personero no encontrado")
    _puede_ver(usuario, objetivo)
    datos = _ficha_o_404(db, usuario_id, mesa)
    pdf = SVC.pdf_credencial(datos)
    return Response(content=pdf, media_type="application/pdf",
                    headers={"Content-Disposition":
                             f"attachment; filename=credencial-{datos['dni']}-"
                             f"{datos['asignacion']['mesa']}.pdf"})
