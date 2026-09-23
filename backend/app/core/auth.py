"""Autenticación, RBAC y alcance territorial para las rutas de la API.

Flujo:
  1. ``POST /api/auth/login`` valida credenciales con **bcrypt** y emite un
     token de sesión opaco (el cliente lo manda en ``Authorization: Bearer``).
  2. Cada petición pasa por ``usuario_actual``, que resuelve el token, valida
     expiración/revocación y carga al usuario con su alcance territorial.
  3. ``requerir_rol(...)`` restringe por rol; ``alcance_ubigeos`` devuelve los
     ubigeos que el usuario puede ver y ``validar_alcance_venue`` decide si un
     local concreto está dentro de su ámbito.
  4. ``contexto_rls`` fija ``app.usuario_id`` y ``app.rol_actual`` en la sesión
     de base: es lo que las políticas RLS del esquema PostgreSQL leen. Con el
     prototipo en SQLite es un no-op registrado en los logs de la petición, y
     con PostgreSQL real aplica defensa en profundidad por fila.

Bloqueo por fuerza bruta: 5 intentos fallidos en 15 minutos => 15 minutos de
bloqueo, contando por usuario (la bitácora queda en accesos_log).
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Iterable

from fastapi import Depends, Header, HTTPException, Request, status
from sqlalchemy import or_
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.models import (ROLES_GLOBALES, ROLES_SISTEMA, AccesoLog,
                              AsignacionPersonero, Sesion, Table, Usuario,
                              UsuarioAlcance, Venue)
from app.core.security import (REFRESH_UMBRAL_HORAS, SESSION_TTL_HORAS,
                               expirado, expiracion, generar_token,
                               hash_token, verificar_password)

logger = logging.getLogger(__name__)

MAX_INTENTOS = 5
VENTANA_BLOQUEO_MIN = 15
DURACION_BLOQUEO_MIN = 15

ESQUEMA = {"type": "http", "scheme": "bearer"}


# ---------------------------------------------------------------------------
# Utilidades de bitácora
# ---------------------------------------------------------------------------

def _ip(request: Request) -> str | None:
    return request.client.host if request.client else None


def _registrar_acceso(db: Session, request: Request, email: str | None,
                      exitoso: bool, detalle: str) -> None:
    db.add(AccesoLog(
        email=(email or "")[:160] or None,
        exitoso=exitoso,
        ip=_ip(request),
        user_agent=(request.headers.get("user-agent") or "")[:220] or None,
        detalle=detalle[:220],
    ))


# ---------------------------------------------------------------------------
# Resolución de usuario por token
# ---------------------------------------------------------------------------

def _cargar_usuario_con_alcance(db: Session, usuario_id: int) -> Usuario | None:
    usuario = db.get(Usuario, usuario_id)
    if usuario is None:
        return None
    # Carga anticipada del alcance (evita N+1 y permite validarlo en memoria)
    _ = list(usuario.alcance)
    return usuario


def resolver_token(db: Session, token: str) -> tuple[Usuario, Sesion] | None:
    """Devuelve (usuario, sesion) si el token es válido, activo y no expiró."""
    if not token:
        return None
    sesion = (
        db.query(Sesion)
        .filter(Sesion.token_hash == hash_token(token))
        .first()
    )
    if sesion is None or sesion.revocada or expirado(sesion.expira_at):
        return None
    if not sesion.usuario.activo:
        return None
    usuario = _cargar_usuario_con_alcance(db, sesion.usuario_id)
    if usuario is None:
        return None
    return usuario, sesion


# ---------------------------------------------------------------------------
# Dependencia principal
# ---------------------------------------------------------------------------

def credenciales_bearer(authorization: str | None = Header(default=None)) -> str | None:
    """Extrae el token del header Authorization: Bearer <token>."""
    if not authorization:
        return None
    partes = authorization.split(None, 1)
    if len(partes) == 2 and partes[0].lower() == "bearer" and partes[1].strip():
        return partes[1].strip()
    return None


def usuario_actual(
    request: Request,
    db: Session = Depends(get_db),
    token: str | None = Depends(credenciales_bearer),
) -> Usuario:
    """Resuelve el usuario del token. 401 si falta o es inválido."""
    if not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="No autenticado: falta el token Bearer",
            headers={"WWW-Authenticate": "Bearer"},
        )
    resuelto = resolver_token(db, token)
    if resuelto is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token inválido, expirado o revocado",
            headers={"WWW-Authenticate": "Bearer"},
        )
    usuario, sesion = resuelto

    # Contexto para la RLS de PostgreSQL (no-op en SQLite, ver docs)
    db.execute(_contexto_rls_sql(usuario))
    request.state.usuario = usuario
    request.state.sesion_id = sesion.id
    request.state.alcance_ubigeos = alcance_ubigeos(usuario)
    return usuario


# ---------------------------------------------------------------------------
# Roles y alcance
# ---------------------------------------------------------------------------

def es_rol_global(usuario: Usuario) -> bool:
    """True si el rol tiene alcance nacional y omite todo filtro ubigeo.

    Roles globales: SUPER_ADMIN (histórico) y DIGITADOR_GLOBAL (nuevo rol
    transversal). Ninguno necesita filas en ``usuario_alcance``.
    """
    return (usuario.rol or "") in ROLES_GLOBALES


def tiene_acceso_global(usuario: Usuario) -> bool:
    """Alias legible para chequeos de negocio (actas, dashboard, RLS)."""
    return es_rol_global(usuario)


def requerir_digitador_global_o_admin() -> object:
    """Dependencia: sólo DIGITADOR_GLOBAL o SUPER_ADMIN.

    Se usa en los endpoints de rectificación nacional y en la auditoría.
    """
    return requerir_rol("DIGITADOR_GLOBAL", "SUPER_ADMIN")


def omitir_scope_geografico(usuario: Usuario) -> bool:
    """¿Debe la consulta ignorar el scope geográfico? (decorador lógico).

    Úsalo al inicio de cualquier filtro territorial::

        if omitir_scope_geografico(usuario):
            query = db.query(Venue)  # sin filtros
        else:
            query = venues_en_alcance(db, usuario)
    """
    return es_rol_global(usuario)

def requerir_rol(*roles: str):
    """Fábrica de dependencia: exige uno de los roles dados."""
    roles_validos = [r for r in roles if r in ROLES_SISTEMA]
    if not roles_validos:
        raise ValueError(f"roles desconocidos: {roles}")

    def _dependencia(usuario: Usuario = Depends(usuario_actual)) -> Usuario:
        if usuario.rol not in roles_validos:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Requiere rol {' o '.join(roles_validos)} (tienes {usuario.rol})",
            )
        return usuario

    return _dependencia


def alcance_ubigeos(usuario: Usuario) -> list[str]:
    """Ubigeos visibles por el usuario. Rol global: [] significa 'todo el país'."""
    if es_rol_global(usuario):
        return []
    return sorted({a.ubigeo for a in usuario.alcance})


def _prefijo_alcance(ubigeo: str) -> str:
    """Prefijo territorial de un ubigeo codificado a 6 dígitos.

    040000 (departamento) -> '04'; 040100 (provincia) -> '0401';
    040112 (distrito) -> '040112'. Es la misma jerarquía por prefijo que
    usa la política RLS del esquema PostgreSQL.
    """
    limpio = (ubigeo or "").rstrip("0")
    return limpio if len(limpio) >= 2 else ubigeo


def venues_en_alcance(db: Session, usuario: Usuario):
    """Query de Venue filtrada por rol y alcance territorial.

    Jerarquía de visibilidad:
      SUPER_ADMIN / DIGITADOR_GLOBAL .. todo el país (sin filtros).
      Coordinadores ....... locales de su ámbito (prefijo de ubigeo).
      PERSONERO/DELEGADO .. SÓLO los locales de sus mesas asignadas: no ven
      datos generales de la región ni de otras mesas.
    """
    query = db.query(Venue)
    if es_rol_global(usuario):
        return query
    if usuario.rol in ("PERSONERO", "DELEGADO_MESA"):
        sub = (
            db.query(Table.venue_id)
            .join(AsignacionPersonero,
                  AsignacionPersonero.mesa_id == Table.id)
            .filter(AsignacionPersonero.usuario_id == usuario.id)
            .distinct()
            .subquery()
        )
        return query.filter(Venue.id.in_(sub))
    ubigeos = alcance_ubigeos(usuario)
    if not ubigeos:
        # Rol territorial sin alcance asignado: no ve ningún local
        return query.filter(Venue.id < 0)
    prefijos = sorted({_prefijo_alcance(u) for u in ubigeos})
    condiciones = [Venue.ubigeo.like(f"{p}%") for p in prefijos]
    return query.filter(or_(*condiciones))


def validar_alcance_venue(db: Session, usuario: Usuario, venue_id: int) -> Venue:
    """Devuelve el venue si está en el alcance del usuario; 403 si no."""
    venue = (
        venues_en_alcance(db, usuario)
        .filter(Venue.id == venue_id)
        .first()
    )
    if venue is None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="El local de votación está fuera de tu alcance territorial",
        )
    return venue


# ---------------------------------------------------------------------------
# Contexto RLS por petición
# ---------------------------------------------------------------------------

def _contexto_rls_sql(usuario: Usuario):
    """SQL que fija el contexto de sesión para las políticas RLS.

    En PostgreSQL (esquema de producción) las políticas de `actas` leen
    ``app.usuario_id`` y ``app.rol_actual``. En el prototipo SQLite este
    statement es un no-op (SQLite no tiene set_config) y se registra.
    """
    from sqlalchemy import text

    dialecto = db_dialecto()
    if dialecto != "postgresql":
        logger.debug(
            "RLS context (no-op en %s): usuario_id=%s rol=%s alcance=%s",
            dialecto, usuario.id, usuario.rol, alcance_ubigeos(usuario),
        )
        return text("SELECT 1")

    # PostgreSQL real: SET LOCAL dentro de la transacción de la petición
    return text(
        "SELECT set_config('app.usuario_id', :uid, true), "
        "       set_config('app.rol_actual', :rol, true)"
    ).bindparams(uid=str(usuario.id), rol=usuario.rol)


def db_dialecto() -> str:
    from app.core.database import engine
    return engine.dialect.name


# ---------------------------------------------------------------------------
# Login / logout / refresh (lo usa el router /api/auth)
# ---------------------------------------------------------------------------

def autenticar(db: Session, request: Request, email: str, contrasena: str,
               dispositivo: str | None) -> tuple[Usuario, str, datetime]:
    """Valida credenciales y crea la sesión. Lanza HTTPException si falla."""
    email_norm = (email or "").strip().lower()
    usuario = (
        db.query(Usuario)
        .filter(func_lower_email(Usuario.email) == email_norm)
        .first()
    )

    if usuario is None:
        _registrar_acceso(db, request, email_norm, False, "usuario desconocido")
        db.commit()
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="Credenciales inválidas")

    if not usuario.activo:
        _registrar_acceso(db, request, email_norm, False, "cuenta desactivada")
        db.commit()
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                            detail="Cuenta desactivada. Contacta al SUPER_ADMIN.")

    ahora = datetime.now(timezone.utc)
    if usuario.bloqueado_hasta is not None:
        bloqueo = usuario.bloqueado_hasta
        if bloqueo.tzinfo is None:
            bloqueo = bloqueo.replace(tzinfo=timezone.utc)
        if bloqueo > ahora:
            minutos = int((bloqueo - ahora).total_seconds() // 60) + 1
            _registrar_acceso(db, request, email_norm, False, "cuenta bloqueada")
            db.commit()
            raise HTTPException(status_code=status.HTTP_423_LOCKED,
                                detail=f"Cuenta bloqueada por intentos fallidos. Reintenta en {minutos} min.")
        usuario.bloqueado_hasta = None
        usuario.intentos_fallidos = 0

    if not verificar_password(contrasena, usuario.password_hash):
        usuario.intentos_fallidos = (usuario.intentos_fallidos or 0) + 1
        detalle = f"clave incorrecta (intento {usuario.intentos_fallidos})"
        if usuario.intentos_fallidos >= MAX_INTENTOS:
            usuario.bloqueado_hasta = ahora + timedelta(minutes=DURACION_BLOQUEO_MIN)
            usuario.intentos_fallidos = 0
            detalle += f" => bloqueado {DURACION_BLOQUEO_MIN} min"
        _registrar_acceso(db, request, email_norm, False, detalle)
        db.commit()
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="Credenciales inválidas")

    # Éxito: reinicia contadores, crea la sesión y audita
    usuario.intentos_fallidos = 0
    usuario.bloqueado_hasta = None
    usuario.ultimo_acceso = ahora

    token = generar_token()
    sesion = Sesion(
        usuario_id=usuario.id,
        token_hash=hash_token(token),
        dispositivo=(dispositivo or "")[:120] or None,
        ip=_ip(request),
        expira_at=expiracion(SESSION_TTL_HORAS),
    )
    db.add(sesion)
    _registrar_acceso(db, request, email_norm, True, "login ok")
    db.commit()
    db.refresh(sesion)
    db.refresh(usuario)
    logger.info("login ok: %s (%s) desde %s", usuario.email, usuario.rol, _ip(request))
    return usuario, token, sesion.expira_at


def cerrar_sesion(db: Session, sesion: Sesion) -> None:
    sesion.revocada = True
    db.commit()


def refrescar_sesion(db: Session, sesion: Sesion) -> tuple[str, datetime]:
    """Revoca la sesión actual y emite una nueva (rotación de token)."""
    if not sesion.usuario.activo:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cuenta desactivada")
    nueva_exp = expiracion(SESSION_TTL_HORAS)
    sesion.revocada = True
    token = generar_token()
    nueva = Sesion(
        usuario_id=sesion.usuario_id,
        token_hash=hash_token(token),
        dispositivo=sesion.dispositivo,
        ip=sesion.ip,
        expira_at=nueva_exp,
    )
    db.add(nueva)
    db.commit()
    db.refresh(nueva)
    return token, nueva.expira_at


def necesita_refresh(sesion: Sesion) -> bool:
    """True si la sesión expira pronto (para que el cliente la renueve)."""
    expira = sesion.expira_at
    if expira.tzinfo is None:
        expira = expira.replace(tzinfo=timezone.utc)
    return expira <= datetime.now(timezone.utc) + timedelta(hours=REFRESH_UMBRAL_HORAS)


def func_lower_email(columna):
    """lower() portable entre SQLite y PostgreSQL para emails."""
    from sqlalchemy import func
    return func.lower(columna)


# ---------------------------------------------------------------------------
# Sesión desde petición autenticada (para /me y /logout)
# ---------------------------------------------------------------------------

def sesion_actual(request: Request, db: Session = Depends(get_db),
                  token: str | None = Depends(credenciales_bearer)) -> Sesion:
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="No autenticado")
    resuelto = resolver_token(db, token)
    if resuelto is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="Token inválido, expirado o revocado")
    usuario, sesion = resuelto
    request.state.usuario = usuario
    return sesion
