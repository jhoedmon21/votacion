"""Migración SQLite -> PostgreSQL del sistema de cómputo electoral.

Copia las 15 tablas del prototipo preservando los IDs (las FKs entre
``records/acta_metadata -> tables``, ``tables -> venues`` y
``asignacion_personeros -> usuarios/tables`` son enteros directos), en orden
de dependencias y dentro de una sola transacción por tabla.

Las secuencias de cada tabla se reposicionan al máximo id + 1 (``setval``),
sinó el primer INSERT post-migración chocaría con las PK copiadas.

Uso:
    python -m app.migrate_to_postgres            # migra con defaults
    python -m app.migrate_to_postgres --truncate # vacía PG antes de copiar
    python -m app.migrate_to_postgres --dry-run  # cuenta filas sin copiar

El origen es la URL SQLite vieja (o --origen) y el destino la DATABASE_URL
actual del .env (PostgreSQL). El script no toca SQLite: sólo lee.
"""
from __future__ import annotations

import argparse
import logging

from sqlalchemy import MetaData, Table, create_engine, text
from sqlalchemy.orm import Session

from app.core.config import settings

logger = logging.getLogger(__name__)

# Origen por defecto: la SQLite del prototipo (archivo junto a main.py).
SQLITE_URL_DEFECTO = "sqlite:///./votopaucarpata.db"

# Orden de dependencias: padres primero (venues <- tables <- records/...).
ORDEN = (
    "venues",
    "tables",
    "usuarios",
    "usuario_alcance",
    "sesiones",
    "accesos_log",
    "district_candidates",
    "provincial_candidates",
    "consejero_candidates",
    "regional_candidates",
    "records",
    "acta_metadata",
    "acta_auditoria_global",
    "asignacion_personeros",
    "checkins_personero",
)


def tablas_orm(engine_pg) -> dict[str, Table]:
    """Metadata completa del ORM (15 tablas) reflejada contra PostgreSQL."""
    import app.core.models  # noqa: F401  registra las tablas en Base.metadata
    from app.core.database import Base

    Base.metadata.create_all(bind=engine_pg)
    return {t.name: t for t in Base.metadata.sorted_tables}


def contar(origen) -> dict[str, int]:
    meta = MetaData()
    meta.reflect(bind=origen)
    with origen.connect() as con:
        return {n: con.execute(text(f"SELECT COUNT(*) FROM {n}")).scalar() or 0
                for n in ORDEN if n in meta.tables}


def migrar(origen_url: str, destino, truncate: bool) -> dict[str, int]:
    origen = create_engine(origen_url)
    mapa = tablas_orm(destino)

    resumen: dict[str, int] = {}
    with origen.connect() as con_o:
        for nombre in ORDEN:
            tabla = mapa.get(nombre)
            if tabla is None:
                logger.warning("tabla %s no está en el ORM; se omite", nombre)
                continue
            filas = [dict(f._mapping) for f in
                     con_o.execute(text(f"SELECT * FROM {nombre}"))]
            if truncate:
                with destino.begin() as tx:
                    tx.execute(text(f'TRUNCATE TABLE "{nombre}" CASCADE'))
            if not filas:
                resumen[nombre] = 0
                continue
            with destino.begin() as tx:
                tx.execute(tabla.insert(), filas)
                # Reposicionar la secuencia de la PK simple (si la tiene): las
                # PKs compuestas (p.ej. usuario_alcance) no tienen secuencia.
                pk = list(tabla.primary_key.columns)[0].name
                seq = tx.execute(text(
                    "SELECT pg_get_serial_sequence(:tabla, :col)"),
                    {"tabla": nombre, "col": pk},
                ).scalar()
                if seq:
                    maximo = tx.execute(
                        text(f'SELECT COALESCE(MAX("{pk}"), 0) FROM "{nombre}"')
                    ).scalar() or 0
                    if maximo:
                        tx.execute(text(
                            f"SELECT setval('{seq}', {maximo}, true)"))
            resumen[nombre] = len(filas)
    return resumen


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origen", default=SQLITE_URL_DEFECTO,
                        help="URL SQLAlchemy de la SQLite fuente")
    parser.add_argument("--truncate", action="store_true",
                        help="vacía las tablas de PostgreSQL antes de copiar")
    parser.add_argument("--dry-run", action="store_true",
                        help="sólo informa cuántas filas copiaría")
    args = parser.parse_args()

    destino = create_engine(settings.database_url)
    if args.dry_run:
        coneos = contar(create_engine(args.origen))
        logger.info("Filas a migrar: %s", coneos)
        return

    resumen = migrar(args.origen, destino, args.truncate)
    logger.info("Migradas: %s", resumen)
    total = sum(resumen.values())
    logger.info("[OK] %s filas copiadas a %s",
                total, destino.url.render_as_string(hide_password=True))


if __name__ == "__main__":
    main()
