# votacion

Sistema de cómputo rápido y transmisión de actas para las **Elecciones Regionales y Municipales de Arequipa 2026**, sobre el padrón real de la ONPE.

## Qué incluye

- **Padrón real ONPE**: 491 locales de votación y 4.194 mesas de los 109 distritos de Arequipa, importados desde el Excel oficial (`actas.xlsx`) con resolución de ubigeos RENIEC → INEI.
- **Cédula oficial**: partidos y candidatos en el orden del sorteo ONPE del 10-jun-2026 (bloque nacional + movimientos regionales), con numeración de casilla en la interfaz.
- **Carga de actas** con OCR (GPT-4o-mini / Gemini Flash / Tesseract local como respaldo) y evidencia fotográfica.
- **Ficha de acta/mesa**: ubicación, padrón, votos distrital/provincial/regional, checklist ONPE y visor de foto.
- **Mapa coroplético vectorial** (Leaflet + GeoJSON INEI) con las siluetas de los 109 distritos: clic → zoom al distrito → KPIs y ranking recalculados en vivo. Niveles distrito/provincia, modos "por avance" y "por ganador".
- **PWA móvil** de campo (`frontend/public/actas-movil.html`) y formulario raíz (`registro_acta.html`), ambos alimentados por el padrón real.
- **Verificación de integridad**: reconciliación de actas y contratos JSON (`docs/schemas/`).

## Arquitectura

```
backend/    FastAPI + SQLAlchemy (SQLite dev / PostgreSQL prod) — app/, sql/, tools/
frontend/   React + Vite + Tailwind (dashboard) + Leaflet — src/, public/
onpe-scraper/   Crawler del padrón de locales y mesas (CSV/XLSX → JSON/SQL)
jne-scraper/    Crawler de candidatos y organizaciones (JNE)
js/         PWA estática ligera
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

## Convenciones clave

- El `sort_order` de una organización **es** la posición física en la cédula (1-based), no orden alfabético.
- Ubigeos internos siempre en código **INEI** (el padrón ONPE viene en RENIEC; el importador resuelve por nombre).
- El padrón no trae electores por mesa: se usa 250 (tope de la regla R2) hasta contar con la cifra real.
- Las fotos de candidatos servidas viven en `backend/storage/candidatos` (montado en `/storage`).
