"""Padrón REAL de locales y mesas de Arequipa para el prototipo (SQLite).

El prototipo arrancó con un padrón sintético (``app/seed_arequipa.py``: locales
"I.E. <capital> N°1" y mesas 100001+ inventadas). Este módulo lo reemplaza por el
**archivo oficial de la ONPE**, normalizado por
``onpe-scraper/crawler_locales_mesas.py --importar actas.xlsx`` en
``frontend/public/data/locales_mesas_arequipa.json``: 109 distritos, 491 locales
y 4 194 mesas con nombre, dirección y número de mesa reales.

Reglas:

* **Idempotente y no destructivo con lo real.** Sólo elimina las mesas y locales
  que NO existen en el padrón oficial (es decir, los sintéticos). Reejecutarlo
  conserva las actas ya registradas sobre mesas reales.
* **Ubigeo INEI.** El archivo oficial viene en codificación RENIEC; el importador
  ya lo reasignó al ubigeo INEI del catálogo, que es la llave del sistema.
* **Georreferenciación honesta.** El archivo oficial no trae coordenadas por
  local, así que cada local se ubica en el centroide de su distrito
  (``seed_ubigeo_arequipa.sql``). No se inventan puntos por local.
* ``electores_habiles`` por mesa: 250 (promedio del padrón) hasta que exista la
  cifra real; es el tope de la regla R2.

Uso:
    python -m app.seed_padron_real --dry-run
    python -m app.seed_padron_real --reemplazar
"""
from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.database import SessionLocal
from app.core.models import (ActaAuditoriaGlobal, ActaMetadata,
                             AsignacionPersonero, CheckinPersonero, Record,
                             Table, Venue)
from app.seed_arequipa import leer_distritos

logger = logging.getLogger(__name__)

RAIZ = Path(__file__).resolve().parents[2]
JSON_PADRON = RAIZ / "frontend" / "public" / "data" / "locales_mesas_arequipa.json"

# Promedio del padrón cuando la mesa no declara electores hábiles propios.
ELECTORES_POR_MESA = 250


def cargar_padron() -> dict:
    """Lee el padrón real normalizado (salida del importador de la ONPE)."""
    if not JSON_PADRON.exists():
        raise SystemExit(
            f"No existe {JSON_PADRON}.\n"
            "Genere el padrón real primero:\n"
            "    python onpe-scraper/crawler_locales_mesas.py --importar actas.xlsx"
        )
    return json.loads(JSON_PADRON.read_text(encoding="utf-8"))


def mesas_reales(padron: dict) -> dict[str, tuple[str, str]]:
    """numero_mesa -> (ubigeo, nombre del local) de todo el padrón oficial."""
    indice: dict[str, tuple[str, str]] = {}
    for ubigeo, entrada in padron["por_ubigeo"].items():
        for local in entrada["locales"]:
            for mesa in local["mesas"]:
                indice[mesa] = (ubigeo, local["nombre"])
    return indice


def inventario(db: Session) -> dict[str, int]:
    return {
        "venues": db.query(Venue).count(),
        "tables": db.query(Table).count(),
        "records": db.query(Record).count(),
        "acta_metadata": db.query(ActaMetadata).count(),
        "asignaciones": db.query(AsignacionPersonero).count(),
        "checkins": db.query(CheckinPersonero).count(),
        "auditoria": db.query(ActaAuditoriaGlobal).count(),
    }


def _sinteticas(db: Session, reales: dict[str, tuple[str, str]]) -> list[Table]:
    """Mesas del prototipo que no figuran en el padrón oficial."""
    return [t for t in db.query(Table).all() if t.numero_mesa not in reales]


def purgar_sinteticos(db: Session, sinteticas: list[Table], dry_run: bool) -> dict[str, int]:
    """Elimina mesas sintéticas y sus derivados (actas, asignaciones, etc.).

    El orden respeta las claves foráneas: primero los hijos, después la mesa.
    """
    ids = [t.id for t in sinteticas]
    resumen = {"tables": len(ids)}
    if not ids:
        return resumen

    resumen["checkins"] = (
        db.query(CheckinPersonero)
        .filter(CheckinPersonero.asignacion_id.in_(
            db.query(AsignacionPersonero.id).filter(AsignacionPersonero.mesa_id.in_(ids))))
        .count()
    )
    resumen["asignaciones"] = (
        db.query(AsignacionPersonero).filter(AsignacionPersonero.mesa_id.in_(ids)).count()
    )
    numeros = [t.numero_mesa for t in sinteticas]
    resumen["auditoria"] = (
        db.query(ActaAuditoriaGlobal)
        .filter(ActaAuditoriaGlobal.numero_mesa.in_(numeros)).count()
    )
    resumen["records"] = db.query(Record).filter(Record.table_id.in_(ids)).count()
    resumen["acta_metadata"] = (
        db.query(ActaMetadata).filter(ActaMetadata.table_id.in_(ids)).count()
    )

    if dry_run:
        return resumen

    db.query(CheckinPersonero).filter(
        CheckinPersonero.asignacion_id.in_(
            db.query(AsignacionPersonero.id).filter(AsignacionPersonero.mesa_id.in_(ids)))
    ).delete(synchronize_session=False)
    db.query(AsignacionPersonero).filter(
        AsignacionPersonero.mesa_id.in_(ids)).delete(synchronize_session=False)
    db.query(ActaAuditoriaGlobal).filter(
        ActaAuditoriaGlobal.numero_mesa.in_(numeros)).delete(synchronize_session=False)
    db.query(Record).filter(Record.table_id.in_(ids)).delete(synchronize_session=False)
    db.query(ActaMetadata).filter(
        ActaMetadata.table_id.in_(ids)).delete(synchronize_session=False)
    db.query(Table).filter(Table.id.in_(ids)).delete(synchronize_session=False)
    db.flush()

    # Locales que quedaron sin mesas = locales sintéticos.
    resumen["venues"] = (
        db.query(Venue).filter(~Venue.id.in_(db.query(Table.venue_id))).delete(
            synchronize_session=False)
    )
    db.flush()
    return resumen


def sembrar(db: Session, padron: dict, dry_run: bool) -> dict[str, int]:
    """Crea los locales y mesas reales que falten (idempotente)."""
    centroides = {d["ubigeo"]: d for d in leer_distritos()}
    resumen = {"locales": 0, "locales_existentes": 0, "locales_reparados": 0,
               "mesas": 0, "mesas_existentes": 0, "mesas_reasignadas": 0}

    for ubigeo, entrada in sorted(padron["por_ubigeo"].items()):
        centro = centroides.get(ubigeo) or {}
        lat = centro.get("latitud", -16.409047)
        lon = centro.get("longitud", -71.537451)
        for local in entrada["locales"]:
            venue = (
                db.query(Venue)
                .filter(Venue.ubigeo == ubigeo, Venue.name == local["nombre"])
                .first()
            )
            if venue is None:
                resumen["locales"] += 1
                if not dry_run:
                    venue = Venue(
                        name=local["nombre"],
                        sector=entrada["distrito"],
                        address=local.get("direccion") or None,
                        latitude=lat,
                        longitude=lon,
                        ubigeo=ubigeo,
                        total_tables=0,
                    )
                    db.add(venue)
                    db.flush()
            else:
                resumen["locales_existentes"] += 1
                # Reparación: locales heredados sin coordenadas (o en 0,0, que la
                # ONPE usa como "sin georreferenciar") quedan fuera del mapa.
                if not venue.latitude or not venue.longitude:
                    resumen["locales_reparados"] += 1
                    if not dry_run:
                        venue.latitude, venue.longitude = lat, lon
                if not (venue.sector or "").strip():
                    if not dry_run:
                        venue.sector = entrada["distrito"]
                if not (venue.address or "").strip() and local.get("direccion"):
                    if not dry_run:
                        venue.address = local["direccion"]

            for numero in local["mesas"]:
                ya = db.query(Table).filter(Table.numero_mesa == numero).first()
                if ya is not None:
                    # El número de mesa es único y el padrón oficial manda sobre
                    # el local: si una mesa real quedó colgada de otro local
                    # (resto del padrón sintético), se reasigna a su local real.
                    if ya.venue_id == getattr(venue, "id", None):
                        resumen["mesas_existentes"] += 1
                    else:
                        # En dry-run el local nuevo aún no existe (venue is None),
                        # pero si la mesa ya está en la base con otro local, se
                        # reasignará en la corrida real.
                        logger.info("mesa %s reasignada a %r", numero, local["nombre"])
                        if not dry_run and venue is not None:
                            ya.venue_id = venue.id
                        resumen["mesas_reasignadas"] += 1
                    continue
                if dry_run:
                    resumen["mesas"] += 1
                    continue
                electores = (local.get("electores") or {}).get(numero) or ELECTORES_POR_MESA
                db.add(Table(numero_mesa=numero, venue_id=venue.id,
                             electores_habiles=electores))
                resumen["mesas"] += 1

    if not dry_run:
        db.flush()
        # Locales que quedaron sin mesas tras reasignar (restos sintéticos).
        resumen["venues_vacios_eliminados"] = (
            db.query(Venue).filter(~Venue.id.in_(db.query(Table.venue_id))).delete(
                synchronize_session=False)
        )
        db.execute(text(
            "UPDATE venues SET total_tables = "
            "(SELECT COUNT(*) FROM tables WHERE tables.venue_id = venues.id)"
        ))
        db.commit()
    return resumen


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="informa el reemplazo sin escribir nada")
    parser.add_argument("--reemplazar", action="store_true",
                        help="aplica: borra los datos sintéticos y siembra el padrón real")
    args = parser.parse_args()
    if not args.dry_run and not args.reemplazar:
        parser.error("indique --dry-run (informa) o --reemplazar (aplica)")

    padron = cargar_padron()
    reales = mesas_reales(padron)
    dry = args.dry_run

    db = SessionLocal()
    try:
        antes = inventario(db)
        sinteticas = _sinteticas(db, reales)
        print(f"Padrón real: {padron['total_locales']} locales, "
              f"{padron['total_mesas']} mesas en {padron['distritos_con_datos']} distritos")
        print(f"Base antes : {antes}")
        print(f"Mesas sintéticas a eliminar: {len(sinteticas)}")
        purga = purgar_sinteticos(db, sinteticas, dry)
        print(f"Eliminado  : {purga}")

        siembra = sembrar(db, padron, dry)
        print(f"Sembrado   : {siembra}")
        if dry:
            print("(dry-run: no se escribió nada)")
            return
        despues = inventario(db)
        print(f"Base después: {despues}")
        if despues["tables"] == padron["total_mesas"]:
            print("[OK] padrón oficial cargado")
        else:
            print(f"[AVISO] mesas en base ({despues['tables']}) != "
                  f"padrón ({padron['total_mesas']})")
    finally:
        db.close()


if __name__ == "__main__":
    main()
