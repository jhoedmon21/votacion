"""Seed idempotente de usuarios demo (bcrypt) para el prototipo.

Espeja ``backend/sql/seed_auth_arequipa.sql`` (mismos correos, mismos roles,
mismas contraseñas) sobre el prototipo SQLite. Corre al arrancar la app, así
que las credenciales de prueba existen desde el primer arranque.
"""
from __future__ import annotations

import logging

from sqlalchemy.orm import Session

from app.core.models import ROLES_SISTEMA, Usuario, UsuarioAlcance, Venue
from app.core.security import hash_password

logger = logging.getLogger(__name__)

# (email, dni, nombres, apellidos, telefono, rol, contraseña, [alcance ubigeo])
USUARIOS_DEMO = [
    ("admin@computoarequipa.gob.pe", "40000001", "Rosa", "Delgado Vela",
     "959000001", "SUPER_ADMIN", "Admin.Arequipa2026", []),
    ("coord.arequipa@computoarequipa.gob.pe", "40000002", "Iván", "Paredes Chávez",
     "959000002", "COORD_PROVINCIAL", "Coord.Arequipa2026", ["040100"]),
    ("coord.caylloma@computoarequipa.gob.pe", "40000003", "Milagros", "Huanca Sullo",
     "959000003", "COORD_PROVINCIAL", "Coord.Caylloma2026", ["040500"]),
    ("resp.paucarpata@computoarequipa.gob.pe", "40000004", "Jorge", "Mamani Quispe",
     "959000004", "RESPONSABLE_DISTRITAL", "Distrital.Paucarpata2026", ["040112"]),
    ("resp.yanahuara@computoarequipa.gob.pe", "40000005", "Lucía", "Bustinza Flores",
     "959000005", "RESPONSABLE_DISTRITAL", "Distrital.Yanahuara2026", ["040126"]),
    ("personero.paucarpata@computoarequipa.gob.pe", "40000006", "Abel", "Cáceres Puma",
     "959000006", "PERSONERO", "Personero.Paucarpata2026", ["040112"]),
    # Digitador Global: alcance nacional (sin filas en usuario_alcance).
    ("digitador.global@computoarequipa.gob.pe", "40000009", "Elena", "Quispe Vargas",
     "959000009", "DIGITADOR_GLOBAL", "Digitador.Global2026", []),
]

ROL_A_PREFIJO = {
    "SUPER_ADMIN": "admin",
    "COORD_PROVINCIAL": "coord",
    "RESPONSABLE_DISTRITAL": "resp",
    "PERSONERO": "personero",
}


def asegurar_usuario_demo(db: Session) -> None:
    """Crea los usuarios demo si faltan; no toca los existentes."""
    creados = 0
    for email, dni, nombres, apellidos, telefono, rol, clave, alcance in USUARIOS_DEMO:
        if rol not in ROLES_SISTEMA:
            continue
        existe = db.query(Usuario).filter(Usuario.email == email).first()
        if existe is not None:
            continue
        usuario = Usuario(
            email=email, dni=dni, nombres=nombres, apellidos=apellidos,
            telefono=telefono, rol=rol,
            password_hash=hash_password(clave),
            debe_cambiar_clave=True,
        )
        db.add(usuario)
        db.flush()
        for ubigeo in alcance:
            db.add(UsuarioAlcance(usuario_id=usuario.id, ubigeo=ubigeo))
        creados += 1
        logger.info("usuario demo creado: %s (%s)", email, rol)

    if creados:
        db.commit()
        logger.info("seed de usuarios demo: %d creados", creados)


def asegurar_ubigeo_venues(db: Session) -> None:
    """Etiqueta los locales existentes con el ubigeo de Paucarpata si falta.

    El prototipo vive en Paucarpata (040112): el alcance territorial del
    RESPONSABLE_DISTRITAL y del PERSONERO demo filtra por ese ubigeo.
    """
    sin_ubigeo = db.query(Venue).filter(Venue.ubigeo.is_(None)).all()
    for venue in sin_ubigeo:
        venue.ubigeo = "040112"
    if sin_ubigeo:
        db.commit()
        logger.info("venues etiquetados con ubigeo 040112: %d", len(sin_ubigeo))
