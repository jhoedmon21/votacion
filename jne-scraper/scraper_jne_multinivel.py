"""
VotoPaucarpata — Scraper del portal Voto Informado (JNE).

Extrae organizaciones políticas y candidatos del departamento de Arequipa
para los 3 niveles de gobierno: Distrital, Provincial y Regional.
"""

import asyncio
import json
import re
from pathlib import Path

from playwright.async_api import async_playwright

BASE = "https://votoinformado.jne.gob.pe"

# Configuración para los 3 niveles
LEVELS = [
    {
        "name": "DISTRITAL",
        "tipoEleccion": "MUNICIPAL DISTRITAL",
        "dep": "04",
        "pro": "01", 
        "dis": "09",
        "provincia": "Arequipa",
        "distrito": "Paucarpata"
    },
    {
        "name": "PROVINCIAL", 
        "tipoEleccion": "MUNICIPAL PROVINCIAL",
        "dep": "04",
        "pro": "01",
        "dis": "00",  # Distrito 00 suele indicar nivel provincial
        "provincia": "Arequipa",
        "distrito": "Arequipa"  # A nivel provincial, el distrito es la propia provincia
    },
    {
        "name": "REGIONAL",
        "tipoEleccion": "GOBIERNO REGIONAL DE AREQUIPA", 
        "dep": "04",
        "pro": "00",  # Provincia 00 suele indicar nivel regional
        "dis": "00",   # Distrito 00 indica nivel regional
        "provincia": "Arequipa",
        "distrito": "Arequipa"
    }
]

API_ORG = f"{BASE}/api/v1/candidatos/organizaciones"
API_CAND = f"{BASE}/api/v1/candidatos/organizaciones/candidatos"

# Contenedores de medios detectados (blob de Azure)
MEDIA_BASE = "https://stovotoinformadodev.blob.core.windows.net/contenedor-1"
LOGO_BASE = "https://stovotoinformadodev.blob.core.windows.net/contenedor-2"

OUT_JSON = Path(__file__).parent / "candidatos_completo.json"
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

    async def fetch_organizaciones(self, page, location):
        """Obtiene lista de organizaciones para una ubicación específica."""
        try:
            return await page.evaluate(
                """async (loc) => {
                    const r = await fetch("/api/v1/candidatos/organizaciones", {
                        method: "POST",
                        headers: {"Content-Type": "application/json"},
                        body: JSON.stringify(loc),
                    });
                    return await r.json();
                }""",
                location,
            )
        except Exception as e:
            print(f"  [error] fallo al obtener organizaciones: {e}")
            return None

    async def fetch_candidatos(self, page, location, solicitud_id: int):
        """Obtiene candidatos para una organización específica."""
        try:
            data = await page.evaluate(
                """async (args) => {
                    const r = await fetch(args.url, {
                        method: "POST",
                        headers: {"Content-Type": "application/json"},
                        body: JSON.stringify(args.body),
                    });
                    return await r.json();
                }""",
                {"url": API_CAND, "body": {**location, "idSolicitudLista": solicitud_id}},
            )
            return data
        except Exception as e:
            print(f"  [error] fallo al obtener candidatos: {e}")
            return None

    async def download(self, page, url: str, dest: Path):
        """Descarga un archivo de media."""
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

            resultado = {
                "departamento": "AREQUIPA",
                "niveles": {}
            }

            # Procesar cada nivel
            for level in LEVELS:
                print(f"\n{'='*50}")
                print(f"PROCESANDO NIVEL: {level['name']}")
                print(f"{'='*50}")
                
                # Construir location para este nivel
                location = {
                    "dep": level["dep"],
                    "pro": level["pro"], 
                    "dis": level["dis"]
                }
                
                # Obtener organizaciones
                org_resp = await self.fetch_organizaciones(page, location)
                if not org_resp or not org_resp.get("data"):
                    print(f"  [error] no se obtuvo la lista de organizaciones para {level['name']}")
                    continue

                # Buscar el bloque correspondiente al tipo de elección
                bloque = None
                for org_block in org_resp["data"]:
                    if org_block.get("tipoEleccion") == level["tipoEleccion"]:
                        bloque = org_block
                        break
                
                if not bloque:
                    print(f"  [error] bloque {level['tipoEleccion']} no encontrado")
                    continue

                print(f"  Encontradas {len(bloque.get('organizaciones', []))} organizaciones")

                nivel_resultado = {
                    "departamento": level["provincia"],
                    "provincia": level["provincia"], 
                    "distrito": level["distrito"],
                    "ubigeo": f"{level['dep']}{level['pro']}{level['dis']}",
                    "tipoEleccion": level["tipoEleccion"],
                    "organizaciones": [],
                }

                # Preparar directorios de media
                nivel_partidos_dir = DIR_PARTIDOS / level["name"].lower()
                nivel_candidatos_dir = DIR_CANDIDATOS / level["name"].lower()
                nivel_partidos_dir.mkdir(parents=True, exist_ok=True)
                nivel_candidatos_dir.mkdir(parents=True, exist_ok=True)

                # Procesar cada organización
                for org in bloque.get("organizaciones", []):
                    nombre = org["organizacionPolitica"]
                    print(f"\n=== {nombre} ===")
                    
                    for lista in org.get("listas", []):
                        logo_file = org.get("URLlogoOP")
                        logo_path = nivel_partidos_dir / f"partido_{slugify(nombre)}.png"
                        if logo_file:
                            await self.download(page, f"{LOGO_BASE}/{logo_file}", logo_path)
                            print(f"  logo: {logo_path.name}")

                        cand_resp = await self.fetch_candidatos(page, location, lista["idSolicitudLista"])
                        candidatos = []
                        if cand_resp and cand_resp.get("data"):
                            for bloque_cand in cand_resp["data"]:
                                for o in bloque_cand.get("organizaciones", []):
                                    for l in o.get("listas", []):
                                        candidatos.extend(l.get("candidatos", []))

                        alcalde = None
                        regidores = []
                        governors = []  # Para nivel regional
                        
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
                                if dni:
                                    foto_dest = nivel_candidatos_dir / f"candidato_{dni}.jpg"
                                else:
                                    foto_dest = nivel_candidatos_dir / f"candidato_{entry['numero']}.jpg"
                                await self.download(page, f"{MEDIA_BASE}/{foto_file}", foto_dest)
                                entry["foto_local"] = foto_dest.name

                            # Clasificar según el cargo
                            if "ALCALDE" in (entry["cargo"] or ""):
                                alcalde = entry
                            elif "REGIDOR" in (entry["cargo"] or ""):
                                regidores.append(entry)
                            elif "GOBERNADOR" in (entry["cargo"] or ""):
                                governors.append(entry)
                            elif "VICE GOBERNADOR" in (entry["cargo"] or ""):
                                governors.append(entry)

                        # Ordenar según corresponda
                        if level["name"] == "REGIONAL":
                            governors.sort(key=lambda g: (g["numero"] is None, g["numero"] or 0))
                        else:
                            regidores.sort(key=lambda r: (r["numero"] is None, r["numero"] or 0))

                        organizacion_data = {
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
                        }
                        
                        # Añadir cargos según el nivel
                        if level["name"] == "REGIONAL":
                            organizacion_data["gobernador"] = governors[0] if governors else None
                            organizacion_data["vicegobernador"] = governors[1] if len(governors) > 1 else None
                        else:
                            organizacion_data["alcalde"] = alcalde
                            organizacion_data["regidores"] = regidores

                        nivel_resultado["organizaciones"].append(organizacion_data)

                resultado["niveles"][level["name"]] = nivel_resultado
                print(f"\n[DONE] Nivel {level['name']} procesado")
                print(f"       Organizaciones: {len(nivel_resultado['organizaciones'])}")

            # Guardar resultado combinado
            OUT_JSON.write_text(
                json.dumps(resultado, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            print(f"\n[DONE] JSON completo guardado en {OUT_JSON}")

            await browser.close()


async def main():
    scraper = JNEScraper()
    await scraper.run()


if __name__ == "__main__":
    asyncio.run(main())