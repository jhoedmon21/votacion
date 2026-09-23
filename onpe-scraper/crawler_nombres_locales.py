"""Nombres reales de locales de votación — crawler de datos abiertos ONPE.

Rastrea el grupo ONPE de datosabiertos.gob.pe (Drupal 7 + DKAN, sin
`package_search`: se recorre el HTML paginado), resuelve cada dataset vía
`package_show`, descarga sus recursos (ZIP/CSV) y busca columnas con nombres
de local + ubigeo/mesa. Lo encontrado para Arequipa (ubigeo 04) se guarda en
``backend/sql/locales_reales.json``, que ``app.seed_arequipa`` consume
posicionalmente para renombrar los locales sintéticos ("I.E. X N°k").

Lo que este crawler NO hace: barrer DNI en consulta electoral o ETLV para
reconstruir padrón (dato personal protegido; además ETLV cerró el 14/12/2025
y ambos exigen identidad por ciudadano). Si un dataset no trae columna de
local, se reporta y se sigue — nunca se inventan nombres.

Sólo librería estándar. Rate-limit cooperativo + User-Agent de navegador
(anti-403 del reverse proxy).

Uso:
    python crawler_nombres_locales.py --descubrir
    python crawler_nombres_locales.py --cazar --dry-run
    python crawler_nombres_locales.py --cazar --salida backend/sql/locales_reales.json
    python crawler_nombres_locales.py --cazar --solo 040201 -v
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import logging
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger("nombres")

RAIZ = Path(__file__).resolve().parents[1]
SALIDA_DEFECTO = RAIZ / "backend" / "sql" / "locales_reales.json"
DIR_DATA = Path(__file__).resolve().parent / "data"

GRUPO_ONPE = "https://www.datosabiertos.gob.pe/group/oficina-nacional-de-procesos-electorales-onpe"
API_SHOW = "https://www.datosabiertos.gob.pe/api/3/action/package_show"

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
PAUSA_SEG = 1.5
TIMEOUT = 40
MAX_PAGINAS_GRUPO = 25
MAX_MB_RECURSO = 80

RE_DATASET = re.compile(r'href="(/dataset/[a-z0-9][a-z0-9\-]*)"')
RE_UBIGEO = re.compile(r"^\d{6}$")


def _norm(texto: object) -> str:
    base = unicodedata.normalize("NFKD", str(texto or ""))
    base = "".join(c for c in base if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", "_", base.lower()).strip("_")


def _tokens(clave: str) -> frozenset[str]:
    vacias = {"de", "del", "la", "el", "los", "las", "en", "y", "e", "al", "por"}
    return frozenset(t for t in clave.split("_") if t and t not in vacias)


def es_columna_local(cabecera: str) -> bool:
    """¿Esta columna trae el nombre del local? (conservador: evita falsos +)."""
    toks = _tokens(_norm(cabecera))
    if not toks:
        return False
    if toks <= {"local", "locales", "colegio", "sede", "sede_votacion"}:
        return True
    return "local" in toks and bool(toks & {"nombre", "nom", "denominacion", "votacion"})


def es_columna_ubigeo(cabecera: str) -> bool:
    toks = _tokens(_norm(cabecera))
    return bool(toks & {"ubigeo", "ubigeo_inei", "codigo_ubigeo"}) or toks == {"ubigeo"}


def es_columna_mesa(cabecera: str) -> bool:
    toks = _tokens(_norm(cabecera))
    return bool(toks) and toks <= {"mesa", "mesas", "numero", "nro", "n", "num"} \
        and bool(toks & {"mesa", "mesas"})


class Cliente:
    """GET con ritmo, UA real y errores tipados (403/WAF vs resto)."""

    def __init__(self, pausa: float = PAUSA_SEG) -> None:
        self.pausa = pausa
        self._ultima = 0.0

    def _esperar(self) -> None:
        espera = self.pausa - (time.monotonic() - self._ultima)
        if espera > 0:
            time.sleep(espera)
        self._ultima = time.monotonic()

    def get(self, url: str, params: dict | None = None) -> tuple[int, bytes, str]:
        self._esperar()
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                return r.status, r.read(), r.headers.get("content-type", "")
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403, 429):
                raise RuntimeError(f"BLOQUEO {exc.code} en {url}: subir --pausa") from exc
            raise RuntimeError(f"HTTP {exc.code} en {url}") from exc
        except Exception as exc:  # noqa: BLE001 (red, DNS, timeout...)
            raise RuntimeError(f"sin respuesta de {url}: {exc}") from exc

    def get_json(self, url: str, params: dict | None = None) -> object:
        _, crudo, _ = self.get(url, params)
        return json.loads(crudo.decode("utf-8", "replace"))


# ---------------------------------------------------------------------------
# Descubrimiento: slugs del grupo + recursos vía package_show
# ---------------------------------------------------------------------------
CACHE_DATASETS = DIR_DATA / "datasets_onpe.json"
CACHE_HORAS = 24


def descubrir_datasets(cli: Cliente, refrescar: bool = False) -> list[str]:
    """Slugs /dataset/... del grupo ONPE (recorre páginas hasta agotar).

    Cachea en data/datasets_onpe.json por 24 h (el catálogo casi no cambia
    y cada página cuesta una petición con pausa).
    """
    if not refrescar and CACHE_DATASETS.exists():
        try:
            cache = json.loads(CACHE_DATASETS.read_text(encoding="utf-8"))
            ts = datetime.fromisoformat(cache.get("generado_en", "2000-01-01"))
            edad_h = (datetime.now(timezone.utc) - ts).total_seconds() / 3600
            if edad_h < CACHE_HORAS and cache.get("slugs"):
                logger.info("datasets desde caché (%d, %.1fh)", len(cache["slugs"]), edad_h)
                return list(cache["slugs"])
        except (ValueError, OSError):
            pass
    vistos: list[str] = []
    for pagina in range(MAX_PAGINAS_GRUPO):
        _, crudo, _ = cli.get(GRUPO_ONPE, {"page": pagina} if pagina else None)
        html = crudo.decode("utf-8", "replace")
        nuevos = [s for s in dict.fromkeys(RE_DATASET.findall(html)) if s not in vistos]
        if not nuevos:
            break
        vistos.extend(nuevos)
        logger.info("grupo pag %d: +%d datasets (%d)", pagina, len(nuevos), len(vistos))
    DIR_DATA.mkdir(parents=True, exist_ok=True)
    CACHE_DATASETS.write_text(json.dumps(
        {"generado_en": datetime.now(timezone.utc).isoformat(), "slugs": vistos},
        ensure_ascii=False), encoding="utf-8")
    return vistos


def recursos_de_dataset(cli: Cliente, slug: str) -> list[dict]:
    """Recursos descargables (zip/csv/xls/xlsx) de un dataset vía package_show."""
    ident = slug.rsplit("/", 1)[-1]
    try:
        data = cli.get_json(API_SHOW, {"id": ident})
    except RuntimeError as exc:
        logger.warning("package_show %s: %s", ident[:60], exc)
        return []
    res = data.get("result", data) if isinstance(data, dict) else []
    if isinstance(res, list):  # sabor DKAN: result es lista
        res = res[0] if res else {}
    salida = []
    for r in (res.get("resources", []) if isinstance(res, dict) else []):
        formato = str(r.get("format", "")).lower()
        url = r.get("url", "")
        if formato in ("zip", "csv", "xls", "xlsx") and url.startswith("http"):
            salida.append({"dataset": ident, "titulo": r.get("name", ""),
                           "url": url, "formato": formato,
                           "tamano": r.get("size", "")})
    return salida


# ---------------------------------------------------------------------------
# Caza: descargar, oler columnas, extraer (ubigeo 04 -> locales)
# ---------------------------------------------------------------------------
def _leer_csv_texto(raw: bytes) -> tuple[list[str], list[list[str]]]:
    # Páginas de error HTML en vez de CSV: se detecta antes de parsear.
    if raw.lstrip()[:1] in (b"<",):
        raise RuntimeError("el recurso devolvió HTML (no es un CSV)")
    encodings = ["utf-8-sig", "latin-1"]
    if b"\x00" in raw[:1000]:
        # UTF-16 (típico en CSV exportados desde Excel Windows).
        encodings = ["utf-16", "utf-16-le", "utf-16-be"] + encodings
    for enc in encodings:
        try:
            texto = raw.decode(enc)
            break
        except (UnicodeDecodeError, ValueError):
            continue
    else:
        raise RuntimeError("encoding ilegible")
    texto = texto.replace("\r\n", "\n").replace("\r", "\n")
    muestra = texto[:8192]
    try:
        dialecto = csv.Sniffer().sniff(muestra, delimiters=",;|\t")
    except csv.Error:
        dialecto = csv.excel
    filas = list(csv.reader(io.StringIO(texto), dialect=dialecto))
    if not filas:
        raise RuntimeError("CSV vacío")
    return filas[0], filas[1:]


def extraer_locales_csv(nombre: str, raw: bytes, solo: set[str]) -> tuple[dict, dict]:
    """(por_ubigeo, reporte): nombres de local de filas de Arequipa."""
    cabeceras, filas = _leer_csv_texto(raw)
    idx_local = [i for i, c in enumerate(cabeceras) if es_columna_local(c)]
    idx_ubi = [i for i, c in enumerate(cabeceras) if es_columna_ubigeo(c)]
    idx_mesa = [i for i, c in enumerate(cabeceras) if es_columna_mesa(c)]
    reporte: dict = {"archivo": nombre, "columnas": cabeceras,
                     "col_local": [cabeceras[i] for i in idx_local],
                     "col_ubigeo": [cabeceras[i] for i in idx_ubi],
                     "filas": len(filas), "arequipa": 0, "locales": 0}
    if not idx_local or not (idx_ubi or idx_mesa):
        reporte["veredicto"] = "sin columnas LOCAL (+ubigeo/mesa): no sirve"
        return {}, reporte
    iu, il = idx_ubi[0] if idx_ubi else None, idx_local[0]
    por_ubigeo: dict[str, Counter] = {}
    for f in filas:
        if iu is None or len(f) <= max(iu, il):
            continue
        ub = (f[iu] or "").strip()
        if not RE_UBIGEO.match(ub) or not ub.startswith("04"):
            continue
        if solo and ub not in solo:
            continue
        nombre_local = (f[il] or "").strip()
        if not nombre_local:
            continue
        por_ubigeo.setdefault(ub, Counter())[nombre_local] += 1
        reporte["arequipa"] += 1
    reporte["locales"] = sum(len(c) for c in por_ubigeo.values())
    reporte["veredicto"] = "OK" if reporte["locales"] else "sin filas de Arequipa"
    return por_ubigeo, reporte


def cazar_recurso(cli: Cliente, rec: dict, solo: set[str], max_mb: int) -> tuple[dict, dict]:
    """Descarga un recurso y extrae locales. Devuelve (por_ubigeo, reporte)."""
    logger.info("descargando %s (%s)", rec["url"][:90], rec.get("tamano") or "?")
    estado, crudo, _ = cli.get(rec["url"])
    if len(crudo) > max_mb * 1_000_000:
        return {}, {"archivo": rec["url"], "veredicto": f"pesa {len(crudo)//1_000_000}MB: omitido"}
    if rec["formato"] == "zip":
        with zipfile.ZipFile(io.BytesIO(crudo)) as z:
            candidatos = [n for n in z.namelist()
                          if n.lower().endswith((".csv", ".txt"))]
            if not candidatos:
                return {}, {"archivo": rec["url"],
                            "veredicto": "ZIP sin CSV (suele traer XLSX: requiere openpyxl)"}
            elegido = max(candidatos, key=lambda n: z.getinfo(n).file_size)
            return extraer_locales_csv(elegido, z.read(elegido), solo)
    if rec["formato"] in ("csv", "txt"):
        return extraer_locales_csv(rec["url"], crudo, solo)
    return {}, {"archivo": rec["url"], "veredicto": f"{rec['formato']}: omitido (sin openpyxl)"}


# ---------------------------------------------------------------------------
# Salida: locales_reales.json para el seed
# ---------------------------------------------------------------------------
def fusionar(extracciones: list[dict]) -> dict[str, list[dict]]:
    """Une {ubigeo: Counter} de varios archivos → {ubigeo: [{nombre, ...}]}."""
    total: dict[str, Counter] = {}
    for ext in extracciones:
        for ub, contador in ext.items():
            total.setdefault(ub, Counter()).update(contador)
    return {
        ub: [{"nombre": nombre, "mesas": n, "fuente": "datosabiertos.onpe"}
             for nombre, n in cont.most_common()]
        for ub, cont in sorted(total.items())
    }


def comando_descubrir(cli: Cliente, args: argparse.Namespace) -> int:
    slugs = descubrir_datasets(cli, refrescar=args.refrescar)
    print(f"[descubrir] {len(slugs)} datasets en el grupo ONPE")
    con_recurso = 0
    for slug in slugs:
        recs = recursos_de_dataset(cli, slug)
        if recs:
            con_recurso += 1
            print(f"  {slug.rsplit('/', 1)[-1][:70]}")
            for r in recs:
                print(f"    [{r['formato']}] {r['url'][:100]}")
    print(f"[descubrir] {con_recurso}/{len(slugs)} datasets con recurso descargable")
    return 0


def comando_cazar(cli: Cliente, args: argparse.Namespace) -> int:
    solo = set(args.solo or [])
    filtro = (args.filtro or "").lower()
    slugs = descubrir_datasets(cli, refrescar=args.refrescar)
    if filtro:
        slugs = [s for s in slugs if filtro in s.lower()]
        print(f"[cazar] filtro {args.filtro!r}: {len(slugs)} datasets")
    DIR_DATA.mkdir(parents=True, exist_ok=True)
    extracciones: list[dict] = []
    reportes: list[dict] = []
    revisados = descargados = 0
    for slug in slugs:
        for rec in recursos_de_dataset(cli, slug):
            revisados += 1
            try:
                por_ub, rep = cazar_recurso(cli, rec, solo, args.max_mb)
            except RuntimeError as exc:
                rep, por_ub = {"archivo": rec["url"], "veredicto": str(exc)}, {}
            rep["dataset"] = slug.rsplit("/", 1)[-1]
            reportes.append(rep)
            logger.info("%s -> %s", rep["dataset"][:50], rep["veredicto"])
            if por_ub:
                descargados += 1
                extracciones.append(por_ub)
                if args.max_datasets and descargados >= args.max_datasets:
                    break
        if args.max_datasets and descargados >= args.max_datasets:
            break
    fusion = fusionar(extracciones)
    n_nombres = sum(len(v) for v in fusion.values())
    print(f"[cazar] recursos revisados: {revisados} | con locales Arequipa: {descargados}")
    print(f"[cazar] distritos con nombres: {len(fusion)} | nombres: {n_nombres}")
    (DIR_DATA / "caza_locales_reporte.json").write_text(
        json.dumps({"generado_en": datetime.now(timezone.utc).isoformat(),
                    "reportes": reportes,
                    "resumen": {u: len(v) for u, v in fusion.items()}},
                   ensure_ascii=False, indent=1), encoding="utf-8")
    if not fusion:
        print("[cazar] ningún recurso trae columna LOCAL: se conserva el seed actual. "
              "Detalle en onpe-scraper/data/caza_locales_reporte.json")
        return 1
    if args.dry_run:
        for ub, filas in sorted(fusion.items())[:10]:
            print(f"  {ub}: " + "; ".join(f"{f['nombre'][:40]}({f['mesas']})" for f in filas[:4]))
        print("[dry-run] sin escribir locales_reales.json")
        return 0
    args.salida.parent.mkdir(parents=True, exist_ok=True)
    args.salida.write_text(json.dumps(fusion, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"[cazar] escrito {args.salida} ({len(fusion)} distritos)")
    print("Aplique con: python -m app.seed_arequipa  (renombra sintéticos sin duplicar)")
    return 0


def parsear(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Crawler de nombres reales de locales ONPE")
    modo = p.add_mutually_exclusive_group(required=True)
    modo.add_argument("--descubrir", action="store_true", help="lista datasets y recursos")
    modo.add_argument("--cazar", action="store_true", help="extrae nombres de Arequipa")
    p.add_argument("--salida", type=Path, default=SALIDA_DEFECTO)
    p.add_argument("--solo", action="append", default=[], help="ubigeo distrital (repetible)")
    p.add_argument("--filtro", default="",
                   help="sólo datasets cuyo slug/título contenga este texto (ej. local)")
    p.add_argument("--pausa", type=float, default=PAUSA_SEG)
    p.add_argument("--max-mb", type=int, default=MAX_MB_RECURSO)
    p.add_argument("--max-datasets", type=int, default=0,
                   help="tope de datasets con hallazgo (0 = sin tope; debug)")
    p.add_argument("--refrescar", action="store_true",
                   help="ignora la caché de datasets y recorre el grupo de nuevo")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("-v", "--verbose", action="store_true")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parsear(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
                        datefmt="%H:%M:%S")
    cli = Cliente(pausa=args.pausa)
    try:
        if args.descubrir:
            return comando_descubrir(cli, args)
        return comando_cazar(cli, args)
    except RuntimeError as exc:
        print(f"[error] {exc}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
