#!/usr/bin/env python
"""Scraper/ETL del padrón electoral — Locales y mesas de AREQUIPA (ONPE) a BD.

Extrae, por cada distrito de las 8 provincias (ubigeo base '04'):
  ubicación administrativa (departamento/provincia/distrito/ubigeo),
  local (nombre oficial, dirección/referencia, lat/lon si la fuente la trae) y
  detalle de mesas (número exacto de 6 dígitos + total por local),
y los carga con UPSERT idempotente en `locales_votacion`/`mesas_votacion`.

Fuentes:
  --fuente archivo   Archivo oficial ONPE (CSV/JSON/XLSX). Vía de producción.
  --fuente catalogo  Catálogo de datos abiertos: busca el dataset y descarga
                     el recurso (requiere --recurso-url o --termino).
  --fuente check     Sólo verifica disponibilidad (sin descargar ni cargar).

Ejemplos:
  python scraper_padron_arequipa.py --fuente archivo --archivo relacion_onpe.csv
  python scraper_padron_arequipa.py --fuente archivo --archivo f.csv --dry-run -v
  python scraper_padron_arequipa.py --fuente archivo --archivo f.csv --solo-provincia CAYLLOMA
  python scraper_padron_arequipa.py --fuente catalogo --recurso-url https://.../locales.zip
  python scraper_padron_arequipa.py --fuente check
  DATABASE_URL=postgresql+psycopg2://u:p@host:5432/padron python scraper_padron_arequipa.py ...

Códigos de salida: 0 ok · 1 sin datos / fuente no disponible · 2 uso/config.
"""
from __future__ import annotations

import argparse
import logging
import sys
from collections import defaultdict
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(RAIZ))

from padron import config as C  # noqa: E402
from padron.carga import StatsCarga, cargar_provincia  # noqa: E402
from padron.fuentes import (  # noqa: E402
    buscar_en_catalogo, descargar_y_extraer, leer_registros_crudos, normalizar,
    recursos_descargables,
)
from padron.http import FuenteBloqueada, FuenteNoDisponible  # noqa: E402
from padron.modelos import crear_engine_y_sesion, crear_tablas  # noqa: E402

LOG = logging.getLogger("padron")


def configurar_logs(nivel: str) -> None:
    logging.basicConfig(
        level=getattr(logging, nivel.upper(), logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )


def parsear(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="ETL del padrón ONPE de Arequipa: locales y mesas a BD relacional.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--fuente", choices=("archivo", "catalogo", "check"),
                   default=None, help="origen de datos (default: PADRON_FUENTE/archivo)")
    p.add_argument("--archivo", type=Path, default=None,
                   help="CSV/JSON/XLSX oficial de la ONPE (con --fuente archivo)")
    p.add_argument("--recurso-url", default=None,
                   help="URL directa al recurso del catálogo (con --fuente catalogo)")
    p.add_argument("--termino", default=None,
                   help="término de búsqueda en el catálogo (default: env CATALOGO_TERMINO)")
    p.add_argument("--db", default=None, help="string de conexión (default: DATABASE_URL)")
    p.add_argument("--schema", default=None, help="schema PG dedicado (default: PADRON_SCHEMA)")
    p.add_argument("--solo-provincia", default=None,
                   help="carga sólo una provincia: AREQUIPA|CAMANA|CARAVELI|CASTILLA|"
                        "CAYLLOMA|CONDESUYOS|ISLAY|LA UNION")
    p.add_argument("--pausa", type=float, default=None,
                   help="segundos entre peticiones HTTP (default: HTTP_PAUSA_SEG)")
    p.add_argument("--dry-run", action="store_true",
                   help="parsea y valida sin escribir en la BD")
    p.add_argument("--detalle", action="store_true",
                   help="lista cada local (ubigeo, código, nombre, n° mesas) "
                        "para verificar la agrupación antes de cargar")
    p.add_argument("--crear-tablas", action="store_true",
                   help="CREATE TABLE IF NOT EXISTS antes de cargar (desarrollo/SQLite; "
                        "en PG productivo manda sql/ddl_locales_mesas.sql)")
    p.add_argument("-v", "--verbose", action="store_true", help="DEBUG (detalle por distrito)")
    return p.parse_args(argv)


def resolver_archivo(args: argparse.Namespace, aj: C.Ajustes) -> Path:
    """Obtiene el archivo de trabajo según la fuente elegida."""
    if aj.fuente == "archivo":
        ruta = args.archivo or (Path(aj.archivo) if aj.archivo else None)
        if not ruta:
            raise SystemExit(
                "[error] --fuente archivo requiere --archivo RUTA o PADRON_ARCHIVO.\n"
                "        Pruebe con el ejemplo: "
                "onpe-scraper/fixtures/locales_mesas_ejemplo.csv"
            )
        if not ruta.exists():
            raise SystemExit(f"[error] no existe el archivo: {ruta}")
        return ruta

    # --fuente catalogo: URL directa o búsqueda en el catálogo.
    if args.recurso_url or aj.recurso_url:
        url = args.recurso_url or aj.recurso_url
        LOG.info("descargando recurso directo: %s", url)
        return descargar_y_extraer(
            url, aj.dir_salida / "catalogo",
            timeout_seg=aj.timeout_seg, pausa_seg=aj.pausa_seg,
            reintentos=aj.reintentos, user_agent=aj.user_agent)

    termino = args.termino or aj.catalogo_termino
    LOG.info("buscando %r en %s ...", termino, aj.catalogo_base)
    paquetes = buscar_en_catalogo(
        aj.catalogo_base, termino, timeout_seg=aj.timeout_seg,
        pausa_seg=aj.pausa_seg, reintentos=aj.reintentos, user_agent=aj.user_agent)
    for pq in paquetes:
        recursos = recursos_descargables(pq)
        if recursos:
            r = recursos[0]
            LOG.info("dataset: %s → %s (%s)",
                     pq.get("title", "?")[:80], r.titulo[:60], r.formato)
            return descargar_y_extraer(
                r.url, aj.dir_salida / "catalogo",
                timeout_seg=aj.timeout_seg, pausa_seg=aj.pausa_seg,
                reintentos=aj.reintentos, user_agent=aj.user_agent)
    raise FuenteNoDisponible(
        f"ningún dataset de {aj.catalogo_base!r} trae recurso descargable para "
        f"{termino!r}. Pase --recurso-url o use --fuente archivo."
    )


def comando_check(aj: C.Ajustes) -> int:
    """Vigilancia de disponibilidad del catálogo (sin descargar)."""
    try:
        paquetes = buscar_en_catalogo(
            aj.catalogo_base, aj.catalogo_termino, timeout_seg=aj.timeout_seg,
            pausa_seg=aj.pausa_seg, reintentos=aj.reintentos, user_agent=aj.user_agent)
    except (FuenteBloqueada, FuenteNoDisponible) as exc:
        print(f"[no disponible] {exc}")
        return 1
    print(f"[ok] catálogo {aj.catalogo_base}: {len(paquetes)} paquetes para "
          f"{aj.catalogo_termino!r}")
    for pq in paquetes[:10]:
        n = len(recursos_descargables(pq))
        print(f"  - {str(pq.get('title', '?'))[:90]} [{n} recursos]")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parsear(argv)
    # .env opcional junto al script (no falla si falta python-dotenv).
    try:
        from dotenv import load_dotenv  # type: ignore

        load_dotenv(Path(__file__).resolve().parent / ".env")
    except ImportError:
        pass

    try:
        aj = C.Ajustes.desde_entorno(
            **{k: v for k, v in {
                "fuente": args.fuente, "solo_provincia": (args.solo_provincia or "").upper() or None,
                "pausa_seg": args.pausa, "dry_run": args.dry_run or None,
                "database_url": args.db,
                "padron_schema": args.schema,
                "log_nivel": "DEBUG" if args.verbose else None,
            }.items() if v is not None})
    except ValueError as exc:
        print(f"[error] {exc}")
        return 2
    configurar_logs(aj.log_nivel)

    if aj.fuente == "check":
        return comando_check(aj)

    # 1) Adquisición.
    try:
        archivo = resolver_archivo(args, aj)
    except (FuenteBloqueada, FuenteNoDisponible) as exc:
        print(f"[fuente no disponible] {exc}")
        return 1
    LOG.info("fuente: %s", archivo)

    # 2) Parseo + normalización (validación territorial Arequipa).
    try:
        filas = leer_registros_crudos(archivo)
    except (FileNotFoundError, ValueError, RuntimeError) as exc:
        print(f"[error] {exc}")
        return 2
    LOG.info("registros crudos: %d", len(filas))
    res = normalizar(filas, solo_provincia=aj.solo_provincia)
    LOG.info("locales: %d | mesas: %d | distritos con datos: %d",
             len(res.locales), sum(len(l.mesas) for l in res.locales),
             res.distritos_con_datos)
    if res.descartes:
        LOG.warning("%d descartes (primeros 15):", len(res.descartes))
        for d in res.descartes[:15]:
            LOG.warning("  - %s", d)
    if not res.locales:
        print("[aviso] nada válido para cargar (revise descartes con -v).")
        return 1

    # 3) Plan por provincia (log territorial explícito).
    por_prov: dict[str, list] = defaultdict(list)
    for local in res.locales:
        por_prov[local.provincia or "SIN-PROVINCIA"].append(local)
    print(f"[plan] {len(por_prov)} provincias, {len(res.locales)} locales, "
          f"{sum(len(l.mesas) for l in res.locales)} mesas")
    for prov in sorted(por_prov):
        ubigeos = sorted({l.ubigeo for l in por_prov[prov]})
        print(f"  {prov:12} {len(por_prov[prov]):4} locales "
              f"{sum(len(l.mesas) for l in por_prov[prov]):5} mesas "
              f"{len(ubigeos):3} distritos (ej. {ubigeos[0]})")
    if args.detalle:
        print("[detalle] agrupacion mesa -> local:")
        for local in sorted(res.locales, key=lambda l: (l.ubigeo, l.codigo_local)):
            mes = ",".join(m.numero for m in local.mesas[:6])
            mas = f" (+{len(local.mesas) - 6})" if len(local.mesas) > 6 else ""
            print(f"  {local.ubigeo} [{local.codigo_local}] "
                  f"{local.nombre_local[:45]:45} {len(local.mesas):3} mesas: {mes}{mas}")
    if aj.dry_run:
        print("[dry-run] sin escritura en BD.")
        return 0

    # 4) Carga UPSERT por provincia (un commit por provincia).
    engine, Fabrica = crear_engine_y_sesion(aj.database_url, aj.padron_schema)
    LOG.info("BD: %s (schema=%s)",
             aj.database_url.split("@")[-1], aj.padron_schema or "default")
    if args.crear_tablas or aj.database_url.startswith("sqlite"):
        crear_tablas(engine)
        LOG.info("tablas verificadas (CREATE TABLE IF NOT EXISTS)")
    nativo_pg = engine.dialect.name == "postgresql"
    total = StatsCarga()
    with Fabrica() as sesion:
        for prov in sorted(por_prov):
            st = cargar_provincia(sesion, prov, por_prov[prov],
                                  fuente="ONPE", nativo_pg=nativo_pg)
            total.locales_nuevos += st.locales_nuevos
            total.locales_actualizados += st.locales_actualizados
            total.mesas_nuevas += st.mesas_nuevas
            total.mesas_actualizadas += st.mesas_actualizadas
    print(f"[ok] carga completa: {total.resumen()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
