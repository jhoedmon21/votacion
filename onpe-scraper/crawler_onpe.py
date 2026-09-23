#!/usr/bin/env python
"""Crawler/ETL ONPE — Ubigeos, locales, direcciones, referencias y mesas.

Doble enfoque (el primero que devuelva datos reales gana):

  Enfoque A (API / web scraping)
      Itera los ubigeos de Arequipa (0401 a 0408, 109 distritos) contra los
      endpoints ONPE configurados en ONPE_ENDPOINTS (plantillas con
      {ubigeo}, {provincia}, {departamento}). Cada distrito registra ok/fallo
      en el log y en data/caza_onpe_reporte.json. LÍMITE VERIFICADO
      2026-09-18: la ONPE no expone endpoint bulk por ubigeo (su API es por
      DNI y ETLV cerró); sin plantillas configuradas los distritos quedan
      "pendiente-fuente" y el reporte lo dice, sin inventar datos.

  Enfoque B (datos abiertos / fallback con Pandas)
      Descarga o lee el CSV/Excel oficial (URL o archivo, o dataset de
      datosabiertos vía --dataset), lo normaliza y lo carga con UPSERT.

Destino: tablas `locales_votacion` (ubigeo, departamento, provincia,
distrito, nombre_local, direccion, referencia, total_mesas) y
`mesas_votacion` (local_id → FK, numero_mesa, estado_acta), según
sql/ddl_locales_mesas.sql. Reejecutable sin duplicar (UNIQUE + ON CONFLICT).

Ejemplos:
  python crawler_onpe.py --enfoque a --ambito arequipa --dry-run
  python crawler_onpe.py --enfoque b --csv relacion_onpe.csv --db sqlite:///./padron.db
  python crawler_onpe.py --enfoque b --dataset <slug-datosabiertos> --db postgresql+psycopg2://u:p@h:5432/padron
  python crawler_onpe.py --enfoque b --excel https://.../locales.xlsx --solo-provincia CAMANA -v

Códigos de salida: 0 ok · 1 sin datos / distritos fallidos · 2 uso/config.
"""
from __future__ import annotations

import argparse
import itertools
import json
import logging
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from padron import config as C  # noqa: E402
from padron.carga import StatsCarga, cargar_provincia  # noqa: E402
from padron.fuentes import (  # noqa: E402
    buscar_en_catalogo, descargar_y_extraer, distritos_oficiales,
    leer_registros_crudos, normalizar, recursos_descargables,
)
from padron.http import (  # noqa: E402
    FuenteBloqueada, FuenteNoDisponible, crear_sesion, descargar, obtener,
)
from padron.modelos import crear_engine_y_sesion, crear_tablas  # noqa: E402

LOG = logging.getLogger("onpe")

# Pool de User-Agent reales: rotación cooperativa (sigue habiendo pausa
# entre peticiones; rotar no es evadir, es parecerse a tráfico normal).
POOL_UA = [
    ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
     "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"),
    ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
     "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"),
    ("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) "
     "Gecko/20100101 Firefox/132.0"),
]

# Sondas de disponibilidad (una sola petición, no por ubigeo).
PORTAL_CONSULTA = "https://consultaelectoral.onpe.gob.pe/inicio"

RE_DATASET = re.compile(r'href="(/dataset/[a-z0-9][a-z0-9\-]*)"')


def _slugs_grupo(html: str) -> list[str]:
    """Slugs /dataset/... del HTML del grupo (bs4 si está, regex si no)."""
    try:
        from bs4 import BeautifulSoup  # type: ignore

        sopa = BeautifulSoup(html, "html.parser")
        return sorted({a["href"] for a in
                       sopa.select('h2.node-title a[href^="/dataset/"]')
                       if a.get("href")})
    except ImportError:
        LOG.info("beautifulsoup4 no instalado: parseo HTML con regex")
        return sorted(set(RE_DATASET.findall(html)))


def _plantillas_endpoints() -> list[str]:
    """Plantillas {ubigeo} desde env ONPE_ENDPOINTS (coma-separadas)."""
    import os

    crudo = os.environ.get("ONPE_ENDPOINTS", "")
    return [t.strip() for t in crudo.split(",") if "{ubigeo}" in t]


def _ubigeos_ambito(ambito: str) -> list[str]:
    """Ubigeos a recorrer: 109 de Arequipa (catálogo) o sin filtro."""
    if ambito == "nacional":
        return []  # sin filtro: vale lo que devuelvan las fuentes
    oficiales = distritos_oficiales()
    if oficiales:
        return sorted(oficiales)
    # Degradación: prefijos provinciales 0401..0408 (sin detalle distrital).
    return [f"040{i}" for i in range(1, 9)]


# ---------------------------------------------------------------------------
# Enfoque A — barrido por ubigeo sobre endpoints configurados
# ---------------------------------------------------------------------------
def enfoque_a(aj: C.Ajustes, args: argparse.Namespace) -> int:
    import os

    ubigeos = _ubigeos_ambito(args.ambito)
    plantillas = _plantillas_endpoints()
    oficiales = distritos_oficiales()
    ciclo_ua = itertools.cycle(POOL_UA)
    reporte: list[dict] = []

    # Sonda 1 (una vez): ¿el portal de consulta responde?
    sesion, limitador = crear_sesion(next(ciclo_ua), aj.reintentos,
                                     aj.timeout_seg, aj.pausa_seg)
    try:
        r = obtener(sesion, limitador, PORTAL_CONSULTA)
        LOG.info("portal ONPE: HTTP %d (consulta ciudadana por DNI)", r.status_code)
    except (FuenteBloqueada, FuenteNoDisponible) as exc:
        LOG.warning("portal ONPE: %s", exc)

    # Sonda 2 (una vez): datasets del grupo (para el cruce por ubigeo).
    try:
        paquetes = buscar_en_catalogo(
            aj.catalogo_base, "ONPE", timeout_seg=aj.timeout_seg,
            pausa_seg=aj.pausa_seg, reintentos=aj.reintentos,
            user_agent=next(ciclo_ua))
        LOG.info("catálogo: %d paquetes ONPE", len(paquetes))
    except (FuenteBloqueada, FuenteNoDisponible) as exc:
        LOG.warning("catálogo: %s", exc)
        paquetes = []

    if not plantillas:
        LOG.warning(
            "sin ONPE_ENDPOINTS con {ubigeo}: la ONPE no publica endpoint bulk "
            "por ubigeo (API por DNI, ETLV cerrado). Los %d distritos quedan "
            "'pendiente-fuente': use --enfoque b con el archivo oficial.",
            len(ubigeos))
        for ub in ubigeos:
            info = oficiales.get(ub, {})
            reporte.append({"ubigeo": ub,
                            "distrito": info.get("distrito", ""),
                            "provincia": info.get("provincia", ""),
                            "estado": "pendiente-fuente",
                            "detalle": "sin endpoint bulk configurado"})
        _guardar_reporte(reporte, args)
        return 0 if not args.estricto else 1

    # Barrido real por ubigeo sobre cada plantilla configurada.
    fallidos = 0
    for ub in ubigeos:
        info = oficiales.get(ub, {})
        fila: dict = {"ubigeo": ub, "distrito": info.get("distrito", ""),
                      "provincia": info.get("provincia", "")}
        ua = next(ciclo_ua)  # rotación por distrito
        ses, lim = crear_sesion(ua, aj.reintentos, aj.timeout_seg, aj.pausa_seg)
        ok = False
        for tpl in plantillas:
            url = tpl.format(ubigeo=ub, provincia=ub[:4], departamento="04")
            try:
                resp = obtener(ses, lim, url)
                fila.setdefault("respuestas", []).append(
                    {"url": url[:100], "http": resp.status_code,
                     "bytes": len(resp.content)})
                ok = True
            except (FuenteBloqueada, FuenteNoDisponible) as exc:
                fila.setdefault("errores", []).append(f"{url[:80]}: {exc}")
        fila["estado"] = "ok" if ok else "fallido"
        if not ok:
            fallidos += 1
            LOG.warning("[%s] %s: sin datos (%s)", ub,
                        fila["distrito"], "; ".join(fila.get("errores", []))[:160])
        else:
            LOG.info("[%s] %s: ok", ub, fila["distrito"])
        reporte.append(fila)
    _guardar_reporte(reporte, args)
    print(f"[A] distritos: {len(ubigeos)} | fallidos: {fallidos} "
          f"(detalle: onpe-scraper/data/caza_onpe_reporte.json)")
    if args.dry_run:
        print("[dry-run] Enfoque A no escribe en BD (solo sondea).")
    return 0 if fallidos == 0 else 1


def _guardar_reporte(reporte: list[dict], args: argparse.Namespace) -> None:
    aj_dir = Path("data")
    aj_dir.mkdir(parents=True, exist_ok=True)
    (aj_dir / "caza_onpe_reporte.json").write_text(
        json.dumps({"generado_en": datetime.now(timezone.utc).isoformat(),
                    "enfoque": "a", "distritos": reporte},
                   ensure_ascii=False, indent=1), encoding="utf-8")


# ---------------------------------------------------------------------------
# Enfoque B — Pandas sobre CSV/Excel oficial (URL, dataset o archivo)
# ---------------------------------------------------------------------------
def _resolver_fuente_b(args: argparse.Namespace, aj: C.Ajustes) -> Path:
    if args.csv or args.excel:
        origen = args.csv or args.excel
        if str(origen).startswith(("http://", "https://")):
            sesion, lim = crear_sesion(aj.user_agent, aj.reintentos,
                                       aj.timeout_seg, aj.pausa_seg)
            destino = aj.dir_salida / "enfoque_b" / str(origen).split("?")[0].split("/")[-1]
            return descargar(sesion, lim, str(origen), destino)
        ruta = Path(origen)
        if not ruta.exists():
            raise SystemExit(f"[error] no existe: {ruta}")
        return ruta
    if args.dataset:
        paquetes = buscar_en_catalogo(
            aj.catalogo_base, args.dataset, timeout_seg=aj.timeout_seg,
            pausa_seg=aj.pausa_seg, reintentos=aj.reintentos,
            user_agent=aj.user_agent)
        for pq in paquetes:
            recs = recursos_descargables(pq)
            if recs:
                LOG.info("dataset %s -> %s", args.dataset, recs[0]["url"][:90])
                return descargar_y_extraer(
                    recs[0]["url"], aj.dir_salida / "enfoque_b",
                    timeout_seg=aj.timeout_seg, pausa_seg=aj.pausa_seg,
                    reintentos=aj.reintentos, user_agent=aj.user_agent)
        raise SystemExit(f"[error] dataset sin recurso descargable: {args.dataset}")
    if aj.archivo:
        ruta = Path(aj.archivo)
        if ruta.exists():
            return ruta
    raise SystemExit("[error] Enfoque B requiere --csv URL|ruta, --excel, "
                     "--dataset <slug> o PADRON_ARCHIVO.")


def _filas_con_pandas(ruta: Path) -> list[dict] | None:
    """Lee con Pandas (rápido en archivos grandes); None si no está."""
    try:
        import pandas as pd  # type: ignore
    except ImportError:
        return None
    suf = ruta.suffix.lower()
    if suf in (".xls", ".xlsx"):
        df = pd.read_excel(ruta, dtype=str).fillna("")
    else:
        df = pd.read_csv(ruta, dtype=str, encoding="utf-8-sig",
                         sep=None, engine="python").fillna("")
    from padron.fuentes import mapear_columnas  # noqa: E402

    mapa = mapear_columnas(list(df.columns))
    LOG.info("pandas: %d filas x %d columnas (%s)", len(df), len(df.columns),
             ruta.name)
    return [{d: fila.get(o, "") for d, o in mapa.items()}
            for fila in df.to_dict(orient="records")]


def enfoque_b(aj: C.Ajustes, args: argparse.Namespace) -> int:
    try:
        archivo = _resolver_fuente_b(args, aj)
    except (FuenteBloqueada, FuenteNoDisponible, SystemExit) as exc:
        print(exc)
        return 1
    LOG.info("fuente B: %s", archivo)

    filas = _filas_con_pandas(archivo)
    if filas is None:
        LOG.info("pandas no instalado: lector stdlib")
        try:
            filas = leer_registros_crudos(archivo)
        except (FileNotFoundError, ValueError, RuntimeError) as exc:
            print(f"[error] {exc}")
            return 2
    LOG.info("registros crudos: %d", len(filas))

    res = normalizar(filas, solo_provincia=aj.solo_provincia)
    if args.ambito == "arequipa":
        antes = len(res.locales)
        res.locales = [l for l in res.locales if l.ubigeo.startswith("04")]
        if len(res.locales) != antes:
            LOG.warning("filtro Arequipa: %d locales fuera de 04 descartados",
                        antes - len(res.locales))
    LOG.info("locales: %d | mesas: %d | distritos: %d", len(res.locales),
             sum(len(l.mesas) for l in res.locales), res.distritos_con_datos)
    if res.descartes:
        LOG.warning("%d descartes (primeros 15):", len(res.descartes))
        for dd in res.descartes[:15]:
            LOG.warning("  - %s", dd)
    if not res.locales:
        print("[aviso] nada válido para cargar (revise descartes con -v).")
        return 1

    por_prov: dict[str, list] = defaultdict(list)
    for local in res.locales:
        por_prov[local.provincia or "SIN-PROVINCIA"].append(local)
    print(f"[plan] {len(por_prov)} provincias, {len(res.locales)} locales, "
          f"{sum(len(l.mesas) for l in res.locales)} mesas")
    for prov in sorted(por_prov):
        ubs = sorted({x.ubigeo for x in por_prov[prov]})
        print(f"  {prov:12} {len(por_prov[prov]):4} locales "
              f"{sum(len(x.mesas) for x in por_prov[prov]):5} mesas "
              f"{len(ubs):3} distritos (ej. {ubs[0]})")
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

    engine, Fabrica = crear_engine_y_sesion(aj.database_url, aj.padron_schema)
    if args.crear_tablas or aj.database_url.startswith("sqlite"):
        crear_tablas(engine)
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


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parsear(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Crawler/ETL ONPE: ubigeos, locales, direcciones, "
                    "referencias y mesas a PostgreSQL/MySQL/SQLite.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--enfoque", choices=("a", "b"), default="a",
                   help="a: barrido por ubigeo (0401-0408) · b: pandas sobre "
                        "CSV/Excel oficial (default: %(default)s)")
    p.add_argument("--ambito", choices=("arequipa", "nacional"),
                   default="arequipa")
    p.add_argument("--csv", default=None, help="URL o ruta del CSV oficial (B)")
    p.add_argument("--excel", default=None, help="URL o ruta del Excel oficial (B)")
    p.add_argument("--dataset", default=None, help="slug de datosabiertos (B)")
    p.add_argument("--db", default=None, help="string de conexión SQLAlchemy")
    p.add_argument("--schema", default=None, help="schema PG dedicado")
    p.add_argument("--solo-provincia", default=None)
    p.add_argument("--pausa", type=float, default=None)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--detalle", action="store_true")
    p.add_argument("--crear-tablas", action="store_true")
    p.add_argument("--estricto", action="store_true",
                   help="exit 1 si algún distrito quedó pendiente/fallido (A)")
    p.add_argument("-v", "--verbose", action="store_true")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parsear(argv)
    try:
        from dotenv import load_dotenv  # type: ignore

        load_dotenv(Path(__file__).resolve().parent / ".env")
    except ImportError:
        pass
    try:
        aj = C.Ajustes.desde_entorno(
            **{k: v for k, v in {
                "solo_provincia": (args.solo_provincia or "").upper() or None,
                "pausa_seg": args.pausa, "dry_run": args.dry_run or None,
                "database_url": args.db, "padron_schema": args.schema,
                "log_nivel": "DEBUG" if args.verbose else None,
            }.items() if v is not None})
    except ValueError as exc:
        print(f"[error] {exc}")
        return 2
    logging.basicConfig(
        level=getattr(logging, aj.log_nivel.upper(), logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%H:%M:%S")
    if args.enfoque == "a":
        return enfoque_a(aj, args)
    return enfoque_b(aj, args)


if __name__ == "__main__":
    raise SystemExit(main())
