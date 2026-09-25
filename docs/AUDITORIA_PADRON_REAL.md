# Auditoría del Padrón Electoral Real — Arequipa 2026

> Verificación ejecutada contra `actas.xlsx` (ONPE) → importador
> `onpe-scraper/crawler_locales_mesas.py --importar actas.xlsx` →
> `frontend/public/data/locales_mesas_arequipa.json` → BD del prototipo
> (`python -m app.seed_padron_real --reemplazar`).

## 1. Cifras del padrón oficial

| Métrica | Esperado (ONPE) | En base de datos | Estado |
|---|---:|---:|---|
| Distritos | 109 | 109 | ✅ |
| Locales de votación | 491 | 491 | ✅ |
| Mesas de sufragio | 4.194 | 4.194 | ✅ |
| Electores hábiles | cifra real pendiente | 1.048.498 (250/mesa, default) | ℹ️ provisional |

Ubigueos cubiertos: `040101` (Arequipa Cercado) → `040811` (La Unión).

## 2. Distribución de locales por provincia

| Provincia | Locales |
|---|---:|
| Arequipa (0401) | 319 |
| Caylloma (0405) | 39 |
| Camaná (0402) | 29 |
| Castilla (0404) | 27 |
| Caravelí (0403) | 24 |
| Islay (0407) | 21 |
| La Unión (0408) | 17 |
| Condesuyos (0406) | 15 |
| **Total** | **491** |

## 3. Resolución de ubigeos RENIEC → INEI

El archivo oficial usa codificación RENIEC; el importador reasigna al catálogo
INEI, que es la llave del sistema. Puntos verificados:

- **Paucarpata** está en `040112` (INEI). El falso positivo habitual
  `040109` (RENIEC) corresponde aquí a **Mariano Melgar**, distrito legítimo
  con 11 locales y 179 mesas propias, sin solapamiento de locales con Paucarpata.
- Los 109 ubigeos del padrón coinciden 1:1 con el catálogo de distritos.

## 4. Limpieza del padrón sintético (ejecutada)

El prototipo arrancó con un padrón inventado ("I.E. <capital> N°1", mesas
100001+). El reemplazo oficial (`--dry-run` previo, luego `--reemplazar`) dejó:

| Operación | Cantidad |
|---|---:|
| Mesas sintéticas eliminadas | 1.302 |
| Locales sintéticos eliminados | 221 |
| Asignaciones demo huérfanas eliminadas | 5 |
| Mesas reales preservadas (con acta) | 3 |
| Asignaciones de personeros válidas conservadas | 42 |

Verificación posterior: `[OK] padrón oficial cargado` — `venues: 491,
tables: 4194` exactos.

## 5. Actas registradas sobre mesas reales

Las 89 filas de votos corresponden a **3 actas físicas** (una fila por
candidato y nivel: 15 regionales, 17 provinciales, 10 distritales):

| Mesa | Niveles capturados | Sufragaron | R2 (≤ hábiles) | R1 |
|---|---|---:|---|---|
| 005174 | regional | 103 | ✅ (250) | ⚠️ `total_electores` en default |
| 005188 | regional + provincial | 40 | ✅ (250) | ⚠️ `total_electores` en default |
| 006339 | regional + provincial + distrital | 6 | ✅ (250) | ⚠️ `total_electores` en default |

- **R4 (duplicados)**: ✅ una sola acta por mesa.
- **R2 (sufragaron ≤ hábiles)**: ✅ sin sobrepasos.
- **R1 (cuadre)**: los votos capturados son parciales de demo y
  `total_electores` aún guarda el default 250; al registrar el total real de
  sufragantes (103 / 40 / 6) las tres actas quedan cuadradas.

## 6. Cómo reproducir la auditoría

```bash
# 1. Regenerar el padrón normalizado desde el Excel oficial
python onpe-scraper/crawler_locales_mesas.py --importar actas.xlsx

# 2. Informar el reemplazo sin escribir
cd backend && python -m app.seed_padron_real --dry-run

# 3. Aplicar el reemplazo (no destructivo con lo real)
python -m app.seed_padron_real --reemplazar
```
