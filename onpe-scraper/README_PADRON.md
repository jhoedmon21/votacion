# ETL del padrón ONPE — Locales y mesas de Arequipa a BD relacional

Carga el catálogo completo de locales de votación y mesas electorales de la
**Región Arequipa** (departamento `AREQUIPA`, ubigeo base `04`, 8 provincias /
109 distritos) en las tablas `locales_votacion` y `mesas_votacion`.

> **Estado de fuente honesto (verificado 2026-09-18):** la API ciudadana
> de la ONPE (`consultaelectoral.onpe.gob.pe/v1/api/busqueda/dni`) es **por
> persona** y el padrón es dato personal protegido: no existe endpoint que
> devuelva todos los locales/mesas de un distrito, y barrer DNI sería abuso,
> no técnica. Este ETL **no barre DNI** (lo prohíbe por código). La vía real de
> producción es el **archivo oficial** (`--fuente archivo`); `--fuente catalogo`
> automatiza la descarga en cuanto el dataset esté publicado en datos abiertos.

## 1. Entregables

| Archivo | Qué es |
|---|---|
| `sql/ddl_locales_mesas.sql` | DDL PostgreSQL (variante MySQL 8 incluida): `locales_votacion` + `mesas_votacion` con FK, CHECKs, índices, triggers `updated_at`, `fn_recalcular_totales_locales()` y vista `vista_padron_arequipa` |
| `scraper_padron_arequipa.py` | CLI ejecutable del ETL |
| `padron/config.py` | Ajustes por entorno + plan territorial (8 provincias) |
| `padron/http.py` | Sesión con User-Agent real, reintentos con backoff, rate-limiting, manejo 403/429 |
| `padron/fuentes.py` | Adaptadores (catálogo CKAN/DKAN, archivo CSV/JSON/XLSX) + validación y normalización |
| `padron/modelos.py` | ORM SQLAlchemy (con `PADRON_SCHEMA` opcional) |
| `padron/carga.py` | UPSERT idempotente por provincia (nativo `ON CONFLICT` en PG) + logs territoriales |
| `padron/tests/test_padron.py` | 10 tests `unittest` (normalización, idempotencia, DDL) |
| `requirements-padron.txt` | Dependencias |
| `.env.example` | Plantilla de configuración |

## 2. Instalación

```bash
# 1) Dependencias (núcleo; pandas/openpyxl/lxml son opcionales con fallback stdlib)
python -m pip install -r onpe-scraper/requirements-padron.txt

# 2) Base de datos: aplique el DDL (PostgreSQL productivo)
createdb padron_arequipa
psql -d padron_arequipa -v ON_ERROR_STOP=1 -f onpe-scraper/sql/ddl_locales_mesas.sql

# 3) Configuración: copie y complete el entorno
copy onpe-scraper\.env.example onpe-scraper\.env   # Windows
# cp onpe-scraper/.env.example onpe-scraper/.env   # Linux
```

Variables clave (`onpe-scraper/.env`):

```ini
DATABASE_URL=postgresql+psycopg2://postgres:postgres@localhost:5432/padron_arequipa
#DATABASE_URL=mysql+pymysql://root:root@localhost:3306/padron_arequipa
#DATABASE_URL=sqlite:///./padron_arequipa.db   # desarrollo, cero instalación
PADRON_SCHEMA=        # "padron" si convive con backend/sql/schema_arequipa.sql
PADRON_ARCHIVO=onpe-scraper/fixtures/locales_mesas_ejemplo.csv
HTTP_PAUSA_SEG=1.5    # súbalo si recibe 403/429
```

> **Convivencia:** `backend/sql/schema_arequipa.sql` ya define `locales_votacion`
> con otra forma. No aplique ambos DDL en el mismo schema: use `PADRON_SCHEMA=padron`
> (el loader crea el schema) o una base separada.

## 3. Uso

```bash
# Plan territorial sin tocar nada (109 distritos / 8 provincias)
python onpe-scraper/scraper_padron_arequipa.py --fuente archivo --archivo f.csv --dry-run

# Carga productiva (idempotente: re-ejecutable sin duplicar)
python onpe-scraper/scraper_padron_arequipa.py --fuente archivo --archivo relacion_onpe.csv

# Sólo una provincia / depuración fina
python onpe-scraper/scraper_padron_arequipa.py --fuente archivo --archivo f.csv --solo-provincia CAYLLOMA -v

# Catálogo de datos abiertos (cuando el dataset esté publicado)
python onpe-scraper/scraper_padron_arequipa.py --fuente check                                   # vigilancia
python onpe-scraper/scraper_padron_arequipa.py --fuente catalogo --recurso-url https://...zip  # descarga+carga

# Tests (10, SQLite temporal, sin red)
cd onpe-scraper && python -m unittest padron.tests.test_padron -v
```

Formato de entrada (columnas flexibles, ignora acentos/mayúsculas):

```csv
ubigeo,distrito,local_codigo,local_nombre,local_direccion,mesa,electores
040112,PAUCARPATA,023001,I.E. Manuel Veramendi,Av. Arequipa 123,023001,250
```

## 4. Guardas y operación

- **Validación:** ubigeo 6 dígitos + prefijo `04` + dentro de los 109 distritos
  (`backend/app/core/ubigeo_catalogo.py`); mesa 6 dígitos; mesa duplicada entre
  locales → descarte (candado R4); coordenadas fuera de rango → CHECK del DDL.
- **UPSERT:** `UNIQUE(ubigeo, codigo_local)` y `UNIQUE(local_id, numero_mesa)`;
  segunda pasada con la misma fuente = `+0/~N` (verificado). `total_mesas` se
  recalcula desde las mesas reales.
- **Logs:** INFO por provincia (`[CAYLLOMA] commit: locales +1/~0 | mesas +2/~0`),
  DEBUG por distrito con `-v`; descartes con motivo.
- **Integración con el sistema:** el padrón crudo alimenta el operativo vía
  `POST /api/ingesta/jornada` (distribución: locales+mesas+electores hábiles,
  tope de la regla R2) o el seed de `crawler_locales_mesas.py --sql`.
- **Salida:** 0 ok · 1 sin datos/fuente no disponible · 2 uso/config.
