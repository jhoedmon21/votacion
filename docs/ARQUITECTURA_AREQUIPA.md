# Arquitectura — Sistema de Control Político y Cómputo de Votos · Arequipa 2026

Documento de arquitectura del sistema de captura, validación y cómputo de actas
para la Región Arequipa (8 provincias / 109 distritos) en las tres elecciones
simultáneas: **Gobierno Regional**, **Municipal Provincial** y **Municipal
Distrital**.

> **Nota de partida.** Este repositorio ya implementa buena parte del diseño
> descrito en el brief: el esquema PostgreSQL, el motor de reglas ONPE, la PWA de
> digitación, el control de roles y el dashboard. Este documento **mapea** lo
> existente a los requerimientos, y **especifica lo que falta** (mapa de calor,
> motor de alertas, tiempo real por push y plan de alta disponibilidad). No
> duplica lo ya escrito en `REGLAS_DE_NEGOCIO.md`: lo referencia.

---

## 0. Estado actual frente a los requerimientos

| Requerimiento del brief | Estado | Artefacto |
|---|---|---|
| Modelo relacional: ubigeo, partidos, candidatos, actas, usuarios | **Implementado** | `backend/sql/schema_arequipa.sql` (1020 líneas, 15 tablas, 12 tipos enum, 16 triggers, 5 vistas) |
| Partidos y candidatos de Arequipa | **Implementado con datos reales** | `backend/app/load_jne_data.py` carga 568 filas de los **110 ámbitos** crawleados del JNE (101 distritos + 8 provincias + regional) en las tablas del dashboard; `candidatos_arequipa.json` queda como mock de referencia |
| Formulario de captura rápida por mesa | **Implementado** | `frontend/public/actas-movil.html` (PWA, 4 secciones) |
| Subida de JPG/PNG/PDF + OCR asistido | **Parcial** (OCR simulado) | `backend/app/routers/actas.py::/ocr`, `app/services/vision.py` |
| Edición / auditoría de acta observada | **Implementado** | `frontend/src/components/ActaEditModal.tsx`, `ActaDetailModal.tsx`, `GET/PUT /api/actas/{id}` |
| Historial y control de versiones por acta | **Implementado** | Tabla `acta_eventos` + triggers `trg_actas_auditar`, `fn_consolidar_acta` |
| Validación de inconsistencias (suma, tope, duplicidad) | **Implementado** | `acta_validator.py` + trigger `fn_validar_contabilizacion` + JS de la PWA |
| Estados: Pendiente / Validada / Observada | **Implementado** | Enum `estado_acta` (5 valores, incluye `ANULADA`) |
| Usuarios y roles (Personero, Coord. Distrital, Admin Regional) | **Implementado** | `usuarios`, `usuario_alcance`, RLS, `app/core/auth.py` |
| Dashboard: % actas procesadas filtrable | **Implementado** | `GET /api/analytics/summary?scope=` |
| Gráficos de barras / pie por partido | **Implementado** | `frontend/src/ONPEPaucarpataDashboard.tsx` |
| Comparativa Regional vs Provincial vs Distrital | **Implementado** | Selector de ámbito (`Scope`) en el dashboard |
| **Mapas de calor territoriales** | **Gap → §5.3** | Nuevo `views_analytics_arequipa.sql` |
| **Alertas de inconsistencias agregadas** | **Gap → §6** | Nuevo `views_analytics_arequipa.sql` |
| **Analytics en tiempo real (push)** | **Gap → §5.4** | Hoy el dashboard sólo consulta al cambiar de ámbito |
| **Plan de alta disponibilidad día D** | **Gap → §8** | Este documento |

---

## 1. Arquitectura de capas

```
┌────────────────────────┐   ┌──────────────────────────────┐
│ Personero / Coord.     │   │ SUPER_ADMIN / Coordinadores  │
│ en el local de votación│   │ en el centro de cómputo      │
└───────────┬────────────┘   └──────────────┬───────────────┘
            │                              │
   ┌────────▼─────────┐          ┌─────────▼──────────┐
   │ PWA actas-movil  │          │ Dashboard React    │
   │ · foto + SHA-256 │          │ · summary / ranking│
   │ · cola offline   │          │ · mapa de locales  │
   │ · validación viva│          │ · bandeja de actas │
   └────────┬─────────┘          └─────────┬──────────┘
            │  HTTPS + Bearer (token opaco)│
            └──────────────┬───────────────┘
                           │
                 ┌─────────▼──────────────────────┐
                 │ FastAPI                        │
                 │ · RBAC por rol                 │
                 │ · alcance territorial (ubigeo) │
                 │ · acta_validator.py (autoridad)│
                 │ · set_config RLS por petición  │
                 └─────────┬──────────────────────┘
                           │
        ┌──────────────────┼────────────────────┐
        │                  │                    │
┌───────▼───────┐  ┌───────▼────────┐  ┌────────▼─────────┐
│ PostgreSQL 15 │  │ Object storage │  │ OCR (vision.py)  │
│ · 15 tablas   │  │ fotos de actas │  │ pre-carga, no    │
│ · 16 triggers │  │ (hash SHA-256) │  │ es autoridad     │
│ · 5 vistas    │  └────────────────┘  └──────────────────┘
└───────────────┘
```

**Principio rector (heredado de las Reglas de Negocio).** El dato se guarda tal
como está escrito en el papel; lo que se **prueba** es la contabilización. Las
reglas matemáticas no son `CHECK` de la tabla `actas` — bloquearían guardar la
realidad de un local sin señal — sino condiciones del trigger que dispara la
transición a `CONTABILIZADA`. Ver `REGLAS_DE_NEGOCIO.md` §1–§2.

---

## 2. Arquitectura de pantallas

### 2.1 PWA de digitación — `frontend/public/actas-movil.html`

Página única, optimizada para teléfono en un local de votación (`max-width:820px`,
Bootstrap 5). Cuatro secciones + una barra fija de validación:

| # | Sección | Contenido | Regla que alimenta |
|---|---|---|---|
| 1 | Ubicación de la mesa | Tipo de elección (Distrital/Provincial/Regional), provincia, distrito, local, N° de mesa (6 dígitos), electores hábiles | `R2_TOPE_ELECTORES` |
| 2 | Foto del acta física | `capture="environment"`, preview, hash SHA-256 visible, aviso de duplicidad | `R4_ACTA_DUPLICADA`, `R5_FOTO_AUSENTE` |
| 3 | Digitación de votos | Una fila por organización política, columnas A y B del acta, blancos/nulos/impugnados por columna | `R1_SUMA_VOTOS`, `R3_COLUMNAS_INCOHERENTES` |
| 4 | Validación | Lista de hallazgos, columna principal, total de votantes, participación | — |
| — | Barra fija | Σ+B+N+I vs "Acta dice", punto de estado, botones Validar / Registrar, info de cola offline | — |

Decisiones de diseño que sostienen el uso real en campo:

* **La sección 2 va antes que la digitación.** La foto es la fuente de verdad del
  acta; obligar a tomarla primero evita el patrón "digito de memoria y subo la
  foto después" (que es lo que produce `R5` y actas inauditables).
* **El hash SHA-256 se muestra al usuario mientras sube.** Convierte el candado
  anti-duplicidad en algo verificable en el acto y no en una sorpresa al enviar.
* **La barra de validación es fija (`position` inferior).** El veredicto
  Σ+B+N+I vs total permanece visible mientras se digita, sin hacer scroll.
* **`#cola-info` informa el estado offline en la propia barra.** El acta se
  encola con su hash y se sincroniza al recuperar señal; la validación se repite
  en el servidor porque la PWA no es fuente de verdad.

### 2.2 Dashboard de análisis — `frontend/src/`

Entrada: `main.tsx` → `LoginGate` → `ONPEPaucarpataDashboard`.

| Pantalla / componente | Rol que la usa | Función |
|---|---|---|
| `ONPEPaucarpataDashboard.tsx` | Todos | Selector de ámbito (`DISTRITAL` / `PROVINCIAL` / `REGIONAL`), tarjetas de métricas, ranking por organización, gráficos |
| `Actas.tsx` | Coordinadores | Bandeja de trabajo: cola de actas por estado |
| `components/ActaValidationForm.tsx` | Personero / Distrital | Formulario estructurado de ingreso y validación |
| `components/ActaEditModal.tsx` | Responsable distrital | Corrección de digitación con sustento |
| `components/ActaDetailModal.tsx` | Coordinador | Detalle + historial de eventos del acta |
| `components/ActaUploader.tsx` | Personero | Carga de imagen/PDF con OCR asistido |
| `MapView.tsx` | Coordinador regional | Marcadores geográficos de locales |

### 2.3 Flujo de navegación por rol

```
PERSONERO               RESPONSABLE_DISTRITAL        COORD_PROVINCIAL         SUPER_ADMIN
────────                ─────────────────────        ────────────────         ───────────
PWA: ubicación    ──▶   Bandeja: OBSERVADAS    ──▶   Cola provincia     ──▶   Tablero regional
foto (SHA-256)          de su distrito                (todas sus              · 8 provincias
digitación             · comparar con foto            provincias)             · alertas
validación viva        · corregir digitación     · actas que no          · desviaciones
envío (o cola offline) · recalcular                    cuadran de origen   · auditoría
                       · sustento (obligatorio)     · duplicidad (R4)
                                                     · ilegibilidad (R6)
```

El alcance territorial es jerárquico y se aplica en dos capas: en el backend
(`venues_en_alcance`) y en PostgreSQL vía RLS sobre `actas` (políticas
`p_actas_super_admin` / `p_actas_alcance`). El ubigeo de provincia `040100`
alcanza a todos los locales `0401xx`.

---

## 3. Modelo de datos

15 tablas en tres bloques (más `sesiones` y `accesos_log` de autenticación). El
detalle de columnas y constraints está en `backend/sql/schema_arequipa.sql`.

### 3.1 Jerarquía territorial y padrón

```
ubigeo (CHAR(6) PK, ubigeo_reniec, nivel, lat/long)
  └─ locales_votacion (codigo_local, electores_habiles, lat/long)
       └─ mesas (numero_mesa CHAR(6), electores_habiles, pabellon)
```

**Ubigeo: INEI es canónico, RENIEC se guarda también.** En Arequipa 85 de los 109
distritos difieren entre ambas codificaciones (Paucarpata es `040112` INEI y
`040109` RENIEC). El ubigeo canónico del sistema es el INEI; el crawler del JNE
usa RENIEC porque es lo que responde su API. Por eso la tabla guarda las dos
columnas y no una traducción al vuelo.

### 3.2 Oferta electoral

```
organizaciones_politicas (nombre, tipo, id_jne, color_hex)
  └─ candidatos (organizacion_id, ubigeo, tipo_eleccion, cargo, numero_lista,
                 nombre_completo, estado)
```

Un candidato es la tupla *(organización, ámbito, cargo, posición)*. El ámbito es
el ubigeo del distrito (`DISTRITAL`), de la provincia (`PROVINCIAL`) o `040000`
(`REGIONAL`). El `CHECK candidatos_cargo_coherente` impide mezclar cargos entre
niveles — no se puede registrar un `REGIDOR_DISTRITAL` en una lista regional.

La oferta electoral la produce `jne-scraper/crawler_arequipa.py`, que recorre
el ubigeo oficial con **HTTP directo** sobre la API del JNE (reintentos con
backoff exponencial, sin navegador) y la publica en las tablas del dashboard con
`backend/app/load_jne_data.py`. `candidatos_arequipa.json` sobrevive como mock de
referencia del formato.

### 3.3 Actas y trazabilidad

```
actas (mesa_id, tipo_eleccion, estado, electores_habiles,
       foto_url, foto_hash_sha256, validacion, diferencia_suma,
       digitada_por, validada_por, contabilizada_at, resolucion_final)
  │   UNIQUE (mesa_id, tipo_eleccion)   -- anti-duplicado en base
  ├─ acta_columnas (columna, total_votantes, blancos, nulos, impugnados)
  │    └─ detalle_votos_acta (organizacion_id, candidato_id, votos)
  ├─ acta_observaciones (regla, severidad, mensaje, resuelta, sustento)
  ├─ acta_eventos (evento, estado_anterior, estado_nuevo, detalle JSONB)
  └─ acta_adjuntos (tipo, url, hash_sha256)
```

**La unidad contable es la organización política, no el candidato.** En un acta
municipal el elector marca una vez el partido para alcalde y una vez para
regidores; no se vota regidor por regidor. Por eso `detalle_votos_acta`
referencia `organizacion_id` y sólo opcionalmente `candidato_id` (columnas de un
solo cargo, que habilitan el ranking nominal).

**El acta tiene dos columnas.** El papel trae dos cómputos independientes — A
(alcalde / gobernador y vice) y B (regidores / consejeros) — cada uno con sus
propios blancos, nulos, impugnados y total de votantes. `R1` se evalúa **por
columna**: basta que una descuadre para que el acta no sea contabilizable. La
cabecera de `actas` resume la columna principal (la del cargo de mayor
jerarquía), que es la que fija el resultado oficial.

**La columna B del acta regional es provincial.** Los votos de CONSEJEROS se
persisten en el nivel propio `consejero` (`consejero_candidates`, ubigeo
provincial `040100`…`040800`), separados del gobernador (`regional`, ubigeo
`040000`) y de cada otra provincia. El dashboard (vista Cómputo, nivel
CONSEJERO) renderiza una tarjeta por provincia con ganador, curules y escaños
d'Hondt (`resumen.consejeros[]`). Oferta cargada desde el expediente regional
del JNE filtrando `cargo = CONSEJERO_REGIONAL` por provincia de postulación.

---

## 4. Flujo de ingreso / edición de un acta

### 4.1 Camino normal (personero → cómputo)

```
1. Ubicar mesa     provincia ▸ distrito ▸ local ▸ N° mesa ▸ electores hábiles
2. Fotografiar     captura + hash SHA-256 (rechaza foto ya usada por otra acta)
3. Digitar         fila por organización; validación aritmética en cada tecleo
4. Validar         POST /api/actas/validar  → hallazgos, sin escribir nada
5. Registrar       POST /api/actas/movil    → evalúa y, sólo si cuadra,
                                              pasa a CONTABILIZADA; si no, 409
                                              y el acta queda OBSERVADA
```

Las reglas se aplican en tres capas que dicen lo mismo (defensa en profundidad):

| Capa | Archivo | Momento |
|---|---|---|
| PWA (JS) | `actas-movil.html` | mientras se digita — retroalimentación inmediata |
| Backend (Python) | `app/services/acta_validator.py` | **autoridad**: `/validar` y `/movil` |
| Base de datos | trigger `fn_validar_contabilizacion` | última línea: rechaza la fila aunque la app falle |

### 4.2 Edición de un acta observada

La edición no reescribe la historia. `PUT /api/actas/{id}` recalcula
(`fn_consolidar_acta`) y cada cambio que altera total, diferencia o consistencia
genera un evento `RECALCULADA` en `acta_eventos` con el estado anterior y el
nuevo. El detalle de quién cambió qué y a qué hora sale de
`GET /api/actas/{id}` (bitácora) sin necesidad de tabla adicional.

### 4.3 Estructura del formulario (contrato de datos)

El payload que consumen `/validar` y `/movil` (`ActaValidacionIn`) refleja la
forma del acta física:

```jsonc
{
  "tipo_eleccion": "DISTRITAL",          // REGIONAL | PROVINCIAL | DISTRITAL
  "ubigeo": "040112",                    // Paucarpata (INEI)
  "numero_mesa": "012345",
  "electores_habiles": 250,
  "foto_hash_sha256": "9f2c…",           // opcional pero habilitante
  "columnas": [
    {
      "columna": "ALCALDE",              // A
      "total_votantes": 214,
      "votos_blancos": 11, "votos_nulos": 6, "votos_impugnados": 2,
      "detalle": [
        { "organizacion_id": 1, "candidato_id": 42, "votos": 88 },
        { "organizacion_id": 2, "votos": 74 }
      ]
    },
    {
      "columna": "REGIDORES",            // B — tiene su propio cuadre
      "total_votantes": 209,
      "votos_blancos": 14, "votos_nulos": 7, "votos_impugnados": 1,
      "detalle": [ { "organizacion_id": 1, "votos": 90 } ]
    }
  ]
}
```

El formulario React equivalente es `components/ActaValidationForm.tsx`, y la
variante de corrección con sustento es `components/ActaEditModal.tsx`.

---

## 5. Dashboard de analytics

### 5.1 Métrica principal

`GET /api/analytics/summary?scope=district|provincial|regional` devuelve
`total_venues`, `total_tables`, `processed_tables`, `review_tables`,
`progress_pct` y el `ranking` de candidatos, **acotado al alcance del usuario**
(`venues_en_alcance`). El selector de ámbito del dashboard cambia
`Regional ▸ Provincial ▸ Distrital` sobre la misma pantalla.

### 5.2 Vistas SQL de soporte

`schema_arequipa.sql` ya expone las vistas base:

| Vista | Contenido |
|---|---|
| `v_acta_consolidada` | Estado por acta + `participacion_pct` + `columnas_descuadradas` |
| `v_resultados_organizacion` | Ranking oficial por organización (sólo `CONTABILIZADA`) |
| `v_resultados_candidato` | Ranking nominal (alcaldes / gobernadores) |
| `v_actas_observadas` | Cola de revisión con el detalle de descuadre |
| `v_avance_distrito` | Avance de los 109 distritos |

### 5.3 Mapa de calor territorial (nuevo)

`backend/sql/views_analytics_arequipa.sql` agrega las vistas que faltaban:

| Vista nueva | Para qué |
|---|---|
| `v_avance_provincia` | Rollup de las 8 provincias (semáforo regional) |
| `v_mapa_calor_distrito` | `intensidad` 0-100 + `banda` (`SIN_DATOS`/`INICIADO`/`EN_CURSO`/`AVANZADO`/`CERRADO`) + ganador distrital, con lat/long del ubigeo |
| `v_alertas_integridad` | Un renglón por anomalía (§6) |
| `v_desviacion_distrito` | z-score de cada organización por distrito vs su media provincial |
| `v_cola_revision_priorizada` | Cola de observadas ordenada por bloqueantes, antigüedad y magnitud |

El heat map se pinta por distrito con `intensidad` como variable de color y
`banda` como leyenda; al no necesitar geometría GeoJSON en el caso más simple,
basta un coropleta con el `ubigeo` como clave o, si se prefiere un mapa
geográfico, un `MapView` que coloree por `intensidad` usando lat/long del ubigeo.

### 5.4 Tiempo real (gap identificado)

Hoy el dashboard sólo consulta al montar y al cambiar de ámbito: no hay push. En
la jornada, con los coordinadores mirando el tablero, conviene:

1. **Endpoint SSE** `GET /api/analytics/stream` que emita un evento por acta
   contabilizada/observada. SSE y no WebSocket: el tráfico es unidireccional
   (servidor → navegador), atraviesa proxies HTTP sin upgrade y se reconecta solo.
2. **Origen de los eventos: `LISTEN/NOTIFY` de PostgreSQL.** El trigger
   `trg_actas_auditar` ya escribe cada transición en `acta_eventos`; un
   `NOTIFY acta_actualizada, '<json>'` en esa misma función convierte la bitácora
   —que ya existe— en el bus de eventos, sin polling y sin tabla de outbox.
3. **Filtrado por alcance en el emisor.** El stream debe emitir sólo eventos del
   ámbito del usuario, con la misma función de alcance que el resto de endpoints.
4. **Contadores agregados, no el detalle.** Emitir `{provincia, distrito,
   contabilizadas, observadas, avance_pct}` por distrito afectado evita que N
   navegadores recalculen el agregado.
5. **Fallback: polling de 30 s** cuando el navegador no soporta SSE o la conexión
   está restringida.

---

## 6. Motor de alertas

`v_alertas_integridad` normaliza todas las alertas en un formato común
(`alerta`, `severidad`, `acta_id`, `tipo_eleccion`, `provincia`, `distrito`,
`numero_mesa`, `valor_acta`, `valor_referencia`, `magnitud`, `mensaje`) para que
el dashboard sólo ordene y pinte. Las reglas que cubre:

| Alerta | Severidad | Detección |
|---|---|---|
| `R2_TOPE_ELECTORES` | BLOQUEANTE | `actas.total_votantes > mesas.electores_habiles` |
| `R1_DESCUADRE` | BLOQUEANTE | `estado = 'OBSERVADA'` y `fn_descuadres_acta(a.id)` devuelve filas |
| `PARTICIPACION_ANOMALA` | ADVERTENCIA | acta contabilizada con `participacion_pct < 30` |
| `OBSERVADA_SLA_VENCIDO` | ADVERTENCIA | observada sin tocar por más de 24 h |

La comparación **distrito vs provincia** que pide el brief va aparte, en
`v_desviacion_distrito`, porque no es una alerta por acta sino una señal
estadística: calcula el porcentaje de cada organización en cada distrito y lo
compara con su propio promedio provincial, exponiendo `desviacion_pp` y
`z_score`, y sólo devuelve filas con `|z| >= 2.5` y al menos 3 distritos con
datos (para que la desviación estándar signifique algo).

> **Advertencia de lectura.** Una desviación alta no es prueba de nada: en
> distritos pequeños un puñado de actas mueve el porcentaje mucho. La vista sirve
> para **priorizar dónde mirar**, y su resultado se resuelve siempre por el
> circuito humano de §7, con sustento.

---

## 7. Flujo optimizado de resolución de observaciones

```
PENDIENTE ──digitación──▶ DIGITADA ──reglas OK──▶ CONTABILIZADA
                             │
                             └──BLOQUEANTE──▶ OBSERVADA ──resolución──▶ CONTABILIZADA
                                                  │
                                                  └──irresoluble──▶ ANULADA (+ nueva acta)
```

Tres niveles escalonados, cada uno con requisito de sustento:

| Nivel | Rol | Resuelve | Sustento exigido | Plazo |
|---|---|---|---|---|
| 1 | `RESPONSABLE_DISTRITAL` | Errores de digitación, contra la foto que él subió | Foto visible al corregir | mismo día |
| 2 | `COORD_PROVINCIAL` | El acta **no cuadra de origen**: error del papel, `R2` por padrón desfasado, `R4` duplicidad, `R6` ilegibilidad | `acta_observaciones.sustento` + `actas.resolucion_final` | 24 h |
| 3 | `SUPER_ADMIN` | Actas siniestradas, resoluciones del JEE, correcciones masivas | Resolución del JEE adjunta | 48 h |

Optimizaciones del circuito:

1. **La cola se ordena sola.** `v_cola_revision_priorizada` pone primero lo
   bloqueante, luego lo más antiguo y lo de mayor descuadre. El coordinador abre
   el día y trabaja de arriba hacia abajo, sin decidir qué es urgente.
2. **El sistema no permite cerrar una observación sin sustento.**
   `CHECK observacion_resuelta_completa` exige `resuelta_por`, `resuelta_at` y
   `sustento`. Es lo que hace defendible el cierre ante el JEE.
3. **Contabilizar con bloqueantes abiertos es imposible por construcción.**
   `fn_validar_contabilizacion` rechaza con un mensaje que nombra la columna y el
   descuadre: `ACTA_INCONSISTENTE: el acta 12 no cuadra en 1 columna(s):
   REGIDORES (diferencia 160 votos)`.
4. **Reabrir una contabilizada es explícito y auditado.** Una observación
   bloqueante sobre un acta ya cerrada se rechaza (`ACTA_YA_CONTABILIZADA`): el
   camino correcto es revertir el estado a `OBSERVADA` —transición que queda en
   `acta_eventos`— y después observar. Así el tablero no muestra dos verdades.
5. **Nada se borra.** Un acta irresoluble se `ANULADA` y se registra la nueva,
   conservando la trazabilidad completa de ambas.

---

## 8. Alta disponibilidad para el día de la elección

### 8.1 Perfil de carga real (y por qué no hay que sobredimensionar)

Con el padrón de Arequipa (~1.1 M electores) y ~3.400 mesas, y **tres actas por
mesa** (regional, provincial, distrital), el total ronda **10.000 actas**. Si el
80 % se concentra entre las 16:00 y las 22:00, el pico ronda las **30–40
escrituras por segundo**. Es un volumen que **una sola instancia de PostgreSQL
maneja sin despeinarse**.

La consecuencia de ingeniería es la importante: **el riesgo del día D no es el
throughput, es la disponibilidad y la cola humana de revisión.** Un sharding o
una arquitectura distribuida que añada puntos de fallo sería un error de
prioridades. El esfuerzo debe ir a que el sistema nunca se caiga, nunca pierda
un dato y nunca deje una observación dormida.

### 8.2 Prioridades, en orden

| # | Medida | Por qué |
|---|---|---|
| 1 | **Cola offline en la PWA** (ya implementada) | Un local sin señal no puede ser un acta perdida. Es la medida de continuidad con mejor retorno. |
| 2 | **Idempotencia de las escrituras** | `UNIQUE (mesa_id, tipo_eleccion)` + hash de foto hacen que un reintento de la cola offline no genere duplicados. Verificar que `/movil` devuelva el acta existente en lugar de 500 ante un reintento. |
| 3 | **PgBouncer en modo `transaction`** delante de PostgreSQL | El backend abre muchas conexiones cortas; sin pooler, el límite de conexiones es el primer techo que se toca. |
| 4 | **Réplica de lectura** para `analytics/*` y los tableros | El dashboard de 50 coordinadores refrescando no debe competir con las escrituras del cómputo. |
| 5 | **Almacenamiento de fotos separado** (`app/services/storage.py`) | Las fotos no van a la base ni al disco del API: van a object storage, y la base guarda sólo URL y hash. |
| 6 | **Postgres con `synchronous_commit = on` y WAL en SSD** | Se está contando un acto oficial: perder una escritura confirmada no es una opción, aunque cueste latencia. |
| 7 | **Backpressure explícito** en `/movil` ante saturación: `503` + `Retry-After`, nunca timeout silencioso | El cliente ya sabe reintentar (cola offline); un timeout opaco, en cambio, hace que el personero vuelva a digitar. |
| 8 | **Monitoreo de la métrica que importa**: actas observadas sin resolver y su antigüedad | Es la señal de que el cómputo se está atascando, y se ve en `v_alertas_integridad` antes de que sea un problema. |
| 9 | **Ensayo de carga** con el payload real de un acta sobre PgBouncer + réplica | Valida el dimensionamiento en vez de suponerlo. |
| 10 | **Runbook del día D**: a quién se llama, cómo se revierte un estado, cómo se reanuda la sincronización de la cola | La parte que se olvida y la que más duele cuando algo falla a las 20:00. |

### 8.3 Lo que **no** se debe hacer

* **Particionar `actas` por fecha.** Con 10.000 filas por jornada, el particionado
  añade complejidad sin resolver nada.
* **Cachear el ranking en Redis.** `v_resultados_organizacion` sobre 10.000 actas
  contabilizadas es una consulta trivial; el caché sólo introduce otra fuente de
  verdad sobre un dato que debe ser único.
* **Microservicios.** El sistema es un backend y una base. Partirlo multiplicaría
  las fallas parciales justo donde hace falta una verdad única.

---

## 9. Brechas y roadmap priorizado

| Prioridad | Trabajo | Por qué primero |
|---|---|---|
| P0 | **Correr `views_analytics_arequipa.sql` y exponerlas** en `/api/analytics` (`/heatmap`, `/alertas`, `/cola`) | Es lo que convierte los datos ya existentes en las vistas que pide el brief |
| P0 | **Idempotencia de `/api/actas/movil`** ante reintento de la cola offline | Debe estar resuelto antes de la jornada, no durante |
| P1 | **Stream SSE** con `LISTEN/NOTIFY` sobre `acta_eventos` (§5.4) | El tablero en vivo es el punto del brief que hoy no se cumple |
| P1 | **Pantalla de alertas** en el dashboard, sobre `v_alertas_integridad` | Sin superficie, el motor de alertas no sirve |
| P1 | **Integrar el coropleta** de `v_mapa_calor_distrito` en `MapView.tsx` | Completa "Mapas de Calor" |
| P2 | **Unificar el modelo del prototipo con el esquema PostgreSQL** | `analytics.py` lee modelos SQLAlchemy de prototipo (`DistrictCandidate`, `Venue`, `Record`) que no son las tablas de `schema_arequipa.sql`; conviven dos modelos de datos. El prototipo ya tiene la dimensión territorial (`ubigeo` en las tres tablas de candidatos) y **el ámbito acota la oferta y los votos** en `processor._save`, `/movil`, `_apply_votes` y `analytics.summary`, pero sigue sin `organizaciones_politicas` ni historial de acta |
| P2 | **PDF en `/ocr`** (hoy sólo imagen) y OCR real | El brief pide JPG/PNG/**PDF** |
| P2 | **Retirar o justificar `LoginGate` en el React** | La PWA ya abre sin login; el dashboard no debería tener una postura distinta sin una razón de seguridad explícita |

---

## 10. Verificación

```bash
# Oferta electoral real en la base del dashboard (idempotente)
cd backend && python -m app.load_jne_data --dry-run       # plan sin escribir
cd backend && python -m app.load_jne_data                 # 568 filas de 110 ámbitos

# Crawler del JNE: HTTP directo, sin navegador
cd jne-scraper && python crawler_arequipa.py --estado      # ¿responde la API?
cd jne-scraper && python crawler_arequipa.py --dry-run     # los 118 ámbitos del plan
cd jne-scraper && python tests/test_crawler_reintentos.py  # 13 casos, sin red
# Validar una corrida contra lo ya extraído (0 = contenido idéntico)
cd jne-scraper && python tools/comparar_crawl.py --a data/arequipa --b data/arequipa_http

# Reglas de negocio (3 capas)
cd backend && python tests/test_acta_validator.py        # 14 casos
cd backend && python tests/test_auth.py                  # 20 casos de auth/RBAC
cd backend && python tools/validate_schema.py            # coherencia del DDL

# Integración contra PostgreSQL real (termina en ROLLBACK)
psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/tests/sql/actas_integracion.sql
psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/tests/sql/actas_hostil.sql

# Capa de analytics nueva (idempotente, no toca datos)
psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/sql/views_analytics_arequipa.sql
psql -d computo_arequipa -c "SELECT * FROM v_avance_provincia ORDER BY avance_pct DESC;"
psql -d computo_arequipa -c "SELECT * FROM v_mapa_calor_distrito ORDER BY avance_pct;"
psql -d computo_arequipa -c "SELECT alerta, severidad, distrito, mensaje FROM v_alertas_integridad ORDER BY magnitud DESC;"
```

---

## Referencias

* `docs/REGLAS_DE_NEGOCIO.md` — motor de reglas R1–R8, ciclo de vida y roles (autoridad funcional)
* `backend/sql/schema_arequipa.sql` — DDL, triggers, vistas y RLS
* `backend/sql/views_analytics_arequipa.sql` — heat map, alertas y desviación sistemática
* `backend/app/services/acta_validator.py` — validador autoridad
* `frontend/public/actas-movil.html` — PWA de digitación
* `candidatos_arequipa.json` — datos dummy de la oferta electoral
