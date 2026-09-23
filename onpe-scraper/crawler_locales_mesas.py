"""Locales de votación y mesas de Arequipa desde la fuente de la ONPE.

POR QUÉ ESTE ARCHIVO TIENE TRES MODOS Y NO UN CRAWLER DE BARRIDO
---------------------------------------------------------------
Verificado el 2026-09-16 contra el portal oficial:

  * El ORM 2026 de la ONPE enlaza la consulta ciudadana desde
    https://erm2026.onpe.gob.pe/electores-y-miembros-de-mesa/conoce-tu-local-de-votacion/
    y ahí responde, literalmente, "¡Próximamente! El sistema se habilitará con
    la información...". La data de las ERM 2026 todavía no está publicada.

  * El portal de consulta (https://consultaelectoral.onpe.gob.pe) es una SPA
    Angular detrás de AWS WAF (el propio bundle declara el challenge de
    token.awswaf.com). Su contrato, extraído de `main-2BIJKEBZ.js`:

        apiUrl     = ""            # Object.assign sobreescribe "/clv-ciudadano-backend"
        apiVersion = "v1/api"

        POST /v1/api/busqueda/dni          {numeroDocumento: "<DNI>"}
             -> local de votación + número de mesa + si es miembro de mesa
        POST /v1/api/consulta/provisional  {}
        POST /v1/api/consulta/definitiva   {}
        POST /v1/api/configuracion/listar  {}

    (hoy los cuatro devuelven el index.html de la SPA: el backend de las ERM
     2026 aún no está expuesto detrás del reverse proxy)

  * La consecuencia importante: **la API es por ciudadano**. No hay ningún
    endpoint que devuelva la relación completa de locales y mesas de un
    distrito, y no puede haberlo: el padrón es dato personal protegido. Barrer
    DNI para reconstruir el padrón sería un abuso, no una técnica.

Por eso este programa no barre ciudadanos. Hace las tres cosas que sí se
sostienen:

    --estado      Vigila cuándo ONPE habilita la data (sin navegador).
    --descubrir   Abre el portal con un navegador real, resuelve el WAF y
                  captura los XHR para fijar el contrato exacto el día que
                  habiliten la información, sin tener que adivinarlo.
    --importar    Normaliza el ARCHIVO OFICIAL de locales y mesas (CSV, XLSX o
                  JSON) (la
                  "relación de locales de votación y mesas" que la ONPE
                  entrega a las organizaciones políticas y publica como
                  dataset antes de la jornada) al formato que consume la PWA.
                  Ésta es la vía real de producción.

Salida por defecto: frontend/public/data/locales_mesas_arequipa.json
    que la PWA prefiere sobre locales_mesas_demo.json en cuanto existe.

Uso:
    python crawler_locales_mesas.py --dry-run
    python crawler_locales_mesas.py --estado
    python crawler_locales_mesas.py --descubrir [--headful]
    python crawler_locales_mesas.py --importar relacion_onpe.csv
    python crawler_locales_mesas.py --importar actas.xlsx
    python crawler_locales_mesas.py --importar relacion_onpe.csv --sql seed_locales.sql
"""
from __future__ import annotations

import argparse
import asyncio
import csv
import json
import re
import sys
import unicodedata
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

RAIZ = Path(__file__).resolve().parents[1]
UBIGEO_JSON = RAIZ / "frontend" / "public" / "data" / "ubigeo_arequipa.json"
SALIDA_DEFECTO = RAIZ / "frontend" / "public" / "data" / "locales_mesas_arequipa.json"
DIR_DATA = Path(__file__).resolve().parent / "data"
DIR_DESCUBRIMIENTO = DIR_DATA / "descubrimiento.json"
DIR_ERRORES = DIR_DATA / "_errores.log"

ONPE_BASE = "https://consultaelectoral.onpe.gob.pe"
ONPE_CONSULTA = f"{ONPE_BASE}/consulta"
# Rutas del contrato observado en el bundle Angular de la SPA.
ONPE_API = {
    "busqueda/dni": {"numeroDocumento": ""},
    "consulta/provisional": {},
    "consulta/definitiva": {},
    "configuracion/listar": {},
}
DEPARTAMENTO = "04"

ELECTORES_POR_MESA_DEFECTO = 250

CABECERAS_NAVEGADOR = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    ),
    "Accept": "application/json, text/plain, */*",
    "Content-Type": "application/json",
    "Referer": ONPE_CONSULTA,
    "Origin": ONPE_BASE,
}


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
def sin_acentos(texto: Any) -> str:
    base = unicodedata.normalize("NFKD", str(texto or ""))
    return "".join(c for c in base if not unicodedata.combining(c))


def clave(texto: Any) -> str:
    """Normaliza un nombre de columna: 'N° de Mesa' -> 'n_de_mesa'."""
    limpio = sin_acentos(texto).lower().replace("°", "").replace("nº", "n")
    limpio = re.sub(r"[^a-z0-9]+", "_", limpio).strip("_")
    return limpio


ALIAS_COLUMNAS: dict[str, tuple[str, ...]] = {
    "ubigeo": ("ubigeo", "ubigeo_inei", "codigo_ubigeo", "ubigeo_distrito", "cod_distrito"),
    "distrito": ("distrito", "nombre_distrito", "dist"),
    "provincia": ("provincia", "nombre_provincia", "prov"),
    "local_codigo": ("local_codigo", "codigo_local", "cod_local", "local_id", "codigo"),
    "local_nombre": ("local_nombre", "nombre_local", "local_votacion", "local", "nombre"),
    "local_direccion": ("local_direccion", "direccion", "direccion_local", "direccion_votacion"),
    "mesa": ("mesa", "numero_mesa", "nro_mesa", "mesa_sufragio", "n_mesa", "mesa_numero"),
    "mesas": ("mesas", "lista_mesas", "relacion_mesas"),
    "electores": ("electores", "electores_habiles", "padron", "electores_mesa"),
    "pabellon": ("pabellon", "pabellon_aula"),
    "piso": ("piso", "nivel"),
    "latitud": ("latitud", "lat", "latitude"),
    "longitud": ("longitud", "lon", "lng", "longitude"),
}


# Palabras vacías para el matching por tokens ("NOMBRE DEL LOCAL" →
# {nombre, local}). OJO: "n"/"nro" sí son significativos (n° de mesa).
PALABRAS_VACIAS = frozenset(
    {"de", "del", "la", "el", "los", "las", "en", "y", "e", "al", "por"}
)

# Desempate entre destinos (el primero gana): ubigeo y mesa antes que los
# nombres, y lo específico ("codigo_local") antes que lo genérico ("local").
PRIORIDAD_COLUMNAS: tuple[str, ...] = (
    "ubigeo", "mesa", "mesas", "local_codigo", "local_nombre",
    "local_direccion", "distrito", "provincia", "electores",
    "pabellon", "piso", "latitud", "longitud",
)


def _tokens(clave_norm: str) -> frozenset[str]:
    """Tokens significativos de una cabecera normalizada."""
    return frozenset(
        t for t in clave_norm.split("_") if t and t not in PALABRAS_VACIAS
    )


def mapear_columnas(cabeceras: Iterable[str]) -> dict[str, str]:
    """Empareja las columnas del archivo con el vocabulario interno.

    Matching por tokens (no igualdad exacta): "NOMBRE DEL LOCAL" o
    "NÚMERO DE MESA" nunca igualan a un alias pero sí contienen todos sus
    tokens. Gana el alias más específico; a igualdad, PRIORIDAD_COLUMNAS.
    """
    mapa: dict[str, str] = {}
    for original in cabeceras:
        ht = _tokens(clave(original))
        if not ht:
            continue
        mejor: tuple[int, int, str] | None = None  # (tokens, -prioridad, destino)
        for orden, destino in enumerate(PRIORIDAD_COLUMNAS):
            for alias in ALIAS_COLUMNAS[destino]:
                at = _tokens(alias)
                if at and at <= ht:
                    cand = (len(at), -orden, destino)
                    if mejor is None or cand > mejor:
                        mejor = cand
        if mejor is not None and mejor[2] not in mapa:
            mapa[mejor[2]] = original
    return mapa


def columnas_no_mapeadas(cabeceras: Iterable[str], mapa: dict[str, str]) -> list[str]:
    """Cabeceras que no alimentan ningún destino (diagnóstico para el log)."""
    usadas = set(mapa.values())
    return [c for c in cabeceras if c not in usadas]


def es_mesa_valida(valor: Any) -> bool:
    return bool(re.fullmatch(r"\d{6}", str(valor or "").strip()))


def es_ubigeo_valido(valor: Any) -> bool:
    return bool(re.fullmatch(r"\d{6}", str(valor or "").strip()))


def partir_mesas(valor: Any) -> list[str]:
    """'023001, 023002' / '023001 023002' -> ['023001','023002']."""
    return [m for m in re.split(r"[,\s;|]+", str(valor or "").strip()) if m]


# ---------------------------------------------------------------------------
# Plan territorial
# ---------------------------------------------------------------------------
def cargar_ubigeo(ruta: Path = UBIGEO_JSON) -> dict:
    if not ruta.exists():
        raise SystemExit(
            f"No existe {ruta}. Genere el ubigeo primero:\n"
            "    python jne-scraper/tools/build_ubigeo.py"
        )
    return json.loads(ruta.read_text(encoding="utf-8"))


def distritos_de_arequipa(datos: dict) -> list[dict]:
    """Lista plana de los 109 distritos con su provincia."""
    salida: list[dict] = []
    for provincia in datos["provincias"]:
        for distrito in provincia["distritos"]:
            salida.append(
                {
                    "ubigeo": distrito["ubigeo"],
                    # El catálogo guarda AMBAS codificaciones: el archivo oficial de
                    # la ONPE viene en RENIEC (Paucarpata 040109) y el INEI del
                    # sistema es 040112. Sin las dos no se puede emparejar.
                    "ubigeo_reniec": distrito.get("ubigeo_reniec"),
                    "distrito": distrito["nombre"].upper(),
                    "provincia": provincia["nombre"].upper(),
                    "latitud": distrito.get("latitude"),
                    "longitud": distrito.get("longitude"),
                }
            )
    return salida


def _clave_nombre(texto: Any) -> str:
    """Clave de emparejamiento por nombre: sin acentos, en mayúsculas."""
    return " ".join(sin_acentos(texto).upper().split())


class IndiceTerritorial:
    """Resuelve cada fila al distrito del catálogo y devuelve su ubigeo INEI.

    El archivo oficial de la ONPE trae el ubigeo RENIEC y el catálogo del sistema
    está indexado por el INEI; no coinciden (Paucarpata es 040109 y 040112), y
    además 97 códigos colisionan entre sí. Por eso el nombre (provincia, distrito)
    resuelve primero —el dato legible no colisiona— y el código RENIEC queda como
    respaldo para las variantes de grafía ("SANTA RITA DE SIHUAS" por SIGUAS).
    El resultado es siempre el ubigeo INEI que usa el resto del sistema.
    """

    def __init__(self, distritos: list[dict]):
        self.por_ubigeo = {d["ubigeo"]: d for d in distritos}
        # Índice RENIEC completo (los códigos RENIEC son únicos entre los 109).
        # Se consulta sólo después del nombre, porque 97 de esos códigos también
        # existen como INEI y apuntarían a otro distrito si se mirara primero.
        self.por_reniec = {
            d["ubigeo_reniec"]: d for d in distritos if d.get("ubigeo_reniec")
        }
        self.por_nombre = {
            (_clave_nombre(d["provincia"]), _clave_nombre(d["distrito"])): d
            for d in distritos
        }

    def resolver(self, ubigeo: str, provincia: Any, distrito: Any) -> dict | None:
        return (
            self.por_nombre.get((_clave_nombre(provincia), _clave_nombre(distrito)))
            or self.por_reniec.get(ubigeo)
            or self.por_ubigeo.get(ubigeo)
        )


# ---------------------------------------------------------------------------
# Modo 1: vigilancia de disponibilidad
# ---------------------------------------------------------------------------
def _post_json(ruta_api: str, cuerpo: dict, timeout: int = 25) -> tuple[str, Any]:
    """POST al contrato de la ONPE. Devuelve (estado, contenido)."""
    url = f"{ONPE_BASE}/v1/api/{ruta_api}"
    req = urllib.request.Request(
        url, data=json.dumps(cuerpo).encode(), headers=CABECERAS_NAVEGADOR, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            crudo = r.read().decode("utf-8", "replace")
            tipo = r.headers.get("content-type", "")
    except urllib.error.HTTPError as exc:
        return f"HTTP_{exc.code}", exc.read().decode("utf-8", "replace")[:200]
    except Exception as exc:  # noqa: BLE001
        return type(exc).__name__, str(exc)[:200]

    # El reverse proxy de la SPA responde index.html con 200 para lo que no
    # conoce: eso NO es una API viva, es una ruta sin backend.
    if "json" not in tipo:
        return "NO_JSON", f"{tipo or 'sin content-type'} | {crudo[:120]}"
    try:
        return "JSON", json.loads(crudo)
    except json.JSONDecodeError:
        return "NO_JSON", crudo[:200]


def estado_onpe(verbose: bool = True) -> dict:
    """Consulta si el backend de consulta ya está expuesto. Sin navegador."""
    resultado = {"consultado_at": datetime.now(timezone.utc).isoformat(), "rutas": {}}
    vivas = 0
    for ruta, cuerpo in ONPE_API.items():
        # No se consulta por DNI con un documento inventado más de lo necesario:
        # basta saber si la ruta responde JSON.
        estado, contenido = _post_json(ruta, cuerpo)
        resultado["rutas"][ruta] = {"estado": estado, "muestra": contenido if estado != "JSON" else "ok"}
        if estado == "JSON":
            vivas += 1
        if verbose:
            marca = "VIVA" if estado == "JSON" else estado
            print(f"  {marca:8} POST /v1/api/{ruta}")
            if estado != "JSON":
                print(f"           {str(contenido)[:100]}")

    resultado["rutas_vivas"] = vivas
    resultado["habilidata"] = vivas > 0
    return resultado


def comando_estado(salida: bool = True) -> int:
    print(f"Consultando el contrato de {ONPE_BASE} ...")
    info = estado_onpe()
    DIR_DATA.mkdir(parents=True, exist_ok=True)
    (DIR_DATA / "estado_onpe.json").write_text(
        json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print()
    if info["habilidata"]:
        print(
            f"  {info['rutas_vivas']}/{len(ONPE_API)} rutas responden JSON: "
            "el backend de consulta de la ONPE ya está expuesto."
        )
        print("  Siguiente paso: --descubrir, para capturar el contrato exacto.")
        return 0
    print("  Ninguna ruta responde JSON: el backend de las ERM 2026 todavía no")
    print("  está publicado. El portal lo anuncia como 'Próximamente'.")
    print("  Este comando se puede repetir hasta que la data esté habilitada.")
    return 1


# ---------------------------------------------------------------------------
# Modo 2: descubrimiento del contrato (navegador real, resuelve el WAF)
# ---------------------------------------------------------------------------
async def descubrir_contrato(headful: bool = False, espera_ms: int = 9000) -> dict:
    """Abre el portal con un navegador real y graba todo XHR hacia /v1/api.

    Al ser una SPA detrás de AWS WAF, la única forma de ver el contrato real es
    dejar que el navegador resuelva el challenge y observar lo que la aplicación
    pide. Así no hay que adivinar rutas ni cuerpos de petición.
    """
    from playwright.async_api import async_playwright

    capturas: list[dict] = []
    datos: dict = {
        "portal": ONPE_CONSULTA,
        "capturado_at": datetime.now(timezone.utc).isoformat(),
        "titulo": None,
        "sobre_el_aviso": None,
        "peticiones": capturas,
    }

    async with async_playwright() as pw:
        navegador = await pw.chromium.launch(headless=not headful)
        contexto = await navegador.new_context(locale="es-PE")
        pagina = await contexto.new_page()

        pendientes: list[asyncio.Task] = []

        async def registrar(respuesta) -> None:
            url = respuesta.url
            if "/v1/api" not in url and "json" not in (respuesta.headers.get("content-type") or ""):
                return
            cuerpo = ""
            try:
                cuerpo = (await respuesta.text())[:2000]
            except Exception:  # noqa: BLE001
                cuerpo = "<cuerpo no disponible>"
            capturas.append(
                {
                    "metodo": respuesta.request.method,
                    "url": url,
                    "estado": respuesta.status,
                    "content_type": respuesta.headers.get("content-type"),
                    "cuerpo_peticion": respuesta.request.post_data,
                    "cuerpo_respuesta": cuerpo,
                }
            )

        def al_responder(respuesta) -> None:
            pendientes.append(asyncio.create_task(registrar(respuesta)))

        pagina.on("response", al_responder)

        await pagina.goto(ONPE_CONSULTA, wait_until="domcontentloaded", timeout=90_000)
        await pagina.wait_for_timeout(espera_ms)

        try:
            datos["titulo"] = await pagina.title()
        except Exception:  # noqa: BLE001
            pass
        try:
            visible = (await pagina.inner_text("body"))[:600]
            datos["sobre_el_aviso"] = " ".join(visible.split())
        except Exception:  # noqa: BLE001
            pass

        if pendientes:
            await asyncio.gather(*pendientes, return_exceptions=True)
        await navegador.close()

    return datos


def comando_descubrir(headful: bool, espera_ms: int) -> int:
    try:
        import playwright  # noqa: F401
    except ImportError:
        print("[error] falta Playwright. Instale las dependencias del crawler:")
        print("          python -m pip install -r onpe-scraper/requirements-crawler.txt")
        print("          python -m playwright install chromium")
        return 2

    print(f"Abriendo {ONPE_CONSULTA} con un navegador real ...")
    try:
        datos = asyncio.run(descubrir_contrato(headful=headful, espera_ms=espera_ms))
    except Exception as exc:  # noqa: BLE001
        mensaje = str(exc)
        print(f"[error] no se pudo abrir el portal: {type(exc).__name__}")
        if "Executable doesn't exist" in mensaje or "install" in mensaje.lower():
            print("        El binario del navegador no está descargado. Ejecute:")
            print("          python -m playwright install chromium")
        else:
            print(f"        {mensaje[:300]}")
        return 2

    DIR_DATA.mkdir(parents=True, exist_ok=True)
    DIR_DESCUBRIMIENTO.write_text(
        json.dumps(datos, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"  título: {datos['titulo']}")
    if datos.get("sobre_el_aviso"):
        print(f"  aviso del portal: {datos['sobre_el_aviso'][:180]}")
    print(f"  peticiones a /v1/api capturadas: {len(datos['peticiones'])}")
    for p in datos["peticiones"][:10]:
        print(f"    {p['metodo']} {p['estado']} {p['url'][:95]}")
    print(f"\n  contrato guardado en {DIR_DESCUBRIMIENTO}")
    if not datos["peticiones"]:
        print("  (el portal todavía no pide datos: la información no está habilitada)")
    return 0


# ---------------------------------------------------------------------------
# Modo 3: normalización del archivo oficial
# ---------------------------------------------------------------------------
def _indice_columna(ref: str) -> int:
    """'A2' -> 0, 'AA10' -> 26 (letras de la referencia de celda de Excel)."""
    letras = "".join(ch for ch in ref if ch.isalpha())
    idx = 0
    for ch in letras:
        idx = idx * 26 + (ord(ch.upper()) - ord("A") + 1)
    return max(0, idx - 1)


def _aplicar_mapa(cabeceras: list[str], crudas: Iterable[dict], ruta: Path) -> list[dict]:
    """Empareja las cabeceras con el vocabulario interno y proyecta las filas."""
    mapa = mapear_columnas(cabeceras)
    sobran = columnas_no_mapeadas(cabeceras, mapa)
    sobran = [c for c in sobran if clave(c) != "departamento"]
    if sobran:
        print(f"  [aviso] columnas ignoradas (sin destino): {sobran}")
    faltantes = {"ubigeo", "mesa"} - set(mapa)
    if faltantes and "mesas" not in mapa:
        raise SystemExit(
            f"No reconocí las columnas {sorted(faltantes)} en {ruta.name}.\n"
            f"Cabeceras leídas: {cabeceras}\n"
            f"Esperaba algo como: ubigeo, distrito, local_codigo, local_nombre, "
            f"local_direccion, mesa, electores"
        )
    return [
        {destino: fila.get(original) for destino, original in mapa.items()}
        for fila in crudas
    ]


def leer_csv(ruta: Path) -> tuple[list[str], list[dict]]:
    """CSV delimitado por , ; tab o | con detección automática."""
    with ruta.open("r", encoding="utf-8-sig", newline="") as fh:
        muestra = fh.read(8192)
        fh.seek(0)
        try:
            dialecto = csv.Sniffer().sniff(muestra, delimiters=",;\t|")
        except csv.Error:
            dialecto = csv.excel
        lector = csv.DictReader(fh, dialect=dialecto)
        cabeceras = list(lector.fieldnames or [])
        return cabeceras, [dict(fila) for fila in lector]


def leer_xlsx(ruta: Path) -> tuple[list[str], list[dict]]:
    """Lee un .xlsx sin dependencias externas (zipfile + xml.etree).

    El archivo oficial de la ONPE no trae la cabecera en la primera fila (arriba
    van títulos y la fecha), así que la cabecera se busca: la primera fila que
    reconozca UBIGEO y MESA/MESAS. Con eso `--importar actas.xlsx` funciona tal
    como se descarga.
    """
    import xml.etree.ElementTree as ET
    import zipfile

    ns = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    with zipfile.ZipFile(ruta) as z:
        compartidos: list[str] = []
        if "xl/sharedStrings.xml" in z.namelist():
            raiz = ET.fromstring(z.read("xl/sharedStrings.xml"))
            for si in raiz.findall(ns + "si"):
                compartidos.append("".join(t.text or "" for t in si.iter(ns + "t")))

        hojas = sorted(
            n for n in z.namelist() if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", n)
        )
        if not hojas:
            raise SystemExit(f"{ruta.name} no trae hojas de cálculo legibles.")

        crudas: list[list[str]] = []
        with z.open(hojas[0]) as fh:
            fila: list[str] = []
            for _evento, el in ET.iterparse(fh, events=("end",)):
                if el.tag == ns + "c":
                    tipo = el.get("t")
                    idx = _indice_columna(el.get("r", ""))
                    if tipo == "inlineStr":
                        valor = "".join(t.text or "" for t in el.iter(ns + "t"))
                    else:
                        v = el.find(ns + "v")
                        valor = ""
                        if v is not None and v.text is not None:
                            valor = compartidos[int(v.text)] if tipo == "s" else v.text
                    while len(fila) <= idx:
                        fila.append("")
                    fila[idx] = valor
                    el.clear()
                elif el.tag == ns + "row":
                    if any(c.strip() for c in fila):
                        crudas.append(fila)
                    fila = []
                    el.clear()

    for i, candidata in enumerate(crudas[:60]):
        mapa = mapear_columnas(candidata)
        if "ubigeo" in mapa and ({"mesa", "mesas"} & set(mapa)):
            cabeceras = [c.strip() for c in candidata]
            ancho = len(cabeceras)
            filas = [
                dict(zip(cabeceras, (f + [""] * ancho)[:ancho]))
                for f in crudas[i + 1:]
            ]
            return cabeceras, filas

    raise SystemExit(
        f"No encontré la fila de cabeceras (UBIGEO … NUMERO MESA) en {ruta.name}. "
        f"Primeras filas: {crudas[:3]}"
    )


def leer_registros(ruta: Path) -> list[dict]:
    """Lee CSV, XLSX o JSON y devuelve filas con columnas ya mapeadas."""
    if ruta.suffix.lower() == ".json":
        crudo = json.loads(ruta.read_text(encoding="utf-8"))
        filas = crudo if isinstance(crudo, list) else crudo.get("registros") or crudo.get("data") or []
        if not isinstance(filas, list):
            raise SystemExit("El JSON debe ser una lista de registros o traer 'registros'/'data'.")
        return [{(clave(k)): v for k, v in fila.items()} for fila in filas]
    if ruta.suffix.lower() in {".xlsx", ".xlsm"}:
        cabeceras, crudas = leer_xlsx(ruta)
    else:
        cabeceras, crudas = leer_csv(ruta)
    return _aplicar_mapa(cabeceras, crudas, ruta)


def normalizar(filas: list[dict], indice: "IndiceTerritorial") -> tuple[dict, dict]:
    """Convierte filas planas en el formato por_ubigeo que consume la PWA."""
    por_ubigeo: dict[str, dict] = {}
    descartes: list[str] = []
    reapuntes: dict[str, str] = {}
    mesas_vistas: dict[str, str] = {}
    mesa_a_electores: dict[str, int] = {}

    for i, fila in enumerate(filas, start=2):
        ubigeo_crudo = str(fila.get("ubigeo") or "").strip()
        if not es_ubigeo_valido(ubigeo_crudo):
            descartes.append(f"fila {i}: ubigeo inválido ({ubigeo_crudo!r})")
            continue
        if not ubigeo_crudo.startswith(DEPARTAMENTO):
            descartes.append(f"fila {i}: ubigeo {ubigeo_crudo} no es de Arequipa")
            continue
        distrito_info = indice.resolver(
            ubigeo_crudo, fila.get("provincia"), fila.get("distrito")
        )
        if distrito_info is None:
            descartes.append(
                f"fila {i}: ubigeo {ubigeo_crudo} "
                f"({fila.get('distrito')!r}) no está en los 109 distritos"
            )
            continue
        ubigeo = distrito_info["ubigeo"]
        if ubigeo != ubigeo_crudo:
            reapuntes[ubigeo_crudo] = ubigeo

        codigo_crudo = str(fila.get("local_codigo") or "").strip()
        nombre_crudo = str(fila.get("local_nombre") or "").strip()
        if not codigo_crudo and not nombre_crudo:
            descartes.append(f"fila {i}: sin código ni nombre de local")
            continue
        # Clave de agrupación: el código ONPE manda; sin código se agrupa por
        # nombre normalizado (antes todo caía en un único "SIN-CODIGO" por
        # distrito y las mesas quedaban en un local incorrecto).
        clave_local = (f"COD:{codigo_crudo}" if codigo_crudo
                       else f"NOM:{clave(nombre_crudo)}")
        local_codigo = codigo_crudo or "SIN-CODIGO"
        local_nombre = nombre_crudo or f"Local {codigo_crudo or ubigeo}"
        etiqueta = f"{ubigeo}/{codigo_crudo or nombre_crudo}"
        entrada = por_ubigeo.setdefault(
            ubigeo,
            {
                "distrito": distrito_info["distrito"],
                "provincia": distrito_info["provincia"],
                "locales": [],
            },
        )
        local = next((l for l in entrada["locales"] if l["_clave"] == clave_local), None)
        if local is None:
            local = {
                "_clave": clave_local,
                "codigo": local_codigo,
                "nombre": local_nombre,
                "direccion": str(fila.get("local_direccion") or "").strip(),
                "mesas": [],
            }
            for campo in ("latitud", "longitud"):
                valor = fila.get(campo)
                if valor not in (None, ""):
                    try:
                        local[campo] = float(valor)
                    except (TypeError, ValueError):
                        pass
            entrada["locales"].append(local)
        elif (codigo_crudo and clave(nombre_crudo)
                and clave(nombre_crudo) != clave(local["nombre"])):
            descartes.append(
                f"fila {i}: código {codigo_crudo} con nombres distintos "
                f"({local['nombre']!r} vs {nombre_crudo!r}): se conserva el primero"
            )

        candidatas = []
        if fila.get("mesa") not in (None, ""):
            candidatas = [str(fila["mesa"]).strip()]
        elif fila.get("mesas"):
            candidatas = partir_mesas(fila["mesas"])

        electores = None
        if fila.get("electores") not in (None, ""):
            try:
                electores = int(float(str(fila["electores"]).replace(",", "")))
            except ValueError:
                electores = None

        for numero in candidatas:
            if not es_mesa_valida(numero):
                descartes.append(f"fila {i}: mesa inválida ({numero!r})")
                continue
            dueno = mesas_vistas.get(numero)
            if dueno and dueno != etiqueta:
                descartes.append(
                    f"fila {i}: mesa {numero} ya estaba en {dueno} "
                    f"(duplicada en {etiqueta})"
                )
                continue
            mesas_vistas[numero] = etiqueta
            if numero not in local["mesas"]:
                local["mesas"].append(numero)
            if electores:
                mesa_a_electores[numero] = electores
                # Electores por mesa: es el dato que la regla R2 (tope del padrón)
                # necesita con precisión. Se guarda por número de mesa para que el
                # formulario no tenga que asumir un promedio.
                local.setdefault("electores", {})[numero] = electores

    for entrada in por_ubigeo.values():
        for local in entrada["locales"]:
            local.pop("_clave", None)  # interna: no sale al JSON ni al SQL
            local["mesas"].sort()
            if local.get("electores"):
                local["electores"] = {
                    m: local["electores"][m] for m in local["mesas"] if m in local["electores"]
                }
            electores_local = [
                mesa_a_electores[m] for m in local["mesas"] if m in mesa_a_electores
            ]
            if electores_local:
                local["electores_habiles"] = sum(electores_local)
                local["electores_por_mesa"] = max(electores_local)

    doc = {
        "nota": (
            "Locales de votación y mesas OFICIALES de Arequipa, normalizados desde "
            "el archivo de la ONPE. Reemplaza a locales_mesas_demo.json."
        ),
        "fuente": "ONPE — relación de locales de votación y mesas (ERM 2026)",
        "generado_at": datetime.now(timezone.utc).isoformat(),
        "departamento": "Arequipa",
        "electores_por_mesa_defecto": ELECTORES_POR_MESA_DEFECTO,
        "total_locales": sum(len(e["locales"]) for e in por_ubigeo.values()),
        "total_mesas": len(mesas_vistas),
        "distritos_con_datos": len(por_ubigeo),
        "por_ubigeo": dict(sorted(por_ubigeo.items())),
    }
    if mesa_a_electores:
        doc["mesas_con_electores"] = len(mesa_a_electores)
    return doc, {
        "descartes": descartes,
        "reapuntes": reapuntes,
        "mesas_vistas": mesas_vistas,
    }


def generar_sql(doc: dict) -> str:
    """Seed SQL para backend/sql/, coherente con schema_arequipa.sql."""
    lineas = [
        "-- Locales de votación y mesas de Arequipa — generado por onpe-scraper",
        f"-- Generado: {doc['generado_at']}",
        f"-- Locales: {doc['total_locales']} | Mesas: {doc['total_mesas']}",
        "--",
        "-- Requiere que el ubigeo ya esté cargado (seed_ubigeo_arequipa.sql).",
        "BEGIN;",
        "",
    ]
    for ubigeo, entrada in doc["por_ubigeo"].items():
        lineas.append(f"-- {entrada['distrito']} ({entrada['provincia']})")
        for local in entrada["locales"]:
            nombre = local["nombre"].replace("'", "''")
            direccion = local["direccion"].replace("'", "''")
            lat = local.get("latitud")
            lon = local.get("longitud")
            lat_sql = "NULL" if lat is None else f"{lat}"
            lon_sql = "NULL" if lon is None else f"{lon}"
            lineas.append(
                "INSERT INTO locales_votacion "
                "(ubigeo, codigo_local, nombre, direccion, latitud, longitud) VALUES\n"
                f"    ('{ubigeo}', '{local['codigo']}', '{nombre}', "
                f"'{direccion}', {lat_sql}, {lon_sql})\n"
                "ON CONFLICT (ubigeo, codigo_local) DO UPDATE SET\n"
                "    nombre = EXCLUDED.nombre, direccion = EXCLUDED.direccion;"
            )
            por_mesa = local.get("electores") or {}
            for mesa in local["mesas"]:
                electores = por_mesa.get(mesa) or local.get(
                    "electores_por_mesa", ELECTORES_POR_MESA_DEFECTO
                )
                lineas.append(
                    "INSERT INTO mesas (local_id, numero_mesa, electores_habiles) VALUES\n"
                    f"    ((SELECT id FROM locales_votacion WHERE ubigeo = '{ubigeo}' "
                    f"AND codigo_local = '{local['codigo']}'), '{mesa}', {electores})"
                )
                lineas.append("ON CONFLICT (local_id, numero_mesa) DO NOTHING;")
        lineas.append("")
    lineas += ["COMMIT;", ""]
    return "\n".join(lineas)


def comando_importar(ruta: Path, salida: Path, sql: Path | None, verbose: bool) -> int:
    if not ruta.exists():
        print(f"[error] no existe {ruta}")
        return 2

    datos_ubigeo = cargar_ubigeo()
    lista_distritos = distritos_de_arequipa(datos_ubigeo)
    distritos = {d["ubigeo"]: d for d in lista_distritos}
    print(f"Distritos de Arequipa en el ubigeo: {len(distritos)}")

    filas = leer_registros(ruta)
    print(f"Registros leídos de {ruta.name}: {len(filas)}")

    doc, meta = normalizar(filas, IndiceTerritorial(lista_distritos))

    salida.parent.mkdir(parents=True, exist_ok=True)
    salida.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")

    print()
    print(f"  locales       : {doc['total_locales']}")
    print(f"  mesas         : {doc['total_mesas']}")
    print(f"  distritos     : {doc['distritos_con_datos']}/{len(distritos)}")
    reapuntes = meta.get("reapuntes") or {}
    if reapuntes:
        print(f"  ubigeo RENIEC reasignado al INEI del catálogo: {len(reapuntes)} "
              f"(ej. {next(iter(reapuntes.items()))})")
    if doc.get("mesas_con_electores"):
        print(f"  mesas con electores hábiles declarados: {doc['mesas_con_electores']}")
    print(f"  escrito en    : {salida}")

    faltan = sorted(set(distritos) - set(doc["por_ubigeo"]))
    if faltan:
        print(f"\n  {len(faltan)} distrito(s) sin data en el archivo (primeros 10): {faltan[:10]}")

    descartes = meta["descartes"]
    if descartes:
        DIR_DATA.mkdir(parents=True, exist_ok=True)
        with DIR_ERRORES.open("a", encoding="utf-8") as fh:
            fh.write(f"{datetime.now(timezone.utc).isoformat()} {ruta.name}\n")
            for d in descartes:
                fh.write(f"    {d}\n")
        print(f"\n  {len(descartes)} registro(s) descartado(s); detalle en {DIR_ERRORES}")
        if verbose:
            for d in descartes[:25]:
                print(f"    - {d}")

    if sql:
        sql.parent.mkdir(parents=True, exist_ok=True)
        sql.write_text(generar_sql(doc), encoding="utf-8")
        print(f"\n  seed SQL escrito en: {sql}")

    if not doc["total_mesas"]:
        print("\n  [aviso] no se reconoció ninguna mesa válida (6 dígitos).")
        return 1
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parsear(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Locales de votación y mesas de Arequipa desde la fuente de la ONPE",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "La API de consulta de la ONPE es POR CIUDADANO: no existe endpoint que\n"
            "devuelva la relación completa de locales y mesas de un distrito, y el\n"
            "padrón es dato personal protegido. Por eso la vía de producción es\n"
            "--importar con el archivo oficial; --estado y --descubrir cubren la\n"
            "vigilancia hasta que la data esté publicada."
        ),
    )
    modo = p.add_mutually_exclusive_group()
    modo.add_argument("--estado", action="store_true",
                      help="consulta si el backend de la ONPE ya está expuesto (sin navegador)")
    modo.add_argument("--descubrir", action="store_true",
                      help="abre el portal con navegador real y captura el contrato /v1/api")
    modo.add_argument("--importar", type=Path, metavar="ARCHIVO",
                      help="normaliza el archivo oficial de locales y mesas (CSV, XLSX o JSON)")

    p.add_argument("--salida", type=Path, default=SALIDA_DEFECTO,
                   help="ruta del JSON de salida (default: %(default)s)")
    p.add_argument("--sql", type=Path,
                   help="además, genera un seed SQL para backend/sql/")
    p.add_argument("--headful", action="store_true",
                   help="navegador visible en --descubrir (depuración)")
    p.add_argument("--espera", type=int, default=9000,
                   help="ms de espera tras cargar el portal en --descubrir")
    p.add_argument("--dry-run", action="store_true",
                   help="muestra el plan territorial sin tocar la red")
    p.add_argument("-v", "--verbose", action="store_true", help="muestra los descartes")
    return p.parse_args(argv)


def comando_dry_run() -> int:
    datos = cargar_ubigeo()
    distritos = distritos_de_arequipa(datos)
    print(f"[dry-run] plan territorial de Arequipa: {len(distritos)} distritos "
          f"en {len(datos['provincias'])} provincias")
    for provincia in datos["provincias"]:
        ds = provincia["distritos"]
        print(f"  {provincia['ubigeo']} {provincia['nombre']:12} {len(ds):3} distritos"
              f"  (ej. {ds[0]['ubigeo']} {ds[0]['nombre']})")
    print(f"\n  salida por defecto : {SALIDA_DEFECTO}")
    print(f"  contrato ONPE      : {ONPE_BASE}/v1/api/{{{', '.join(ONPE_API)}}}")
    print("\n  Este programa no barre DNI: la API de la ONPE es por ciudadano.")
    print("  Use --estado para vigilar la publicación y --importar para el archivo oficial.")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parsear(argv)
    if args.dry_run:
        return comando_dry_run()
    if args.estado:
        return comando_estado()
    if args.descubrir:
        return comando_descubrir(args.headful, args.espera)
    if args.importar:
        return comando_importar(args.importar, args.salida, args.sql, args.verbose)
    parsear(["--help"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
