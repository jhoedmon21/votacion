"""Campo v1 — presencia del personero y check de validación del acta.

  * ``POST /api/v1/campo/asignar`` — el coordinador asigna un personero a una
    mesa (TITULAR/SUPLENTE), dentro de su alcance.
  * ``POST /api/v1/campo/checkin`` — check-in GPS del personero al arribar al
    local: valida Haversine contra las coordenadas del local (radio 300 m) y
    eleva la asignación a PRESENTE sólo dentro del radio.
  * ``GET /api/v1/campo/mi-estado`` — asignaciones y presencia validada hoy.
  * ``GET /api/v1/actas/checklist`` — pre-vuelo del acta: padrón, presencia,
    oferta por nivel (distrital/provincial/regional) y actas ya registradas.

El registro de actas (``/movil`` y ``/v1/actas/registrar``) exige presencia
validada al PERSONERO/DELEGADO_MESA; los supervisores están exentos.
"""
from __future__ import annotations

import logging
import math
from datetime import datetime, timezone


def _hoy_utc() -> str:
    """Fecha UTC (los timestamps de la base usan UTC: SQLite CURRENT_TIMESTAMP)."""
    return datetime.now(timezone.utc).date().isoformat()

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.core.auth import (alcance_ubigeos, es_rol_global, requerir_rol,
                            usuario_actual, validar_alcance_venue)
from app.core.database import get_db
from app.core.models import (AsignacionPersonero, CheckinPersonero, ConsejeroCandidate,
                              DistrictCandidate, ProvincialCandidate, Record,
                              RegionalCandidate, Table, Usuario, Venue)
from app.core.schemas import (V1AsignarIn, V1AsignarLoteIn, V1CheckinIn,
                               V1CheckinOut, V1ChecklistOut, V1DesasignarIn,
                               V1MiEstadoOut)
from app.core.ubigeo import candidatos_del_ambito, ubigeo_de_nivel

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1", tags=["campo-v1"])

RADIO_LOCAL_M = 300.0

ROLES_GESTORES = ("SUPER_ADMIN", "COORD_PROVINCIAL", "RESPONSABLE_DISTRITAL",
                  "COORD_LOCAL")
ROLES_CAMPO = ("PERSONERO", "DELEGADO_MESA")

MODELOS_NIVEL = {
    "REGIONAL": RegionalCandidate,
    "CONSEJERO": ConsejeroCandidate,
    "PROVINCIAL": ProvincialCandidate,
    "DISTRITAL": DistrictCandidate,
}
CLAVE_NIVEL = {"REGIONAL": "regional", "CONSEJERO": "consejero",
               "PROVINCIAL": "provincial", "DISTRITAL": "district"}


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Distancia en metros entre dos puntos GPS."""
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = (math.sin(dp / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(a))


def _mesa_en_alcance(db: Session, usuario: Usuario, numero_mesa: str) -> Table:
    """Mesa del padrón validada contra el alcance (404/403)."""
    table = db.query(Table).filter(Table.numero_mesa == numero_mesa).first()
    if table is None:
        raise HTTPException(
            status_code=404,
            detail=f"Mesa {numero_mesa} no está en el padrón de locales")
    validar_alcance_venue(db, usuario, table.venue_id)
    return table


def presencia_validada(db: Session, usuario_id: int, venue_id: int) -> bool:
    """¿Tiene check-in dentro del radio HOY en ese local?"""
    hoy = _hoy_utc()
    return (
        db.query(CheckinPersonero.id)
        .join(AsignacionPersonero,
              AsignacionPersonero.id == CheckinPersonero.asignacion_id)
        .join(Table, Table.id == AsignacionPersonero.mesa_id)
        .filter(AsignacionPersonero.usuario_id == usuario_id,
                Table.venue_id == venue_id,
                CheckinPersonero.dentro_de_radio == True,  # noqa: E712
                func.date(CheckinPersonero.created_at) == hoy)
        .first()
        is not None
    )


def exigir_presencia(db: Session, usuario: Usuario, venue_id: int) -> None:
    """Puerta de carga para PERSONERO/DELEGADO_MESA (supervisores exentos)."""
    if usuario.rol in ROLES_CAMPO and not presencia_validada(
            db, usuario.id, venue_id):
        raise HTTPException(
            status_code=403,
            detail="Registra primero tu check-in GPS en el local "
                   "(POST /api/v1/campo/checkin)",
        )


def mesa_asignada(db: Session, usuario: Usuario, table_id: int) -> bool:
    """¿Tiene el usuario asignación en esa mesa? (supervisores: siempre)."""
    if usuario.rol not in ROLES_CAMPO:
        return True
    return (
        db.query(AsignacionPersonero.id)
        .filter(AsignacionPersonero.usuario_id == usuario.id,
                AsignacionPersonero.mesa_id == table_id)
        .first()
        is not None
    )


def exigir_asignacion(db: Session, usuario: Usuario, table_id: int,
                      numero_mesa: str) -> None:
    """El personero sólo carga sus mesas asignadas."""
    if not mesa_asignada(db, usuario, table_id):
        raise HTTPException(
            status_code=403,
            detail=f"La mesa {numero_mesa} no te está asignada: pide tu "
                   "asignación al coordinador",
        )


# ---------------------------------------------------------------------------
# Asignación y check-in
# ---------------------------------------------------------------------------

@router.post("/campo/asignar")
def asignar(payload: V1AsignarIn, db: Session = Depends(get_db),
            usuario: Usuario = Depends(requerir_rol(*ROLES_GESTORES))):
    """Asigna un personero a una mesa (idempotente por usuario/mesa/tipo)."""
    table = _mesa_en_alcance(db, usuario, payload.numero_mesa)
    objetivo = db.query(Usuario).filter(Usuario.id == payload.usuario_id).first()
    if objetivo is None:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    if objetivo.rol not in ROLES_CAMPO:
        raise HTTPException(
            status_code=422,
            detail=f"Sólo PERSONERO/DELEGADO_MESA, no {objetivo.rol}")
    if not objetivo.activo:
        raise HTTPException(status_code=422, detail="El usuario está inactivo")

    fila = (
        db.query(AsignacionPersonero)
        .filter(AsignacionPersonero.usuario_id == objetivo.id,
                AsignacionPersonero.mesa_id == table.id,
                AsignacionPersonero.tipo == payload.tipo)
        .first()
    )
    if fila is None:
        fila = AsignacionPersonero(
            usuario_id=objetivo.id, mesa_id=table.id, tipo=payload.tipo,
            estado="ASIGNADO", asignado_por=usuario.id, notas=payload.notas)
        db.add(fila)
    else:
        fila.estado = "ASIGNADO"
        fila.asignado_por = usuario.id
        if payload.notas is not None:
            fila.notas = payload.notas
    db.commit()
    db.refresh(fila)
    logger.info("asignado %s a mesa %s (%s) por %s", objetivo.email,
                payload.numero_mesa, payload.tipo, usuario.email)
    return {"id": fila.id, "usuario": objetivo.email,
            "numero_mesa": payload.numero_mesa, "tipo": fila.tipo,
            "estado": fila.estado}


@router.post("/campo/asignar-lote")
def asignar_lote(payload: V1AsignarLoteIn, db: Session = Depends(get_db),
                 usuario: Usuario = Depends(requerir_rol(*ROLES_GESTORES))):
    """Asigna un personero a varias mesas de golpe (misma pantalla del local).

    Idempotente por usuario/mesa/tipo. Devuelve por-mesa el resultado para
    pintar la grilla: "creada", "reactivada" o "ya_estaba"; 404 con detalle
    si alguna mesa no existe o está fuera del alcance del gestor.
    """
    objetivo = db.query(Usuario).filter(Usuario.id == payload.usuario_id).first()
    if objetivo is None:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    if objetivo.rol not in ROLES_CAMPO:
        raise HTTPException(
            status_code=422,
            detail=f"Sólo PERSONERO/DELEGADO_MESA, no {objetivo.rol}")
    if not objetivo.activo:
        raise HTTPException(status_code=422, detail="El usuario está inactivo")

    orden = sorted(set(m for m in payload.numero_mesas if m.strip()))
    resultados: list[dict] = []
    for numero in orden:
        try:
            table = _mesa_en_alcance(db, usuario, numero)
        except HTTPException as e:
            raise HTTPException(status_code=e.status_code,
                                detail=f"Mesa {numero}: {e.detail}")
        fila = (
            db.query(AsignacionPersonero)
            .filter(AsignacionPersonero.usuario_id == objetivo.id,
                    AsignacionPersonero.mesa_id == table.id,
                    AsignacionPersonero.tipo == payload.tipo)
            .first()
        )
        if fila is None:
            db.add(AsignacionPersonero(
                usuario_id=objetivo.id, mesa_id=table.id, tipo=payload.tipo,
                estado="ASIGNADO", asignado_por=usuario.id, notas=payload.notas))
            resultados.append({"numero_mesa": numero, "resultado": "creada"})
        else:
            reactivada = fila.estado != "ASIGNADO"
            fila.estado = "ASIGNADO"
            fila.asignado_por = usuario.id
            if payload.notas is not None:
                fila.notas = payload.notas
            resultados.append({"numero_mesa": numero,
                               "resultado": "reactivada" if reactivada else "ya_estaba"})
    db.commit()
    logger.info("asignar-lote %s: %d mesas a %s (por %s)",
                payload.tipo, len(orden), objetivo.email, usuario.email)
    return {"usuario": objetivo.email, "tipo": payload.tipo,
            "total": len(orden), "mesas": resultados}


@router.post("/campo/desasignar")
def desasignar(payload: V1DesasignarIn, db: Session = Depends(get_db),
               usuario: Usuario = Depends(requerir_rol(*ROLES_GESTORES))):
    """Quita una asignación personero↔mesa. La mesa vuelve a quedar libre."""
    fila = (
        db.query(AsignacionPersonero)
        .filter(AsignacionPersonero.id == payload.asignacion_id).first()
    )
    if fila is None:
        raise HTTPException(status_code=404, detail="Asignación no encontrada")
    # El gestor sólo toca mesas dentro de su alcance.
    table = db.query(Table).filter(Table.id == fila.mesa_id).first()
    _mesa_en_alcance(db, usuario, table.numero_mesa if table else "000000")
    db.delete(fila)
    db.commit()
    return {"ok": True, "asignacion_id": payload.asignacion_id}


@router.get("/campo/mesas-local")
def mesas_de_local(venue_id: int = Query(...),
                   usuario_id: int | None = Query(default=None),
                   db: Session = Depends(get_db),
                   usuario: Usuario = Depends(usuario_actual)):
    """Mesas de un local con su estado de asignación (para la grilla).

    Con ``usuario_id`` marca además qué mesas tiene ESE personero (y el id de
    asignación) para resaltarlas y permitir desasignar desde la grilla.
    """
    venue = db.query(Venue).filter(Venue.id == venue_id).first()
    if venue is None:
        raise HTTPException(status_code=404, detail="Local no encontrado")
    validar_alcance_venue(db, usuario, venue.id)

    filas = (
        db.query(Table, AsignacionPersonero, Usuario)
        .outerjoin(AsignacionPersonero,
                   (AsignacionPersonero.mesa_id == Table.id)
                   & (AsignacionPersonero.estado.in_(("ASIGNADO", "CONFIRMADO", "PRESENTE"))))
        .outerjoin(Usuario, Usuario.id == AsignacionPersonero.usuario_id)
        .filter(Table.venue_id == venue.id)
        .order_by(Table.numero_mesa)
        .limit(600)
        .all()
    )
    salida = []
    for mesa, asign, persona in filas:
        item = {
            "id": mesa.id,
            "numero_mesa": mesa.numero_mesa,
            "electores_habiles": mesa.electores_habiles,
            "estado": mesa.status,
            "asignacion_id": asign.id if asign else None,
            "asignado_a": (persona.nombre_completo if persona else None),
            "asignado_a_id": (persona.id if persona else None),
            "tipo": asign.tipo if asign else None,
            "es_del_personero": bool(
                usuario_id is not None and persona and persona.id == usuario_id),
        }
        salida.append(item)
    return salida


@router.post("/campo/checkin", response_model=V1CheckinOut)
def checkin(payload: V1CheckinIn, db: Session = Depends(get_db),
            usuario: Usuario = Depends(usuario_actual)):
    """Check-in GPS: valida que el personero esté EN el local.

    Calcula Haversine contra las coordenadas del local (radio 300 m). Dentro
    del radio la asignación pasa a PRESENTE; fuera, queda registrado el
    intento con su distancia (auditoría anti-fraude).
    """
    table = _mesa_en_alcance(db, usuario, payload.numero_mesa)
    asign = (
        db.query(AsignacionPersonero)
        .filter(AsignacionPersonero.usuario_id == usuario.id,
                AsignacionPersonero.mesa_id == table.id)
        .order_by(AsignacionPersonero.id)
        .first()
    )
    if asign is None:
        if usuario.rol in ROLES_GESTORES:
            raise HTTPException(
                status_code=422,
                detail="No tienes asignación en esta mesa (los gestores no "
                       "hacen check-in; asigna a tu personero)")
        raise HTTPException(
            status_code=403,
            detail="No estás asignado a esta mesa: pide tu asignación al "
                   "coordinador")

    venue = db.query(Venue).filter(Venue.id == table.venue_id).first()
    distancia = haversine_m(payload.latitud, payload.longitud,
                            venue.latitude, venue.longitude)
    dentro = distancia <= RADIO_LOCAL_M

    db.add(CheckinPersonero(
        asignacion_id=asign.id, latitud=payload.latitud,
        longitud=payload.longitud, presicion_m=payload.precision_m,
        dentro_de_radio=dentro, distancia_m=round(distancia, 1),
        dispositivo=payload.dispositivo))
    if dentro and asign.estado != "PRESENTE":
        asign.estado = "PRESENTE"
    db.commit()
    logger.info("checkin %s mesa %s: %sm %s", usuario.email,
                payload.numero_mesa, round(distancia, 1),
                "DENTRO" if dentro else "FUERA")
    return V1CheckinOut(
        dentro_de_radio=dentro, distancia_m=round(distancia, 1),
        estado=asign.estado, local=venue.name,
        mensaje=(f"Presencia validada en {venue.name}."
                 if dentro else
                 f"Fuera del radio del local ({round(distancia, 1)} m > "
                 f"{int(RADIO_LOCAL_M)} m). Acércate al local y reintenta."),
    )


@router.get("/campo/mi-estado", response_model=V1MiEstadoOut)
def mi_estado(db: Session = Depends(get_db),
              usuario: Usuario = Depends(usuario_actual)):
    """Asignaciones del usuario, último check-in y presencia validada hoy."""
    hoy = _hoy_utc()
    filas = (
        db.query(AsignacionPersonero, Table, Venue)
        .join(Table, Table.id == AsignacionPersonero.mesa_id)
        .join(Venue, Venue.id == Table.venue_id)
        .filter(AsignacionPersonero.usuario_id == usuario.id)
        .order_by(Table.numero_mesa)
        .all()
    )
    asignaciones = []
    validada = False
    ultimo = None
    for asign, mesa, local in filas:
        check = (
            db.query(CheckinPersonero)
            .filter(CheckinPersonero.asignacion_id == asign.id)
            .order_by(CheckinPersonero.created_at.desc())
            .first()
        )
        if check is not None and (
                ultimo is None or str(check.created_at) > ultimo):
            ultimo = check.created_at.isoformat() if check.created_at else None
        ok_hoy = bool(
            check is not None and check.dentro_de_radio
            and check.created_at is not None
            and str(check.created_at)[:10] == hoy)
        if ok_hoy:
            validada = True
        asignaciones.append({
            "numero_mesa": mesa.numero_mesa, "local": local.name,
            "ubigeo": local.ubigeo, "tipo": asign.tipo, "estado": asign.estado,
            "checkin_hoy": bool(ok_hoy),
        })
    return V1MiEstadoOut(asignaciones=asignaciones,
                         presencia_validada=validada,
                         ultimo_checkin=ultimo)


# ---------------------------------------------------------------------------
# Padrón de personeros (gestores)
# ---------------------------------------------------------------------------

@router.get("/campo/personeros")
def listar_personeros(db: Session = Depends(get_db),
                      usuario: Usuario = Depends(requerir_rol(*ROLES_GESTORES))):
    """Personeros/Delegados del alcance del gestor con sus mesas, estado y
    último check-in. Fuente de la pestaña «Personeros» (reorganiza al personal
    de campo fuera del dashboard general)."""
    equipo = db.query(Usuario).filter(
        Usuario.rol.in_(("PERSONERO", "DELEGADO_MESA"))).all()
    if not es_rol_global(usuario):
        prefijos = sorted({(u or "").rstrip("0") or u
                           for u in alcance_ubigeos(usuario)})
        equipo = [
            u for u in equipo
            if any(_en_alcance(a, prefijos) for a in alcance_ubigeos(u))
        ]

    salida = []
    for p in sorted(equipo, key=lambda u: (u.apellidos, u.nombres)):
        filas = (
            db.query(AsignacionPersonero, Table, Venue)
            .join(Table, Table.id == AsignacionPersonero.mesa_id)
            .join(Venue, Venue.id == Table.venue_id)
            .filter(AsignacionPersonero.usuario_id == p.id)
            .order_by(Table.numero_mesa)
            .all()
        )
        mesas = []
        for asign, mesa, local in filas:
            check = (
                db.query(CheckinPersonero)
                .filter(CheckinPersonero.asignacion_id == asign.id)
                .order_by(CheckinPersonero.created_at.desc())
                .first()
            )
            mesas.append({
                "numero_mesa": mesa.numero_mesa, "local": local.name,
                "ubigeo": local.ubigeo, "tipo": asign.tipo,
                "estado": asign.estado, "asignacion_id": asign.id,
                "ultimo_checkin": (check.created_at.isoformat()
                                   if check and check.created_at else None),
                "dentro_de_radio": bool(check.dentro_de_radio) if check else None,
                "distancia_m": check.distancia_m if check else None,
            })
        salida.append({
            "id": p.id, "email": str(p.email), "dni": p.dni,
            "nombre_completo": p.nombre_completo, "telefono": p.telefono,
            "rol": p.rol, "activo": p.activo,
            "alcance_ubigeos": alcance_ubigeos(p),
            "mesas": mesas,
            "presente_hoy": any(
                m["estado"] == "PRESENTE" for m in mesas),
        })
    return salida


def _en_alcance(ubigeo: str, prefijos: list[str]) -> bool:
    return any((ubigeo or "").startswith(p) for p in prefijos)


# ---------------------------------------------------------------------------
# Check de validación previo al registro
# ---------------------------------------------------------------------------

@router.get("/actas/checklist", response_model=V1ChecklistOut)
def checklist(numero_mesa: str = Query(..., min_length=6, max_length=6,
                                       pattern=r"^[0-9]{6}$"),
              db: Session = Depends(get_db),
              usuario: Usuario = Depends(usuario_actual)):
    """Pre-vuelo del acta: padrón, presencia, oferta por nivel y duplicados.

    El formulario lo consulta al cargar la mesa y pinta el check de
    validación (✓/✗ por ítem); ``puede_registrar`` habilita el envío.
    """
    table = _mesa_en_alcance(db, usuario, numero_mesa)
    venue = db.query(Venue).filter(Venue.id == table.venue_id).first()

    es_campo = usuario.rol in ROLES_CAMPO
    asignado = mesa_asignada(db, usuario, table.id)
    presencia = (presencia_validada(db, usuario.id, venue.id)
                 if es_campo else True)

    oferta: dict[str, int] = {}
    for tipo, modelo in MODELOS_NIVEL.items():
        ambito = ubigeo_de_nivel(venue.ubigeo or "", CLAVE_NIVEL[tipo])
        oferta[tipo] = (
            db.query(modelo).filter(modelo.ubigeo == ambito).count())

    existentes = [
        tipo for tipo, clave in CLAVE_NIVEL.items()
        if db.query(Record.id).filter(
            Record.table_id == table.id,
            Record.candidate_type == clave).first() is not None
    ]

    items = [
        {"clave": "asignacion", "etiqueta": "Mesa asignada",
         "ok": asignado,
         "detalle": ("Mesa asignada a ti"
                     if asignado else
                     ("Todas las mesas (supervisor)" if not es_campo
                      else "Pide tu asignación al coordinador"))},
        {"clave": "padron", "etiqueta": "Mesa en padrón",
         "ok": True, "detalle": f"{venue.name} · {table.electores_habiles or '?'} hábiles"},
        {"clave": "habiles", "etiqueta": "Padrón de electores",
         "ok": bool(table.electores_habiles),
         "detalle": (f"{table.electores_habiles} electores (tope R2)"
                     if table.electores_habiles else "Sin padrón: no se puede validar R2")},
        {"clave": "presencia", "etiqueta": "Personero en el local",
         "ok": bool(presencia),
         "detalle": ("Check-in GPS válido hoy"
                     if presencia else
                     ("Exento (supervisor)" if not es_campo
                      else "Sin check-in válido: regístralo en el local"))},
    ]
    for tipo in ("REGIONAL", "PROVINCIAL", "DISTRITAL"):
        n = oferta.get(tipo, 0)
        items.append({
            "clave": f"oferta_{tipo.lower()}", "etiqueta": f"Oferta {tipo}",
            "ok": n > 0,
            "detalle": (f"{n} organizaciones en el acta"
                        if n else "Sin oferta cargada para este ámbito")})
    items.append({
        "clave": "duplicados", "etiqueta": "Actas ya registradas",
        "ok": True,
        "detalle": (f"Niveles con acta: {', '.join(existentes)} (se re-digita)"
                    if existentes else "Mesa sin actas: los 3 niveles libres")})

    puede = (bool(table.electores_habiles) and bool(presencia)
             and bool(asignado) and any(oferta.values()))
    return V1ChecklistOut(
        numero_mesa=numero_mesa, local=venue.name,
        ubigeo=venue.ubigeo or "", electores_habiles=table.electores_habiles,
        presencia_validada=bool(presencia), oferta_por_nivel=oferta,
        actas_existentes=existentes, puede_registrar=puede,
        items=items)
