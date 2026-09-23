#!/usr/bin/env python3
"""Scraper de candidatos del JNE/Voto Informado para la Región Arequipa.

Cubre: 1 Regional (Gobernador + Consejeros)
       8 Provinciales (Alcalde + Regidores)
       109 Distritales (Alcalde + Regidores)

Flujo:
  1. Lee ubigeo_arequipa.json (mapa territorial oficial).
  2. Consulta la API interna del JNE por ámbito (dep/pro/dis).
  3. Extrae organizaciones políticas, candidatos, logos y fotos.
  4. Guarda en candidatos_arequipa.json y opcionalmente en SQLite.

Uso:
    python scraper_candidatos_arequipa.py                     # todo
    python scraper_candidatos_arequipa.py --nivel distrital   # solo distritales
    python scraper_candidatos_arequipa.py --nivel provincial  # solo provinciales
    python scraper_candidatos_arequipa.py --nivel regional    # solo regional
    python scraper_candidatos_arequipa.py --rps 2.0           # más agresivo
    python scraper_candidatos_arequipa.py --sqlite            # guarda también en DB
    python scraper_candidatos_arequipa.py --generar-mock      # genera datos simulados
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import sqlite3
import sys
import time
import urllib.parse
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

__version__ = "1.2.0"

# ---------------------------------------------------------------------------
# CONSTANTES
# ---------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parent
UBIGEO_JSON = ROOT / "frontend" / "public" / "data" / "ubigeo_arequipa.json"
SALIDA_JSON = ROOT / "candidatos_arequipa.json"
SALIDA_SQLITE = ROOT / "candidatos_arequipa.db"

JNE_BASE = "https://votoinformado.jne.gob.pe"
API_ORGANIZACIONES = f"{JNE_BASE}/api/v1/candidatos/organizaciones"
API_CANDIDATOS = f"{JNE_BASE}/api/v1/candidatos/organizaciones/candidatos"

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

TIPOS_ELECCION = {
    "regional": "REGIONAL",
    "provincial": "MUNICIPAL PROVINCIAL",
    "distrital": "MUNICIPAL DISTRITAL",
}

CARGOS_MAP = {
    "GOBERNADOR": "GOBERNADOR_REGIONAL",
    "VICE_GOBERNADOR": "VICE_GOBERNADOR",
    "CONSEJERO_REGIONAL": "CONSEJERO_REGIONAL",
    "ALCALDE_PROVINCIAL": "ALCALDE_PROVINCIAL",
    "REGIDOR_PROVINCIAL": "REGIDOR_PROVINCIAL",
    "ALCALDE_DISTRITAL": "ALCALDE_DISTRITAL",
    "REGIDOR_DISTRITAL": "REGIDOR_DISTRITAL",
}

NIVELES = ("regional", "provincial", "distrital")


# ---------------------------------------------------------------------------
# MODELOS
# ---------------------------------------------------------------------------
@dataclass
class Candidato:
    dni: str
    nombres: str
    apellido_paterno: str
    apellido_materno: str
    nombre_completo: str
    cargo: str
    posicion: int
    estado: str
    foto_url: str | None
    hoja_vida_url: str | None

    @property
    def key(self) -> str:
        return f"{self.cargo}:{self.dni or self.nombre_completo}"


@dataclass
class Organizacion:
    nombre: str
    id_org: int | None
    logo_url: str | None
    candidatos: list[Candidato]

    @property
    def slug(self) -> str:
        limpio = re.sub(r"[^A-Za-z0-9]+", "_", self.nombre or "").strip("_").lower()
        return limpio[:60]


@dataclass
class AmbitoElectoral:
    nivel: str
    ubigeo: str
    departamento: str
    provincia: str
    distrito: str | None
    tipo_eleccion: str
    organizaciones: list[Organizacion]
    codigos_jne: dict
    crawled_at: str


# ---------------------------------------------------------------------------
# CLIENTE HTTP PARA LA API DEL JNE
# ---------------------------------------------------------------------------
class JNEApiClient:
    def __init__(self, rps: float = 1.0, timeout: int = 30):
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": USER_AGENT,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "es-PE,es;q=0.9,en;q=0.8",
            "Origin": JNE_BASE,
            "Referer": f"{JNE_BASE}/candidatos/resultados",
        })
        self.rps = rps
        self.timeout = timeout
        self._last_request = 0.0
        self._cookies_set = False

    def _rate_limit(self):
        ahora = time.monotonic()
        diff = ahora - self._last_request
        if diff < 1.0 / self.rps:
            time.sleep((1.0 / self.rps) - diff)
        self._last_request = time.monotonic()

    def _init_session(self):
        if self._cookies_set:
            return
        try:
            r = self.session.get(
                f"{JNE_BASE}/candidatos/resultados?departamento=Arequipa&depCode=04",
                timeout=self.timeout,
            )
            r.raise_for_status()
            self._cookies_set = True
        except requests.RequestException as e:
            print(f"  [warn] no se pudo inicializar sesión JNE: {e}")

    def fetch_organizaciones(self, dep: str, pro: str, dis: str) -> list[dict]:
        self._rate_limit()
        self._init_session()
        payload = {"dep": dep, "pro": pro, "dis": dis}
        r = self.session.post(API_ORGANIZACIONES, json=payload, timeout=self.timeout)
        r.raise_for_status()
        return r.json().get("data", [])

    def fetch_candidatos(self, dep: str, pro: str, dis: str, id_lista: int) -> list[dict]:
        self._rate_limit()
        payload = {"dep": dep, "pro": pro, "dis": dis, "idSolicitudLista": id_lista}
        r = self.session.post(API_CANDIDATOS, json=payload, timeout=self.timeout)
        r.raise_for_status()
        data = r.json().get("data", [])
        candidatos = []
        for bloque in data:
            for org in bloque.get("organizaciones", []):
                for lista in org.get("listas", []):
                    candidatos.extend(self._extraer_candidatos(lista))
        return candidatos

    def _extraer_candidatos(self, lista: dict) -> list[dict]:
        encontrados = []
        claves = ("candidatos", "gobernadores", "vicegobernadores",
                   "consejeros", "alcaldes", "regidores")
        for clave in claves:
            valor = lista.get(clave)
            if isinstance(valor, list):
                encontrados.extend(c for c in valor if isinstance(c, dict))
        if not encontrados:
            for valor in lista.values():
                if isinstance(valor, list):
                    encontrados.extend(c for c in valor if isinstance(c, dict))
        return encontrados

    def close(self):
        self.session.close()


# ---------------------------------------------------------------------------
# NORMALIZACIÓN DE DATOS
# ---------------------------------------------------------------------------
def normalizar_dni(*valores: Any) -> str:
    for v in valores:
        m = re.search(r"(\d{8})", str(v or ""))
        if m:
            return m.group(1)
    return ""


def clasificar_cargo(cargo: str, nivel: str) -> str:
    texto = (cargo or "").upper()
    if "GOBERNADOR" in texto and "VICE" not in texto:
        return "GOBERNADOR_REGIONAL"
    if "VICE" in texto:
        return "VICE_GOBERNADOR"
    if "CONSEJERO" in texto:
        return "CONSEJERO_REGIONAL"
    if "ALCALDE" in texto:
        return "ALCALDE_PROVINCIAL" if nivel == "provincial" else "ALCALDE_DISTRITAL"
    if "REGIDOR" in texto:
        return "REGIDOR_PROVINCIAL" if nivel == "provincial" else "REGIDOR_DISTRITAL"
    return "OTRO"


def nombre_completo(c: dict) -> str:
    return " ".join(filter(None, [c.get("nombres"),
                                   c.get("apellidoPaterno"),
                                   c.get("apellidoMaterno")])).strip()


# ---------------------------------------------------------------------------
# CONSTRUCCIÓN DEL PLAN DE RECORRIDO
# ---------------------------------------------------------------------------
def cargar_ubigeo(ruta: Path = UBIGEO_JSON) -> dict:
    if not ruta.exists():
        raise FileNotFoundError(f"No existe {ruta}")
    return json.loads(ruta.read_text("utf-8"))


def construir_plan(datos: dict, nivel: str = "all") -> list[dict]:
    dep = datos["ubigeo_departamento"]
    plan = []

    if nivel in ("all", "regional"):
        plan.append({
            "nivel": "regional",
            "ubigeo": f"{dep}0000",
            "dep": dep, "pro": "00", "dis": "00",
            "provincia": "AREQUIPA", "distrito": None,
        })

    for prov in datos["provincias"]:
        if nivel in ("all", "provincial"):
            plan.append({
                "nivel": "provincial",
                "ubigeo": prov["ubigeo"],
                "dep": dep, "pro": prov["jne_pro"],
                "dis": "00",
                "provincia": prov["nombre"].upper(), "distrito": None,
            })
        if nivel in ("all", "distrital"):
            for dist in prov["distritos"]:
                plan.append({
                    "nivel": "distrital",
                    "ubigeo": dist["ubigeo"],
                    "dep": dist["jne"]["dep"],
                    "pro": dist["jne"]["pro"],
                    "dis": dist["jne"]["dis"],
                    "provincia": prov["nombre"].upper(),
                    "distrito": dist["nombre"].upper(),
                })
    return plan


# ---------------------------------------------------------------------------
# SCRAPER PRINCIPAL
# ---------------------------------------------------------------------------
class ScraperCandidatosArequipa:
    def __init__(self, cliente: JNEApiClient, ruta_salida: Path = SALIDA_JSON):
        self.cliente = cliente
        self.ruta_salida = ruta_salida
        self.resultados: list[dict] = []
        self.estadisticas = {"ambitos": 0, "ok": 0, "fallidos": 0, "candidatos": 0}

    def ejecutar(self, plan: list[dict]) -> list[dict]:
        total = len(plan)
        for i, ambito in enumerate(plan, 1):
            self.estadisticas["ambitos"] += 1
            etiqueta = ambito.get("distrito") or ambito.get("provincia", "DESCONOCIDO")
            print(f"[{i}/{total}] {ambito['nivel']:>10} {ambito['ubigeo']} {etiqueta}")

            try:
                resultado = self._procesar_ambito(ambito)
                self.resultados.append(resultado)
                self.estadisticas["ok"] += 1
                self.estadisticas["candidatos"] += sum(
                    len(org["candidatos"]) for org in resultado["organizaciones"]
                )
                self._guardar_parcial()
            except Exception as e:
                self.estadisticas["fallidos"] += 1
                print(f"      [error] {e}")
                with open(ROOT / "_scraper_errors.log", "a", encoding="utf-8") as f:
                    f.write(f"{ambito['ubigeo']} {ambito['nivel']}: {e}\n")

        self._guardar_final()
        return self.resultados

    def _procesar_ambito(self, ambito: dict) -> dict:
        loc = {"dep": ambito["dep"], "pro": ambito["pro"], "dis": ambito["dis"]}
        bloques = self.cliente.fetch_organizaciones(loc["dep"], loc["pro"], loc["dis"])
        tipo = TIPOS_ELECCION[ambito["nivel"]]

        bloque = next(
            (b for b in bloques if (b.get("tipoEleccion") or "").upper() == tipo), None
        ) or next(
            (b for b in bloques if tipo in (b.get("tipoEleccion") or "").upper()), None
        )
        if not bloque:
            disponibles = [(b.get("tipoEleccion") or "") for b in bloques]
            raise RuntimeError(f"No se encontró bloque '{tipo}' en {ambito['ubigeo']}. Disponibles: {disponibles}")

        organizaciones = []
        for org_data in bloque.get("organizaciones", []):
            nombre = org_data.get("organizacionPolitica") or "SIN_NOMBRE"
            candidatos = []
            for lista in org_data.get("listas", []):
                id_lista = lista.get("idSolicitudLista")
                if id_lista is None:
                    continue
                crudos = self.cliente.fetch_candidatos(
                    loc["dep"], loc["pro"], loc["dis"], id_lista
                )
                for c in crudos:
                    candidatos.append(self._normalizar(c, ambito))

            candidatos = [c for c in candidatos if c["cargo"] != "OTRO"]
            candidatos.sort(key=lambda c: (c["cargo"], c["posicion"]))
            organizaciones.append({
                "organizacionPolitica": nombre,
                "idOrganizacionPolitica": org_data.get("idOrganizacionPolitica"),
                "logo_url": (
                    f"https://stovotoinformadodev.blob.core.windows.net/contenedor-2/{org_data['URLlogoOP']}"
                    if org_data.get("URLlogoOP") else None
                ),
                "codigoExpediente": (org_data.get("listas") or [{}])[0].get("codigoExpediente"),
                "candidatos": candidatos,
            })

        return {
            "nivel": ambito["nivel"],
            "ubigeo": ambito["ubigeo"],
            "departamento": "AREQUIPA",
            "provincia": ambito["provincia"],
            "distrito": ambito["distrito"],
            "tipoEleccion": tipo,
            "codigos_jne": loc,
            "crawled_at": datetime.now(timezone.utc).isoformat(),
            "total_organizaciones": len(organizaciones),
            "total_candidatos": sum(len(o["candidatos"]) for o in organizaciones),
            "organizaciones": organizaciones,
        }

    def _normalizar(self, crudo: dict, ambito: dict) -> dict:
        cargo_texto = crudo.get("cargoEleccion") or ""
        return {
            "dni": normalizar_dni(crudo.get("urlFotoCandidato"), crudo.get("rutaHojaVida")),
            "nombres": crudo.get("nombres"),
            "apellidoPaterno": crudo.get("apellidoPaterno"),
            "apellidoMaterno": crudo.get("apellidoMaterno"),
            "nombre_completo": nombre_completo(crudo),
            "cargo": clasificar_cargo(cargo_texto, ambito["nivel"]),
            "cargo_jne": cargo_texto,
            "posicion": crudo.get("numeroCandidato") or crudo.get("numeroPosicion") or 0,
            "estado": (crudo.get("estadoCandidato") or "INSCRITO").upper(),
            "provincia": ambito["provincia"],
            "distrito": ambito["distrito"],
            "ubigeo": ambito["ubigeo"],
            "tipo_eleccion": ambito["nivel"].upper(),
            "foto_url": (
                f"https://stovotoinformadodev.blob.core.windows.net/contenedor-1/{crudo['urlFotoCandidato']}"
                if crudo.get("urlFotoCandidato") else None
            ),
            "hoja_vida_url": (
                f"https://stovotoinformadodev.blob.core.windows.net/contenedor-1/{crudo['rutaHojaVida']}"
                if crudo.get("rutaHojaVida") else None
            ),
        }

    def _guardar_parcial(self):
        salida = {"metadata": self._metadata(), "ambitos": self.resultados}
        self.ruta_salida.write_text(json.dumps(salida, ensure_ascii=False, indent=2), "utf-8")

    def _guardar_final(self):
        salida = {
            "metadata": self._metadata(),
            "resumen": {
                "ambitos_procesados": self.estadisticas["ok"],
                "ambitos_fallidos": self.estadisticas["fallidos"],
                "total_candidatos": self.estadisticas["candidatos"],
            },
            "ambitos": self.resultados,
        }
        self.ruta_salida.write_text(json.dumps(salida, ensure_ascii=False, indent=2), "utf-8")
        print(f"\nDatos guardados en {self.ruta_salida}")

    def _metadata(self) -> dict:
        return {
            "fuente": "JNE Voto Informado (votoinformado.jne.gob.pe)",
            "departamento": "Arequipa",
            "ubigeo_base": "040000",
            "total_provincias": 8,
            "total_distritos": 109,
            "generado_por": f"scraper_candidatos_arequipa.py v{__version__}",
            "generado_en": datetime.now(timezone.utc).isoformat(),
        }


# ---------------------------------------------------------------------------
# GENERADOR DE DATOS SIMULADOS (fallback cuando la API del JNE no responde)
# ---------------------------------------------------------------------------
class GeneradorMockCandidatos:
    """Genera datos electorales simulados creíbles para desarrollo/demo."""

    ORGANIZACIONES_REALES = [
        "Acción Popular", "Alianza para el Progreso", "Arequipa Avancemos",
        "Arequipa Tradición y Futuro", "Batalla Perú", "Fuerza Arequipeña",
        "Juntos por el Perú", "Partido Morado", "Perú Libre",
        "Renovación Popular", "Somos Perú", "Yo Arequipa",
    ]

    NOMBRES = ["Carlos", "María", "José", "Ana", "Luis", "Rosa", "Pedro", "Lucía",
               "Miguel", "Carmen", "Jorge", "Elena", "Ricardo", "Patricia", "Fernando"]
    APELLIDOS = ["García", "Quispe", "Mamani", "Flores", "Condori", "Paredes",
                 "Huanca", "Delgado", "Chávez", "Valdivia", "Cáceres", "Bustinza"]

    def __init__(self, semilla: int = 42):
        self.rng = random.Random(semilla)
        self._dnis_usados: set[str] = set()

    def generar_dataset(self) -> dict:
        ambitos = []
        ubigeo = cargar_ubigeo()

        ambitos.append(self._generar_regional(ubigeo))
        for prov in ubigeo["provincias"]:
            ambitos.append(self._generar_provincial(prov))
            for dist in prov["distritos"]:
                ambitos.append(self._generar_distrital(prov, dist))

        return {
            "metadata": {
                "fuente": "DATOS SIMULADOS PARA DESARROLLO",
                "departamento": "Arequipa",
                "ubigeo_base": "040000",
                "total_provincias": 8,
                "total_distritos": 109,
                "generado_por": f"scraper_candidatos_arequipa.py v{__version__} (modo mock)",
                "generado_en": datetime.now(timezone.utc).isoformat(),
                "advertencia": "Estos datos no son reales. Use el modo normal (sin --generar-mock) para datos oficiales del JNE.",
            },
            "resumen": {
                "ambitos_procesados": 1 + 8 + 109,
                "ambitos_fallidos": 0,
                "total_candidatos": 0,
            },
            "ambitos": ambitos,
        }

    def _dni(self) -> str:
        while True:
            d = f"{self.rng.randint(1000000, 99999999):08d}"
            if d not in self._dnis_usados:
                self._dnis_usados.add(d)
                return d

    def _nombre(self) -> dict:
        n = self.rng.choice(self.NOMBRES)
        a1 = self.rng.choice(self.APELLIDOS)
        a2 = self.rng.choice(self.APELLIDOS)
        return {"nombres": n, "apellidoPaterno": a1, "apellidoMaterno": a2,
                "nombre_completo": f"{n} {a1} {a2}"}

    def _generar_candidatos(self, cargo_base: str, count: int, nivel: str, prov: str, dist: str | None, ubigeo: str) -> list[dict]:
        return [{
            **self._nombre(),
            "dni": self._dni(),
            "cargo": cargo_base,
            "posicion": i + 1,
            "estado": "INSCRITO",
            "provincia": prov,
            "distrito": dist,
            "ubigeo": ubigeo,
            "tipo_eleccion": nivel.upper(),
            "foto_url": None,
            "hoja_vida_url": None,
        } for i in range(count)]

    def _orgs(self, nivel: str, num: int) -> list[dict]:
        seleccion = self.rng.sample(self.ORGANIZACIONES_REALES,
                                     min(num, len(self.ORGANIZACIONES_REALES)))
        return [{"organizacionPolitica": o, "idOrganizacionPolitica": self.rng.randint(100, 999),
                  "logo_url": None, "codigoExpediente": f"EXP-{self.rng.randint(1000,9999)}",
                  "candidatos": []} for o in seleccion]

    def _generar_regional(self, ubigeo: dict) -> dict:
        dep = ubigeo["ubigeo_departamento"]
        orgs = self._orgs("regional", 10)
        for org in orgs:
            org["candidatos"] = (
                self._generar_candidatos("GOBERNADOR_REGIONAL", 1, "regional", "AREQUIPA", None, f"{dep}0000") +
                self._generar_candidatos("VICE_GOBERNADOR", 1, "regional", "AREQUIPA", None, f"{dep}0000") +
                self._generar_candidatos("CONSEJERO_REGIONAL", 3, "regional", "AREQUIPA", None, f"{dep}0000")
            )
        return {"nivel": "regional", "ubigeo": f"{dep}0000", "departamento": "AREQUIPA",
                "provincia": "AREQUIPA", "distrito": None, "tipoEleccion": "REGIONAL",
                "codigos_jne": {"dep": dep, "pro": "00", "dis": "00"},
                "crawled_at": datetime.now(timezone.utc).isoformat(),
                "total_organizaciones": len(orgs),
                "total_candidatos": sum(len(o["candidatos"]) for o in orgs),
                "organizaciones": orgs}

    def _generar_provincial(self, prov: dict) -> dict:
        orgs = self._orgs("provincial", 8)
        for org in orgs:
            org["candidatos"] = (
                self._generar_candidatos("ALCALDE_PROVINCIAL", 1, "provincial",
                      prov["nombre"].upper(), None, prov["ubigeo"]) +
                self._generar_candidatos("REGIDOR_PROVINCIAL", 5, "provincial",
                      prov["nombre"].upper(), None, prov["ubigeo"])
            )
        return {"nivel": "provincial", "ubigeo": prov["ubigeo"], "departamento": "AREQUIPA",
                "provincia": prov["nombre"].upper(), "distrito": None,
                "tipoEleccion": "MUNICIPAL PROVINCIAL",
                "codigos_jne": {"dep": "04", "pro": prov["jne_pro"], "dis": "00"},
                "crawled_at": datetime.now(timezone.utc).isoformat(),
                "total_organizaciones": len(orgs),
                "total_candidatos": sum(len(o["candidatos"]) for o in orgs),
                "organizaciones": orgs}

    def _generar_distrital(self, prov: dict, dist: dict) -> dict:
        orgs = self._orgs("distrital", 6)
        for org in orgs:
            org["candidatos"] = (
                self._generar_candidatos("ALCALDE_DISTRITAL", 1, "distrital",
                      prov["nombre"].upper(), dist["nombre"].upper(), dist["ubigeo"]) +
                self._generar_candidatos("REGIDOR_DISTRITAL", 4, "distrital",
                      prov["nombre"].upper(), dist["nombre"].upper(), dist["ubigeo"])
            )
        return {"nivel": "distrital", "ubigeo": dist["ubigeo"], "departamento": "AREQUIPA",
                "provincia": prov["nombre"].upper(), "distrito": dist["nombre"].upper(),
                "tipoEleccion": "MUNICIPAL DISTRITAL",
                "codigos_jne": dist["jne"],
                "crawled_at": datetime.now(timezone.utc).isoformat(),
                "total_organizaciones": len(orgs),
                "total_candidatos": sum(len(o["candidatos"]) for o in orgs),
                "organizaciones": orgs}


# ---------------------------------------------------------------------------
# EXPORTADOR A SQLITE
# ---------------------------------------------------------------------------
class ExportadorSQLite:
    def __init__(self, ruta: Path = SALIDA_SQLITE):
        self.ruta = ruta
        self._conn: sqlite3.Connection | None = None

    def __enter__(self):
        self._conn = sqlite3.connect(str(self.ruta))
        self._crear_tablas()
        return self

    def __exit__(self, *args):
        if self._conn:
            self._conn.close()

    def _crear_tablas(self):
        c = self._conn.cursor()
        c.executescript("""
            CREATE TABLE IF NOT EXISTS organizaciones (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                nivel TEXT, ubigeo TEXT, provincia TEXT, distrito TEXT,
                nombre TEXT UNIQUE, id_org INTEGER, logo_url TEXT,
                tipo_eleccion TEXT, crawled_at TEXT
            );
            CREATE TABLE IF NOT EXISTS candidatos (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                org_id INTEGER REFERENCES organizaciones(id),
                dni TEXT, nombres TEXT, apellido_paterno TEXT,
                apellido_materno TEXT, nombre_completo TEXT, cargo TEXT,
                posicion INTEGER, estado TEXT, provincia TEXT, distrito TEXT,
                ubigeo TEXT, tipo_eleccion TEXT, foto_url TEXT, hoja_vida_url TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_candidatos_dni ON candidatos(dni);
            CREATE INDEX IF NOT EXISTS idx_candidatos_cargo ON candidatos(cargo);
            CREATE INDEX IF NOT EXISTS idx_candidatos_ubigeo ON candidatos(ubigeo);
        """)
        self._conn.commit()

    def exportar(self, dataset: dict):
        c = self._conn.cursor()
        for ambito in dataset.get("ambitos", []):
            for org in ambito.get("organizaciones", []):
                c.execute("""
                    INSERT OR IGNORE INTO organizaciones
                    (nivel, ubigeo, provincia, distrito, nombre, id_org, logo_url, tipo_eleccion, crawled_at)
                    VALUES (?,?,?,?,?,?,?,?,?)
                """, (ambito["nivel"], ambito["ubigeo"], ambito["provincia"],
                      ambito["distrito"], org["organizacionPolitica"],
                      org.get("idOrganizacionPolitica"), org.get("logo_url"),
                      ambito.get("tipoEleccion"), ambito.get("crawled_at")))
                org_id = c.lastrowid
                if org_id == 0:
                    c.execute("SELECT id FROM organizaciones WHERE nombre = ?",
                              (org["organizacionPolitica"],))
                    row = c.fetchone()
                    org_id = row[0] if row else None
                for cand in org.get("candidatos", []):
                    if org_id:
                        c.execute("""
                            INSERT INTO candidatos
                            (org_id, dni, nombres, apellido_paterno, apellido_materno,
                             nombre_completo, cargo, posicion, estado, provincia,
                             distrito, ubigeo, tipo_eleccion, foto_url, hoja_vida_url)
                            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """, (org_id, cand.get("dni"), cand.get("nombres"),
                              cand.get("apellidoPaterno"), cand.get("apellidoMaterno"),
                              cand.get("nombre_completo"), cand.get("cargo"),
                              cand.get("posicion"), cand.get("estado"),
                              cand.get("provincia"), cand.get("distrito"),
                              cand.get("ubigeo"), cand.get("tipo_eleccion"),
                              cand.get("foto_url"), cand.get("hoja_vida_url")))
        self._conn.commit()
        print(f"Exportado a SQLite: {self.ruta}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=f"Scraper de candidatos JNE para Arequipa v{__version__}",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--nivel", choices=(*NIVELES, "all"), default="all")
    p.add_argument("--rps", type=float, default=1.0, help="peticiones por segundo")
    p.add_argument("--timeout", type=int, default=30, help="timeout HTTP en segundos")
    p.add_argument("--salida", type=Path, default=SALIDA_JSON, help="archivo JSON de salida")
    p.add_argument("--sqlite", action="store_true", help="exportar también a SQLite")
    p.add_argument("--generar-mock", action="store_true",
                   help="generar datos simulados (sin conexión JNE)")
    p.add_argument("--dry-run", action="store_true", help="mostrar plan sin ejecutar")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    datos = cargar_ubigeo()
    plan = construir_plan(datos, args.nivel)

    if not plan:
        print("El plan quedó vacío. Revise --nivel.")
        return 2

    if args.dry_run:
        print(f"Plan de recorrido: {len(plan)} ámbito(s)")
        for a in plan[:20]:
            d = a.get("distrito") or "—"
            print(f"  {a['nivel']:>10} {a['ubigeo']}  {a['provincia']:<20} {d}")
        if len(plan) > 20:
            print(f"  ... y {len(plan)-20} más")
        return 0

    if args.generar_mock:
        print("Generando datos simulados (modo mock)...")
        generador = GeneradorMockCandidatos()
        dataset = generador.generar_dataset()
        args.salida.write_text(json.dumps(dataset, ensure_ascii=False, indent=2), "utf-8")
        total = sum(len(o["candidatos"]) for a in dataset["ambitos"] for o in a["organizaciones"])
        print(f"Dataset simulado guardado: {args.salida}")
        print(f"Total candidatos generados: {total}")
        if args.sqlite:
            with ExportadorSQLite() as exp:
                exp.exportar(dataset)
        return 0

    cliente = JNEApiClient(rps=args.rps, timeout=args.timeout)
    try:
        scraper = ScraperCandidatosArequipa(cliente, ruta_salida=args.salida)
        resultados = scraper.ejecutar(plan)
        stats = scraper.estadisticas
        print(f"\n=== Resumen ===")
        print(f"  Ámbitos: {stats['ok']}/{stats['ambitos']} (fallidos: {stats['fallidos']})")
        print(f"  Candidatos: {stats['candidatos']}")

        if args.sqlite:
            with ExportadorSQLite() as exp:
                exp.exportar({"ambitos": resultados})
        return 0 if stats["fallidos"] == 0 else 1
    finally:
        cliente.close()


if __name__ == "__main__":
    raise SystemExit(main())