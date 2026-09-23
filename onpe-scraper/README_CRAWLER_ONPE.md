# `crawler_onpe.py` — Crawler/ETL de locales y mesas ONPE

Extrae la estructura de ubigeos, locales (nombre, dirección exacta,
referencia), y mesas de la ONPE para Arequipa (0401–0408, 109 distritos) o a
nivel nacional, y la carga con UPSERT en PostgreSQL/MySQL/SQLite.

Esquema: `sql/ddl_locales_mesas.sql` (`locales_votacion` 1—N
`mesas_votacion` por FK `local_id`; claves `UNIQUE(ubigeo, codigo_local)` y
`UNIQUE(local_id, numero_mesa)`).

## 1. Instalación

```bash
python -m pip install -r onpe-scraper/requirements.txt
copy onpe-scraper\.env.example onpe-scraper\.env   # Windows
# cp onpe-scraper/.env.example onpe-scraper/.env   # Linux
```

Mínimo en `.env`:

```ini
DATABASE_URL=postgresql+psycopg2://postgres:postgres@localhost:5432/padron_arequipa
#DATABASE_URL=mysql+pymysql://root:root@localhost:3306/padron_arequipa
#DATABASE_URL=sqlite:///./padron_arequipa.db
```

Aplique el DDL una vez (PostgreSQL):

```bash
createdb padron_arequipa
psql -d padron_arequipa -v ON_ERROR_STOP=1 -f onpe-scraper/sql/ddl_locales_mesas.sql
```

## 2. Ejecución

```bash
# Enfoque A: barrido por ubigeo (solo sondea; la ONPE no publica bulk por ubigeo)
python onpe-scraper/crawler_onpe.py --enfoque a --ambito arequipa --dry-run -v

# A con endpoints propios (plantillas {ubigeo}, separadas por coma):
ONPE_ENDPOINTS="https://api.ejemplo.gob.pe/locales?ubigeo={ubigeo}" \
python onpe-scraper/crawler_onpe.py --enfoque a --estricto

# Enfoque B: CSV/Excel oficial (URL o archivo) — vía productiva
python onpe-scraper/crawler_onpe.py --enfoque b --csv relacion_onpe.csv --dry-run --detalle
python onpe-scraper/crawler_onpe.py --enfoque b --csv relacion_onpe.csv --db sqlite:///./padron.db
python onpe-scraper/crawler_onpe.py --enfoque b --excel https://.../locales.xlsx --solo-provincia CAMANA
python onpe-scraper/crawler_onpe.py --enfoque b --dataset <slug-datosabiertos> --db postgresql+psycopg2://u:p@h:5432/padron

# Tests (SQLite temporal, sin red)
cd onpe-scraper && python -m unittest padron.tests.test_padron -v
```

Columnas aceptadas (flexibles, sin importar mayúsculas/acentos): `ubigeo`,
`provincia`, `distrito`, `codigo_local`, `nombre_local`, `direccion`,
`referencia`, `mesa`/`mesas`, `electores`, `latitud`, `longitud`.

## 3. Resiliencia

- User-Agent rotativo (pool de 3 navegadores reales) + pausa configurable
  (`--pausa` / `HTTP_PAUSA_SEG`); 403/429 no se reintentan a lo loco: abortan
  con guía (`FuenteBloqueada`).
- Reintentos con backoff en 5xx/timeouts (`HTTP_REINTENTOS`).
- Todo distrito/provincia con fallo queda en el log (`[040201] ...: sin
  datos`) y en `data/caza_onpe_reporte.json` (enfoque A) o en descartes con
  motivo (enfoque B).
- UPSERT idempotente: re-correr con la misma fuente da `+0/~N`; `total_mesas`
  se recalcula desde las mesas reales. Salidas: 0 ok · 1 sin datos · 2 config.
