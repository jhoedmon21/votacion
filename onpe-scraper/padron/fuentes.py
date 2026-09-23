"""Adaptadores de fuente + validación y normalización del padrón.

Fuentes (en orden de preferencia operativa):
  1. `archivo`   — archivo oficial ONPE (CSV/JSON) de locales y mesas. Es la
                   vía real de producción: la ONPE lo entrega a las
                   organizaciones políticas antes de la jornada.
  2. `catalogo`  — catálogo de datos abiertos (CKAN/DKAN de datosabiertos.gob.pe):
                   busca el dataset y descarga el recurso (ZIP/CSV/XLSX).
  3. `check`     — sólo verifica disponibilidad, sin descargar (vigilancia).

LÍMITE ÉTICO/TÉCNICO: la API ciudadana de la ONPE (`busqueda/dni`) es POR
PERSONA y el padrón es dato personal protegido. Este ETL NO barre DNI y no
expone ninguna opción para hacerlo (`reclamar_barrido_dni` lanza siempre).
"""
from __future__ import annotations

import csv
import json
import logging
import re
import sys
import unicodedata
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from .config import (DEPARTAMENTO_NOMBRE, DEPARTAMENTO_UBIGEO,
                     PREFIJO_A_PROVINCIA, provincia_de_ubigeo)
from .http import (FuenteBloqueada, FuenteNoDisponible, crear_sesion, descargar,
                   obtener)

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Catálogo oficial de distritos (fuente única del repo, con degradación honesta)
# ---------------------------------------------------------------------------
_DISTRITOS: dict[str, dict] | None = None


def distritos_oficiales() -> dict[str, dict]:
    """{ubigeo: {distrito, provincia}} de los 109 distritos de Arequipa.

    Reutiliza `backend/app/core/ubigeo_catalogo.py`. Si no está disponible
    (ejecución fuera del repo), degrada a validación por prefijo y lo avisa.
    """
    global _DISTRITOS
    if _DISTRITOS is not None:
        return _DISTRITOS
    _DISTRITOS = {}
    try:
        raiz = Path(__file__).resolve().parents[2]
        if str(raiz) not in sys.path:
            sys.path.insert(0, str(raiz))
        from backend.app.core.ubigeo_catalogo import DISTRITOS  # type: ignore

        for ubigeo, provincia, distrito in DISTRITOS:
            _DISTRITOS[ubigeo] = {"distrito": distrito, "provincia": provincia}
        logger.info("catálogo de distritos cargado: %d", len(_DISTRITOS))
    except Exception as exc:  # noqa: BLE001 — degradación documentada
        logger.warning(
            "sin catálogo fino de distritos (%s): valido sólo por prefijo 04", exc
        )
    return _DISTRITOS


def reclamar_barrido_dni(*_: Any, **__: Any) -> None:
    """Guarda explícita: barrer DNI para reconstruir el padrón es abuso."""
    raise RuntimeError(
        "Operación prohibida: la API ciudadana de la ONPE es por persona y el "
        "padrón es dato personal protegido. Use --fuente archivo|catalogo."
    )


# ---------------------------------------------------------------------------
# Registros normalizados
# ---------------------------------------------------------------------------
@dataclass
class Mesa:
    numero: str                       # 6 dígitos, ej. '023001'
    electores: int | None = None      # electores hábiles (tope regla R2)


@dataclass
class RegistroLocal:
    ubigeo: str
    departamento: str = DEPARTAMENTO_NOMBRE
    provincia: str = ""
    distrito: str = ""
    codigo_local: str = "SIN-CODIGO"
    nombre_local: str = ""
    direccion: str = ""
    referencia: str = ""
    latitud: float | None = None
    longitud: float | None = None
    mesas: list[Mesa] = field(default_factory=list)

    @property
    def total_mesas(self) -> int:
        return len(self.mesas)


# ---------------------------------------------------------------------------
# Validación (rechaza y reporta en vez de publicar lo indefendible)
# ---------------------------------------------------------------------------
_RE_6DIG = re.compile(r"^\d{6}$")


def es_ubigeo_valido(ubigeo: str) -> bool:
    return bool(_RE_6DIG.match(ubigeo or ""))


def es_mesa_valida(numero: str) -> bool:
    return bool(_RE_6DIG.match((numero or "").strip()))


# ---------------------------------------------------------------------------
# Lectura flexible del archivo oficial (mismo vocabulario que el crawler)
# ---------------------------------------------------------------------------
def _clave(texto: Any) -> str:
    base = unicodedata.normalize("NFKD", str(texto or ""))
    base = "".join(c for c in base if not unicodedata.combining(c))
    base = base.lower().replace("°", "").replace("nº", "n")
    return re.sub(r"[^a-z0-9]+", "_", base).strip("_")


ALIAS_COLUMNAS: dict[str, tuple[str, ...]] = {
    "ubigeo": ("ubigeo", "ubigeo_inei", "codigo_ubigeo", "ubigeo_distrito"),
    "distrito": ("distrito", "nombre_distrito", "dist"),
    "provincia": ("provincia", "nombre_provincia", "prov"),
    "local_codigo": ("local_codigo", "codigo_local", "cod_local", "codigo"),
    "local_nombre": ("local_nombre", "nombre_local", "local_votacion", "local", "nombre"),
    "local_direccion": ("local_direccion", "direccion", "direccion_local",
                        "direccion_exacta"),
    "local_referencia": ("local_referencia", "referencia", "referencia_local",
                         "punto_referencia", "como_llegar"),
    "mesa": ("mesa", "numero_mesa", "nro_mesa", "mesa_sufragio", "n_mesa"),
    "mesas": ("mesas", "lista_mesas", "relacion_mesas"),
    "electores": ("electores", "electores_habiles", "padron", "electores_mesa"),
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
    "local_direccion", "local_referencia", "distrito", "provincia", "electores",
    "latitud", "longitud",
)


def _tokens(clave_norm: str) -> frozenset[str]:
    """Tokens significativos de una cabecera normalizada."""
    return frozenset(
        t for t in clave_norm.split("_") if t and t not in PALABRAS_VACIAS
    )


def mapear_columnas(cabeceras: Iterable[str]) -> dict[str, str]:
    """Empareja las columnas del archivo con el vocabulario interno.

    Matching por tokens (no igualdad exacta): los encabezados oficiales
    vienen como "NOMBRE DEL LOCAL" o "NÚMERO DE MESA", que nunca igualan a
    un alias pero sí contienen todos sus tokens ("nombre"+"local",
    "numero"+"mesa"). Gana el alias más específico; a igualdad, la
    prioridad de PRIORIDAD_COLUMNAS.
    """
    mapa: dict[str, str] = {}
    for original in cabeceras:
        k = _clave(original)
        ht = _tokens(k)
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


def _avisar_no_mapeadas(cabeceras: list[str], mapa: dict[str, str]) -> None:
    """WARNING con las columnas ignoradas (antes se perdían en silencio)."""
    sobran = columnas_no_mapeadas(cabeceras, mapa)
    # "DEPARTAMENTO" y cía. son contexto, no destinos: no ensucian el log.
    sobran = [c for c in sobran if _clave(c) not in ("departamento",)]
    if sobran:
        logger.warning("columnas ignoradas (sin destino): %s", sobran)


def partir_mesas(valor: Any) -> list[str]:
    return [m for m in re.split(r"[,\s;|]+", str(valor or "").strip()) if m]


def leer_csv_filas(ruta: Path) -> list[dict]:
    """Lee CSV con pandas si está (rápido) o csv stdlib (sin dependencias)."""
    try:
        import pandas as pd  # type: ignore

        df = pd.read_csv(ruta, dtype=str, encoding="utf-8-sig").fillna("")
        mapa = mapear_columnas(list(df.columns))
        _avisar_no_mapeadas(list(df.columns), mapa)
        return [{d: fila.get(o, "") for d, o in mapa.items()}
                for fila in df.to_dict(orient="records")]
    except ImportError:
        logger.info("pandas no instalado: leo CSV con stdlib")
    with ruta.open("r", encoding="utf-8-sig", newline="") as fh:
        muestra = fh.read(8192)
        fh.seek(0)
        try:
            dialecto = csv.Sniffer().sniff(muestra, delimiters=",;\t|")
        except csv.Error:
            dialecto = csv.excel
        lector = csv.DictReader(fh, dialect=dialecto)
        mapa = mapear_columnas(lector.fieldnames or [])
        _avisar_no_mapeadas(lector.fieldnames or [], mapa)
        return [{d: (fila.get(o) or "") for d, o in mapa.items()} for fila in lector]


def leer_registros_crudos(ruta: Path) -> list[dict]:
    """Lee CSV/JSON/XML-cabeceras-flexibles → filas con claves internas."""
    if not ruta.exists():
        raise FileNotFoundError(f"archivo oficial no existe: {ruta}")
    if ruta.suffix.lower() == ".json":
        crudo = json.loads(ruta.read_text(encoding="utf-8"))
        filas = crudo if isinstance(crudo, list) else crudo.get("registros") or crudo.get("data") or []
        if not isinstance(filas, list):
            raise ValueError("el JSON debe ser lista o traer 'registros'/'data'")
        return [{_clave(k): v for k, v in f.items()} for f in filas if isinstance(f, dict)]
    if ruta.suffix.lower() in (".xls", ".xlsx"):
        try:
            import pandas as pd  # type: ignore

            df = pd.read_excel(ruta, dtype=str).fillna("")
            mapa = mapear_columnas(list(df.columns))
            return [{d: fila.get(o, "") for d, o in mapa.items()}
                    for fila in df.to_dict(orient="records")]
        except ImportError as exc:
            raise RuntimeError("para .xlsx instale pandas+openpyxl") from exc
    return leer_csv_filas(ruta)


# ---------------------------------------------------------------------------
# Normalización → registros por (ubigeo, codigo_local), con descartes
# ---------------------------------------------------------------------------
@dataclass
class ResultadoNormalizacion:
    locales: list[RegistroLocal]
    descartes: list[str]
    distritos_con_datos: int


def normalizar(
    filas: list[dict],
    *,
    solo_provincia: str = "",
) -> ResultadoNormalizacion:
    """Agrupa filas planas en locales con sus mesas; valida territorio Arequipa.

    Reglas: ubigeo 6 dígitos con prefijo 04 y dentro de los 109 distritos
    (si hay catálogo); mesa 6 dígitos; mesa duplicada entre locales distintos
    se descarta (mismo candado anti-duplicado R4 de las actas).
    """
    oficiales = distritos_oficiales()
    por_clave: dict[tuple[str, str], RegistroLocal] = {}
    descartes: list[str] = []
    mesa_duena: dict[str, str] = {}

    for i, fila in enumerate(filas, start=2):
        ubigeo = str(fila.get("ubigeo") or "").strip()
        if not es_ubigeo_valido(ubigeo):
            descartes.append(f"fila {i}: ubigeo inválido ({ubigeo!r})")
            continue
        if not ubigeo.startswith(DEPARTAMENTO_UBIGEO):
            descartes.append(f"fila {i}: ubigeo {ubigeo} no es de Arequipa")
            continue
        if oficiales and ubigeo not in oficiales:
            descartes.append(f"fila {i}: ubigeo {ubigeo} fuera de los 109 distritos")
            continue
        provincia = (str(fila.get("provincia") or "").strip().upper()
                     or (oficiales.get(ubigeo, {}).get("provincia", "") if oficiales else "")
                     or provincia_de_ubigeo(ubigeo) or "")
        if solo_provincia and provincia != solo_provincia:
            continue  # filtro provincial del CLI: no es descarte, es selección
        distrito = (str(fila.get("distrito") or "").strip().upper()
                    or (oficiales.get(ubigeo, {}).get("distrito", "") if oficiales else ""))

        codigo = str(fila.get("local_codigo") or "").strip()
        nombre = str(fila.get("local_nombre") or "").strip()
        direccion = str(fila.get("local_direccion") or "").strip()

        # Clave de agrupación: el código ONPE manda; sin código se agrupa por
        # nombre normalizado (antes todo caía en un único "SIN-CODIGO" por
        # distrito y las mesas quedaban en un local incorrecto).
        if codigo:
            clave_local = (ubigeo, f"COD:{codigo}")
        elif nombre:
            clave_local = (ubigeo, f"NOM:{_clave(nombre)}")
        else:
            descartes.append(f"fila {i}: sin código ni nombre de local")
            continue
        etiqueta_duena = f"{ubigeo}/{codigo or nombre}"

        def _num(campo: str) -> float | None:
            try:
                return float(str(fila.get(campo) or "").strip())
            except (TypeError, ValueError):
                return None

        local = por_clave.get(clave_local)
        if local is None:
            local = RegistroLocal(
                ubigeo=ubigeo, provincia=provincia, distrito=distrito,
                codigo_local=codigo or "SIN-CODIGO",
                nombre_local=nombre or f"Local {codigo or ubigeo}",
                direccion=direccion,
                referencia=str(fila.get("local_referencia") or "").strip(),
                latitud=_num("latitud"), longitud=_num("longitud"),
            )
            por_clave[clave_local] = local
        elif codigo and _clave(nombre) and _clave(nombre) != _clave(local.nombre_local):
            # Mismo código, distinto nombre: dato sospechoso (se conserva el
            # primero y se avisa en vez de mezclar locales distintos).
            descartes.append(
                f"fila {i}: código {codigo} con nombres distintos "
                f"({local.nombre_local!r} vs {nombre!r}): se conserva el primero"
            )

        candidatas = ([str(fila["mesa"]).strip()] if fila.get("mesa") not in (None, "")
                      else partir_mesas(fila.get("mesas")))
        electores = None
        if str(fila.get("electores") or "").strip() not in ("", "None"):
            try:
                electores = int(float(str(fila["electores"]).replace(",", "")))
            except ValueError:
                pass  # electores no numérico: se ignora el valor, no la fila
        for numero in candidatas:
            if not es_mesa_valida(numero):
                descartes.append(f"fila {i}: mesa inválida ({numero!r})")
                continue
            duena = mesa_duena.get(numero)
            if duena and duena != etiqueta_duena:
                descartes.append(
                    f"fila {i}: mesa {numero} ya estaba en {duena} "
                    f"(duplicada en {etiqueta_duena})"
                )
                continue
            mesa_duena[numero] = etiqueta_duena
            if all(m.numero != numero for m in local.mesas):
                local.mesas.append(Mesa(numero=numero, electores=electores))

    locales = sorted(por_clave.values(), key=lambda l: (l.ubigeo, l.codigo_local))
    for local in locales:
        local.mesas.sort(key=lambda m: m.numero)
    return ResultadoNormalizacion(
        locales=locales,
        descartes=descartes,
        distritos_con_datos=len({l.ubigeo for l in locales}),
    )


# ---------------------------------------------------------------------------
# Fuente: catálogo de datos abiertos (CKAN/DKAN-compatible)
# ---------------------------------------------------------------------------
@dataclass
class RecursoCatalogo:
    titulo: str
    url: str
    formato: str


def buscar_en_catalogo(
    base: str, termino: str, *, timeout_seg: int, pausa_seg: float,
    reintentos: int, user_agent: str,
) -> list[dict]:
    """Busca datasets en el catálogo (CKAN `package_search`, fallback DKAN).

    Retorna paquetes crudos. Si el portal no expone API de búsqueda, lanza
    FuenteNoDisponible con los pasos de descubrimiento manual.
    """
    sesion, limitador = crear_sesion(user_agent, reintentos, timeout_seg, pausa_seg)
    # 1) CKAN estándar.
    try:
        resp = obtener(sesion, limitador,
                       f"{base}/api/3/action/package_search",
                       params={"q": termino, "rows": 20})
        paquetes = resp.json().get("result", {}).get("results", [])
        logger.info("catálogo CKAN: %d paquetes para %r", len(paquetes), termino)
        return paquetes
    except (FuenteBloqueada, FuenteNoDisponible) as exc:
        logger.info("CKAN no disponible (%s); pruebo DKAN", exc)
    # 2) DKAN (Drupal): búsqueda de nodos dataset.
    try:
        resp = obtener(sesion, limitador,
                       f"{base}/api/1/search",
                       params={"fulltext": termino})
        datos = resp.json()
        nodos = datos.get("results", datos if isinstance(datos, list) else [])
        logger.info("catálogo DKAN: %d nodos para %r", len(nodos), termino)
        return nodos if isinstance(nodos, list) else []
    except (FuenteBloqueada, FuenteNoDisponible) as exc:
        raise FuenteNoDisponible(
            f"el catálogo {base} no expone API de búsqueda pública ({exc}). "
            "Identifique el dataset a mano en el portal y pase su URL con "
            "--recurso-url, o use --fuente archivo."
        ) from exc


def recursos_descargables(paquete: dict) -> list[RecursoCatalogo]:
    """Extrae recursos ZIP/CSV/XLSX/XLS de un paquete CKAN o nodo DKAN."""
    recursos: list[RecursoCatalogo] = []
    for r in paquete.get("resources", []) or []:
        formato = str(r.get("format", "")).upper()
        url = r.get("url", "")
        if formato in ("CSV", "ZIP", "XLSX", "XLS") and url:
            recursos.append(RecursoCatalogo(
                titulo=r.get("name", url), url=url, formato=formato))
    # DKAN expone distribuciones DCAT en vez de resources.
    for d in paquete.get("distribution", []) or []:
        url = d.get("downloadURL") or d.get("accessURL", "")
        formato = str(d.get("mediaType", d.get("format", ""))).upper()
        if url and any(f in formato for f in ("CSV", "ZIP", "EXCEL", "SHEET")):
            recursos.append(RecursoCatalogo(
                titulo=d.get("title", url), url=url, formato=formato))
    return recursos


def descargar_y_extraer(
    url: str, destino_dir: Path, *, timeout_seg: int, pausa_seg: float,
    reintentos: int, user_agent: str,
) -> Path:
    """Descarga un recurso y, si es ZIP, extrae el primer CSV/XLSX útil."""
    sesion, limitador = crear_sesion(user_agent, reintentos, timeout_seg, pausa_seg)
    destino_dir.mkdir(parents=True, exist_ok=True)
    nombre = url.split("?")[0].rstrip("/").split("/")[-1] or "recurso"
    archivo = descargar(sesion, limitador, url, destino_dir / nombre)
    if archivo.suffix.lower() == ".zip":
        with zipfile.ZipFile(archivo) as z:
            candidatos = [n for n in z.namelist()
                          if n.lower().endswith((".csv", ".xlsx", ".xls", ".json"))]
            if not candidatos:
                raise FuenteNoDisponible(f"el ZIP {nombre} no trae CSV/XLSX/JSON")
            # Prefiere el archivo más grande (suele ser el dataset, no el diccionario).
            elegido = max(candidatos,
                          key=lambda n: z.getinfo(n).file_size)
            extraido = destino_dir / Path(elegido).name
            with z.open(elegido) as src, extraido.open("wb") as dst:
                dst.write(src.read())
            logger.info("extraído %s del ZIP", extraido.name)
            return extraido
    return archivo
