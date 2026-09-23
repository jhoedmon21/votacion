# onpe-scraper — Locales de votación y mesas de Arequipa

Herramienta para obtener la **relación de locales de votación y mesas** de la
Región Arequipa (8 provincias / 109 distritos) desde la fuente oficial de la
ONPE, en el formato que consume la PWA (`frontend/public/data/locales_mesas_arequipa.json`).

---

## 1. Por qué esto no es un crawler de barrido

La investigación del origen (2026-09-16) dio tres hechos que cambian el diseño:

**a) La data de las ERM 2026 todavía no está publicada.** El portal oficial
    `erm2026.onpe.gob.pe/electores-y-miembros-de-mesa/conoce-tu-local-de-votacion/`
    responde, literalmente:

> *"¡Próximamente! El sistema se habilitará con la información para que puedas
> consultar tu local de votación."*

**b) El backend de consulta aún no está expuesto.** El portal ciudadano
    `consultaelectoral.onpe.gob.pe` es una SPA Angular detrás de **AWS WAF**
    (el bundle declara el challenge de `token.awswaf.com`). Su contrato,
    extraído de `main-2BIJKEBZ.js`:

```js
apiUrl     = ""            // Object.assign sobreescribe "/clv-ciudadano-backend"
apiVersion = "v1/api"

POST /v1/api/busqueda/dni          { numeroDocumento: "<DNI>" }
POST /v1/api/consulta/provisional  {}
POST /v1/api/consulta/definitiva   {}
POST /v1/api/configuracion/listar  {}
```

Hoy los cuatro devuelven el `index.html` de la SPA: el reverse proxy todavía no
tiene backend detrás. Es decir, la ruta existe pero la data no.

**c) La API es POR CIUDADANO, y eso no es un detalle de implementación.**
    `busqueda/dni` devuelve el local y la mesa de *una* persona. **No existe
    ningún endpoint que devuelva la relación completa de locales y mesas de un
    distrito**, y no puede existir: el padrón es dato personal protegido.

> Barrer DNI para reconstruir el padrón no sería una técnica de extracción, sería
> un abuso. Este programa **no lo hace** y no expone ninguna opción para hacerlo.

### Entonces, ¿de dónde sale la data en producción?

Del **archivo oficial** de locales y mesas que la ONPE entrega a las
organizaciones políticas y publica como dataset antes de la jornada electoral.
Ésa es la vía real, y es la que implementa `--importar`.

---

## 2. Los tres modos

| Modo | Qué hace | Necesita navegador |
|---|---|---|
| `--estado` | Consulta si el backend de la ONPE ya responde JSON. **Vigilante de disponibilidad**: se puede repetir sin costo hasta que habiliten la data. | No |
| `--descubrir` | Abre el portal con un navegador real (resuelve el WAF) y **captura los XHR hacia `/v1/api`**, guardando método, cuerpo de petición y respuesta. Fija el contrato exacto el día que habiliten la información, sin adivinar rutas. | Sí |
| `--importar` | Normaliza el archivo oficial (CSV, XLSX o JSON) al formato de la PWA, y opcionalmente genera un seed SQL. | No |

Además, `--dry-run` imprime el plan territorial (los 109 distritos) sin tocar la red.

---

## 3. Uso

```bash
# Plan territorial, sin red
python onpe-scraper/crawler_locales_mesas.py --dry-run

# ¿Ya publicaron la data? (repetible; sale 1 mientras no esté)
python onpe-scraper/crawler_locales_mesas.py --estado

# El día que habiliten: capturar el contrato real del portal
python onpe-scraper/crawler_locales_mesas.py --descubrir          # guarda data/descubrimiento.json
python onpe-scraper/crawler_locales_mesas.py --descubrir --headful # viendo el navegador

# Producción: normalizar el archivo oficial de locales y mesas
python onpe-scraper/crawler_locales_mesas.py --importar relacion_onpe.csv
python onpe-scraper/crawler_locales_mesas.py --importar actas.xlsx  # acepta el Excel oficial
python onpe-scraper/crawler_locales_mesas.py --importar relacion_onpe.csv --sql ../backend/sql/seed_locales_mesas_arequipa.sql
```

Salida por defecto: `frontend/public/data/locales_mesas_arequipa.json`.

La PWA (`.html`) **prefiere ese archivo** sobre `locales_mesas_demo.json` en cuanto
existe, y el chip de la cabecera cambia de `DEMO` a `PADRÓN · N/109`, de modo que
nunca se confunde un ejemplo con el padrón.

### Instalación del navegador (sólo para `--descubrir`)

```bash
python -m pip install -r onpe-scraper/requirements-crawler.txt
python -m playwright install chromium
```

> La versión de Playwright y la del navegador descargado **deben coincidir**.
> Si en la caché de Playwright hay un Chromium de otra versión, no se reutiliza:
> hay que ejecutar `playwright install chromium` una vez.

---

## 4. Formato de entrada aceptado

CSV o JSON, con cabeceras flexibles (se ignoran acentos, mayúsculas y signos).
Columnas reconocidas:

| Interno | Alias aceptados |
|---|---|
| `ubigeo` | `ubigeo`, `ubigeo_inei`, `codigo_ubigeo`, `ub_digito` |
| `distrito` | `distrito`, `nombre_distrito` |
| `provincia` | `provincia`, `nombre_provincia` |
| `local_codigo` | `local_codigo`, `codigo_local`, `cod_local`, `codigo` |
| `local_nombre` | `local_nombre`, `nombre_local`, `local_votacion`, `local`, `nombre` |
| `local_direccion` | `local_direccion`, `direccion`, `direccion_local` |
| `mesa` | `mesa`, `numero_mesa`, `nro_mesa`, `mesa_sufragio`, `n_mesa` |
| `mesas` | `mesas`, `lista_mesas` (lista separada por comas o espacios) |
| `electores` | `electores`, `electores_habiles`, `padron` |
| `latitud`/`longitud` | `latitud`/`lat`, `longitud`/`lon`/`lng` |

Ejemplo mínimo (una fila por mesa):

```csv
ubigeo,distrito,local_codigo,local_nombre,local_direccion,mesa,electores
040112,PAUCARPATA,023001,I.E. Manuel Veramendi,Av. Arequipa 123,023001,250
```

---

## 5. Guardas de validación

El normalizador **rechaza y reporta** en vez de publicar datos que no se puedan
defender. Cada descarte queda en `data/_errores.log` con el motivo:

- ubigeo con formato inválido (no son 6 dígitos)
- ubigeo fuera de Arequipa (prefijo `04`)
- ubigeo que no está entre los 109 distritos del ubigeo oficial
- mesa con formato inválido (no son 6 dígitos)
- **mesa repetida** entre locales distintos (el mismo candado anti-duplicado
  que `R4` impone sobre las actas)
- `electores` no numérico (se ignora el valor, no la fila)

`fixtures/locales_mesas_hostil.csv` ejercita todas esas guardas y se espera que
produzca 7 descartes; `fixtures/locales_mesas_ejemplo.csv` es el caso limpio.

---

## 6. Relación con el resto del sistema

- La PWA usa los locales y las mesas para el tope del padrón (`R2_TOPE_ELECTORES`).
  Con `DEMO`, ese tope se prueba contra 250 electores por mesa y no contra el
  padrón real: por eso la distinción está visible en el chip.
- El seed SQL que genera `--sql` respeta los `UNIQUE` de `schema_arequipa.sql`
  (`locales_codigo_por_ubigeo` y `mesas_unica_por_local`) con `ON CONFLICT`,
  así que es idempotente.
- Los candidatos son otro problema y otra fuente (JNE): ver `jne-scraper/`.

## 7. Verificación

```bash
python onpe-scraper/crawler_locales_mesas.py --dry-run
python onpe-scraper/crawler_locales_mesas.py --estado
python onpe-scraper/crawler_locales_mesas.py --importar onpe-scraper/fixtures/locales_mesas_ejemplo.csv --salida /tmp/prueba.json -v
python onpe-scraper/crawler_locales_mesas.py --importar onpe-scraper/fixtures/locales_mesas_hostil.csv  --salida /tmp/hostil.json -v
```
