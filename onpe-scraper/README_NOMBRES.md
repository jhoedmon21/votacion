# Crawler de nombres reales de locales (`crawler_nombres_locales.py`)

Reemplaza los nombres sintéticos del seed (`I.E. X N°k`) por los oficiales de
la ONPE **crawleando**, sin escribirlos a mano.

## Cómo funciona

1. Recorre el grupo ONPE de datosabiertos.gob.pe (HTML paginado + caché 24 h,
   porque `package_search` está deshabilitado; `package_show` sí responde).
2. Descarga recursos ZIP/CSV (con tope `--max-mb`, UTF-16 incluido) y detecta
   columnas de local + ubigeo/mesa.
3. Extrae `{ubigeo: [{nombre, mesas}]}` de Arequipa a
   `backend/sql/locales_reales.json`.
4. `python -m app.seed_arequipa` lo consume posicionalmente y **renombra** los
   sintéticos sin duplicar (precedencia: JSON crawleado > tabla confirmada).

```bash
python crawler_nombres_locales.py --descubrir
python crawler_nombres_locales.py --cazar --filtro <texto> --dry-run -v
python crawler_nombres_locales.py --cazar
python -m app.seed_arequipa            # aplica renombres (idempotente)
cd onpe-scraper && python -m unittest tests.test_nombres_locales -v
```

## Estado de fuentes (verificado 2026-09-18)

| Fuente | Estado |
|---|---|
| 116 datasets ONPE (resultados por mesa) | Crawleados: **ninguno trae columna LOCAL** (solo UBIGEO/MESA/votos). Ver `data/caza_locales_reporte.json` |
| ETLV (`eligetulocal`) | Cerrado el 14/12/2025 y con DNI: no crawleable en bloque |
| Consulta electoral por DNI | Por ciudadano: barrer DNI es abuso, prohibido |
| MINEDU (ESCALE/Identicole) | Inalcanzable desde aquí (timeout); reintentar con `--filtro` si vuelve |

El día que la ONPE publique la relación de locales ERM2026, `--cazar` la
detecta y llena los 109 distritos sin tocar código.
