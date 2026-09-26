"""Crawler de candidatos del JNE (Voto Informado) para toda la Región Arequipa.

Cubre las tres instancias que se computan en Arequipa:

  * REGIONAL    — Gobierno Regional (gobernador, vicegobernador, consejeros)
  * PROVINCIAL  — 8 alcaldías provinciales (alcalde + regidores)
  * DISTRITAL   — 109 alcaldías distritales (alcalde + regidores)

El recorrido no está escrito a mano: se genera desde el ubigeo oficial
(`frontend/public/data/ubigeo_arequipa.json`, producido por tools/build_ubigeo.py).
Cada distrito aporta sus códigos dep/pro/dis en codificación RENIEC, que es la
que responde la API del JNE.

Diseño:
  * RateLimiter      — token bucket con jitter (respeta al portal del JNE).
  * JNEClient        — HTTP directo con `httpx.AsyncClient`, reintentos y
                       backoff exponencial. La API del JNE acepta un POST JSON
                       abierto: no pide cookies, sesión de navegador ni
                       cabeceras de origen, así que no hace falta Playwright.
  * MediaDownloader  — descarga logos y fotos con deduplicación por URL, sobre
                       el mismo cliente HTTP (también con reintentos).
  * CrawlerArequipa  — orquesta el recorrido con checkpoint por ámbito: si se
                       corta, una nueva corrida reanuda sólo lo que falta
                       (`--fresh` lo ignora y recorre todo otra vez).
  * cambios          — módulo hermano que detecta qué candidato entró, cuál
                       salió y a quién le cambió el estado, emparejando por
                       DNI, posición y nombre (el DNI desaparece justo cuando
                       alguien sale de la carrera).

Salida (una por ámbito, así se puede reanudar y versionar por separado):
    data/arequipa/regional/040000.json
    data/arequipa/provincial/040100.json
    data/arequipa/distrital/040112.json
    data/arequipa/_state.json          (progreso)
    data/arequipa/_errors.log          (ámbitos fallidos)

Uso:
    python crawler_arequipa.py --dry-run                 # recorre el plan sin red
    python crawler_arequipa.py --estado                  # ¿responde la API del JNE?
    python crawler_arequipa.py --nivel distrital --distrito 040112
    python crawler_arequipa.py --nivel all --rps 0.8
    python crawler_arequipa.py --nivel provincial --fresh

    # Verificador de cambios: recorre y reporta SÓLO lo que cambió desde el
    # archivo ya publicado, sin escribir nada. Sale con 1 si hubo cambios.
    python crawler_arequipa.py --verificar
    python crawler_arequipa.py --verificar --solo-criticos --informe cambios.json

La ejecución no necesita dependencias de navegador; sólo `httpx`.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import random
import re
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import httpx

# Detección de cambios: módulo hermano, en el mismo directorio que este script.
import cambios as cambios_mod

ROOT = Path(__file__).resolve().parents[1]
UBIGEO_JSON = ROOT / "frontend" / "public" / "data" / "ubigeo_arequipa.json"
OUT_DIR = Path(__file__).resolve().parent / "data" / "arequipa"
MEDIA_DIR = Path(__file__).resolve().parent / "media"

BASE = "https://votoinformado.jne.gob.pe"
API_ORG = f"{BASE}/api/v1/candidatos/organizaciones"
API_CAND = f"{BASE}/api/v1/candidatos/organizaciones/candidatos"
MEDIA_BASE = "https://stovotoinformadodev.blob.core.windows.net/contenedor-1"
LOGO_BASE = "https://stovotoinformadodev.blob.core.windows.net/contenedor-2"

# La API no valida el agente, pero identificarse es lo correcto con un servicio
# público y deja rastro legible en sus registros. Sólo ASCII: httpx rechaza
# cabeceras con caracteres fuera de ese rango.
USER_AGENT = "votoinformado-arequipa/1.0 (+crawler de investigacion; httpx)"

# Etiqueta con la que el JNE rotula cada bloque en /organizaciones.
# El bloque regional llega como "REGIONAL" (y en algunos ámbitos como
# "GOBIERNO REGIONAL DE AREQUIPA"), por eso se compara por coincidencia.
NIVELES = ("regional", "consejero", "provincial", "distrital")
TIPOS_ELECCION = {
    "regional": "REGIONAL",
    "consejero": "REGIONAL",  # mismo bloque del portal; se filtra por provincia
    "provincial": "MUNICIPAL PROVINCIAL",
    "distrital": "MUNICIPAL DISTRITAL",
}
CARGOS = {
    "GOBERNADOR": "GOBERNADOR",
    "VICE": "VICE_GOBERNADOR",
    "CONSEJERO": "CONSEJERO_REGIONAL",
    "ALCALDE": None,       # se resuelve según el nivel (provincial|distrital)
    "REGIDOR": None,
}


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
def slugify(texto: str) -> str:
    limpio = re.sub(r"[^A-Za-z0-9]+", "_", texto or "").strip("_").lower()
    return limpio[:60] or "organizacion"


def normalizar_dni(*candidatos: Any) -> str:
    """El JNE expone el DNI dentro del nombre del archivo de la foto."""
    for valor in candidatos:
        m = re.search(r"(\d{8})", str(valor or ""))
        if m:
            return m.group(1)
    return ""


def clasificar_cargo(cargo: str, nivel: str) -> str | None:
    """Mapea el cargoEleccion del JNE al enum del dominio."""
    texto = (cargo or "").upper()
    if "GOBERNADOR" in texto and "VICE" not in texto:
        return "GOBERNADOR"
    if "VICE" in texto:
        return "VICE_GOBERNADOR"
    if "CONSEJERO" in texto:
        return "CONSEJERO_REGIONAL"
    if "ALCALDE" in texto:
        return "ALCALDE_PROVINCIAL" if nivel == "provincial" else "ALCALDE_DISTRITAL"
    if "REGIDOR" in texto:
        return "REGIDOR_PROVINCIAL" if nivel == "provincial" else "REGIDOR_DISTRITAL"
    return None


# El JNE no usa siempre la misma clave: en las listas distritales/provinciales
# los candidatos vienen en `candidatos`, mientras que en las regionales vienen
# separados en `gobernadores` y `consejeros`.
CLAVES_CANDIDATOS = (
    "candidatos",
    "gobernadores",
    "vicegobernadores",
    "consejeros",
    "alcaldes",
    "regidores",
)


def extraer_candidatos(lista: dict) -> list[dict]:
    """Devuelve los candidatos de una lista sin depender del nombre de la clave."""
    encontrados: list[dict] = []
    for clave in CLAVES_CANDIDATOS:
        valor = lista.get(clave)
        if isinstance(valor, list):
            encontrados.extend(c for c in valor if isinstance(c, dict))
    if encontrados:
        return encontrados
    # Respaldo: cualquier lista de diccionarios dentro de la lista
    for valor in lista.values():
        if isinstance(valor, list):
            encontrados.extend(c for c in valor if isinstance(c, dict))
    return encontrados


def nombre_completo(candidato: dict) -> str:
    partes = [
        candidato.get("nombres"),
        candidato.get("apellidoPaterno"),
        candidato.get("apellidoMaterno"),
    ]
    return " ".join(p for p in partes if p).strip()


# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------
class RateLimiter:
    """Token bucket: `rps` peticiones por segundo con ráfaga `burst` y jitter."""

    def __init__(self, rps: float = 1.0, burst: int = 2) -> None:
        self.rps = max(0.05, rps)
        self.capacity = max(1, burst)
        self._tokens = float(self.capacity)
        self._last = time.monotonic()
        self._lock = asyncio.Lock()

    async def acquire(self) -> None:
        async with self._lock:
            ahora = time.monotonic()
            self._tokens = min(
                self.capacity, self._tokens + (ahora - self._last) * self.rps
            )
            self._last = ahora
            if self._tokens < 1:
                espera = (1 - self._tokens) / self.rps
                await asyncio.sleep(espera)
                self._tokens = 1
            self._tokens -= 1
            # Jitter para no golpear el portal en intervalos exactos
            await asyncio.sleep(random.uniform(0.05, 0.25))


# ---------------------------------------------------------------------------
# Plan de recorrido
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Ambito:
    nivel: str
    ubigeo: str
    dep: str
    pro: str
    dis: str
    provincia: str
    distrito: str | None = None

    @property
    def etiqueta(self) -> str:
        if self.nivel == "regional":
            return "AREQUIPA"
        return self.distrito or self.provincia

    @property
    def loc(self) -> dict[str, str]:
        return {"dep": self.dep, "pro": self.pro, "dis": self.dis}

    def archivo(self, base: Path) -> Path:
        return base / self.nivel / f"{self.ubigeo}.json"


def cargar_ubigeo(ruta: Path = UBIGEO_JSON) -> dict:
    if not ruta.exists():
        raise SystemExit(
            f"No existe {ruta}. Genere el ubigeo primero:\n"
            "    python jne-scraper/tools/build_ubigeo.py"
        )
    return json.loads(ruta.read_text(encoding="utf-8"))


def construir_plan(datos: dict, nivel: str = "all") -> list[Ambito]:
    """Convierte el ubigeo de Arequipa en la lista de ámbitos a recorrer."""
    dep = datos["ubigeo_departamento"]
    plan: list[Ambito] = []

    if nivel in ("all", "regional"):
        plan.append(
            Ambito("regional", f"{dep}0000", dep, "00", "00", "AREQUIPA", None)
        )

    # CONSEJERO REGIONAL: se elige POR PROVINCIA, así que la oferta del portal
    # se pide con el CÓDIGO de cada provincia (pro=01..08), no con pro="00".
    # Cada ámbito guarda su expediente en consejero/040X00.json.
    if nivel in ("all", "consejero"):
        for provincia in datos["provincias"]:
            plan.append(
                Ambito(
                    "consejero",
                    provincia["ubigeo"],
                    dep,
                    provincia["jne_pro"],
                    "00",
                    provincia["nombre"].upper(),
                    None,
                )
            )

    for provincia in datos["provincias"]:
        if nivel in ("all", "provincial"):
            plan.append(
                Ambito(
                    "provincial",
                    provincia["ubigeo"],
                    dep,
                    provincia["jne_pro"],
                    "00",
                    provincia["nombre"].upper(),
                    None,
                )
            )
        if nivel in ("all", "distrital"):
            for distrito in provincia["distritos"]:
                plan.append(
                    Ambito(
                        "distrital",
                        distrito["ubigeo"],
                        distrito["jne"]["dep"],
                        distrito["jne"]["pro"],
                        distrito["jne"]["dis"],
                        provincia["nombre"].upper(),
                        distrito["nombre"].upper(),
                    )
                )
    return plan


# ---------------------------------------------------------------------------
# Descarga de medios
# ---------------------------------------------------------------------------
class MediaDownloader:
    """Descarga logos y fotos, deduplicando por URL.

    Los binarios están en un blob público, así que se bajan con el mismo
    cliente HTTP (y por tanto con los mismos reintentos) en lugar del contexto
    del navegador. Un fallo de medio nunca tumba el ámbito: sólo se cuenta.
    """

    def __init__(self, cliente: "JNEClient", habilitado: bool = True) -> None:
        self.cliente = cliente
        self.habilitado = habilitado
        self._vistos: set[str] = set()
        self.descargados = 0
        self.fallidos = 0

    async def bajar(self, url: str, destino: Path) -> str | None:
        if not self.habilitado or not url or url in self._vistos:
            return None
        self._vistos.add(url)
        if destino.exists() and destino.stat().st_size > 0:
            return destino.name
        try:
            contenido = await self.cliente.get_bytes(url)
        except Exception as exc:  # noqa: BLE001
            self.fallidos += 1
            print(f"      [warn] media {url}: {type(exc).__name__}")
            return None
        if not contenido:
            self.fallidos += 1
            return None
        destino.parent.mkdir(parents=True, exist_ok=True)
        destino.write_bytes(contenido)
        self.descargados += 1
        return destino.name


# ---------------------------------------------------------------------------
# Cliente JNE
# ---------------------------------------------------------------------------
class JNEClient:
    """Cliente HTTP directo sobre la API del JNE, con reintentos y backoff.

    La API interna del portal acepta un POST JSON abierto: no exige cookies,
    sesión de navegador ni cabeceras de origen. La petición del propio portal
    (`POST /v1/candidatos/organizaciones` con `{dep, pro, dis}`) es exactamente
    la misma que se hace desde aquí, así que Playwright sobraba.
    """

    # Vale la pena reintentar: saturación y errores transitorios. Cualquier
    # otro 4xx es un fallo del cliente y no mejora por insistir.
    REINTENTABLES = frozenset({408, 425, 429, 500, 502, 503, 504})

    def __init__(
        self,
        limiter: RateLimiter,
        intentos: int = 4,
        base_espera: float = 2.0,
        max_espera: float = 30.0,
        timeout: float = 30.0,
        user_agent: str = USER_AGENT,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.limiter = limiter
        self.intentos = max(1, intentos)
        self.base_espera = base_espera
        self.max_espera = max_espera
        self.timeout = timeout
        self.user_agent = user_agent
        # Costura para las pruebas: permite inyectar un transporte falso y
        # verificar la política de reintentos sin tocar la red.
        self.transport = transport
        self._http: httpx.AsyncClient | None = None

    async def __aenter__(self) -> "JNEClient":
        self._http = httpx.AsyncClient(
            timeout=httpx.Timeout(self.timeout),
            follow_redirects=True,
            transport=self.transport,
            limits=httpx.Limits(max_connections=4, max_keepalive_connections=2),
            headers={
                "User-Agent": self.user_agent,
                "Accept": "application/json, text/plain, */*",
                "Accept-Language": "es-PE,es;q=0.9",
                "Content-Type": "application/json",
            },
        )
        return self

    async def __aexit__(self, *_) -> None:
        if self._http is not None:
            await self._http.aclose()
            self._http = None

    @property
    def http(self) -> httpx.AsyncClient:
        if self._http is None:
            raise RuntimeError("JNEClient debe usarse dentro de su contexto async")
        return self._http

    async def _dormir(self, segundos: float) -> None:
        """Espera del backoff, aislada para poder observarla en las pruebas."""
        await asyncio.sleep(segundos)

    def _espera(self, intento: int, respuesta: httpx.Response | None = None) -> float:
        """Backoff exponencial con jitter, respetando `Retry-After` si lo trae."""
        if respuesta is not None:
            cabecera = respuesta.headers.get("Retry-After")
            if cabecera:
                try:
                    return min(self.max_espera, max(0.0, float(cabecera)))
                except ValueError:
                    pass  # Retry-After como fecha HTTP: se usa el backoff normal
        return min(self.max_espera, self.base_espera * (2 ** (intento - 1))) \
            + random.uniform(0, 1)

    async def _pedir(self, metodo: str, url: str, **kw) -> httpx.Response:
        """Una petición con reintentos, backoff y respeto del rate limiter."""
        ultimo_error = "sin intentos"
        for intento in range(1, self.intentos + 1):
            await self.limiter.acquire()
            respuesta: httpx.Response | None = None
            try:
                respuesta = await self.http.request(metodo, url, **kw)
                if respuesta.status_code in self.REINTENTABLES:
                    raise httpx.HTTPStatusError(
                        f"HTTP {respuesta.status_code}",
                        request=respuesta.request,
                        response=respuesta,
                    )
                respuesta.raise_for_status()
                return respuesta
            except httpx.HTTPStatusError as exc:
                codigo = exc.response.status_code
                ultimo_error = f"HTTP {codigo}"
                if codigo not in self.REINTENTABLES:
                    raise RuntimeError(f"{metodo} {url} -> {ultimo_error}") from exc
            except Exception as exc:  # noqa: BLE001  (timeout, DNS, conexión, TLS)
                ultimo_error = f"{type(exc).__name__}: {exc}"

            if intento < self.intentos:
                espera = self._espera(intento, respuesta)
                print(
                    f"      [retry {intento}/{self.intentos}] {ultimo_error[:70]} "
                    f"— esperando {espera:.1f}s"
                )
                await self._dormir(espera)

        raise RuntimeError(
            f"{metodo} {url} no respondió tras {self.intentos} intentos: {ultimo_error}"
        )

    async def _post(self, url: str, body: dict) -> dict:
        respuesta = await self._pedir("POST", url, json=body)
        try:
            data = respuesta.json()
        except ValueError as exc:
            raise RuntimeError(
                f"{url} no devolvió JSON ({len(respuesta.content)} bytes)"
            ) from exc
        # El portal envuelve todo en {success, message, data}: un success=False
        # explícito no debe degradarse a una lista vacía en silencio.
        if data.get("success") is False:
            raise RuntimeError(f"{url} respondió success=False: {data.get('message')!r}")
        return data

    async def get_bytes(self, url: str) -> bytes:
        """Descarga un binario (logo o foto) con los mismos reintentos."""
        return (await self._pedir("GET", url)).content

    async def organizaciones(self, loc: dict) -> list[dict]:
        data = await self._post(API_ORG, loc)
        return data.get("data") or []

    async def candidatos(self, loc: dict, id_solicitud_lista: int) -> list[dict]:
        data = await self._post(API_CAND, {**loc, "idSolicitudLista": id_solicitud_lista})
        candidatos: list[dict] = []
        for bloque in data.get("data") or []:
            for organizacion in bloque.get("organizaciones") or []:
                for lista in organizacion.get("listas") or []:
                    candidatos.extend(extraer_candidatos(lista))
        return candidatos

    async def organizaciones(self, loc: dict) -> list[dict]:
        data = await self._post(API_ORG, loc)
        return data.get("data") or []

    async def candidatos(self, loc: dict, id_solicitud_lista: int) -> list[dict]:
        data = await self._post(API_CAND, {**loc, "idSolicitudLista": id_solicitud_lista})
        candidatos: list[dict] = []
        for bloque in data.get("data") or []:
            for organizacion in bloque.get("organizaciones") or []:
                for lista in organizacion.get("listas") or []:
                    candidatos.extend(extraer_candidatos(lista))
        return candidatos


# ---------------------------------------------------------------------------
# Crawler
# ---------------------------------------------------------------------------
@dataclass
class Estadisticas:
    ambitos: int = 0
    ok: int = 0
    fallidos: int = 0
    candidatos: int = 0
    errores: list[str] = field(default_factory=list)


class CrawlerArequipa:
    def __init__(
        self,
        cliente: JNEClient,
        out_dir: Path = OUT_DIR,
        media: MediaDownloader | None = None,
        resume: bool = True,
    ) -> None:
        self.cliente = cliente
        self.out_dir = out_dir
        self.media = media or MediaDownloader(cliente, habilitado=False)
        self.resume = resume
        self.stats = Estadisticas()
        # Capturas de esta corrida en memoria, para poder compararlas sin
        # escribir 110 archivos cuando sólo se quieren ver los cambios.
        self.capturas: dict[str, dict] = {}

    # -- persistencia -------------------------------------------------------
    def _leer_state(self) -> dict:
        ruta = self.out_dir / "_state.json"
        if ruta.exists():
            try:
                return json.loads(ruta.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                return {}
        return {}

    def _guardar_state(self, state: dict) -> None:
        self.out_dir.mkdir(parents=True, exist_ok=True)
        (self.out_dir / "_state.json").write_text(
            json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    def _registrar_error(self, ambito: Ambito, error: Exception) -> None:
        self.out_dir.mkdir(parents=True, exist_ok=True)
        with (self.out_dir / "_errors.log").open("a", encoding="utf-8") as fh:
            fh.write(
                f"{datetime.now(timezone.utc).isoformat()} {ambito.nivel} "
                f"{ambito.ubigeo} {ambito.etiqueta}: {type(error).__name__}: {error}\n"
            )

    # -- recorrido ----------------------------------------------------------
    async def recorrer(self, plan: Iterable[Ambito], guardar: bool = True) -> Estadisticas:
        """Recorre el plan. Con ``guardar=False`` no toca el disco en absoluto."""
        plan = list(plan)
        state = self._leer_state()
        completados = set(state.get("completados", []))

        for i, ambito in enumerate(plan, start=1):
            clave = f"{ambito.nivel}:{ambito.ubigeo}"
            destino = ambito.archivo(self.out_dir)
            self.stats.ambitos += 1

            if guardar and self.resume and clave in completados and destino.exists():
                print(f"[{i}/{len(plan)}] {clave} — ya estaba (checkpoint), se omite")
                continue

            print(f"[{i}/{len(plan)}] {clave} {ambito.etiqueta} -> {ambito.loc}")
            try:
                resultado = await self.crawlear_ambito(ambito)
                self.capturas[clave] = resultado
                self.stats.candidatos += sum(
                    len(org["candidatos"]) for org in resultado["organizaciones"]
                )
                self.stats.ok += 1
                if guardar:
                    destino.parent.mkdir(parents=True, exist_ok=True)
                    destino.write_text(
                        json.dumps(resultado, ensure_ascii=False, indent=2), encoding="utf-8"
                    )
                    completados.add(clave)
                    state["completados"] = sorted(completados)
                    state["ultima_corrida"] = datetime.now(timezone.utc).isoformat()
                    self._guardar_state(state)
            except Exception as exc:  # noqa: BLE001
                self.stats.fallidos += 1
                self.stats.errores.append(f"{clave}: {exc}")
                print(f"      [error] {clave}: {exc}")
                if guardar:
                    self._registrar_error(ambito, exc)

        return self.stats

    async def crawlear_ambito(self, ambito: Ambito) -> dict:
        bloques = await self.cliente.organizaciones(ambito.loc)
        tipo = TIPOS_ELECCION[ambito.nivel]
        disponibles = [(b.get("tipoEleccion") or "").upper() for b in bloques]
        # Coincidencia exacta primero; luego por contención (regional llega como
        # "REGIONAL", "GOBIERNO REGIONAL DE AREQUIPA", etc.)
        bloque = next(
            (b for b in bloques if (b.get("tipoEleccion") or "").upper() == tipo), None
        ) or next(
            (b for b in bloques if tipo in (b.get("tipoEleccion") or "").upper()), None
        )
        if bloque is None:
            raise RuntimeError(
                f"el JNE no devolvió el bloque '{tipo}' (recibidos: {disponibles})"
            )

        organizaciones = []
        for org in bloque.get("organizaciones") or []:
            nombre = org.get("organizacionPolitica") or "SIN NOMBRE"
            candidatos: list[dict] = []

            for lista in org.get("listas") or []:
                id_lista = lista.get("idSolicitudLista")
                if id_lista is None:
                    continue
                crudos = await self.cliente.candidatos(ambito.loc, id_lista)
                candidatos.extend(self._normalizar_candidato(c, ambito) for c in crudos)

            candidatos = [c for c in candidatos if c["cargo"]]
            candidatos.sort(key=lambda c: (c["cargo"], c["posicion"]))

            logo_local = None
            if self.media.habilitado:
                logo_local = await self._descargar_medios(nombre, org, ambito, candidatos)

            organizaciones.append(
                {
                    "organizacionPolitica": nombre,
                    "idOrganizacionPolitica": org.get("idOrganizacionPolitica"),
                    "logo_url": (
                        f"{LOGO_BASE}/{org['URLlogoOP']}" if org.get("URLlogoOP") else None
                    ),
                    "logo_local": logo_local,
                    "codigoExpediente": (org.get("listas") or [{}])[0].get("codigoExpediente"),
                    "candidatos": candidatos,
                }
            )

        return {
            "nivel": ambito.nivel,
            "ubigeo": ambito.ubigeo,
            "departamento": "AREQUIPA",
            "provincia": ambito.provincia,
            "distrito": ambito.distrito,
            "tipoEleccion": tipo,
            "codigos_jne": ambito.loc,
            "crawled_at": datetime.now(timezone.utc).isoformat(),
            "total_organizaciones": len(organizaciones),
            "total_candidatos": sum(len(o["candidatos"]) for o in organizaciones),
            "organizaciones": organizaciones,
        }

    def _normalizar_candidato(self, crudo: dict, ambito: Ambito) -> dict:
        cargo = clasificar_cargo(crudo.get("cargoEleccion"), ambito.nivel)
        estado = (crudo.get("estadoCandidato") or "INSCRITO").upper()
        return {
            "dni": normalizar_dni(crudo.get("urlFotoCandidato"), crudo.get("rutaHojaVida")),
            "nombres": crudo.get("nombres"),
            "apellidoPaterno": crudo.get("apellidoPaterno"),
            "apellidoMaterno": crudo.get("apellidoMaterno"),
            "nombre_completo": nombre_completo(crudo),
            "cargo": cargo,
            "cargo_jne": crudo.get("cargoEleccion"),
            "posicion": crudo.get("numeroCandidato") or crudo.get("numeroPosicion"),
            "numero_posicion": crudo.get("numeroPosicion"),
            "estado": estado,
            "provincia": ambito.provincia,
            "distrito": ambito.distrito,
            "ubigeo": ambito.ubigeo,
            "tipo_eleccion": ambito.nivel.upper(),
            "foto_url": (
                f"{MEDIA_BASE}/{crudo['urlFotoCandidato']}"
                if crudo.get("urlFotoCandidato")
                else None
            ),
            "foto_local": None,
            "hoja_vida_url": (
                f"{MEDIA_BASE}/{crudo['rutaHojaVida']}" if crudo.get("rutaHojaVida") else None
            ),
        }

    async def _descargar_medios(
        self, nombre: str, org: dict, ambito: Ambito, candidatos: list[dict]
    ) -> str | None:
        logo_local = None
        if org.get("URLlogoOP"):
            destino = MEDIA_DIR / "partidos" / f"partido_{slugify(nombre)}.png"
            logo_local = await self.media.bajar(f"{LOGO_BASE}/{org['URLlogoOP']}", destino)
        for candidato in candidatos:
            if not candidato["foto_url"]:
                continue
            identificador = candidato["dni"] or f"{ambito.ubigeo}_{candidato['posicion']}"
            destino = MEDIA_DIR / "candidatos" / f"candidato_{identificador}.jpg"
            candidato["foto_local"] = await self.media.bajar(
                candidato["foto_url"], destino
            )
        return logo_local


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parsear_argumentos(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Crawler de candidatos del JNE para la Región Arequipa",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--nivel", choices=(*NIVELES, "all"), default="all")
    parser.add_argument("--provincia", help="código ubigeo de provincia, p.ej. 040100")
    parser.add_argument("--distrito", help="código ubigeo INEI del distrito, p.ej. 040112")
    parser.add_argument("--limite", type=int, help="máximo de ámbitos a recorrer (smoke test)")
    parser.add_argument("--rps", type=float, default=1.0, help="peticiones por segundo")
    parser.add_argument("--intentos", type=int, default=4, help="intentos por petición")
    parser.add_argument("--base-espera", type=float, default=2.0,
                        help="segundos del primer backoff (se duplica en cada reintento)")
    parser.add_argument("--max-espera", type=float, default=30.0, help="tope del backoff")
    parser.add_argument("--timeout", type=float, default=30.0, help="timeout por petición")
    parser.add_argument("--media", action="store_true", help="descargar logos y fotos")
    parser.add_argument("--fresh", action="store_true", help="ignora el checkpoint y recorre todo")
    parser.add_argument("--estado", action="store_true",
                        help="sólo comprueba si la API del JNE responde, sin recorrer")
    parser.add_argument("--verificar", action="store_true",
                        help="recorre el plan y reporta SÓLO lo que cambió respecto a --contra")
    parser.add_argument("--contra", type=Path, default=OUT_DIR,
                        help="captura de referencia para --verificar")
    parser.add_argument("--solo-criticos", action="store_true",
                        help="en --verificar, informar sólo lo que cambia quién está en carrera")
    parser.add_argument("--informe", type=Path,
                        help="en --verificar, escribir el informe en JSON")
    parser.add_argument("--out", type=Path, default=OUT_DIR)
    parser.add_argument("--dry-run", action="store_true", help="muestra el plan sin tocar la red")
    return parser.parse_args(argv)


def filtrar_plan(plan: list[Ambito], args: argparse.Namespace) -> list[Ambito]:
    if args.nivel != "all":
        plan = [a for a in plan if a.nivel == args.nivel]
    if args.provincia:
        plan = [
            a for a in plan if a.ubigeo.startswith(args.provincia[:4]) or a.ubigeo == args.provincia
        ]
    if args.distrito:
        plan = [a for a in plan if a.ubigeo == args.distrito]
    if args.limite:
        plan = plan[: args.limite]
    return plan


async def ejecutar(args: argparse.Namespace) -> int:
    plan = filtrar_plan(construir_plan(cargar_ubigeo(), args.nivel), args)

    if not plan:
        print("[error] el plan quedó vacío: revise --nivel/--provincia/--distrito")
        return 2

    if args.dry_run:
        print(f"[dry-run] {len(plan)} ámbito(s) a recorrer:")
        for ambito in plan[:15]:
            print(f"  {ambito.nivel:<11} {ambito.ubigeo}  {ambito.etiqueta:<24} {ambito.loc}")
        if len(plan) > 15:
            print(f"  ... y {len(plan) - 15} más")
        return 0

    limiter = RateLimiter(rps=args.rps)
    async with JNEClient(
        limiter,
        intentos=args.intentos,
        base_espera=args.base_espera,
        max_espera=args.max_espera,
        timeout=args.timeout,
    ) as cliente:
        media = MediaDownloader(cliente, habilitado=args.media)
        crawler = CrawlerArequipa(
            cliente, out_dir=args.out, media=media, resume=not args.fresh
        )
        stats = await crawler.recorrer(plan)

    print("\n=== Resumen ===")
    print(f"  ámbitos recorridos : {stats.ok}/{stats.ambitos} (fallidos: {stats.fallidos})")
    print(f"  candidatos         : {stats.candidatos}")
    if args.media:
        print(f"  medios descargados : {media.descargados} (fallidos: {media.fallidos})")
    if stats.errores:
        print("  errores:")
        for error in stats.errores[:10]:
            print(f"    - {error}")
    return 0 if stats.fallidos == 0 else 1


async def verificar(args: argparse.Namespace) -> int:
    """Recorre el plan y reporta sólo lo que cambió respecto a la referencia.

    La captura vive en memoria: no se escribe ningún ámbito, así que se puede
    correr cuantas veces se quiera sin tocar el archivo ya publicado. Devuelve
    0 si no hubo cambios, 1 si los hubo (útil como comprobación automática) y
    2 si no se pudo verificar.
    """
    plan = filtrar_plan(construir_plan(cargar_ubigeo(), args.nivel), args)
    if not plan:
        print("[error] el plan quedó vacío: revise --nivel/--provincia/--distrito")
        return 2

    referencia = cambios_mod.leer_captura(args.contra)
    if not referencia:
        print(f"[error] no hay capturas de referencia en {args.contra}")
        return 2

    print(f"Referencia : {args.contra} ({len(referencia)} ámbitos)")
    print(f"Recorriendo {len(plan)} ámbito(s) sin escribir nada en disco")

    limiter = RateLimiter(rps=args.rps)
    async with JNEClient(
        limiter,
        intentos=args.intentos,
        base_espera=args.base_espera,
        max_espera=args.max_espera,
        timeout=args.timeout,
    ) as cliente:
        crawler = CrawlerArequipa(
            cliente,
            out_dir=args.out,
            media=MediaDownloader(cliente, habilitado=args.media),
            resume=False,  # cada verificación mira el estado actual del portal
        )
        stats = await crawler.recorrer(plan, guardar=False)

    # Sólo entra en el juicio lo que estaba en el plan: acotar el recorrido a un
    # distrito no convierte a los otros 109 ámbitos en «sin verificar». Y de lo
    # que sí estaba, sólo se compara lo que se pudo leer: un ámbito que falló no
    # es un ámbito retirado, y confundirlos llenaría el informe de ruido.
    claves_plan = {f"{ambito.nivel}:{ambito.ubigeo}" for ambito in plan}
    del_plan = {k: v for k, v in referencia.items() if k in claves_plan}
    fuera_del_plan = sorted(set(referencia) - claves_plan)
    comparables = {k: v for k, v in del_plan.items() if k in crawler.capturas}
    sin_verificar = sorted(set(del_plan) - set(crawler.capturas))
    detectados = cambios_mod.comparar(comparables, crawler.capturas)
    conteo = cambios_mod.resumen(detectados)
    criticos = [c for c in detectados if c.critico]

    print()
    print("=== Verificación de cambios ===")
    print(f"  referencia   : {len(referencia)} ámbitos ({len(del_plan)} en el plan)")
    print(f"  comparados   : {len(comparables)}")
    print(f"  recorridos   : {stats.ok}/{stats.ambitos} (fallidos: {stats.fallidos})")
    if fuera_del_plan:
        print(f"  fuera del plan: {len(fuera_del_plan)} ámbitos de la referencia no recorridos")
    if sin_verificar:
        print(f"  sin verificar: {len(sin_verificar)} ámbito(s) del plan que no se leyeron")
        for clave in sin_verificar[:10]:
            print(f"      - {clave}")
        if len(sin_verificar) > 10:
            print(f"      ... y {len(sin_verificar) - 10} más")

    lineas = cambios_mod.formatear(detectados, solo_criticos=args.solo_criticos)
    if lineas:
        print()
        for linea in lineas:
            print(linea)

    print()
    if conteo:
        detalle = ", ".join(f"{tipo}: {cuantos}" for tipo, cuantos in sorted(conteo.items()))
        print(f"  Cambios : {sum(conteo.values())} ({detalle})")
        print(f"  Críticos: {len(criticos)} (cambian quién está en carrera)")
        if args.solo_criticos:
            print("  (mostrando sólo los críticos; quite --solo-criticos para ver todo)")
    else:
        print("  Sin cambios: la captura reproduce la referencia ámbito por ámbito.")

    if args.informe:
        args.informe.parent.mkdir(parents=True, exist_ok=True)
        args.informe.write_text(
            json.dumps(
                {
                    "referencia": str(args.contra),
                    "ambitos_comparados": len(comparables),
                    "ambitos_recorridos": stats.ok,
                    "ambitos_fallidos": stats.fallidos,
                    "errores": stats.errores,
                    "fuera_del_plan": fuera_del_plan,
                    "sin_verificar": sin_verificar,
                    "resumen": dict(conteo),
                    "criticos": len(criticos),
                    "cambios": [asdict(c) | {"critico": c.critico} for c in detectados],
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
        print(f"  Informe : {args.informe}")

    return 1 if detectados else 0


async def comprobar_api(args: argparse.Namespace) -> int:
    """Comprueba si la API del JNE responde, sin recorrer el plan."""
    limiter = RateLimiter(rps=args.rps)
    async with JNEClient(
        limiter, intentos=args.intentos, timeout=args.timeout
    ) as cliente:
        try:
            bloques = await cliente.organizaciones({"dep": "04", "pro": "00", "dis": "00"})
        except Exception as exc:  # noqa: BLE001
            print(f"[estado] la API del JNE NO responde: {type(exc).__name__}: {exc}")
            return 1
    detalle = ", ".join(
        f"{b.get('tipoEleccion')}: {len(b.get('organizaciones') or [])}" for b in bloques
    )
    print(f"[estado] la API del JNE responde. Bloques de Arequipa -> {detalle or 'ninguno'}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parsear_argumentos(argv)
    if args.estado:
        return asyncio.run(comprobar_api(args))
    if args.verificar:
        try:
            return asyncio.run(verificar(args))
        except KeyboardInterrupt:
            print(
                "\n[interrumpido] no se escribió nada: la verificación no toca el archivo",
                file=sys.stderr,
            )
            return 130
    try:
        return asyncio.run(ejecutar(args))
    except KeyboardInterrupt:
        print(
            "\n[interrumpido] el checkpoint quedó guardado: una nueva corrida reanuda "
            "sólo lo que falta (use --fresh para recorrer todo otra vez)",
            file=sys.stderr,
        )
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
