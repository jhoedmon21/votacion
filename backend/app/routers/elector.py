"""Consulta estilo ONPE — GET /api/v1/elector/buscar.

Replica la ficha oficial "Conoce tu local de votación": estado de miembro de
mesa, identidad (DNI + nombres), jerarquía REGIÓN/PROVINCIA/DISTRITO, local
(nombre/dirección/referencia) y detalle (N° mesa + N° orden).

Fuentes reales (sin padrón nacional de ciudadanos en la base):
  * ``?mesa=NNNNNN`` — resuelve íntegra contra el padrón de locales cargado
    (tables + venues + catálogo ubigeo). Es el modo del Digitador Global.
  * ``?dni=DDDDDDDD`` — resuelve identidad contra usuarios del sistema y la
    mesa contra su asignación operativa TITULAR vigente. Si el DNI no es de
    un usuario o no tiene mesa, responde 404 honesto (no se inventa padrón).

El rol global (SUPER_ADMIN / DIGITADOR_GLOBAL) consulta cualquier mesa sin
restricciones; el resto queda acotado a su alcance territorial (403).
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from app.core.auth import alcance_ubigeos, es_rol_global, usuario_actual
from app.core.database import get_db
from app.core.models import (AsignacionPersonero, Table, Usuario, Venue)
from app.core.schemas import (V1ElectorAsignacion, V1ElectorBuscarOut,
                               V1ElectorLocal)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/elector", tags=["elector"])

# N° de orden: posición 1-based de la mesa dentro de su local (orden ONPE).
# Table no guarda orden físico: se deriva del orden del número de mesa.


def _jerarquia(ubigeo: str) -> tuple[str, str]:
    """(provincia, distrito) oficiales del catálogo para un ubigeo."""
    from app.core.ubigeo_catalogo import (DISTRITOS_POR_PROVINCIA,
                                           UBIGEO_DISTRITO)

    distrito = UBIGEO_DISTRITO.get(ubigeo, ubigeo)
    provincia = ""
    for prov, ds in DISTRITOS_POR_PROVINCIA.items():
        if any(u == ubigeo for u, _ in ds):
            provincia = prov
            break
    return provincia, distrito


def _en_alcance(db: Session, usuario: Usuario, venue: Venue) -> None:
    """403 si el local está fuera del alcance (salvo rol global)."""
    if es_rol_global(usuario):
        return
    prefijos = sorted({(u or "").rstrip("0") or u
                       for u in alcance_ubigeos(usuario)})
    if not prefijos or not any((venue.ubigeo or "").startswith(p) for p in prefijos):
        raise HTTPException(
            status_code=403, detail="Mesa fuera de tu alcance territorial")


def _estado_acta(t: Table) -> str:
    if t.requires_review:
        return "OBSERVADA"
    if t.processed:
        return "REGISTRADA"
    return "PENDIENTE"


def _numero_orden(db: Session, table: Table) -> int:
    """Posición 1-based de la mesa en su local (por número de mesa)."""
    from sqlalchemy import func

    return int(db.query(func.count(Table.id)).filter(
        Table.venue_id == table.venue_id,
        Table.numero_mesa <= table.numero_mesa).scalar() or 1)


def _ficha_mesa(db: Session, table: Table, modo: str,
                dni: str | None = None,
                persona: Usuario | None = None,
                asignacion: AsignacionPersonero | None = None) -> V1ElectorBuscarOut:
    """Arma la ficha ONPE completa para una mesa ya resuelta."""
    venue = db.query(Venue).filter(Venue.id == table.venue_id).first()
    if venue is None:
        raise HTTPException(status_code=500,
                            detail=f"Mesa {table.numero_mesa} sin local asignado")
    provincia, distrito = _jerarquia(venue.ubigeo or "")
    es_miembro = asignacion is not None and asignacion.tipo == "TITULAR"
    return V1ElectorBuscarOut(
        modo=modo,
        dni=dni or (persona.dni if persona else None),
        nombres=persona.nombres if persona else None,
        apellidos=persona.apellidos if persona else None,
        ubigeo=venue.ubigeo or "",
        provincia=provincia,
        distrito=distrito,
        esMiembroMesa=es_miembro,
        origen="sistema",
        asignacion=(V1ElectorAsignacion(
            rol=persona.rol, mesa=table.numero_mesa, tipo=asignacion.tipo,
            estado=asignacion.estado, local=venue.name)
            if persona and asignacion else None),
        local=V1ElectorLocal(id=venue.id, nombre=venue.name,
                             direccion=venue.address, referencia=venue.sector),
        numeroMesa=table.numero_mesa,
        numeroOrden=_numero_orden(db, table),
        electoresHabiles=table.electores_habiles,
        estadoActa=_estado_acta(table),
        nota=(None if persona else
              "DNI fuera del registro de usuarios: la ficha muestra la mesa "
              "del padrón; el padrón nacional de ciudadanos lo provee la ONPE."),
    )


@router.get("/buscar", response_model=V1ElectorBuscarOut)
def buscar_elector(
    dni: str | None = Query(default=None, min_length=8, max_length=8,
                            pattern=r"^[0-9]{8}$"),
    mesa: str | None = Query(default=None, min_length=6, max_length=6,
                             pattern=r"^[0-9]{6}$"),
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(usuario_actual),
):
    """Busca la ficha ONPE por DNI (usuario + asignación) o por N° de mesa."""
    if dni is None and mesa is None:
        raise HTTPException(status_code=422,
                            detail="Indique ?dni= (8 dígitos) o ?mesa= (6 dígitos)")

    # ---- Modo mesa: directo al padrón de locales.
    if mesa is not None:
        table = db.query(Table).filter(Table.numero_mesa == mesa).first()
        if table is None:
            raise HTTPException(
                status_code=404, detail=f"Mesa {mesa} no está en el padrón")
        venue = db.query(Venue).filter(Venue.id == table.venue_id).first()
        if venue is not None:
            _en_alcance(db, usuario, venue)
        logger.info("elector/buscar mesa %s por %s", mesa, usuario.email)
        return _ficha_mesa(db, table, modo="mesa")

    # ---- Modo DNI: identidad + asignación operativa vigente.
    assert dni is not None
    persona = db.query(Usuario).filter(Usuario.dni == dni).first()
    if persona is None:
        raise HTTPException(
            status_code=404,
            detail=f"DNI {dni} no registrado en el sistema: use ?mesa= para "
                   "la ficha del padrón de locales")
    asignacion = (
        db.query(AsignacionPersonero)
        .filter(AsignacionPersonero.usuario_id == persona.id,
                AsignacionPersonero.estado.in_(
                    ("ASIGNADO", "CONFIRMADO", "PRESENTE")))
        .order_by(AsignacionPersonero.created_at.desc()).first()
    )
    if asignacion is None:
        # Sin mesa operativa: ficha de identidad sin ubicación (card rojo).
        return V1ElectorBuscarOut(
            modo="dni", dni=persona.dni, nombres=persona.nombres,
            apellidos=persona.apellidos, ubigeo="", provincia="", distrito="",
            esMiembroMesa=False, origen="sistema", asignacion=None,
            local=V1ElectorLocal(id=0, nombre="—"),
            numeroMesa="", numeroOrden=0, estadoActa="PENDIENTE",
            nota="DNI registrado sin mesa asignada: NO ERES MIEMBRO DE MESA.",
        )
    table = db.query(Table).filter(Table.id == asignacion.mesa_id).first()
    if table is None:
        raise HTTPException(status_code=500,
                            detail="Asignación sin mesa en el padrón")
    venue = db.query(Venue).filter(Venue.id == table.venue_id).first()
    if venue is not None:
        _en_alcance(db, usuario, venue)
    logger.info("elector/buscar dni %s -> mesa %s (por %s)",
                dni, table.numero_mesa, usuario.email)
    return _ficha_mesa(db, table, modo="dni", dni=dni,
                       persona=persona, asignacion=asignacion)
