"""Seed de mocks — Provincia de Arequipa (29 distritos).

Genera el JSON de ingesta (contrato ``ingesta-jornada-v1.schema.json``) con
organizaciones, candidatos, locales y mesas de prueba para los distritos de
la provincia, y lo publica con ``POST /api/ingesta/jornada``.

Mesas 910001+ y locales "MOCK": no colisionan con el padrón real y se limpian
con ``DELETE FROM tables WHERE numero_mesa LIKE '910%'``.

Uso:
    python seed_data.py --out mocks/provincia_mock.json
    python seed_data.py --post http://localhost:8000 --token <Bearer>
    python seed_data.py --distritos 040103,040104   # subconjunto
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

# (ubigeo, distrito, capital, lat, lon) — subconjunto representativo;
# el catálogo completo de 29 está en backend/sql/schema.sql §11.
DISTRITOS = [
    ("040103", "CAYMA", "Cayma", -16.3625, -71.544167),
    ("040104", "CERRO COLORADO", "La Libertad", -16.376389, -71.560833),
    ("040112", "PAUCARPATA", "Paucarpata", -16.432778, -71.504722),
    ("040122", "SOCABAYA", "Socabaya", -16.4675, -71.528611),
    ("040126", "YANAHUARA", "Yanahuara", -16.381944, -71.536389),
    ("040129", "JOSE LUIS BUSTAMANTE Y RIVERO", "Ciudad Satélite",
     -16.426667, -71.523889),
]

PARTIDOS = [
    ("AREQUIPA, TRADICION Y FUTURO", "ATF", "#DC2626"),
    ("YO AREQUIPA", "YO", "#0E7490"),
    ("FUERZA AREQUIPEÑA", "FA", "#CA8A04"),
    ("AREQUIPA AVANCEMOS", "AV", "#0056B3"),
    ("SOMOS PERU", "SP", "#0033A0"),
]

CANDIDATOS = [
    ("ROHEL", "SANCHEZ SANCHEZ"),
    ("VICTOR HUGO", "RIVERA GUTIERREZ"),
    ("MARCO ANTONIO", "ANCO HUARCA"),
    ("LUCIA", "PAREDES VERA"),
    ("JORGE", "MAMANI TICONA"),
]


def candidato(numero: int, cargo: str, semilla: int) -> dict:
    nom, ape = CANDIDATOS[(semilla + numero) % len(CANDIDATOS)]
    return {
        "numero": numero, "dni": f"{91000000 + semilla * 10 + numero:08d}",
        "nombres": nom, "apellidos": ape,
        "nombre_completo": f"{nom} {ape}", "cargo": cargo,
        "estado": "INSCRITO",
    }


def documento(distritos: list[tuple]) -> dict:
    ahora = datetime.now(timezone.utc).isoformat()
    orgs_reg = [{
        "numero": i, "organizacionPolitica": nombre, "nombreCorto": corto,
        "idOrganizacionPolitica": 910 + i, "tipo": "MOVIMIENTO_REGIONAL",
        "logo_url": None, "color_hex": color,
        "candidatos": [candidato(1, "GOBERNADOR", i * 7)],
    } for i, (nombre, corto, color) in enumerate(PARTIDOS, start=1)]
    orgs_prov = [{
        "numero": i, "organizacionPolitica": nombre, "nombreCorto": corto,
        "idOrganizacionPolitica": 910 + i, "tipo": "MOVIMIENTO_REGIONAL",
        "logo_url": None, "color_hex": color,
        "candidatos": [candidato(1, "ALCALDE_PROVINCIAL", i * 11)],
    } for i, (nombre, corto, color) in enumerate(PARTIDOS, start=1)]

    ambitos = [
        {"tipo_eleccion": "REGIONAL", "ubigeo": "040000",
         "provincia": None, "distrito": None, "organizaciones": orgs_reg},
        {"tipo_eleccion": "PROVINCIAL", "ubigeo": "040100",
         "provincia": "AREQUIPA", "distrito": None,
         "organizaciones": orgs_prov},
    ]
    for ubigeo, dist, _cap, _lat, _lon in distritos:
        ambitos.append({
            "tipo_eleccion": "DISTRITAL", "ubigeo": ubigeo,
            "provincia": "AREQUIPA", "distrito": dist,
            "organizaciones": [{
                "numero": i, "organizacionPolitica": nombre,
                "nombreCorto": corto, "idOrganizacionPolitica": 910 + i,
                "tipo": "MOVIMIENTO_REGIONAL", "logo_url": None,
                "color_hex": color,
                "candidatos": [candidato(1, "ALCALDE_DISTRITAL", i * 13)],
            } for i, (nombre, corto, color) in enumerate(PARTIDOS, start=1)],
        })

    locales, mesa = [], 910001
    for ubigeo, dist, cap, lat, lon in distritos:
        locales.append({
            "codigo_local": f"MOCK-{ubigeo}", "ubigeo": ubigeo,
            "nombre": f"I.E. MOCK {cap}", "direccion": f"{cap} (MOCK)",
            "referencia": "seed_data.py", "latitud": lat, "longitud": lon,
            "mesas": [{"numero_mesa": f"{mesa + j:06d}",
                       "electores_habiles": 240, "pabellon": "A",
                       "piso": "1", "numero_orden": j + 1} for j in range(3)]})
        mesa += 3

    return {
        "jornada": {
            "fecha": "2026-10-04", "departamento": "AREQUIPA",
            "ubigeo_departamento": "040000", "generada_en": ahora,
            "fuentes": [{"organismo": "JNE", "bloque": "NOMINA",
                         "fecha_extraccion": ahora}],
        },
        "nomina": {"ambitos": ambitos},
        "distribucion": {"locales": locales},
    }


def publicar(base: str, token: str, payload: dict) -> dict:
    req = urllib.request.Request(
        base.rstrip("/") + "/api/ingesta/jornada", method="POST",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return {"status": r.status, "body": json.loads(r.read().decode())}
    except urllib.error.HTTPError as e:
        return {"status": e.code, "body": e.read().decode()[:500]}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", default=None)
    p.add_argument("--post", default=None)
    p.add_argument("--token", default=None)
    p.add_argument("--distritos", default=None,
                   help="ubigeos separados por coma (defecto: representativos)")
    args = p.parse_args()

    elegidos = None
    if args.distritos:
        elegidos = {u.strip() for u in args.distritos.split(",")}
    distritos = [d for d in DISTRITOS if not elegidos or d[0] in elegidos]
    if not distritos:
        print("ERROR: sin distritos", file=sys.stderr)
        return 2

    payload = documento(distritos)
    n_orgs = sum(len(a["organizaciones"]) for a in payload["nomina"]["ambitos"])
    n_mesas = sum(len(l["mesas"]) for l in payload["distribucion"]["locales"])
    print(f"mock provincia: {len(distritos)} distritos, "
          f"{len(payload['nomina']['ambitos'])} ambitos, {n_orgs} orgs, "
          f"{n_mesas} mesas")

    if args.out:
        ruta = Path(args.out)
        ruta.parent.mkdir(parents=True, exist_ok=True)
        ruta.write_text(json.dumps(payload, ensure_ascii=False, indent=2),
                        encoding="utf-8")
        print(f"JSON escrito en {ruta}")
    if args.post:
        if not args.token:
            print("ERROR: --post requiere --token", file=sys.stderr)
            return 2
        res = publicar(args.post, args.token, payload)
        print(f"POST -> {res['status']}: {res['body']}")
        return 0 if res["status"] == 200 else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
