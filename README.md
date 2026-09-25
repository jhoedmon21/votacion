# votacion

Sistema de cómputo rápido y transmisión de actas para las **Elecciones Regionales y Municipales de Arequipa 2026**, sobre el padrón real de la ONPE.

Identidad visual **Fuerza Arequipeña** (rojo `#E02020` · blanco · negro, según el Estatuto del partido, art. 3) y **Sala de Cómputo** oscura con mapa de ganadores por distrito.

## Qué incluye

- **Padrón real ONPE**: 491 locales de votación y 4.194 mesas de los 109 distritos de Arequipa, importados desde el Excel oficial (`actas.xlsx`) con resolución de ubigeos RENIEC → INEI.
- **Cédula oficial**: partidos y candidatos en el orden del sorteo ONPE del 10-jun-2026 (bloque nacional + movimientos regionales), con numeración de casilla en la interfaz.
- **Carga de actas** con OCR (GPT-4o-mini / Gemini Flash / Tesseract local como respaldo) y evidencia fotográfica.
- **Ficha de acta/mesa**: ubicación, padrón, votos distrital/provincial/regional, checklist ONPE y visor de foto.
- **Mapa coroplético vectorial** (Leaflet + GeoJSON INEI) con las siluetas de los 109 distritos: clic → zoom al distrito → KPIs y ranking recalculados en vivo. Niveles distrito/provincia, modos "por avance" y "por ganador".
- **Sala de Cómputo** (`#salacomputo`): dashboard oscuro estilo sala electoral — header con % global, Top 2, lista de candidatos (40 %) y mapa vectorial por UBIGEO (60 %) coloreado por ganador distrital, con hover y clic que filtra toda la vista.
- **Cobertura de personeros**: semáforo verde/amarillo/rojo por local de votación sobre `v_cobertura_locales`, con mapa Leaflet y detalle de mesas críticas.
- **Credenciales FA**: fotochecks con QR y PDF por personero o por distrito.
- **PWA móvil** de campo (`frontend/public/actas-movil.html`) y formulario raíz (`registro_acta.html`), ambos alimentados por el padrón real.
- **Verificación de integridad**: reconciliación de actas y contratos JSON (`docs/schemas/`).

## Arquitectura

```
backend/    FastAPI + SQLAlchemy (PostgreSQL 16, SQLite como fallback) — app/, sql/, tools/
frontend/   React + Vite + Tailwind (dashboard) + Leaflet — src/, public/
onpe-scraper/   Crawler del padrón de locales y mesas (CSV/XLSX → JSON/SQL)
jne-scraper/    Crawler de candidatos y organizaciones (JNE)
js/         PWA estática ligera
```

## Base de datos PostgreSQL

El backend corre sobre **PostgreSQL 16** (`computo_arequipa`, puerto 5432).
La conexión se configura en `backend/.env` (ver `backend/.env.example`):

```
DATABASE_URL=postgresql+psycopg2://postgres:CLAVE@localhost:5432/computo_arequipa
```

Migración de datos desde SQLite (idempotente, preserva IDs y reposiciona secuencias):

```bash
cd backend
python -m app.migrate_to_postgres --dry-run   # informa cuántas filas copiaría
python -m app.migrate_to_postgres --truncate  # copia las 15 tablas desde SQLite
```

Tras migrar, reejecutar las semillas contra PG es seguro (todas idempotentes):

```bash
python -m app.load_jne_data      # oferta electoral JNE (4 niveles: regional, consejero, provincial, distrital)
python -m app.seed_padron_real   # padrón ONPE (109 distritos, 491 locales, 4.194 mesas)
```

## Cómo correr

Backend (puerto 8000):

```bash
cd backend
python -m venv venv
./venv/Scripts/python -m pip install -r requirements.txt   # Linux/Mac: venv/bin/python
cp .env .env.local 2>/dev/null || true
./venv/Scripts/python -m app.seed_arequipa                 # catálogo territorial
./venv/Scripts/python -m app.load_jne_data                 # cédula oficial
./venv/Scripts/python -m app.seed_padron_real              # padrón real (locales/mesas)
./venv/Scripts/python -m uvicorn app.main:app --port 8000
```

Frontend (puerto 5173):

```bash
cd frontend
npm install
npm run dev
```

## Datos y semillas

- `backend/app/seed_padron_real.py` reemplaza locales/mesas sintéticos por el padrón oficial; es idempotente y no borra actas reales.
- `backend/tools/ordenar_cedula.py` reordena los JSON de oferta electoral según la cédula del sorteo (verificador incluido).
- `backend/tools/generar_geo_arequipa.py` genera las capas GeoJSON ligeras de Arequipa (región, provincias, distritos) a partir del GeoJSON nacional INEI.

## Acceso demo

| Campo | Valor |
|---|---|
| Correo | `admin@computoarequipa.gob.pe` |
| Contraseña | `Admin.Arequipa2026` |
| Rol | `SUPER_ADMIN` (sembrado por `backend/app/services/seed_auth.py`) |

## Convenciones clave

- El `sort_order` de una organización **es** la posición física en la cédula (1-based), no orden alfabético.
- Ubigeos internos siempre en código **INEI** (el padrón ONPE viene en RENIEC; el importador resuelve por nombre).
- El padrón no trae electores por mesa: se usa 250 (tope de la regla R2) hasta contar con la cifra real.
- Las fotos de candidatos servidas viven en `backend/storage/candidatos` (montado en `/storage`).
