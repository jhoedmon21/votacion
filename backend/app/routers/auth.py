"""Router de autenticación: login, sesión, logout y refresh de token."""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy.orm import Session

from app.core.auth import (autenticar, cerrar_sesion, necesita_refresh,
                           refrescar_sesion, requerir_rol, sesion_actual,
                           usuario_actual, alcance_ubigeos)
from app.core.database import get_db
from app.core.models import (AccesoLog, ROLES_SISTEMA, Usuario,
                              UsuarioAlcance)
from app.core.security import SESSION_TTL_HORAS, hash_password

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/auth", tags=["auth"])


class LoginIn(BaseModel):
    email: EmailStr
    contrasena: str = Field(min_length=1, max_length=200)
    dispositivo: str | None = Field(default=None, max_length=120)


class TokenOut(BaseModel):
    token: str
    tipo: str = "bearer"
    expira_en_horas: int
    usuario: dict


def _serializar_usuario(usuario: Usuario) -> dict:
    return {
        "id": usuario.id,
        "email": str(usuario.email),
        "dni": usuario.dni,
        "nombres": usuario.nombres,
        "apellidos": usuario.apellidos,
        "nombre_completo": usuario.nombre_completo,
        "rol": usuario.rol,
        "alcance_ubigeos": alcance_ubigeos(usuario),
        "debe_cambiar_clave": usuario.debe_cambiar_clave,
    }


@router.post("/login", response_model=TokenOut)
def login(payload: LoginIn, request: Request, db: Session = Depends(get_db)):
    """Valida credenciales (bcrypt) y emite un token de sesión."""
    usuario, token, _expira = autenticar(
        db, request, payload.email, payload.contrasena, payload.dispositivo
    )
    return {
        "token": token,
        "tipo": "bearer",
        "expira_en_horas": SESSION_TTL_HORAS,
        "usuario": _serializar_usuario(usuario),
    }


@router.get("/me")
def me(usuario: Usuario = Depends(usuario_actual)):
    """Datos del usuario autenticado, con su alcance territorial."""
    return _serializar_usuario(usuario)


@router.post("/logout")
def logout(request: Request, db: Session = Depends(get_db),
           sesion: "Sesion" = Depends(sesion_actual)):
    """Revoca la sesión actual (el token deja de servir de inmediato)."""
    cerrar_sesion(db, sesion)
    return {"ok": True, "mensaje": "Sesión cerrada"}


@router.post("/refresh")
def refresh(request: Request, db: Session = Depends(get_db),
            sesion: "Sesion" = Depends(sesion_actual)):
    """Rotación de token: revoca la sesión actual y emite una nueva."""
    token, expira = refrescar_sesion(db, sesion)
    return {"token": token, "tipo": "bearer", "expira_at": expira.isoformat()}


@router.get("/sesion")
def estado_sesion(sesion: "Sesion" = Depends(sesion_actual),
                  usuario: Usuario = Depends(usuario_actual)):
    """Estado de la sesión: expiración y si conviene refrescar el token."""
    return {
        "expira_at": sesion.expira_at.isoformat(),
        "refrescar": necesita_refresh(sesion),
        "rol": usuario.rol,
    }


@router.get("/usuarios")
def listar_usuarios(usuario: Usuario = Depends(usuario_actual),
                    db: Session = Depends(get_db)):
    """Lista usuarios visibles: todos (SUPER_ADMIN) o los del alcance propio.

    Coordinadores ven a su equipo (alcance intersectado) para gestionarlo;
    el resto de roles sólo se ve a sí mismo.
    """
    filas = db.query(Usuario).order_by(Usuario.rol, Usuario.apellidos).all()
    if usuario.rol in ("SUPER_ADMIN", "DIGITADOR_GLOBAL"):
        # Alcance nacional: ambos ven a todo el padrón de usuarios.
        visibles = filas
    elif usuario.rol in ("COORD_PROVINCIAL", "RESPONSABLE_DISTRITAL"):
        prefijos = _prefijos_de(usuario)
        visibles = [
            u for u in filas
            if u.id == usuario.id or any(
                _en_alcance(a, prefijos) for a in alcance_ubigeos(u)
            )
        ]
    else:
        visibles = [u for u in filas if u.id == usuario.id]
    return [_resumen_usuario(u) for u in visibles]


# ---------------------------------------------------------------------------
# Alta y gestión de usuarios (jerarquía operativa)
# ---------------------------------------------------------------------------

# Quién puede crear cada rol. SUPER_ADMIN crea cualquiera; los coordinadores
# sólo crean hacia abajo dentro de su alcance territorial. El DIGITADOR_GLOBAL
# es transversal y SÓLO lo crea SUPER_ADMIN (no aparece en ningún otro set);
# además nunca lleva filas en usuario_alcance (alcance nacional implícito).
ROLES_CREABLES = {
    "SUPER_ADMIN": set(ROLES_SISTEMA),
    "COORD_PROVINCIAL": {"RESPONSABLE_DISTRITAL", "COORD_LOCAL",
                         "DELEGADO_MESA", "PERSONERO"},
    "RESPONSABLE_DISTRITAL": {"COORD_LOCAL", "DELEGADO_MESA", "PERSONERO"},
}


class UsuarioCrearIn(BaseModel):
    email: EmailStr
    dni: str = Field(min_length=8, max_length=8, pattern=r"^[0-9]{8}$")
    nombres: str = Field(min_length=1, max_length=80)
    apellidos: str = Field(min_length=1, max_length=80)
    telefono: str | None = Field(default=None, max_length=20)
    rol: str
    contrasena: str = Field(min_length=8, max_length=200)
    alcance_ubigeos: list[str] = Field(default_factory=list)


class UsuarioEditarIn(BaseModel):
    telefono: str | None = Field(default=None, max_length=20)
    activo: bool | None = None
    alcance_ubigeos: list[str] | None = None


class ClaveResetIn(BaseModel):
    nueva_clave: str = Field(min_length=8, max_length=200)


def _resumen_usuario(u: Usuario) -> dict:
    return {
        "id": u.id, "email": str(u.email), "dni": u.dni,
        "nombres": u.nombres, "apellidos": u.apellidos,
        "nombre_completo": u.nombre_completo, "telefono": u.telefono,
        "rol": u.rol, "activo": u.activo,
        "alcance_ubigeos": alcance_ubigeos(u),
        "debe_cambiar_clave": u.debe_cambiar_clave,
        "ultimo_acceso": u.ultimo_acceso.isoformat() if u.ultimo_acceso else None,
    }


def _prefijos_de(usuario: Usuario) -> list[str]:
    """Prefijos territoriales del alcance propio ('0401' cubre 0401xx)."""
    return sorted({(u or "").rstrip("0") or u for u in alcance_ubigeos(usuario)})


def _en_alcance(ubigeo: str, prefijos: list[str]) -> bool:
    return any((ubigeo or "").startswith(p) for p in prefijos)


def _puede_gestionar(creador: Usuario, objetivo: Usuario) -> None:
    """403 si el creador no puede gestionar al objetivo (rol o alcance)."""
    if creador.rol == "SUPER_ADMIN":
        return
    if objetivo.rol not in ROLES_CREABLES.get(creador.rol, set()):
        raise HTTPException(
            status_code=403,
            detail=f"Tu rol ({creador.rol}) no puede gestionar rol {objetivo.rol}",
        )
    prefijos = _prefijos_de(creador)
    if not prefijos or not all(
        _en_alcance(a, prefijos) for a in alcance_ubigeos(objetivo)
    ):
        raise HTTPException(
            status_code=403, detail="El usuario está fuera de tu alcance territorial",
        )


def _validar_alcance_nuevo(creador: Usuario, rol: str, alcance: list[str]) -> None:
    if rol not in ROLES_SISTEMA:
        raise HTTPException(status_code=422, detail=f"Rol inválido: {rol}")
    if rol not in ROLES_CREABLES.get(creador.rol, set()):
        raise HTTPException(
            status_code=403,
            detail=f"Tu rol ({creador.rol}) no puede crear rol {rol}",
        )
    if not all(isinstance(u, str) and len(u) == 6 and u.isdigit() for u in alcance):
        raise HTTPException(status_code=422, detail="Alcance: ubigeos de 6 dígitos")
    if creador.rol != "SUPER_ADMIN":
        prefijos = _prefijos_de(creador)
        fuera = [u for u in alcance if not _en_alcance(u, prefijos)]
        if fuera or (rol != "SUPER_ADMIN" and not alcance):
            raise HTTPException(
                status_code=403,
                detail=f"Alcance fuera de tu jurisdicción: {', '.join(fuera) or 'vacío'}",
            )


@router.post("/usuarios")
def crear_usuario(payload: UsuarioCrearIn,
                  usuario: Usuario = Depends(usuario_actual),
                  db: Session = Depends(get_db)):
    """Alta de usuarios: SUPER_ADMIN crea cualquiera; coordinadores crean
    hacia abajo dentro de su alcance. Devuelve el usuario sin hash."""
    _validar_alcance_nuevo(usuario, payload.rol, payload.alcance_ubigeos)
    if db.query(Usuario).filter(Usuario.email == payload.email).first():
        raise HTTPException(status_code=409, detail="El email ya está registrado")
    if db.query(Usuario).filter(Usuario.dni == payload.dni).first():
        raise HTTPException(status_code=409, detail="El DNI ya está registrado")
    nuevo = Usuario(
        email=payload.email, dni=payload.dni,
        nombres=payload.nombres.strip(), apellidos=payload.apellidos.strip(),
        telefono=payload.telefono, rol=payload.rol,
        password_hash=hash_password(payload.contrasena),
        debe_cambiar_clave=True, activo=True,
    )
    db.add(nuevo)
    db.flush()
    for ubigeo in dict.fromkeys(payload.alcance_ubigeos):
        db.add(UsuarioAlcance(usuario_id=nuevo.id, ubigeo=ubigeo))
    db.commit()
    db.refresh(nuevo)
    logger.info("usuario creado: %s (%s) por %s", nuevo.email, nuevo.rol, usuario.email)
    return _resumen_usuario(nuevo)


@router.patch("/usuarios/{usuario_id}")
def editar_usuario(usuario_id: int, payload: UsuarioEditarIn,
                   usuario: Usuario = Depends(usuario_actual),
                   db: Session = Depends(get_db)):
    """Edita teléfono, estado activo y alcance. No permite desactivarse a sí
    mismo ni tocar SUPER_ADMIN sin serlo."""
    objetivo = db.query(Usuario).filter(Usuario.id == usuario_id).first()
    if objetivo is None:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    if objetivo.rol == "SUPER_ADMIN" and usuario.rol != "SUPER_ADMIN":
        raise HTTPException(status_code=403, detail="Sólo SUPER_ADMIN gestiona SUPER_ADMIN")
    _puede_gestionar(usuario, objetivo)
    if payload.activo is False and objetivo.id == usuario.id:
        raise HTTPException(status_code=422, detail="No puedes desactivarte a ti mismo")
    if payload.telefono is not None:
        objetivo.telefono = payload.telefono
    if payload.activo is not None:
        objetivo.activo = payload.activo
        if not payload.activo:
            objetivo.intentos_fallidos = 0
    if payload.alcance_ubigeos is not None:
        _validar_alcance_nuevo(usuario, objetivo.rol, payload.alcance_ubigeos)
        db.query(UsuarioAlcance).filter(UsuarioAlcance.usuario_id == objetivo.id).delete()
        for ubigeo in dict.fromkeys(payload.alcance_ubigeos):
            db.add(UsuarioAlcance(usuario_id=objetivo.id, ubigeo=ubigeo))
    db.commit()
    db.refresh(objetivo)
    return _resumen_usuario(objetivo)


@router.post("/usuarios/{usuario_id}/clave")
def reset_clave(usuario_id: int, payload: ClaveResetIn,
                usuario: Usuario = Depends(usuario_actual),
                db: Session = Depends(get_db)):
    """Restablece la contraseña (el usuario deberá cambiarla al entrar)."""
    objetivo = db.query(Usuario).filter(Usuario.id == usuario_id).first()
    if objetivo is None:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    if objetivo.rol == "SUPER_ADMIN" and usuario.rol != "SUPER_ADMIN":
        raise HTTPException(status_code=403, detail="Sólo SUPER_ADMIN gestiona SUPER_ADMIN")
    _puede_gestionar(usuario, objetivo)
    objetivo.password_hash = hash_password(payload.nueva_clave)
    objetivo.debe_cambiar_clave = True
    objetivo.intentos_fallidos = 0
    objetivo.bloqueado_hasta = None
    db.commit()
    logger.info("clave restablecida a %s por %s", objetivo.email, usuario.email)
    return {"ok": True, "mensaje": f"Clave de {objetivo.email} restablecida"}


@router.get("/accesos")
def ultimos_accesos(usuario: Usuario = Depends(requerir_rol("SUPER_ADMIN")),
                    db: Session = Depends(get_db), limite: int = 50):
    """Bitácora de accesos: sólo SUPER_ADMIN."""
    limite = max(1, min(limite, 200))
    filas = (
        db.query(AccesoLog)
        .order_by(AccesoLog.created_at.desc())
        .limit(limite)
        .all()
    )
    return [
        {
            "id": a.id, "email": str(a.email) if a.email else None,
            "exitoso": a.exitoso, "ip": a.ip, "detalle": a.detalle,
            "created_at": a.created_at.isoformat() if a.created_at else None,
        }
        for a in filas
    ]
