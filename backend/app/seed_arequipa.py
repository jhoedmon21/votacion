"""Padrón regional de locales y mesas para el prototipo (SQLite).

Sin la mesa en el padrón, ``GET /api/actas/plantilla`` responde 404 y el
formulario (``ActaOficialForm``) no puede digitar fuera de Paucarpata. Este
seed genera locales y mesas para los 109 distritos de
``backend/sql/seed_ubigeo_arequipa.sql`` con numeración determinista, de modo
que cualquier mesa de Arequipa abre su plantilla con la oferta del JNE ya
cargada por ``load_jne_data``.

Numeración: secuencial desde 100001 (las 023001/023002 de Paucarpata se
conservan). ``electores_habiles`` 180-300 por mesa (tope de la regla R2).

Idempotente: omite locales ``(ubigeo, nombre)`` y mesas ``numero_mesa`` que ya
existan. Reejecutable sin daño.

Uso:
    python -m app.seed_arequipa              # siembra toda la región
    python -m app.seed_arequipa --dry-run    # informa sin escribir nada
    python -m app.seed_arequipa --solo 040201 --solo 040500
"""
from __future__ import annotations

import argparse
import hashlib
import logging
import re
from pathlib import Path

from sqlalchemy import inspect, text
from sqlalchemy.orm import Session

from app.core.database import Base, SessionLocal, engine
from app.core.models import Table, Venue

logger = logging.getLogger(__name__)

RAIZ = Path(__file__).resolve().parents[2]
SEED_UBIGEO = RAIZ / "backend" / "sql" / "seed_ubigeo_arequipa.sql"
# Salida del crawler (onpe-scraper/crawler_nombres_locales.py --cazar):
# {"040201": [{"nombre": "I.E. Sebastián Barranca", "direccion": ...}, ...]}
# Se aplica posicionalmente (índice 0 = primer local del distrito).
JSON_REALES = RAIZ / "backend" / "sql" / "locales_reales.json"

# Numeración secuencial DETERMINISTA desde MESA_BASE en el orden
# (distrito, local, mesa). Al no depender del contenido previo, reejecutar
# regenera los MISMOS números y el chequeo `ya` los omite (no duplica).
MESA_BASE = 100001

# Nombres REALES verificados a mano (respaldo si el crawler aún no cubre).
# Clave: (ubigeo distrital, índice del local 0-based). El JSON crawleado
# (locales_reales.json) tiene precedencia sobre esta tabla.
LOCALES_REALES: dict[tuple[str, int], dict[str, str]] = {
    ("040201", 0): {"nombre": "I.E. Sebastián Barranca"},
}


def reales_del_json() -> dict[str, list[dict]]:
    """Lee locales_reales.json si existe (sale del crawler, no a mano)."""
    import json

    if not JSON_REALES.exists():
        return {}
    try:
        datos = json.loads(JSON_REALES.read_text(encoding="utf-8"))
    except (ValueError, OSError) as exc:
        logger.warning("locales_reales.json ilegible (%s): se ignora", exc)
        return {}
    return datos if isinstance(datos, dict) else {}

# Valores de respaldo si el seed SQL no trae coordenadas.
LAT_DEFECTO = -16.409047
LON_DEFECTO = -71.537451

FILA_UBIGEO = re.compile(
    r"\('(\d{6})',\s*'(\d{6})',\s*'[^']*',\s*'([^']*)',\s*'([^']*)',\s*"
    r"'DISTRITO',\s*'([^']*)',\s*(-?[\d.]+),\s*(-?[\d.]+),"
)


def _entero_estable(semilla: str, minimo: int, maximo: int) -> int:
    """Entero determinista en [minimo, maximo] derivado de un texto."""
    digest = hashlib.sha256(semilla.encode("utf-8")).digest()
    valor = int.from_bytes(digest[:4], "big")
    return minimo + valor % (maximo - minimo + 1)


def asegurar_columna_padron(db: Session, dry_run: bool) -> None:
    """Añade ``tables.electores_habiles`` si la base viene de antes.

    ``create_all`` no altera tablas existentes (mismo patrón que
    ``load_jne_data.asegurar_esquema``). Las mesas legadas quedan con 250
    electores, igual que el ejemplo de ingesta.
    """
    Base.metadata.create_all(bind=engine)
    columnas = {c["name"] for c in inspect(engine).get_columns("tables")}
    if "electores_habiles" in columnas:
        return
    if dry_run:
        logger.info("[dry-run] Añadiría tables.electores_habiles")
        return
    db.execute(text("ALTER TABLE tables ADD COLUMN electores_habiles INTEGER"))
    db.execute(text("UPDATE tables SET electores_habiles = 250 "
                    "WHERE electores_habiles IS NULL"))
    db.commit()
    logger.info("Añadida tables.electores_habiles (legadas -> 250)")


def leer_distritos() -> list[dict]:
    """Distritos del seed SQL oficial: ubigeo, provincia, distrito, capital, lat, lon."""
    texto = SEED_UBIGEO.read_text(encoding="utf-8", errors="replace")
    distritos = []
    for m in FILA_UBIGEO.finditer(texto):
        ubigeo, _reniec, provincia, distrito, capital, lat, lon = m.groups()
        try:
            latitud, longitud = float(lat), float(lon)
        except ValueError:
            latitud, longitud = LAT_DEFECTO, LON_DEFECTO
        distritos.append({
            "ubigeo": ubigeo,
            "provincia": provincia.strip(),
            "distrito": distrito.strip(),
            "capital": capital.strip() or distrito.strip(),
            "latitud": latitud,
            "longitud": longitud,
        })
    return distritos


def nombre_de_local(d: dict, i: int, n_locales: int,
                    json_reales: dict[str, list[dict]]) -> tuple[str, str, dict | None]:
    """Nombre sintético + corrección real si existe (JSON crawleado > tabla).

    Índice 0 = "... N°1", 1 = "... N°2" (o el único sin sufijo si hay uno).
    """
    sintetico = f"I.E. {d['capital']}" + (f" N°{i + 1}" if n_locales > 1 else "")
    candidatos = json_reales.get(d["ubigeo"], [])
    if i < len(candidatos) and candidatos[i].get("nombre"):
        return sintetico, candidatos[i]["nombre"], candidatos[i]
    real = LOCALES_REALES.get((d["ubigeo"], i))
    if real and real.get("nombre"):
        return sintetico, real["nombre"], real
    return sintetico, sintetico, None


def sembrar(db: Session, solo: set[str] | None, dry_run: bool) -> dict[str, int]:
    """Crea locales y mesas para cada distrito. Devuelve el resumen."""
    resumen = {"distritos": 0, "locales": 0, "locales_existentes": 0,
               "mesas": 0, "mesas_existentes": 0}
    distritos = [d for d in leer_distritos() if not solo or d["ubigeo"] in solo]
    if not distritos:
        logger.warning("Sin distritos (¿ruta del seed? %s)", SEED_UBIGEO)
        return resumen
    json_reales = reales_del_json()
    if json_reales:
        logger.info("nombres reales del crawler: %d distritos (%s)",
                    len(json_reales), JSON_REALES)

    # Secuencia pura: el mismo recorrido genera siempre los mismos números.
    siguiente = MESA_BASE
    for d in distritos:
        resumen["distritos"] += 1
        n_locales = _entero_estable(d["ubigeo"], 1, 3)
        for i in range(n_locales):
            sintetico, nombre, real = nombre_de_local(d, i, n_locales, json_reales)
            venue = (
                db.query(Venue)
                .filter(Venue.ubigeo == d["ubigeo"], Venue.name == nombre)
                .first()
            )
            if venue is None and real is not None:
                # Reparación: el sintético previo se renombra, no se duplica.
                venue = (
                    db.query(Venue)
                    .filter(Venue.ubigeo == d["ubigeo"], Venue.name == sintetico)
                    .first()
                )
                if venue is not None:
                    if dry_run:
                        logger.info("[dry-run] Renombraría %r -> %r",
                                    sintetico, nombre)
                    else:
                        venue.name = nombre
                        if real.get("direccion"):
                            venue.address = real["direccion"]
                        logger.info("Local renombrado: %r -> %r",
                                    sintetico, nombre)
            if venue is None:
                if not dry_run:
                    venue = Venue(
                        name=nombre,
                        sector=d["distrito"],
                        address=(real.get("direccion") if real
                                 else f"{d['capital']}, {d['distrito']}"),
                        latitude=round(d["latitud"] + i * 0.001, 6),
                        longitude=round(d["longitud"] + i * 0.001, 6),
                        ubigeo=d["ubigeo"],
                        total_tables=0,
                    )
                    db.add(venue)
                    db.flush()
                    db.refresh(venue)
                resumen["locales"] += 1
            else:
                resumen["locales_existentes"] += 1

            n_mesas = _entero_estable(f"{d['ubigeo']}#{i}", 4, 8)
            for _j in range(n_mesas):
                numero = f"{siguiente:06d}"
                siguiente += 1
                if venue is not None and not dry_run:
                    habiles = _entero_estable(f"mesa#{numero}", 180, 300)
                    ya = db.query(Table).filter(Table.numero_mesa == numero).first()
                    if ya is None:
                        db.add(Table(numero_mesa=numero, venue_id=venue.id,
                                     electores_habiles=habiles))
                        resumen["mesas"] += 1
                    elif ya.venue_id != venue.id:
                        logger.warning(
                            "mesa %s existe en otro local: se omite (deriva de padrón)",
                            numero)
                        resumen["mesas_existentes"] += 1
                    else:
                        resumen["mesas_existentes"] += 1
                elif dry_run:
                    resumen["mesas"] += 1

    if not dry_run:
        # Totales en una sola pasada (evita lecturas intermedias de la sesión).
        db.execute(text(
            "UPDATE venues SET total_tables = "
            "(SELECT COUNT(*) FROM tables WHERE tables.venue_id = venues.id)"
        ))
        db.commit()
    return resumen


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--solo", action="append", default=[],
                        help="Ubigeo distrital a sembrar (repetible)")
    args = parser.parse_args()

    db = SessionLocal()
    try:
        asegurar_columna_padron(db, args.dry_run)
        resumen = sembrar(db, set(args.solo) or None, args.dry_run)
        logger.info("padrón regional: %s", resumen)
    finally:
        db.close()


if __name__ == "__main__":
    main()
