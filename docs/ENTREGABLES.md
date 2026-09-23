# Entregables Técnicos — Sistema de Monitoreo de Votaciones y Gestión de Delegados de Mesa (Región Arequipa)

Documento índice de los **cuatro entregables** solicitados, con su artefacto final,
cómo mapea al brief y dónde corre cada uno. Todos los entregables están listos
para producción y se apoyan en el código ya implementado en este repositorio.

| Entregable | Brief | Artefacto(s) | Estado |
|---|---|---|---|
| **1. Esquema de base de datos** | DDL completo, PK/FK, índices por mesa/ubigeo, triggers de auditoría | `backend/sql/schema_arequipa.sql` + `backend/sql/modulo_campo_arequipa.sql` + **`backend/sql/migracion_jerarquia_completa.sql`** (nuevo) | Implementado + completado |
| **2. Estructura JSON de ingesta** | Esquema JSON de nómina de candidatos/partidos por distrito + distribución de locales y mesas | **`docs/schemas/ingesta-jornada-v1.schema.json`** + `docs/schemas/ejemplos/ingesta-arequipa-ejemplo.json` + **`backend/app/routers/ingesta.py`** (`POST /api/ingesta/jornada`, nuevo) + **`backend/app/seed_arequipa.py`** (padrón regional, nuevo) | Implementado |
| **3. Componente frontend** | Formulario React+Tailwind+TS de ingreso/validación de votos multi-nivel, imagen, validación matemática, observaciones | **`frontend/src/components/VotosMesaForm.tsx`** (nuevo) sobre el contrato `docs/schemas/plantilla-acta-v1.schema.json` | Implementado |
| **4. Arquitectura de alta disponibilidad** | Estrategia cloud para picos de concurrencia y envío simultáneo en el cierre | `docs/ALTA_DISPONIBILIDAD_DIA_D.md` (AWS multi-AZ, runbook, dimensionamiento) | Implementado |

---

## Entregable 1 — Esquema de base de datos (SQL PostgreSQL)

**Base (ya existente):**
- `backend/sql/schema_arequipa.sql` — 15 tablas, 12 enums, 16 triggers, 5 vistas, RLS.
  Cobertura: ubigeo INEI/RENIEC, locales y mesas, usuarios+RBAC, organizaciones y
  candidatos, actas con trazabilidad (`acta_eventos`), auditoría de cambios en actas
  via trigger `trg_actas_auditar`, validación de contabilización en base
  (`fn_validar_contabilizacion`), índices por `numero_mesa` y `ubigeo`.
- `backend/sql/modulo_campo_arequipa.sql` — semáforo de cobertura
  (`v_cobertura_locales`, `v_cobertura_distrito`), check-in GPS con Haversine
  (`fn_checkin_en_radio`, `checkins_personero`), incidencias de campo con triaje,
  prioridad (BAJA/MEDIA/ALTA/CRITICA), estado y adjuntos, y RLS de campo.

**Nuevo — `backend/sql/migracion_jerarquia_completa.sql`** (cierra la jerarquía del brief):
1. Roles `COORD_LOCAL` y `DELEGADO_MESA` en `rol_usuario` (idempotente).
   Jerarquía resultante: `SUPER_ADMIN → COORD_PROVINCIAL → RESPONSABLE_DISTRITAL
   (= COORD_DISTRITAL) → COORD_LOCAL → DELEGADO_MESA (= PERSONERO)`.
2. `locales_votacion.coordinador_local_id` (quién dirige cada centro educativo).
3. `usuario_alcance.local_id` (alcance acotado a un local) + índices parciales.
4. `fn_locales_del_usuario()` — alcance ubigeo jerárquico o por local.
5. `v_delegados_mesa` — matriz de delegados por local/mesa con estado y último check-in
   (panel de asignación del coordinador distrital/local).
6. RLS extendida (`pol_asig_alcance`, `pol_incid_alcance`) para que un `COORD_LOCAL`
   vea y asigne delegados solo de su centro educativo (también aplicada en
   `modulo_campo_arequipa.sql` para que re-ejecutarlo no regrese).
7. Seed demo: coordinador de local y delegado sobre el local 023001 (Paucarpata).

**Backend alineado:** `ROLES_SISTEMA` y `ROLES_CAPTURA` ya incluyen los roles nuevos
(`app/core/models.py`, `app/routers/actas.py`). Los `UNIQUE (mesa_id, tipo_eleccion)`
y el hash SHA-256 de foto garantizan idempotencia ante reintentos de la cola offline.

**Gestión de usuarios (`backend/app/routers/auth.py`, `frontend/src/components/UsuariosPanel.tsx`):**
- `POST /api/auth/usuarios` — alta jerárquica: SUPER_ADMIN crea cualquier rol;
  COORD_PROVINCIAL crea hacia abajo (distrital/local/personero) y
  RESPONSABLE_DISTRITAL crea local/personero, siempre dentro de su alcance
  (prefijo de ubigeo). DNI/email únicos, clave mínima 8, `debe_cambiar_clave`.
- `PATCH /api/auth/usuarios/{id}` — teléfono, activo/inactivo y alcance
  (sin auto-desactivación; SUPER_ADMIN sólo tocado por SUPER_ADMIN).
- `POST /api/auth/usuarios/{id}/clave` — restablece clave y desbloquea.
- `GET /api/auth/usuarios` — vista según rol (todos / equipo / uno mismo).
- Panel "👥 Usuarios" en el header del dashboard (sólo roles gestores).
- `POST /api/actas/movil` exige mesa en padrón (404), valida alcance contra el
  local real (403 antes que 409) y acepta votos por posición o por partido;
  R4 = votos ya persistidos de ese nivel (el padrón ya no cuenta como duplicado).
- `GET /api/actas/plantilla` también exige alcance: el personero sólo abre
  mesas de su jurisdicción y puede cargar sus actas (plantilla → validar → móvil).

**Orden de aplicación:**
```bash
psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/sql/schema_arequipa.sql
psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/sql/modulo_campo_arequipa.sql
psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/sql/migracion_jerarquia_completa.sql
```
> Ejecutar el último **sin** envolverlo en una sola transacción (los `ALTER TYPE
> ADD VALUE` quedan visibles entre sentencias).

---

## Entregable 2 — Estructura JSON de ingesta de candidatos

**Nuevo — `docs/schemas/ingesta-jornada-v1.schema.json`** (JSON Schema draft-07).
Un solo contrato para el endpoint `POST /api/ingesta/jornada` que recibe la
información oficial antes de la jornada:

- **`jornada`** — cabecera: fecha, departamento (const `AREQUIPA`), fuentes
  (JNE/ONPE/RENIEC por bloque, trazabilidad de la ingesta).
- **`nomina`** — organizaciones políticas y candidatos inscritos **por ámbito**
  (`REGIONAL`=040000, `PROVINCIAL`, `DISTRITAL`), en el orden físico de la columna
  del acta (`numero`). Candidato: `dni` como clave natural, `cargo`, `estado`
  (solo `INSCRITO` se carga como oferta votable). `ubigeo` INEI canónico con
  `ubigeo_reniec` opcional (85/109 distritos de Arequipa difieren entre INEI y RENIEC).
- **`distribucion`** — locales de votación con su padrón de **mesas** y
  `electores_habiles` (tope de la regla R2). Hoy esta parte viaja en CSV del
  `onpe-scraper`; el esquema la unifica a JSON.

**Ejemplo:** `docs/schemas/ejemplos/ingesta-arequipa-ejemplo.json` (3 ámbitos,
3 organizaciones, 2 locales con mesas). Archivo **ilustrativo** (los nombres no son
datos oficiales; el crawler real produce el payload desde las APIs públicas del JNE/ONPE).

Relación con lo existente: `crawler-onpe-v1.schema.json` (payload del crawler del JNE)
y `plantilla-acta-v1.schema.json` (lo que el backend sirve al formulario para
construir el acta digital). La ingesta es el superset de nómina + distribución.

**Implementación del endpoint — `backend/app/routers/ingesta.py`:**
- `POST /api/ingesta/jornada` (roles `SUPER_ADMIN`, `COORD_PROVINCIAL` con
  verificación de alcance sobre todos los ubigeos del documento). Idempotente:
  upsert de candidatos por `(ubigeo, party)` preservando el id (no rompe
  `records.candidate_id`), upsert de locales por `(ubigeo, nombre)` y creación
  de mesas por `numero_mesa` único (las existentes se cuentan y no se tocan).
- `GET /api/ingesta/estado` — cobertura actual (ámbitos con oferta, locales, mesas).
- El padrón de electores de cada mesa queda en `tables.electores_habiles`
  (columna nueva del prototipo, espejo de `mesas.electores_habiles` del esquema
  PostgreSQL): `GET /api/actas/plantilla` lo devuelve y el formulario valida R2.

**Padrón regional — `backend/app/seed_arequipa.py`:**
- Genera locales y mesas para los **109 distritos** del seed ubigeo oficial
  (221 locales, 1302 mesas numeradas desde 100001, electores 180–300).
- Cobertura resultante: 15 regionales, 75 provinciales (8 ámbitos), 478
  distritales (101 ámbitos), 226 locales, 1304 mesas.
- Los 8 distritos **sin** oferta distrital son las capitales provinciales
  (cercado: Arequipa, Camaná, Caravelí, Aplao, Chivay, Chuquibamba, Mollendo,
  Cotahuasi), donde no hay elección distrital: el formulario muestra sólo
  PROVINCIAL + REGIONAL, que es lo electoralmente correcto.

---

## Entregable 3 — Componente frontend (React + Tailwind + TypeScript)

**Nuevo — `frontend/src/components/VotosMesaForm.tsx`** — formulario de
"Ingreso y Validación de Votos por Mesa" que cumple el brief en un solo componente:

| Requisito del brief | Implementación |
|---|---|
| Soporte multi-nivel Distrital/Provincial/Regional | Pestañas por elección; **una acta por nivel** vía `POST /api/actas/movil` (consistente con `UNIQUE (mesa_id, tipo_eleccion)`) |
| Plantilla dinámica con lista oficial de candidatos | Consume `GET /api/actas/plantilla?numero_mesa=` (contrato `plantilla-acta-v1.schema.json`), columnas A/B por elección |
| Validación matemática en cliente | En vivo, por columna: `Σ votos + blancos + nulos + impugnados = total votantes` (R1) y tope contra electores hábiles (R2), espejo de `acta_validator.py` |
| Carga/escaneo del acta física | Input `capture` con preview y **hash SHA-256** (candado anti-duplicidad `fn_evitar_foto_duplicada`); flags `ilegible` (R6) y `firmas` (R7) |
| Registro de observaciones | Campo libre que viaja en el payload (`acta_observaciones` en la capa PostgreSQL; el endpoint del prototipo tolera campos extra) |
| Búsqueda por mesa | Buscador de 6 dígitos; rechaza mesa inexistente (404) y acta duplicada no editable (R4) |
| Cola offline | Reutiliza la cola `cola_actas` de la PWA ante fallo de transporte |

Verificación: `cd frontend && npx tsc -b` — el componente compila sin errores.
(Los errores de `tsc -b` existentes pertenecen a archivos previos del prototipo,
no a este componente.)

Base de estilos: Tailwind v4 con la paleta institucional del repositorio
(`#002B66`/`#003366`), mismas convenciones que `ActaIngresoForm.tsx`.

---

## Entregable 4 — Arquitectura de alta disponibilidad

Documento completo en **`docs/ALTA_DISPONIBILIDAD_DIA_D.md`**. Resumen ejecutivo:

- **Perfil de carga honesto:** ~10.000 actas (3 por mesa × ~3.400 mesas), pico de
  30–40 escrituras/s entre 16:00–22:00. Una instancia PostgreSQL mediana basta para
  las escrituras; **el riesgo del día D es la disponibilidad, no el throughput**.
- **Topología (AWS, una región multi-AZ):** Route 53 → CloudFront+WAF (PWA/fotos) →
  ALB → ECS Fargate (ASG 2→4 instancias por CPU) → PgBouncer (`transaction`) →
  RDS PostgreSQL 15 multi-AZ (`synchronous_commit=on`, failover 60–120 s) + réplica
  de lectura para `/api/analytics/*` → S3 versionado para fotos (URLs prefirmadas).
- **Decisiones de resistencia:** toda escritura idempotente
  (`UNIQUE (mesa_id, tipo_eleccion)` + hash SHA-256), cola offline en cliente,
  backpressure `503 + Retry-After`, fotos fuera del proceso API, lecturas desde
  réplica. **Sin** sharding, sin microservicios, sin caché de resultados.
- **Contingencias y runbook:** falla de instancia (auto <3 min), failover DB
  (auto), CDN caída (sin impacto por PWA offline), régimen región indisponible
  (RPO ≤5 min, RTO ~30 min). Runbook T-7/T-1/Día D/T+1.
- **Coste orientativo del evento (72 h): ~USD 610** + infraestructura base.

---

## Sistema v1 — Registro, OCR y Cómputo (contrato OpenAPI estable)

Archivos etiquetados del paquete (réplica de estándares ONPE):

| Archivo | Contenido |
|---|---|
| `backend/sql/schema.sql` | DDL productivo PostgreSQL/Supabase: extensión `pgcrypto` (UUID), `ubigeo`, `organizaciones_politicas`, `mesas`, `actas`, `detalle_votos_acta`, enums `estado_acta` (NORMAL/OBSERVADA/IMPUGNADA) y `tipo_eleccion`, FKs, CHECKs `votos >= 0`, UNIQUE por mesa y elección, trigger de auditoría y `vista_resultados_distritales` + `fn_validar_acta` (R1/R2) |
| `backend/app/routers/v1.py` (`main.py` lo monta) | `POST /api/v1/actas/registrar` (valida R1/R2, estado NORMAL/OBSERVADA/IMPUGNADA, sólo NORMAL contabiliza), `POST /api/v1/actas/ocr-preview` (OpenCV grayscale+Otsu+Tesseract, 503 si falta el motor), `GET /api/v1/resultados/resumen` (KPIs + partidos) |
| `frontend/src/components/FormularioActa.tsx` | Réplica ONPE: encabezado ubigeo/mesa/hábiles, pestañas por nivel, tabla de partidos + filas fijas (blancos/nulos/impugnación), validación reactiva con alerta roja e inhibición si `total > hábiles`, registro a `/api/v1/actas/registrar` |
| `frontend/src/Dashboard.tsx` | KPIs (procesadas, observadas, % avance, % participación) + barras por organización (vista "📊 Cómputo" del header) |
| `backend/seed.py` | Mocks JSON (ubigeos/mesas/partidos, mesas 900001+) + publicación a `/api/ingesta/jornada` |

Además: botón **⏻ Salir** en el header (cierra sesión y recarga). Nota de
operación: el `venv` se creó desde el Python de QGIS; con `--reload` el
respaldo genera un gemelo QGIS. El backend corre sin `--reload`
(reiniciar tras cambios de código).

## Paquete Provincia de Arequipa (orden oficial R → P → D)

- `backend/sql/schema.sql` §11–§12: INSERTs de los 29 distritos (040101–040129)
  y `vista_computo_arequipa` (filtrable por nivel/distrito, columna `orden_nivel`).
- `GET /api/v1/ubigeo/distritos` (29 con mesas en padrón, acotado a alcance) y
  `GET /api/v1/mesas?ubigeo=` (padrón del distrito para el selector).
- `GET /api/actas/plantilla` responde en orden oficial REGIONAL→PROVINCIAL→DISTRITAL.
- `frontend/src/components/FormularioActaElectoral.tsx`: selector de distrito +
  picker de mesas, dualidad candidato+agrupación+símbolo por tarjeta, inputs
  táctiles grandes, % relativo en vivo, pie de acta obligatorio, total emitido
  automático (+override del papel), banner rojo ACTA OBSERVADA e inhibición R2,
  avance 1/2/3 y auto-avance de pestaña. Montado en el botón "📋 Acta ONPE".
- `backend/seed_data.py`: mocks de provincia (mesas 910xxx, `--distritos` filtro).
- Cómputo específico (`GET /v1/resultados/resumen` + `Dashboard.tsx`): desglose
  válidos/blancos/nulos/impugnados/emitidos/hábiles, barra de estados
  (contabilizadas/observadas/pendientes), avance por distrito (109, más
  atrasados primero) y tabla de observadas (mesa/local/distrito); sólo
  contabilizadas entran al cómputo.
- Catálogo regional (`app/core/ubigeo_catalogo.py`, 8 provincias / 109 distritos):
  `GET /api/v1/ubigeo/provincias` y `GET /api/v1/ubigeo/distritos?provincia=`
  (acepta nombre o ubigeo); selectores agrupados por provincia en dashboard
  y formulario.

## Campo — presencia del personero y check de validación

- `backend/app/routers/campo.py`: `POST /campo/asignar` (coordinador asigna
  personero a mesa, idempotente), `POST /campo/checkin` (GPS + Haversine 300 m;
  dentro → PRESENTE, fuera → intento auditado con distancia),
  `GET /campo/mi-estado` (asignaciones, presencia hoy) y
  `GET /actas/checklist` (pre-vuelo: padrón, presencia, oferta
  REGIONAL/PROVINCIAL/DISTRITAL, duplicados, `puede_registrar`).
- `POST /movil` y `/v1/actas/registrar` exigen check-in válido al
  PERSONERO/DELEGADO_MESA (403 sin presencia; supervisores exentos).
  Comparación en UTC (la base guarda UTC, el servidor UTC-5).
- `FormularioActaElectoral`: sección Check de validación (✓/✗ por ítem) +
  botón "📍 Registrar check-in" (geolocalización del navegador); el envío se
  inhibe hasta el check verde.
- El acta ya trae campos por partido y nivel (plantilla: dualidad
  candidato+agrupación+símbolo y oferta 15/10/8 verificada en Cocachacra).
- `FormularioPersonero.tsx` (sección Actas → "🧾 Registro rápido" y MiPanel):
  wizard Mesa → Nivel → Votos (partidos + blancos + nulos + impugnados/
  visados + total automático + banner R2) con check-in integrado; las tres
  capas (plantilla, checklist, registrar/movil) exigen mesa asignada +
  presencia al personero.

## RBAC visual por jerarquía + pestaña Personeros

- `venues_en_alcance`: PERSONERO/DELEGADO_MESA ven SÓLO sus locales asignados
  (resumen, mapa, cobertura y revisión ya no muestran datos regionales).
- Plantilla exige mesa propia al personero (403 mesa ajena).
- `GET /api/v1/campo/personeros` (gestores, acotado a alcance): equipo con
  mesas, estado, último check-in y presencia → pestaña **🦺 Personeros**.
- Portada por rol: el personero entra a **MiPanel** (sus mesas, check-in,
  registro) sin dashboard general, cómputo, usuarios ni actas globales;
  `FormularioActaElectoral` acepta `mesaInicial` para registro directo.
- Nombres de candidatos en `GET /v1/resultados/resumen` (campo `candidato`) y
  en el cómputo (agregado por agrupación, % recalculado).

## Rediseño UX — semáforo e interfaces

- Kit compartido `frontend/src/components/ui.tsx` (Boton táctil 44px,
  Tarjeta, Alerta, Cargando, Vacio, Insignia, Barra, Campo, Contacto con
  llamada + WhatsApp): una sola voz visual en todo el sistema.
- Teléfonos visibles y contactables: `/api/analytics/cobertura` incluye el
  equipo por local (nombre, teléfono, estado); el semáforo muestra hasta 3
  contactos por local y la pestaña Personeros usa tap-to-call + WhatsApp.
- `CoberturaPanel` reestructurado: pregunta "¿Dónde falta gente?", 3 tarjetas
  grandes tocables (Listos/A medias/Sin cubrir con conteos), buscador de
  colegio/sector/distrito, filtro por distrito (nuevo `ubigeo` en
  `/api/analytics/cobertura`), vista Lista (por defecto) o Mapa, tarjetas con
  barra de progreso y mesas críticas, leyenda en lenguaje claro.
- `MiPanel` (botones grandes "Llegué al local" / "Registrar acta", alertas y
  vacíos del kit), `PersonerosPanel` y `UsuariosPanel` (formularios y alertas
  del kit), `Actas` (botones del kit) y `FormularioActaElectoral` (barra de
  acción fija con Σ/hábiles y registro siempre a la mano).
- Dashboard principal por secciones: **🗳 Votos** (tabs R→P→D, avance, top-2,
  barras por partido) y **🦺 Personeros** (semáforo, mapa de locales y acceso
  a gestión del equipo). Nada mezclado.
- Dashboard ejecutivo: header institucional (marca, navegación, EN VIVO,
  chip de usuario con insignia por rol, salir), alertas operativas
  (observadas/sin cubrir con enlaces), 5 KPIs (mesas, contabilizadas,
  observadas, avance, sin cubrir), 4 accesos directos por rol y barra de
  estado (API, ámbito, versión).
- Top-2 estilo Material (degradado del partido, % grande, foto + **logo del
  partido**, dualidad candidato+agrupación, barra) y barras por agrupación
  con **nombre de candidato**, logo en baldosa, ranking numerado y degradados.
- Armazón Material global (`MaterialShell`): sidebar oscuro con navegación
  por rol (Panel/Actas/Cómputo/Personeros/Usuarios), topbar fija con título
  de vista + EN VIVO, drawer en móvil, usuario e insignia al pie con salir;
  el personero usa el mismo shell con "Mis mesas". Login con tarjeta Material
  (franja institucional, campos táctiles). Vistas (actas/usuarios/cómputo/
  personeros) renderizan como tarjetas de elevación dentro del shell.
- Iconografía Lucide en sidebar, secciones, KPIs y alertas (sin emojis en
  navegación); KPIs con baldosa de color por indicador; grises normalizados
  a slate; accesos duplicados eliminados (la navegación vive en el sidebar).

## Resultados por agrupación — todos los distritos

- `GET /api/analytics/summary` acepta `ubigeo` opcional: con distrito, la oferta
  es la de ESE distrito/provincia/región (antes mezclaba 478 candidatos de 101
  distritos); fuera de alcance → 403. Responde `ubigeo` para la UI.
- Dashboard principal: selector de distrito (29, acotado a alcance) + "Todos",
  tabs en orden oficial R→P→D, gráfico **agregado por partido** (478 filas →
  33 agrupaciones), top-2 nominal con foto, y títulos dinámicos
  (adiós hardcode "Paucarpata").
- `seed_arequipa.py` ahora idempotente de verdad: numeración secuencial
  determinista (re-ejecuciones: 0 locales / 0 mesas nuevas) y `total_tables`
  recalculado en una pasada (corrige progreso y conteo de mesas del resumen).

## Orden de adopción recomendado

1. **Ingesta (E2)** antes de la jornada: cargar nómina y distribución (la mesa sin
   padrón no puede validar R2).
2. **Migración de jerarquía (E1)** y alta de coordinadores/delegados.
3. **Formulario (E3)** montado en `frontend/src/Actas.tsx` reemplazando el prototipo.
4. **HA (E4)**: ensayo de carga, smoke test y runbook según la ventana.

## Deuda técnica conocida (fuera del alcance de estos entregables)

- OCR real (hoy `app/services/vision.py` es simulado) y soporte PDF en `/ocr`.
- Push en tiempo real del dashboard (SSE sobre `LISTEN/NOTIFY` de `acta_eventos`),
  ver `docs/ARQUITECTURA_AREQUIPA.md` §5.4 y §9.
- Unificación de los modelos de datos del prototipo (SQLAlchemy SQLite) con el
  esquema PostgreSQL (`docs/ARQUITECTURA_AREQUIPA.md` §9, P2).