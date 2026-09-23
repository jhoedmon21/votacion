"""
VotoPaucarpata — Scraper del portal Voto Informado (JNE).

Extrae organizaciones políticas y candidatos del distrito de Paucarpata
(Arequipa) mediante Playwright, capturando las respuestas JSON de la API
interna del JNE para obtener los datos crudos y las URLs de medios en
máxima calidad sin depender del DOM.

APIs descubiertas (POST):
  /api/v1/candidatos/organizaciones              -> {dep, pro, dis}
  /api/v1/candidatos/organizaciones/candidatos   -> {dep, pro, dis, idSolicitudLista}

Almacenamiento:
  candidatos_paucarpata.json       -> resultado estructurado
  media/partidos/                  -> logos de organizaciones
  media/candidatos/                -> fotos de candidatos
"""
import asyncio
import json
import re
from pathlib import Path

from playwright.async_api import async_playwright

BASE = "https://votoinformado.jne.gob.pe"
URL = (
    f"{BASE}/candidatos/resultados?departamento=Arequipa&depCode=04"
    "&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"
)

# Ubicación (Paucarpata, Arequipa)
LOCATION = {"dep": "04", "pro": "01", "dis": "09"}

API_ORG = f"{BASE}/api/v1/candidatos/organizaciones"
API_CAND = f"{BASE}/api/v1/candidatos/organizaciones/candidatos"

# Contenedores de medios detectados (blob de Azure)
#  - contenedor-1: fotos de candidatos y hojas de vida (PDF)
#  - contenedor-2: logos de organizaciones políticas
MEDIA_BASE = "https://stovotoinformadodev.blob.core.windows.net/contenedor-1"
LOGO_BASE = "https://stovotoinformadodev.blob.core.windows.net/contenedor-2"

OUT_JSON = Path(__file__).parent / "candidatos_paucarpata.json"
DIR_PARTIDOS = Path(__file__).parent / "media" / "partidos"
DIR_CANDIDATOS = Path(__file__).parent / "media" / "candidatos"


def slugify(text: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "_", text).strip("_").lower()
    return s[:60] or "partido"


def normalize_dni(filename: str) -> str:
    m = re.search(r"(\d{8})", filename or "")
    return m.group(1) if m else ""


class JNEScraper:
    def __init__(self):
        self._responses: dict[str, dict] = {}
        self._media_urls: set[str] = set()

    async def _on_response(self, resp):
        url = resp.url
        if url.startswith(API_ORG) or url.startswith(API_CAND):
            try:
                ct = resp.headers.get("content-type", "")
                if "json" in ct:
                    self._responses[url] = await resp.json()
            except Exception:
                pass

    async def _on_request(self, req):
        if any(x in req.url.lower() for x in [".jpg", ".png", ".pdf", ".jpeg"]):
            self._media_urls.add(req.url)

    async def open_page(self, page):
        page.on("response", self._on_response)
        page.on("request", self._on_request)
        try:
            await page.goto(URL, wait_until="networkidle", timeout=90000)
        except Exception as e:
            print("  [warn] goto:", e)
        await page.wait_for_timeout(3000)
        await page.evaluate(
            """async (loc) => {
                const r = await fetch("/api/v1/candidatos/organizaciones", {
                    method: "POST",
                    headers: {"Content-Type": "application/json"},
                    body: JSON.stringify(loc),
                });
                return await r.json();
            }""",
            LOCATION,
        )
        await page.wait_for_timeout(1500)

    async def fetch_candidatos(self, page, solicitud_id: int):
        data = await page.evaluate(
            """async (args) => {
                const r = await fetch(args.url, {
                    method: "POST",
                    headers: {"Content-Type": "application/json"},
                    body: JSON.stringify(args.body),
                });
                return await r.json();
            }""",
            {"url": API_CAND, "body": {**LOCATION, "idSolicitudLista": solicitud_id}},
        )
        return data

    async def download(self, page, url: str, dest: Path):
        if not url:
            return None
        try:
            resp = await page.request.get(url, timeout=30000)
            if resp.ok:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(await resp.body())
                return dest.name
        except Exception as e:
            print(f"    [warn] descarga fallida {url}: {e}")
        return None

    async def run(self):
        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=True)
            page = await browser.new_page()
            await self.open_page(page)

            org_resp = self._responses.get(API_ORG)
            if not org_resp or not org_resp.get("data"):
                print("  [error] no se obtuvo la lista de organizaciones")
                await browser.close()
                return

            distrital = None
            for bloque in org_resp["data"]:
                if bloque.get("tipoEleccion") == "MUNICIPAL DISTRITAL":
                    distrital = bloque
                    break
            if not distrital:
                print("  [error] bloque MUNICIPAL DISTRITAL no encontrado")
                await browser.close()
                return

            resultado = {
                "departamento": "AREQUIPA",
                "provincia": "AREQUIPA",
                "distrito": "PAUCARPATA",
                "ubigeo": "040109",
                "tipoEleccion": "MUNICIPAL DISTRITAL",
                "organizaciones": [],
            }

            DIR_PARTIDOS.mkdir(parents=True, exist_ok=True)
            DIR_CANDIDATOS.mkdir(parents=True, exist_ok=True)

            for org in distrital["organizaciones"]:
                nombre = org["organizacionPolitica"]
                print(f"\n=== {nombre} ===")
                for lista in org.get("listas", []):
                    logo_file = org.get("URLlogoOP")
                    logo_path = DIR_PARTIDOS / f"partido_{slugify(nombre)}.png"
                    if logo_file:
                        await self.download(page, f"{LOGO_BASE}/{logo_file}", logo_path)
                        print(f"  logo: {logo_path.name}")

                    cand_resp = await self.fetch_candidatos(page, lista["idSolicitudLista"])
                    candidatos = []
                    if cand_resp and cand_resp.get("data"):
                        for bloque in cand_resp["data"]:
                            for o in bloque.get("organizaciones", []):
                                for l in o.get("listas", []):
                                    candidatos.extend(l.get("candidatos", []))

                    alcalde = None
                    regidores = []
                    for c in candidatos:
                        entry = {
                            "numero": c.get("numeroCandidato"),
                            "posicion": c.get("numeroPosicion"),
                            "nombres": c.get("nombres"),
                            "apellidoPaterno": c.get("apellidoPaterno"),
                            "apellidoMaterno": c.get("apellidoMaterno"),
                            "dni": normalize_dni(c.get("urlFotoCandidato")),
                            "cargo": c.get("cargoEleccion"),
                            "estado": c.get("estadoCandidato"),
                            "hojaVida": c.get("rutaHojaVida"),
                            "idHojaVida": c.get("idHojaVida"),
                            "foto": c.get("urlFotoCandidato"),
                        }
                        foto_file = c.get("urlFotoCandidato")
                        if foto_file:
                            dni = entry["dni"]
                            foto_dest = DIR_CANDIDATOS / (
                                f"candidato_{dni}.jpg" if dni else f"candidato_{entry['numero']}.jpg"
                            )
                            await self.download(page, f"{MEDIA_BASE}/{foto_file}", foto_dest)
                            entry["foto_local"] = foto_dest.name

                        if "ALCALDE" in (entry["cargo"] or ""):
                            alcalde = entry
                        elif "REGIDOR" in (entry["cargo"] or ""):
                            regidores.append(entry)

                    regidores.sort(key=lambda r: (r["numero"] is None, r["numero"] or 0))

                    resultado["organizaciones"].append({
                        "organizacionPolitica": nombre,
                        "idOrganizacionPolitica": org.get("idOrganizacionPolitica"),
                        "logo": logo_path.name if logo_file else None,
                        "logo_url": f"{LOGO_BASE}/{logo_file}" if logo_file else None,
                        "codigoExpediente": lista.get("codigoExpediente"),
                        "planGobierno": lista.get("rutaPlanGobierno"),
                        "planGobierno_url": (
                            f"{MEDIA_BASE}/{lista['rutaPlanGobierno']}"
                            if lista.get("rutaPlanGobierno") else None
                        ),
                        "alcalde": alcalde,
                        "regidores": regidores,
                    })

            OUT_JSON.write_text(
                json.dumps(resultado, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            print(f"\n[DONE] JSON guardado en {OUT_JSON}")
            print(f"       Organizaciones: {len(resultado['organizaciones'])}")

            await browser.close()


async def main():
    scraper = JNEScraper()
    await scraper.run()


if __name__ == "__main__":
    asyncio.run(main())