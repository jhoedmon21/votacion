"""Seguridad criptográfica: hash bcrypt y tokens de sesión.

* bcrypt (cost 12) para contraseñas — compatible con el seed SQL del esquema
  de producción (pgcrypto ``gen_salt('bf', 12)`` produce el mismo formato
  ``$2a$`` que la librería ``bcrypt`` de Python).
* Tokens de sesión: 256 bits de entropía, se guardan SOLO como SHA-256 en la
  base (una fuga de la base no revela tokens válidos) y expiran.

El prototipo corre sobre SQLite con SQLAlchemy; las mismas reglas replican lo
que el esquema PostgreSQL exige en ``usuarios`` (CHECK de formato bcrypt) y
``sesiones`` (revocación, expiración).
"""
from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone

import bcrypt

# Cost 12: ~250 ms por hash en una laptop 2026. Es el mismo coste del seed SQL.
BCRYPT_ROUNDS = 12

# Vida útil de la sesión. La PWA renueva el token con /api/auth/refresh.
SESSION_TTL_HORAS = 12
REFRESH_TTL_HORAS = 72
REFRESH_UMBRAL_HORAS = 6  # si queda menos de esto, el login/refresh renueva

ALPHABET_TOKEN = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"


# ---------------------------------------------------------------------------
# Contraseñas
# ---------------------------------------------------------------------------

def hash_password(contrasena: str) -> str:
    """Hash bcrypt con salt aleatorio. Nunca se guarda texto plano."""
    if not contrasena or len(contrasena) < 8:
        raise ValueError("la contraseña debe tener al menos 8 caracteres")
    return bcrypt.hashpw(contrasena.encode("utf-8"), bcrypt.gensalt(rounds=BCRYPT_ROUNDS)).decode("ascii")


def verificar_password(contrasena: str, hash_guardado: str) -> bool:
    """Comparación en tiempo constante. Devuelve False ante hash corrupto."""
    if not contrasena or not hash_guardado:
        return False
    try:
        return bcrypt.checkpw(contrasena.encode("utf-8"), hash_guardado.encode("ascii"))
    except (ValueError, UnicodeEncodeError):
        return False


# ---------------------------------------------------------------------------
# Tokens de sesión
# ---------------------------------------------------------------------------

def generar_token() -> str:
    """Token opaco de ~43 caracteres (256 bits de entropía). Va al cliente."""
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    """SHA-256 hex del token: lo único que se persiste en la base."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def expiracion(horas: int = SESSION_TTL_HORAS) -> datetime:
    return datetime.now(timezone.utc) + timedelta(hours=horas)


def expirado(expira_at: datetime | None) -> bool:
    if expira_at is None:
        return True
    if expira_at.tzinfo is None:
        expira_at = expira_at.replace(tzinfo=timezone.utc)
    return expira_at <= datetime.now(timezone.utc)
