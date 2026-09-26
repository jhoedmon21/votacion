"""Sonda: ¿la API del JNE devuelve consejeros por provincia?

Consulta /organizaciones con dep=04 y pro=<código provincial> para el bloque
REGIONAL. La hipótesis: el consejero regional se elige POR PROVINCIA, así que
el portal filtra la oferta regional por el código de provincia (el crawl
actual siempre envía pro="00" y por eso sólo trae Arequipa).
"""
import asyncio
import sys

import httpx

BASE = "https://votoinformado.jne.gob.pe"
API_ORG = f"{BASE}/api/v1/candidatos/organizaciones"

PROVINCIAS = {
    "01": "AREQUIPA",
    "02": "CAMANA",
    "03": "CARAVELI",
    "04": "CASTILLA",
    "05": "CAYLLOMA",
    "06": "CONDESUYOS",
    "07": "ISLAY",
    "08": "LA UNION",
}


async def sondear(pro: str, nombre: str) -> dict:
    async with httpx.AsyncClient(
        timeout=30,
        headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
        },
    ) as http:
        r = await http.post(API_ORG, json={"dep": "04", "pro": pro, "dis": "00"})
        data = r.json()
        bloques = data.get("data") or []
        regional = next(
            (b for b in bloques if "REGIONAL" in (b.get("tipoEleccion") or "").upper()),
            None,
        )
        tipos = [(b.get("tipoEleccion") or "?") for b in bloques]
        if regional is None:
            return {"provincia": nombre, "pro": pro, "ok": False, "tipos": tipos}
        orgs = regional.get("organizaciones") or []
        # Cuenta cabeceras de lista (cada lista = 1 expediente provincial)
        return {
            "provincia": nombre,
            "pro": pro,
            "ok": True,
            "organizaciones": len(orgs),
            "listas": sum(len(o.get("listas") or []) for o in orgs),
        }


async def main() -> None:
    resultados = []
    for pro, nombre in PROVINCIAS.items():
        try:
            res = await sondear(pro, nombre)
            print(res)
            resultados.append(res)
        except Exception as exc:  # noqa: BLE001
            print({"provincia": nombre, "pro": pro, "error": str(exc)[:80]})
        await asyncio.sleep(0.6)
    ok = [r for r in resultados if r.get("ok")]
    print(f"\nProvincias con bloque REGIONAL: {len(ok)}/8")
    if len(sys.argv) > 1 and sys.argv[1] == "--json":
        import json
        print(json.dumps(resultados, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
