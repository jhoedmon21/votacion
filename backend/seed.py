"""Seed de mocks — Sistema de Registro, OCR y Cómputo Electoral (ONPE).

Genera datos mock estructurados en JSON (ubigeos, mesas y partidos) con el
contrato ``docs/schemas/ingesta-jornada-v1.schema.json`` y los publica con
``POST /api/ingesta/jornada``.

Los mocks usan mesas 900001+ para no colisionar con el padrón real y van
marcados ("MOCK"): sirven para humo/E2E, demos y capacitación de digitadores.

Uso:
    python seed.py --out mocks/arequipa_mock.json
    python seed.py --post http://localhost:8000 --token <JWT/Bearer>
    python seed.py --post http://localhost:8000 --token <t> --out mocks/x.json
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

PARTIDOS = [
    ("AREQUIPA, TRADICION Y FUTURO", "ATF", "MOVIMIENTO_REGIONAL", "#DC2626"),
    ("AREQUIPA AVANCEMOS", "AVANCEMOS", "MOVIMIENTO_REGIONAL", "#0056B3"),
    ("FUERZA AREQUIPEÑA", "FA", "MOVIMIENTO_REGIONAL", "#CA8A04"),
    ("YO AREQUIPA", "YO", "MOVIMIENTO_REGIONAL", "#0E7490"),
    ("SOMOS PERU", "SP", "PARTIDO_NACIONAL", "#0033A0"),
    ("FUERZA POPULAR", "FP", "PARTIDO_NACIONAL", "#F26522"),
]

DISTRITOS = [
    # (ubigeo, ubigeo_reniec, provincia, distrito, capital, lat, lon)
    ("040112", "040109", "AREQUIPA", "PAUCARPATA", "Paucarpata", -16.432778, -71.504722),
    ("040701", "040701", "ISLAY", "MOLLENDO", "Mollendo", -17.023611, -72.016389),
]

NOMBRES = [
    ("JUAN", "PEREZ QUISPE"), ("MARIA", "FLORES MAMANI"),
    ("LUIS", "CONDORI APAZA"), ("ANA", "TORRES VALDIVIA"),
    ("PEDRO", "RAMOS CCAMA"), ("ROSA", "CHAMBI HUARCA"),
]


def candidato(numero: int, cargo: str, semilla: int) -> dict:
    nom, ape = NOMBRES[(semilla + numero) % len(NOMBRES)]
    dni = f"{90000000 + semilla * 10 + numero:08d}"
    return {
        "numero": numero, "dni": dni, "nombres": nom, "apellidos": ape,
        "nombre_completo": f"{nom} {ape}", "cargo": cargo,
        "estado": "INSCRITO",
    }


def ambito(tipo: str, ubigeo: str, provincia: str, distrito: str | None,
           cargos: tuple[str, str]) -> dict:
    orgs = []
    for i, (nombre, corto, tipo_org, color) in enumerate(PARTIDOS, start=1):
        orgs.append({
            "numero": i, "organizacionPolitica": nombre, "nombreCorto": corto,
            "idOrganizacionPolitica": 900 + i, "tipo": tipo_org,
            "logo_url": None, "color_hex": color,
            "candidatos": [candidato(1, cargos[0], i),
                           candidato(2, cargos[1], i + 100)],
        })
    return {"tipo_eleccion": tipo, "ubigeo": ubigeo, "provincia": provincia,
            "distrito": distrito, "organizaciones": orgs}


def documento() -> dict:
    ahora = datetime.now(timezone.utc).isoformat()
    nomina = [
        ambito("REGIONAL", "040000", None, None,
               ("GOBERNADOR", "CONSEJERO_REGIONAL")),
        ambito("PROVINCIAL", "040100", "AREQUIPA", None,
               ("ALCALDE_PROVINCIAL", "REGIDOR_PROVINCIAL")),
        ambito("PROVINCIAL", "040700", "ISLAY", None,
               ("ALCALDE_PROVINCIAL", "REGIDOR_PROVINCIAL")),
    ]
    for ubigeo, _reniec, prov, dist, _cap, _lat, _lon in DISTRITOS:
        nomina.append(ambito("DISTRITAL", ubigeo, prov, dist,
                             ("ALCALDE_DISTRITAL", "REGIDOR_DISTRITAL")))

    locales, mesa = [], 900001
    for ubigeo, _reniec, _prov, dist, cap, lat, lon in DISTRITOS:
        mesas = [{"numero_mesa": f"{mesa + j:06d}",
                  "electores_habiles": 250,
                  "pabellon": "A", "piso": "1", "numero_orden": j + 1}
                 for j in range(2)]
        mesa += 2
        locales.append({
            "codigo_local": f"MOCK-{ubigeo}", "ubigeo": ubigeo,
            "nombre": f"I.E. MOCK {cap}", "direccion": f"{cap}, {dist} (MOCK)",
            "referencia": "seed de demostración", "latitud": lat,
            "longitud": lon, "mesas": mesas})

    return {
        "jornada": {
            "fecha": "2026-10-04", "departamento": "AREQUIPA",
            "ubigeo_departamento": "040000", "generada_en": ahora,
            "fuentes": [{"organismo": "JNE", "bloque": "NOMINA",
                         "fecha_extraccion": ahora},
                        {"organismo": "ONPE", "bloque": "DISTRIBUCION",
                         "fecha_extraccion": ahora}],
        },
        "nomina": {"ambitos": nomina},
        "distribucion": {"locales": locales},
    }


def publicar(base: str, token: str, payload: dict) -> dict:
    # El documento viaja tal cual lo describe ingesta-jornada-v1.schema.json
    # (nomina.ambitos[], distribucion.locales[]).
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
    p.add_argument("--out", default=None, help="ruta del JSON mock")
    p.add_argument("--post", default=None, help="base URL del backend")
    p.add_argument("--token", default=None, help="token Bearer (SUPER_ADMIN)")
    args = p.parse_args()

    payload = documento()
    n_orgs = sum(len(a["organizaciones"]) for a in payload["nomina"]["ambitos"])
    n_mesas = sum(len(l["mesas"]) for l in payload["distribucion"]["locales"])
    print(f"mock: {len(payload['nomina']['ambitos'])} ambitos, "
          f"{n_orgs} organizaciones, "
          f"{len(payload['distribucion']['locales'])} locales, {n_mesas} mesas")

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
        print(f"POST /api/ingesta/jornada -> {res['status']}: {res['body']}")
        return 0 if res["status"] == 200 else 1
    if not args.out and not args.post:
        print(json.dumps(payload, ensure_ascii=False, indent=2)[:600] + "\n…")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
