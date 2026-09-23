"""Configuración del ETL del padrón (variables de entorno + territorio).

Todas las opciones tienen default sensato para desarrollo; producción las
sobrescribe vía entorno o archivo `.env` (ver `onpe-scraper/.env.example`).
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Territorio: departamento AREQUIPA (ubigeo base '04') y sus 8 provincias.
# El prefijo de 4 dígitos identifica la provincia (0401 = AREQUIPA, ...).
# La lista fina de los 109 distritos vive en backend/app/core/ubigeo_catalogo.py
# (fuente única); aquí sólo los prefijos estables para filtrar y reportar.
# ---------------------------------------------------------------------------
DEPARTAMENTO_UBIGEO = "04"
DEPARTAMENTO_NOMBRE = "AREQUIPA"

PROVINCIAS: tuple[tuple[str, str], ...] = (
    ("0401", "AREQUIPA"),
    ("0402", "CAMANA"),
    ("0403", "CARAVELI"),
    ("0404", "CASTILLA"),
    ("0405", "CAYLLOMA"),
    ("0406", "CONDESUYOS"),
    ("0407", "ISLAY"),
    ("0408", "LA UNION"),
)

PREFIJO_A_PROVINCIA: dict[str, str] = dict(PROVINCIAS)


def provincia_de_ubigeo(ubigeo: str) -> str | None:
    """Provincia de un ubigeo de 6 dígitos (None si no es de Arequipa)."""
    if len(ubigeo) == 6 and ubigeo.startswith(DEPARTAMENTO_UBIGEO):
        return PREFIJO_A_PROVINCIA.get(ubigeo[:4])
    return None


@dataclass
class Ajustes:
    """Ajustes efectivos del ETL (inyectables para tests)."""

    database_url: str = "sqlite:///./padron_arequipa.db"
    padron_schema: str = ""          # ej. "padron" en PG multi-esquema; "" = default
    fuente: str = "archivo"          # archivo | catalogo | check
    archivo: str = ""                # ruta CSV/JSON del archivo oficial
    catalogo_base: str = "https://www.datosabiertos.gob.pe"
    catalogo_termino: str = "locales de votacion ONPE"
    recurso_url: str = ""            # URL directa al recurso (ZIP/CSV), si se conoce
    timeout_seg: int = 30
    pausa_seg: float = 1.5           # rate-limit entre peticiones
    reintentos: int = 3
    user_agent: str = (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    )
    solo_provincia: str = ""         # ej. "CAYLLOMA"; "" = las 8
    lote_upsert: int = 500
    dry_run: bool = False
    log_nivel: str = "INFO"
    dir_salida: Path = field(default_factory=lambda: Path("data"))

    @classmethod
    def desde_entorno(cls, **sobrescribir) -> "Ajustes":
        """Construye ajustes desde entorno (.env ya cargado por el CLI)."""
        def env(nombre: str, default: str = "") -> str:
            return os.environ.get(nombre, default)

        def env_float(nombre: str, default: float) -> float:
            try:
                return float(env(nombre, str(default)))
            except ValueError:
                return default

        def env_int(nombre: str, default: int) -> int:
            try:
                return int(float(env(nombre, str(default))))
            except ValueError:
                return default

        base = cls(
            database_url=env("DATABASE_URL", "sqlite:///./padron_arequipa.db"),
            padron_schema=env("PADRON_SCHEMA", ""),
            fuente=env("PADRON_FUENTE", "archivo"),
            archivo=env("PADRON_ARCHIVO", ""),
            catalogo_base=env("CATALOGO_BASE", "https://www.datosabiertos.gob.pe").rstrip("/"),
            catalogo_termino=env("CATALOGO_TERMINO", "locales de votacion ONPE"),
            recurso_url=env("PADRON_RECURSO_URL", ""),
            timeout_seg=env_int("HTTP_TIMEOUT_SEG", 30),
            pausa_seg=env_float("HTTP_PAUSA_SEG", 1.5),
            reintentos=env_int("HTTP_REINTENTOS", 3),
            user_agent=env("HTTP_USER_AGENT", cls.user_agent),
            solo_provincia=env("PADRON_SOLO_PROVINCIA", "").upper(),
            lote_upsert=env_int("PADRON_LOTE_UPSERT", 500),
            log_nivel=env("LOG_NIVEL", "INFO").upper(),
            dir_salida=Path(env("PADRON_DIR_SALIDA", "data")),
        )
        for clave, valor in sobrescribir.items():
            if valor is not None and hasattr(base, clave):
                setattr(base, clave, valor)
        if base.solo_provincia and base.solo_provincia not in dict(PROVINCIAS).values():
            raise ValueError(
                f"PADRON_SOLO_PROVINCIA inválido: {base.solo_provincia!r} "
                f"(usa una de {[p for _, p in PROVINCIAS]})"
            )
        return base
