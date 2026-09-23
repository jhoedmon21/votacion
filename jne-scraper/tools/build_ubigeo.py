"""Genera la base de ubigeo oficial de la Región Arequipa.

Descarga el dataset INEI/RENIEC de departamentos, provincias y distritos del Perú
(jmcastagnetto/ubigeo-peru-aumentado, que normaliza ambos códigos y agrega
latitud/longitud/altitud) y produce dos artefactos para el proyecto:

  1. frontend/public/data/ubigeo_arequipa.json  -> lo consume el formulario móvil
  2. backend/sql/seed_ubigeo_arequipa.sql       -> seed idempotente para PostgreSQL

Arequipa = departamento INEI 04, con 8 provincias y 109 distritos. El código
ubigeo de 6 dígitos se descompone como DEP(2) + PROV(2) + DIST(2).

IMPORTANTE — INEI != RENIEC: en Arequipa 85 de los 109 distritos tienen códigos
distintos entre ambas codificaciones (p. ej. Paucarpata = 040112 INEI pero
040109 RENIEC). La API de Voto Informado del JNE trabaja con la codificación
RENIEC, así que el bloque `jne` de cada distrito se calcula desde el código
RENIEC (con el INEI como respaldo si faltara).

Uso:
    python tools/build_ubigeo.py            # usa la caché local si existe
    python tools/build_ubigeo.py --refresh  # vuelve a descargar el dataset
"""
import argparse
import csv
import io
import json
import sys
import urllib.request
from pathlib import Path

CSV_URL = (
    "https://raw.githubusercontent.com/jmcastagnetto/ubigeo-peru-aumentado/"
    "master/ubigeo_distrito.csv"
)
DEPARTAMENTO = "AREQUIPA"
# Ubigeo INEI del departamento de Arequipa
UBIGEO_DEPARTAMENTO = "04"

ROOT = Path(__file__).resolve().parents[2]
CACHE_CSV = Path(__file__).resolve().parents[1] / "data" / "ubigeo_peru.csv"
OUT_JSON = ROOT / "frontend" / "public" / "data" / "ubigeo_arequipa.json"
OUT_SQL = ROOT / "backend" / "sql" / "seed_ubigeo_arequipa.sql"

PROVINCIAS_ESPERADAS = 8
DISTRITOS_ESPERADOS = 109


def _to_float(value: str) -> float | None:
    try:
        return round(float(value), 6)
    except (TypeError, ValueError):
        return None


def _to_int(value: str) -> int | None:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def _sql_str(value: str | None) -> str:
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def descargar_dataset(refresh: bool) -> str:
    """Devuelve el CSV como texto, usando la caché local salvo --refresh."""
    if CACHE_CSV.exists() and not refresh:
        print(f"[cache] usando {CACHE_CSV.relative_to(ROOT)}")
        return CACHE_CSV.read_text(encoding="utf-8-sig")

    print(f"[net] descargando {CSV_URL}")
    with urllib.request.urlopen(CSV_URL, timeout=60) as resp:
        raw = resp.read().decode("utf-8-sig")
    CACHE_CSV.parent.mkdir(parents=True, exist_ok=True)
    CACHE_CSV.write_text(raw, encoding="utf-8")
    print(f"[net] guardado en {CACHE_CSV.relative_to(ROOT)}")
    return raw


def build(refresh: bool = False) -> dict:
    filas = [
        fila
        for fila in csv.DictReader(io.StringIO(descargar_dataset(refresh)))
        if (fila.get("departamento") or "").strip().upper() == DEPARTAMENTO
    ]
    if not filas:
        raise SystemExit("El dataset no contiene filas para Arequipa")

    provincias: dict[str, dict] = {}
    for fila in filas:
        ubigeo = (fila.get("inei") or "").strip().zfill(6)
        ubigeo_reniec = (fila.get("reniec") or "").strip().zfill(6)
        # El JNE usa la codificación RENIEC; si no existiera, cae al código INEI.
        electoral = ubigeo_reniec if ubigeo_reniec.strip("0") else ubigeo
        prov_code, dist_code = ubigeo[2:4], ubigeo[4:6]
        jne_pro, jne_dis = electoral[2:4], electoral[4:6]
        provincia = (fila.get("provincia") or "").strip().title()

        prov = provincias.setdefault(
            prov_code,
            {
                "codigo": prov_code,
                "ubigeo": f"{UBIGEO_DEPARTAMENTO}{prov_code}00",
                "nombre": provincia,
                "distritos": [],
            },
        )
        prov["distritos"].append(
            {
                "codigo": dist_code,
                "ubigeo": ubigeo,
                "ubigeo_reniec": ubigeo_reniec,
                "nombre": (fila.get("distrito") or "").strip().title(),
                "capital": (fila.get("capital") or "").strip() or None,
                "latitude": _to_float(fila.get("latitude")),
                "longitude": _to_float(fila.get("longitude")),
                "altitude": _to_int(fila.get("altitude")),
                "superficie_km2": _to_float(fila.get("superficie")),
                "densidad_pob_2020": _to_float(fila.get("pob_densidad_2020")),
                # Partes que consume la API del JNE (dep/pro/dis de 2 dígitos, codificación RENIEC)
                "jne": {"dep": UBIGEO_DEPARTAMENTO, "pro": jne_pro, "dis": jne_dis},
            }
        )

    for prov in provincias.values():
        prov["distritos"].sort(key=lambda d: d["codigo"])
        # Código de provincia en codificación RENIEC (el que usa el JNE)
        codigos = [d["jne"]["pro"] for d in prov["distritos"]]
        prov["jne_pro"] = max(set(codigos), key=codigos.count)

    ordenadas = [provincias[k] for k in sorted(provincias)]
    dataset = {
        "departamento": DEPARTAMENTO.title(),
        "ubigeo_departamento": UBIGEO_DEPARTAMENTO,
        "nota_codificacion": (
            "ubigeo=INEI, ubigeo_reniec=RENIEC; jne.dep/pro/dis usan la codificación "
            "RENIEC que espera la API de Voto Informado del JNE"
        ),
        "total_provincias": len(ordenadas),
        "total_distritos": sum(len(p["distritos"]) for p in ordenadas),
        "provincias": ordenadas,
    }
    return dataset


def escribir_json(dataset: dict) -> None:
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps(dataset, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[out] {OUT_JSON.relative_to(ROOT)}")


def escribir_sql(dataset: dict) -> None:
    lineas = [
        "-- Ubigeo oficial de la Región Arequipa (INEI/RENIEC) — generado por tools/build_ubigeo.py",
        "-- Uso: psql -d computo_arequipa -f backend/sql/seed_ubigeo_arequipa.sql",
        "",
        "BEGIN;",
        "",
        "INSERT INTO ubigeo (ubigeo, ubigeo_reniec, departamento, provincia, distrito, nivel,",
        "                    capital, latitud, longitud, altitud, densidad_poblacional)",
        "VALUES",
    ]
    valores = [
        "    ({}, {}, {}, {}, {}, 'DISTRITO', {}, {}, {}, {}, {})".format(
            _sql_str(d["ubigeo"]),
            _sql_str(d["ubigeo_reniec"]),
            _sql_str("AREQUIPA"),
            _sql_str(p["nombre"].upper()),
            _sql_str(d["nombre"].upper()),
            _sql_str(d["capital"]),
            d["latitude"] if d["latitude"] is not None else "NULL",
            d["longitude"] if d["longitude"] is not None else "NULL",
            d["altitude"] if d["altitude"] is not None else "NULL",
            d["densidad_pob_2020"] if d["densidad_pob_2020"] is not None else "NULL",
        )
        for p in dataset["provincias"]
        for d in p["distritos"]
    ]
    lineas.append(",\n".join(valores) + "")
    lineas += [
        "ON CONFLICT (ubigeo) DO UPDATE SET",
        "    ubigeo_reniec = EXCLUDED.ubigeo_reniec,",
        "    provincia     = EXCLUDED.provincia,",
        "    distrito      = EXCLUDED.distrito,",
        "    capital       = EXCLUDED.capital,",
        "    latitud       = EXCLUDED.latitud,",
        "    longitud      = EXCLUDED.longitud,",
        "    altitud       = EXCLUDED.altitud,",
        "    densidad_poblacional = EXCLUDED.densidad_poblacional;",
        "",
        "-- Provincias (nivel intermedio, útil para asignar COORD_PROVINCIAL)",
        "INSERT INTO ubigeo (ubigeo, departamento, provincia, distrito, nivel)",
        "VALUES",
    ]
    # Ojo: a nivel PROVINCIA el CHECK ubigeo_coherencia_nivel exige distrito NULL
    provs = [
        "    ({}, {}, {}, NULL, 'PROVINCIA')".format(
            _sql_str(p["ubigeo"]), _sql_str("AREQUIPA"), _sql_str(p["nombre"].upper())
        )
        for p in dataset["provincias"]
    ]
    lineas.append(",\n".join(provs) + "")
    lineas += [
        "ON CONFLICT (ubigeo) DO UPDATE SET provincia = EXCLUDED.provincia;",
        "",
        "-- El ámbito REGIONAL es el departamento entero (040000). El crawler y el",
        "-- importador lo usan; sin esta fila el JNE regional no se puede cargar.",
        "INSERT INTO ubigeo (ubigeo, departamento, nivel) VALUES ('040000', 'AREQUIPA', 'DEPARTAMENTO')",
        "ON CONFLICT (ubigeo) DO NOTHING;",
        "",
        "COMMIT;",
        "",
    ]
    OUT_SQL.parent.mkdir(parents=True, exist_ok=True)
    OUT_SQL.write_text("\n".join(lineas), encoding="utf-8")
    print(f"[out] {OUT_SQL.relative_to(ROOT)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Genera el ubigeo de Arequipa")
    parser.add_argument("--refresh", action="store_true", help="fuerza la descarga del dataset")
    args = parser.parse_args()

    dataset = build(refresh=args.refresh)
    escribir_json(dataset)
    escribir_sql(dataset)

    print(
        f"[ok] {dataset['total_provincias']} provincias / "
        f"{dataset['total_distritos']} distritos de {dataset['departamento']}"
    )
    for prov in dataset["provincias"]:
        print(f"     {prov['ubigeo']}  {prov['nombre']:<12} {len(prov['distritos']):>3} distritos")

    if dataset["total_provincias"] != PROVINCIAS_ESPERADAS:
        print(
            f"[warn] se esperaban {PROVINCIAS_ESPERADAS} provincias y llegaron "
            f"{dataset['total_provincias']}",
            file=sys.stderr,
        )
    if dataset["total_distritos"] != DISTRITOS_ESPERADOS:
        print(
            f"[warn] se esperaban {DISTRITOS_ESPERADOS} distritos y llegaron "
            f"{dataset['total_distritos']}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
