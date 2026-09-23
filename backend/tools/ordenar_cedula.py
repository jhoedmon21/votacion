#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Ordena la oferta electoral de los JSON según la cédula de sufragio.

El JNE entrega las organizaciones en orden alfabético, pero la cédula las
ordena según el **sorteo de la ONPE del 10-jun-2026** (bloque nacional arriba,
movimientos regionales abajo). Y en este sistema el índice del arreglo
``organizaciones`` **es** la posición de la organización en la columna del acta:
``load_jne_data`` la copia tal cual a ``sort_order`` y la PWA manda los votos
identificados por nombre, así que un array desordenado hace que el acta digital
no coincida con el acta de papel que el digitador tiene delante.

Este script reordena los arrays in situ (idempotente: si ya están en orden, no
reescribe el archivo) y reporta las organizaciones que no figuran en ninguno de
los dos sorteos para que se agreguen al catálogo en ``app/core/orden_cedula.py``.

Uso
---
    python backend/tools/ordenar_cedula.py              # reordena todo
    python backend/tools/ordenar_cedula.py --dry-run    # sólo informa
    python backend/tools/ordenar_cedula.py --path frontend/public/data/candidatos

Después de re-crawlear hay que volver a ejecutarlo: el crawler escribe los JSON
en el orden en que responde el JNE.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.orden_cedula import (  # noqa: E402  (requiere el sys.path de arriba)
    BLOQUE_DESCONOCIDO,
    clave_orden,
    esta_ordenada,
    ordenar_organizaciones,
)

RAIZ = Path(__file__).resolve().parents[2]

# Árboles con oferta electoral. ``candidatos_arequipa.json`` es el mock de
# referencia que consume ``js/electoral_logic.js``; se ordena igual para que no
# contradiga al dataset real.
RUTAS_POR_DEFECTO = (
    RAIZ / "jne-scraper" / "data" / "arequipa",
    RAIZ / "jne-scraper" / "data" / "arequipa_http",
    RAIZ / "frontend" / "public" / "data" / "candidatos",
    RAIZ / "candidatos_arequipa.json",
)

CAMPO = "organizacionPolitica"


class Informe:
    """Cuenta lo que hizo la corrida, para imprimir un resumen legible."""

    def __init__(self) -> None:
        self.archivos = 0
        self.reordenados = 0
        self.sin_cambios = 0
        self.organizaciones = 0
        self.desconocidas: dict[str, int] = {}
        self.movidos: list[tuple[Path, list[str], list[str]]] = []

    def resumen(self, dry_run: bool) -> str:
        modo = "SIMULACIÓN (nada escrito)" if dry_run else "aplicado"
        lineas = [
            f"Orden de cédula {modo}:",
            f"  archivos leídos        : {self.archivos}",
            f"  archivos reordenados   : {self.reordenados}",
            f"  ya estaban en orden    : {self.sin_cambios}",
            f"  organizaciones vistas  : {self.organizaciones}",
        ]
        if self.desconocidas:
            lineas.append(
                f"  SIN SORTEO CONOCIDO    : {len(self.desconocidas)} "
                "(quedan al final, en orden alfabético)"
            )
            for nombre, veces in sorted(self.desconocidas.items()):
                lineas.append(f"      - {nombre} ({veces} ámbitos)")
        return "\n".join(lineas)


def _ordenar_lista(data: dict, informe: Informe) -> tuple[list[str], list[str]] | None:
    """Ordena ``data['organizaciones']`` si existe.

    Devuelve el antes/después cuando hubo que mover algo, y ``None`` cuando la
    lista ya venía en orden (o no hay lista que ordenar).
    """
    organizaciones = data.get("organizaciones")
    if not isinstance(organizaciones, list) or not organizaciones:
        return None

    for org in organizaciones:
        nombre = (org or {}).get(CAMPO) or ""
        informe.organizaciones += 1
        if not nombre:
            continue
        if clave_orden(nombre)[0] == BLOQUE_DESCONOCIDO:
            informe.desconocidas[nombre] = informe.desconocidas.get(nombre, 0) + 1

    if esta_ordenada(organizaciones, CAMPO):
        return None

    antes = [(o or {}).get(CAMPO) for o in organizaciones]
    ordenar_organizaciones(organizaciones, CAMPO)
    return antes, [(o or {}).get(CAMPO) for o in organizaciones]


def _procesar_json(path: Path, dry_run: bool, informe: Informe) -> None:
    """Reordena un JSON de ámbito (o de ámbitos anidados) conservando formato."""
    # Se lee en bytes y se decodifica a mano: ``Path.read_text`` traduce los
    # saltos de línea y estos JSON del crawler vienen con CRLF, que hay que
    # conservar para no llenar el diff de ruido.
    texto = path.read_bytes().decode("utf-8")
    data = json.loads(texto)
    informe.archivos += 1

    if not isinstance(data, dict):
        informe.sin_cambios += 1
        return

    # Un archivo puede traer un ámbito suelto (``organizaciones``) o varios
    # (``candidatos_arequipa.json`` anida la oferta bajo ``ambitos``).
    listas = [data]
    if isinstance(data.get("ambitos"), list):
        listas += [a for a in data["ambitos"] if isinstance(a, dict)]

    cambios = [r for r in (_ordenar_lista(capa, informe) for capa in listas) if r]
    if not cambios:
        informe.sin_cambios += 1
        return

    informe.reordenados += 1
    informe.movidos += [(path, antes, despues) for antes, despues in cambios]
    if dry_run:
        return

    salto = "\r\n" if "\r\n" in texto else "\n"
    cuerpo = json.dumps(data, indent=2, ensure_ascii=False)
    if salto != "\n":
        cuerpo = cuerpo.replace("\n", salto)
    if texto.endswith(("\n", "\r")):
        cuerpo += salto
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(cuerpo)


def archivos_de(ruta: Path) -> list[Path]:
    if ruta.is_file():
        return [ruta]
    if ruta.is_dir():
        return sorted(ruta.rglob("*.json"))
    return []


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Ordena las organizaciones de los JSON según la cédula de sufragio 2026."
    )
    parser.add_argument(
        "--path", action="append", type=Path, default=[],
        help="archivo o carpeta a procesar (repetible). Por defecto, todos los árboles.",
    )
    parser.add_argument("--dry-run", action="store_true",
                        help="informa sin escribir ningún archivo.")
    parser.add_argument("--detalle", action="store_true",
                        help="imprime el antes/después de cada ámbito reordenado.")
    args = parser.parse_args(argv)

    rutas = args.path or list(RUTAS_POR_DEFECTO)
    informe = Informe()
    for ruta in rutas:
        ruta = ruta if ruta.is_absolute() else (RAIZ / ruta)
        if not ruta.exists():
            print(f"  (omitido: no existe {ruta})")
            continue
        for archivo in archivos_de(ruta):
            _procesar_json(archivo, args.dry_run, informe)

    if args.detalle and informe.movidos:
        print("Ámbitos reordenados:")
        for path, antes, despues in informe.movidos:
            print(f"  {path.relative_to(RAIZ)}")
            for viejo, nuevo in zip(antes, despues):
                if viejo != nuevo:
                    print(f"      {viejo}  ->  {nuevo}")

    print(informe.resumen(args.dry_run))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
