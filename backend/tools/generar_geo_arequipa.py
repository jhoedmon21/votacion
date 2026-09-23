"""Genera ``frontend/public/data/geo/arequipa_geo.json``: capas vectoriales de
Arequipa (región, provincias y distritos) recortadas de los GeoJSON nacionales
de https://github.com/juaneladio/peru-geojson y simplificadas con
Douglas-Peucker para que el mapa coroplético del frontend cargue rápido.

Uso (desde ``backend/``):
    ./venv/Scripts/python.exe tools/generar_geo_arequipa.py

Si faltan los GeoJSON fuente se descargan solos a
``frontend/public/data/geo/`` (quedan fuera del repo por tamaño; el script los
vuelve a bajar cuando haga falta).
"""
from __future__ import annotations

import json
import math
import sys
import urllib.request
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
DIR_GEO = RAIZ / "frontend" / "public" / "data" / "geo"
DESTINO = DIR_GEO / "arequipa_geo.json"

FUENTES = {
    "distritos": (
        "peru_distrital_simple.geojson",
        "https://raw.githubusercontent.com/juaneladio/peru-geojson/master/peru_distrital_simple.geojson",
    ),
    "provincias": (
        "peru_provincial_simple.geojson",
        "https://raw.githubusercontent.com/juaneladio/peru-geojson/master/peru_provincial_simple.geojson",
    ),
    "region": (
        "peru_departamental_simple.geojson",
        "https://raw.githubusercontent.com/juaneladio/peru-geojson/master/peru_departamental_simple.geojson",
    ),
}

REGION = "AREQUIPA"
# Tolerancia de simplificación en grados (~0.001° ≈ 110 m).
EPS = {"distritos": 0.0012, "provincias": 0.0015, "region": 0.0020}


# ---------------------------------------------------------------- simplicación
def _dist_perp(p, a, b):
    ax, ay = a
    bx, by = b
    px, py = p
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def simplificar(puntos, eps):
    """Douglas-Peucker iterativo (la recursión larga revienta en Python)."""
    n = len(puntos)
    if n < 3:
        return list(puntos)
    conservar = [False] * n
    conservar[0] = conservar[-1] = True
    pila = [(0, n - 1)]
    while pila:
        i, j = pila.pop()
        if j <= i + 1:
            continue
        dmax, idx = 0.0, -1
        for k in range(i + 1, j):
            d = _dist_perp(puntos[k], puntos[i], puntos[j])
            if d > dmax:
                dmax, idx = d, k
        if dmax > eps:
            conservar[idx] = True
            pila.append((i, idx))
            pila.append((idx, j))
    return [p for p, k in zip(puntos, conservar) if k]


def _area_anillo(puntos):
    """Área con fórmula delShoelace (para descartar islotes minúsculos)."""
    s = 0.0
    n = len(puntos)
    for i in range(n):
        x1, y1 = puntos[i]
        x2, y2 = puntos[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    return abs(s) / 2


def simplificar_poligono(anillos, eps):
    anillos_out = []
    for idx, anillo in enumerate(anillos):
        r = simplificar([(round(x, 5), round(y, 5)) for x, y in anillo], eps)
        if len(r) < 4:
            continue
        # El anillo exterior debe sobrevivir; los huecos se descartan si quedan
        # diminutos tras simplificar.
        if idx > 0 and _area_anillo(r) < 2e-6:
            continue
        anillos_out.append(r)
    return anillos_out


def simplificar_geometry(geom, eps):
    tipo = geom["type"]
    if tipo == "Polygon":
        out = simplificar_poligono(geom["coordinates"], eps)
        return {"type": "Polygon", "coordinates": out} if out else None
    if tipo == "MultiPolygon":
        out = []
        for pol in geom["coordinates"]:
            p = simplificar_poligono(pol, eps)
            if p:
                out.append(p)
        return {"type": "MultiPolygon", "coordinates": out} if out else None
    raise ValueError(f"Geometría no soportada: {tipo}")


# ------------------------------------------------------------------- pipeline
def _cargar(nivel):
    archivo, url = FUENTES[nivel]
    ruta = DIR_GEO / archivo
    if not ruta.exists():
        print(f"  descargando {archivo}…")
        DIR_GEO.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(url, ruta)
    with ruta.open(encoding="utf-8") as fh:
        return json.load(fh)


def _nombre_dept(props):
    for k in ("NOMBDEP", "DEPARTAMEN", "NOMB_DEP", "FIRST_NOMB"):
        v = props.get(k)
        if v:
            return str(v).upper().strip()
    return ""


def main():
    salida = {}
    resumen = []
    for nivel in ("region", "provincias", "distritos"):
        data = _cargar(nivel)
        eps = EPS[nivel]
        feats = []
        for f in data["features"]:
            props = f.get("properties") or {}
            if _nombre_dept(props) != REGION:
                continue
            geom = simplificar_geometry(f["geometry"], eps)
            if geom is None:
                continue
            if nivel == "distritos":
                feats.append({
                    "u": str(props.get("IDDIST", "")).zfill(6),
                    "n": props.get("NOMBDIST", ""),
                    "pv": str(props.get("IDPROV", "")).zfill(6)[:4],
                    "pvn": props.get("NOMBPROV", ""),
                    "geo": geom,
                })
            elif nivel == "provincias":
                # FIRST_IDPR ya es ``dep+prov`` (p.ej. 0401); el ubigeo
                # provincial del sistema es ese + 00.
                feats.append({
                    "u": (str(props.get("FIRST_IDPR", "")).zfill(4) + "00")[:6],
                    "n": props.get("NOMBPROV", ""),
                    "geo": geom,
                })
            else:
                feats.append({
                    "u": str(props.get("IDDPTO", "")).zfill(2),
                    "n": props.get("NOMBDEP", REGION),
                    "geo": geom,
                })
        # En provincias/region la colección nacional trae una feature por
        # unidad; en el departamental AREQUIPA es una sola.
        if nivel == "region":
            salida["region"] = feats[0] if feats else None
            resumen.append(f"region: {len(feats)} geometría(s)")
        else:
            salida[nivel] = feats
            resumen.append(f"{nivel}: {len(feats)}")

    DESTINO.write_text(
        json.dumps(salida, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    kb = DESTINO.stat().st_size / 1024
    print(f"OK {DESTINO.relative_to(RAIZ)} ({kb:.0f} KB) -> {', '.join(resumen)}")
    # Amarras: los ubigeos deben casar con el catálogo INEI del sistema.
    dists = {d["u"] for d in salida["distritos"]}
    cat = RAIZ / "frontend" / "public" / "data" / "ubigeo_arequipa.json"
    if cat.exists():
        catalogo = json.loads(cat.read_text(encoding="utf-8"))
        cats = {
            str(d.get("ubigeo", "")).zfill(6)
            for p in catalogo.get("provincias", [])
            for d in p.get("distritos", [])
        }
        solo_geo = sorted(dists - cats)
        solo_cat = sorted(cats - dists)
        print(f"  cruce con catálogo: geo={len(dists)} catálogo={len(cats)}")
        if solo_geo:
            print(f"  sólo en geo: {solo_geo}")
        if solo_cat:
            print(f"  sólo en catálogo: {solo_cat[:20]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
