"""Consolidado por nivel + reporte de fallos del crawl del JNE.

Recorre data/arequipa/{regional,provincial,distrital}/ y produce:

    data/arequipa/consolidado.json   — resumen ejecutivo por nivel
    data/arequipa/reporte_fallos.md  — reporte legible de lo que falló o faltó

Uso:
    python tools/consolidar.py
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parents[1] / "data" / "arequipa"
RAIZ = Path(__file__).resolve().parents[2]
NIVELES = ("regional", "provincial", "distrital")


def contar_cargo(nivel: str, cargo: str) -> str:
    if nivel == "regional":
        return cargo
    if cargo.startswith("ALCALDE"):
        return "ALCALDE"
    return cargo


def main() -> int:
    ubigeo = json.loads(
        (RAIZ / "frontend" / "public" / "data" / "ubigeo_arequipa.json")
        .read_text(encoding="utf-8")
    )
    esperados = {"regional": 1, "provincial": 0, "distrital": 0}
    for prov in ubigeo["provincias"]:
        esperados["provincial"] += 1
        esperados["distrital"] += len(prov["distritos"])

    resumen = {
        "generado_at": datetime.now(timezone.utc).isoformat(),
        "total_ambitos_esperados": sum(esperados.values()),
        "niveles": {},
        "fallos": [],
    }
    lineas_md = [
        "# Reporte del crawl JNE — Arequipa 2026",
        "",
        f"Generado: {resumen['generado_at']}",
        "",
    ]

    ok_total = 0
    candidatos_total = 0
    orgs_total = 0
    media_total = {"fotos": 0, "logos": 0, "fotos_fallidas": 0, "logos_fallidas": 0}

    for nivel in NIVELES:
        directorio = OUT_DIR / nivel
        archivos = sorted(directorio.glob("*.json")) if directorio.exists() else []
        encontrados = len(archivos)
        ok_total += encontrados
        faltantes = esperados[nivel] - encontrados

        orgs = 0
        candidatos = 0
        por_cargo: dict[str, int] = defaultdict(int)
        con_foto = 0
        sin_foto = 0
        con_logo = 0
        sin_logo = 0
        errores_archivo: list[str] = []
        detalle_fallos: list[dict] = []

        for archivo in archivos:
            try:
                d = json.loads(archivo.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                errores_archivo.append(f"{archivo.name}: JSON corrupto ({exc})")
                detalle_fallos.append(
                    {"ubigeo": archivo.stem, "error": f"JSON corrupto: {exc}"}
                )
                continue
            orgs_nivel = d.get("organizaciones") or []
            orgs += len(orgs_nivel)
            for org in orgs_nivel:
                if org.get("logo_local"):
                    con_logo += 1
                elif org.get("logo_url"):
                    sin_logo += 1
                for c in org.get("candidatos") or []:
                    candidatos += 1
                    por_cargo[contar_cargo(nivel, c.get("cargo") or "?")] += 1
                    if c.get("foto_local"):
                        con_foto += 1
                    elif c.get("foto_url"):
                        sin_foto += 1
                    if (c.get("estado") or "INSCRITO").upper() in ("EXCLUIDO", "RETIRADO", "RENUNCIA"):
                        pass  # se cuentan pero no se distinguen aquí

        resumen["niveles"][nivel] = {
            "esperados": esperados[nivel],
            "crawleados": encontrados,
            "faltantes": max(0, faltantes),
            "organizaciones": orgs,
            "candidatos": candidatos,
            "por_cargo": dict(sorted(por_cargo.items())),
            "fotos_descargadas": con_foto,
            "fotos_pendientes": sin_foto,
            "logos_descargados": con_logo,
            "logos_pendientes": sin_logo,
        }
        candidatos_total += candidatos
        orgs_total += orgs
        media_total["fotos"] += con_foto
        media_total["logos"] += con_logo
        media_total["fotos_fallidas"] += sin_foto
        media_total["logos_fallidas"] += sin_logo

        lineas_md += [
            f"## {nivel.upper()}",
            "",
            f"- Ámbitos: **{encontrados}/{esperados[nivel]}**"
            + (f" — faltan **{faltantes}**" if faltantes > 0 else " — completo"),
            f"- Organizaciones: {orgs}",
            f"- Candidatos: {candidatos} ({', '.join(f'{k}: {v}' for k, v in sorted(por_cargo.items())) or '—'})",
            f"- Fotos: {con_foto} descargadas, {sin_foto} pendientes",
            f"- Logos: {con_logo} descargados, {sin_logo} pendientes",
            "",
        ]

    # Fallos registrados por el crawler
    errores_log = OUT_DIR / "_errors.log"
    fallos_crawler = []
    if errores_log.exists():
        for linea in errores_log.read_text(encoding="utf-8").splitlines():
            if not linea.strip():
                continue
            partes = linea.split(" ", 3)
            if len(partes) >= 4:
                fallos_crawler.append(
                    {"timestamp": partes[0], "nivel": partes[1], "ubigeo": partes[2], "error": partes[3]}
                )

    # Ámbitos que el plan espera pero no tienen JSON
    crawlleados = set()
    for nivel in NIVELES:
        directorio = OUT_DIR / nivel
        if directorio.exists():
            crawlleados |= {f"{nivel}:{a.stem}" for a in directorio.glob("*.json")}

    todos = set()
    dep = ubigeo["ubigeo_departamento"]
    todos.add(f"regional:{dep}0000")
    for prov in ubigeo["provincias"]:
        todos.add(f"provincial:{prov['ubigeo']}")
        for distrito in prov["distritos"]:
            todos.add(f"distrital:{distrito['ubigeo']}")

    faltantes = sorted(todos - crawlleados)
    for clave in faltantes:
        nivel, ubg = clave.split(":", 1)
        resumen["fallos"].append({"nivel": nivel, "ubigeo": ubg, "error": "sin datos (no crawleado o falló)"})
        detalle_fallos.append({"nivel": nivel, "ubigeo": ubg, "error": "sin datos"})

    resumen["fallos_log"] = fallos_crawler[-50:]
    resumen["totales"] = {
        "ambitos_ok": ok_total,
        "ambitos_faltantes": len(faltantes),
        "organizaciones": orgs_total,
        "candidatos": candidatos_total,
        **media_total,
    }

    lineas_md += [
        "## FALLOS Y PENDIENTES",
        "",
    ]
    if resumen["fallos"]:
        lineas_md.append(f"**{len(resumen['fallos'])} ámbito(s) sin datos:**")
        lineas_md.append("")
        lineas_md.append("| Nivel | Ubigeo | Motivo |")
        lineas_md.append("|---|---|---|")
        for f in resumen["fallos"][:40]:
            lineas_md.append(f"| {f['nivel']} | {f['ubigeo']} | {f['error']} |")
        if len(resumen["fallos"]) > 40:
            lineas_md.append(f"| … | … | (+{len(resumen['fallos']) - 40} más en consolidado.json) |")
    else:
        lineas_md.append("Ninguno: los 118 ámbitos crawleados con éxito.")
    lineas_md.append("")

    if fallos_crawler:
        lineas_md += ["### Últimos errores del crawler", ""]
        for f in fallos_crawler[-15:]:
            lineas_md.append(f"- `{f['timestamp'][:19]}` {f['nivel']} {f['ubigeo']}: {f['error'][:110]}")
        lineas_md.append("")

    lineas_md += [
        "## TOTALES",
        "",
        f"- Ámbitos OK: **{ok_total}/{resumen['total_ambitos_esperados']}**",
        f"- Organizaciones: **{orgs_total}**",
        f"- Candidatos: **{candidatos_total}**",
        f"- Fotos: **{media_total['fotos']}** descargadas, {media_total['fotos_fallidas']} pendientes",
        f"- Logos: **{media_total['logos']}** descargados, {media_total['logos_fallidas']} pendientes",
        "",
    ]

    (OUT_DIR / "consolidado.json").write_text(
        json.dumps(resumen, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (OUT_DIR / "reporte_fallos.md").write_text("\n".join(lineas_md), encoding="utf-8")
    print(f"consolidado.json y reporte_fallos.md escritos en {OUT_DIR}")
    print(f"  ambitos OK: {ok_total}/{resumen['total_ambitos_esperados']}")
    print(f"  candidatos: {candidatos_total} en {orgs_total} organizaciones")
    print(f"  fotos: {media_total['fotos']} | logos: {media_total['logos']}")
    print(f"  faltantes: {len(faltantes)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
