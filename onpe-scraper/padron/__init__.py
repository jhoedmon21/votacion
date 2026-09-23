"""Padrón electoral Arequipa — ETL de locales y mesas (ONPE) a base relacional.

Módulos:
    config   Ajustes desde variables de entorno + plan territorial (8 provincias).
    http     Sesión HTTP con cabeceras de navegador, reintentos y rate-limiting.
    fuentes  Adaptadores de fuente (catálogo de datos abiertos / archivo oficial)
             + validación y normalización por provincia/distrito.
    modelos  ORM SQLAlchemy de `locales_votacion` y `mesas_votacion`.
    carga    Loader con UPSERT idempotente y logs por provincia/distrito.

Punto de entrada: `onpe-scraper/scraper_padron_arequipa.py`.
"""
from __future__ import annotations

__version__ = "1.0.0"
__all__ = ["config", "http", "fuentes", "modelos", "carga"]
