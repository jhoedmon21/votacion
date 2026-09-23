"""Compara dos corridas del crawler del JNE, ámbito por ámbito.

Sirve para verificar que una versión nueva del crawler reproduce lo ya
extraído. Compara el contenido significativo —organizaciones, candidatos,
DNIs, cargos, estados y posiciones— y deja fuera lo que cambia en cada corrida
por diseño: la marca de tiempo y los nombres de archivo de los medios locales
(cuando una corrida no usa `--media`, esos campos van vacíos).

Uso:
    python tools/comparar_crawl.py                         # archivo vs corrida nueva
    python tools/comparar_crawl.py --a data/arequipa --b data/arequipa_http
    python tools/comparar_crawl.py --detalle 20            # más ámbitos en detalle

Devuelve 0 si el contenido coincide y 1 si hay diferencias.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ))

# Una sola definición de «qué cambió» para las dos herramientas: el verificador
# del crawler (`--verificar`) y este comparador.
import cambios  # noqa: E402

IGNORAR = {"crawled_at", "foto_local", "logo_local"}


def normalizar(datos: dict) -> dict:
    """Deja sólo el contenido comparable de un ámbito."""
    organizaciones = []
    for org in datos.get("organizaciones") or []:
        candidatos = sorted(
            tuple(
                candidato.get(campo)
                for campo in (
                    "dni", "cargo", "cargo_jne", "nombre_completo", "nombres",
                    "apellidoPaterno", "apellidoMaterno", "posicion",
                    "numero_posicion", "estado", "tipo_eleccion",
                )
            )
            for candidato in org.get("candidatos") or []
        )
        organizaciones.append({
            "organizacionPolitica": org.get("organizacionPolitica"),
            "idOrganizacionPolitica": org.get("idOrganizacionPolitica"),
            "logo_url": org.get("logo_url"),
            "codigoExpediente": org.get("codigoExpediente"),
            "candidatos": candidatos,
        })
    organizaciones.sort(key=lambda o: (o["organizacionPolitica"] or ""))
    return {
        campo: valor
        for campo, valor in datos.items()
        if campo not in IGNORAR and campo != "organizaciones"
    } | {"organizaciones": organizaciones}


def leer_dir(base: Path) -> dict[str, dict]:
    """Todos los ámbitos de un directorio, indexados por `nivel:ubigeo`."""
    ambitos: dict[str, dict] = {}
    for nivel in ("regional", "provincial", "distrital"):
        carpeta = base / nivel
        if not carpeta.exists():
            continue
        for archivo in sorted(carpeta.glob("*.json")):
            try:
                datos = json.loads(archivo.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                print(f"  [warn] {archivo} ilegible: {exc}")
                continue
            ambitos[f"{datos.get('nivel') or nivel}:{datos.get('ubigeo') or archivo.stem}"] = datos
    return ambitos


def resumir(datos: dict) -> str:
    organizaciones = datos.get("organizaciones") or []
    candidatos = sum(len(o.get("candidatos") or []) for o in organizaciones)
    return f"{len(organizaciones):3} orgs / {candidatos:4} candidatos"


def detallar(anterior: dict, nuevo: dict) -> list[str]:
    """Cambios legibles entre dos ámbitos, con las categorías del verificador.

    Recibe los ámbitos **crudos**: el emparejamiento necesita DNI, nombre y
    posición, que la normalización estructural convierte en tuplas.
    """
    return [f"        {cambio}" for cambio in cambios.comparar_ambito(anterior, nuevo)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--a", type=Path, default=RAIZ / "data" / "arequipa",
                        help="corrida de referencia")
    parser.add_argument("--b", type=Path, default=RAIZ / "data" / "arequipa_http",
                        help="corrida nueva a validar")
    parser.add_argument("--detalle", type=int, default=10,
                        help="cuántos ámbitos con diferencias mostrar en detalle")
    args = parser.parse_args(argv)

    if not args.a.exists() or not args.b.exists():
        print(f"[error] falta {args.a if not args.a.exists() else args.b}")
        return 2

    datos_a, datos_b = leer_dir(args.a), leer_dir(args.b)
    print(f"A (referencia) {args.a}: {len(datos_a)} ámbitos")
    print(f"B (nueva)      {args.b}: {len(datos_b)} ámbitos")

    solo_a = sorted(set(datos_a) - set(datos_b))
    solo_b = sorted(set(datos_b) - set(datos_a))
    comunes = sorted(set(datos_a) & set(datos_b))

    for clave in solo_a:
        print(f"  [sólo en A] {clave}  {resumir(datos_a[clave])}")
    for clave in solo_b:
        print(f"  [sólo en B] {clave}  {resumir(datos_b[clave])}")

    distintos: list[str] = []
    for clave in comunes:
        # La igualdad se juzga sobre el contenido normalizado (ignora timestamps
        # y rutas de medios locales); el detalle se explica con `cambios`.
        if normalizar(datos_a[clave]) != normalizar(datos_b[clave]):
            distintos.append(clave)

    orgs_a = sum(len(d.get("organizaciones") or []) for d in datos_a.values())
    orgs_b = sum(len(d.get("organizaciones") or []) for d in datos_b.values())
    cand_a = sum(
        len(o.get("candidatos") or []) for d in datos_a.values() for o in d.get("organizaciones") or []
    )
    cand_b = sum(
        len(o.get("candidatos") or []) for d in datos_b.values() for o in d.get("organizaciones") or []
    )

    print()
    print(f"  ámbitos    A={len(datos_a):4}  B={len(datos_b):4}  comunes={len(comunes):4}")
    print(f"  orgs       A={orgs_a:4}  B={orgs_b:4}")
    print(f"  candidatos A={cand_a:5}  B={cand_b:5}")

    if distintos:
        print(f"\n  {len(distintos)} ámbito(s) con diferencias de contenido:")
        for clave in distintos[: args.detalle]:
            print(f"    {clave}  A: {resumir(datos_a[clave])}  |  B: {resumir(datos_b[clave])}")
            for linea in detallar(datos_a[clave], datos_b[clave]):
                print(linea)
        if len(distintos) > args.detalle:
            print(f"    ... y {len(distintos) - args.detalle} más")

    if not (solo_a or solo_b or distintos):
        print("\n  IDÉNTICOS: B reproduce el contenido de A en los 110 ámbitos.")
        return 0

    print(
        f"\n  DIFERENCIAS: {len(solo_a)} sólo en A, {len(solo_b)} sólo en B, "
        f"{len(distintos)} con contenido distinto."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
