# Reglas de Negocio — Cómputo Electoral y Control de Actas (Arequipa)

Documento de referencia del motor de reglas que decide si un acta **entra al
cómputo** o queda **observada**. Implementado en tres capas que dicen exactamente
lo mismo:

| Capa | Archivo | Rol |
|---|---|---|
| PWA móvil (JS) | `frontend/public/actas-movil.html` | Validación en tiempo real mientras se digita |
| Backend (Python) | `backend/app/services/acta_validator.py` | Autoridad: `POST /api/actas/validar` y `POST /api/actas/movil` |
| Base de datos (PostgreSQL) | `backend/sql/schema_arequipa.sql` | Última defensa: trigger `fn_validar_contabilizacion` |

---

## 1. Principio rector: el dato se guarda, lo contabilizado se prueba

El sistema **no rechaza** un acta que no cuadra: la almacena tal como está escrita
en el papel y la marca `OBSERVADA`. Lo que nunca ocurre es **contabilizarla** sin
que las reglas se cumplan.

Esa distinción es la que permite operar en un local de votación sin señal y sin
perder información: el digitador registra lo que ve, el sistema lo audita, y un
responsable resuelve la diferencia con sustento antes de que el voto cuente.

> Por eso las reglas matemáticas **no** son `CHECK` de la tabla `actas`
> (bloquearían guardar la realidad). Se aplican en el validador y en el trigger
> que dispara la transición a `CONTABILIZADA`.

---

## 2. Catálogo de reglas

| Código | Regla | Severidad | Efecto |
|---|---|---|---|
| `R1_SUMA_VOTOS` | `Σ votos por organización + blancos + nulos + impugnados = total de votantes` (por columna del acta) | BLOQUEANTE | El acta queda `OBSERVADA`; el formulario no se envía |
| `R2_TOPE_ELECTORES` | `total de votantes ≤ electores hábiles de la mesa` | BLOQUEANTE | `OBSERVADA` (posible error de lectura del padrón o de la mesa) |
| `R3_COLUMNAS_INCOHERENTES` | Los totales de las columnas A y B del mismo acta coinciden | ADVERTENCIA | Solo avisa: el total oficial sale de la columna A |
| `R4_ACTA_DUPLICADA` | Una mesa tiene una sola acta por tipo de elección, y una foto pertenece a una sola acta | BLOQUEANTE | Solo un `COORD_PROVINCIAL` puede reemplazarla |
| `R5_FOTO_AUSENTE` | Existe evidencia fotográfica del acta | ADVERTENCIA | Se contabiliza, pero queda pendiente que el `PERSONERO` suba la foto |
| `R6_ILEGIBLE` | No hay campos declarados ilegibles | BLOQUEANTE | Requiere cotejo previo |
| `R7_FIRMA_FALTANTE` | El acta trae las firmas de personeros | ADVERTENCIA | Insumo para el JEE |
| `R8_DIFERENCIA_MANUAL` | Diferencia declarada al cotejar con el papel | ADVERTENCIA | Se registra como observación con sustento |

### 2.1 `R1` — consistencia aritmética (la regla central)

```
Total votantes = Σ votos por organización política
               + votos en blanco
               + votos nulos
               + votos impugnados
```

Se evalúa **por columna**, porque el acta física municipal tiene dos columnas
independientes: **A** (alcalde / gobernador y vice) y **B** (regidores /
consejeros). Cada una tiene sus propios blancos, nulos, impugnados y total.

> **Consejero Regional (nivel `consejero`).** El Consejo Regional se elige
> **por provincia** — cada provincia es una circunscripción con su propia
> columna de CONSEJEROS en el acta y sus propios curules (Res. JNE: Arequipa 6;
> Castilla, Caylloma y La Unión 2; Camaná, Caravelí, Condesuyos e Islay 1;
> **16 en total**). El voto es por **lista cerrada**, sin voto preferencial:
> los escaños se reparten por **cifra repartidora (d'Hondt)** cuando la
> provincia elige 2 o más, y entran los candidatos según el **orden de la
> lista**. En el sistema es un nivel propio (`candidate_type = 'consejero'`,
> tabla `consejero_candidates` con ubigeo provincial): los votos de la columna
> CONSEJEROS **no** se mezclan con los del gobernador (`regional`), ni los de
> una provincia con otra. El cómputo muestra el ganador y los escaños
> proyectados de cada provincia en
> `GET /api/v1/resultados/resumen?tipo_eleccion=CONSEJERO` (campo
> `consejeros[]`); la proyección d'Hondt es indicativa, el resultado oficial
> lo declara el JNE.

La diferencia se reporta con signo: `diferencia = total_declarado − suma_calculada`.
Un `+23` significa que el acta dice 23 votantes más de los que suman sus casillas;
un `−5`, que hay 5 votos sin casilla (típico de una casilla omitida al digitar).

**Basta que una columna descuadre para que el acta no sea consistente**, aunque la
principal cuadre. Las tres capas lo aplican así: la PWA deshabilita el envío, el
validador de la API devuelve `consistente: false` con el detalle en `descuadres`,
y el trigger `fn_validar_contabilizacion` recalcula con `fn_descuadres_acta()` y
rechaza la fila nombrándole la columna que falla.

La cabecera de `actas` sigue otro criterio: `total_votantes`, `votos_validos` y
`diferencia_suma` resumen la **columna principal** (la del cargo de mayor
jerarquía), porque es la que fija el resultado oficial de la mesa. Por eso un
descuadre sólo en la columna B deja `diferencia_suma = 0` y `validacion = false` a
la vez: no es una contradicción, son dos preguntas distintas. Para ver el detalle
por columna está `fn_descuadres_acta(acta_id)` y la vista `v_actas_observadas`
expone `columnas_descuadradas` y `descuadres`.

### 2.2 `R2` — tope del padrón

El total de votantes no puede superar los electores hábiles de la mesa. Se toma
de `mesas.electores_habiles` (padrón ONPE), no de un dato digitado, salvo cuando
el padrón no está cargado, caso en el que el formulario pide el dato y lo deja
consignado en el acta.

### 2.3 `R3` — por qué una diferencia entre columnas **no** bloquea

Un elector puede marcar válidamente su voto para alcalde y anular la columna de
regidores (o dejar la segunda columna en blanco). Por eso el total de votantes de
la columna B puede ser legítimamente menor. El sistema lo trata como
**advertencia** y usa siempre la columna A como el total oficial de la mesa.
Cuando la diferencia es grande, el coordinador la revisa; si no hay sustento, no
se contabiliza.

### 2.4 `R4` — anti-duplicidad (dos candados)

1. **En base de datos**: `UNIQUE (mesa_id, tipo_eleccion)` en `actas`. La misma
   mesa no puede tener dos actas de la misma elección.
2. **Sobre la evidencia**: `actas.foto_hash_sha256` es único y el trigger
   `fn_evitar_foto_duplicada` rechaza adjuntos con hash ya usado. Subir la misma
   foto dos veces para mesas distintas es el intento de duplicación más común
   (mesa caminada dos veces, actas mezcladas).

---

## 3. Ciclo de vida del acta

```
PENDIENTE ──digitación──▶ DIGITADA ──reglas OK──▶ CONTABILIZADA
                             │
                             └──reglas BLOQUEANTES──▶ OBSERVADA ──resolución──▶ CONTABILIZADA
                                                          │
                                                          └──irresoluble──▶ ANULADA (+ nueva acta)
```

* `DIGITADA`: cuadra y no tiene bloqueantes. Queda lista para contabilizar.
* `OBSERVADA`: tiene al menos una observación bloqueante abierta o diferencia ≠ 0.
* `CONTABILIZADA`: suma verificada, sin observaciones bloqueantes, con validador,
  fecha y resultado consistente (lo exige el `CHECK actas_contabilizada_completa`).
* `ANULADA`: el acta no es válida (mesa anulada, acta ilegible sin sustituto,
  error irreparable). Nunca se borra: se anula y se registra la nueva.

Toda transición se escribe automáticamente en `acta_eventos` (trigger
`trg_actas_auditar`) con usuario, estado anterior/nuevo y detalle JSON.

---

## 4. Resolución de actas observadas (flujo por roles)

La resolución es descentralizada y escalonada: cada nivel cierra lo que le
corresponde y lo demás escala con sustento.

### Nivel 1 — `RESPONSABLE_DISTRITAL` (mismo distrito)
Corrige **errores de digitación** contra la fotografía del acta que él mismo
subió. Casos típicos: casilla omitida, número traspapelado (`6`↔`8`), blancos
mal ubicados.
*Requisito:* adjuntar la corrección con la foto visible; el cambio queda
registrado como `RECALCULADA` en `acta_eventos`.

### Nivel 2 — `COORD_PROVINCIAL` (toda su provincia)
Resuelve cuando el acta física **no cuadra de origen**:
* el acta llega con error aritmético del propio papel;
* `R2` por padrón desactualizado o mesa fusionada;
* `R4` duplicidad: anula el acta sobrante y conserva la correcta;
* `R6` ilegibilidad: coteja con la copia del JEE o con el acta de la otra mesa.
*Requisito:* `acta_observaciones.sustento` con la fuente usada, y `resolucion_final`
en el acta. Sin sustento el sistema no permite cerrar la observación
(`CHECK observacion_resuelta_completa`).

### Nivel 3 — `SUPER_ADMIN` (regional)
Solo lo excepcional: actas siniestradas (incendio, extravío), resoluciones del
JEE que cambian lo contabilizado, o correcciones masivas por una regla mal
aplicada. Toda intervención queda asentada y visible en el dashboard regional.

### Escalamiento y plazos recomendados
| Situación | Responsable | Plazo sugerido |
|---|---|---|
| Error de digitación con foto clara | RESPONSABLE_DISTRITAL | mismo día |
| Diferencia matemática del papel | COORD_PROVINCIAL | 24 h |
| Duplicidad de mesa | COORD_PROVINCIAL | 24 h |
| Acta ilegible / mesa siniestrada | SUPER_ADMIN | 48 h |
| Observación del JEE | SUPER_ADMIN | según acta del JEE |

---

## 5. Cómo se protege la integridad del conteo

1. **No se reescribe la historia.** Corregir votos genera un nuevo registro de
   `acta_eventos` con autor y fecha; el estado anterior queda en la bitácora.
2. **Un acta CONTABILIZADA no puede quedar sin validador**: lo impide un `CHECK`.
3. **Contabilizar un acta inconsistente falla en la base de datos**, aunque el
   código de la aplicación tuviera un error. El trigger recalcula el cuadre por
   su cuenta, columna por columna, sin fiarse de la bandera `validacion` de la
   fila:
   `ERROR: ACTA_INCONSISTENTE: el acta 12 no cuadra en 1 columna(s): REGIDORES
   (diferencia 160 votos)`.
4. **Un acta CONTABILIZADA tampoco puede recibir observaciones nuevas sin
   reabrirse**: `trg_observaciones_no_sobre_contabilizada` rechaza un bloqueante
   sobre un acta ya contabilizada (`ACTA_YA_CONTABILIZADA`). Sin eso el conteo
   quedaba cerrado mientras la cola de revisión la seguía señalando, y el
   tablero mostraba dos verdades a la vez. El camino correcto es revertir el
   estado a `OBSERVADA` — transición que queda auditada en `acta_eventos` — y
   después registrar la observación.
5. **Aislamiento territorial (RLS)** sobre `actas`: cada usuario ve solo las actas
   de su ámbito (`usuario_alcance`), y `SUPER_ADMIN` ve toda la región. Es defensa
   en profundidad — el backend igualmente valida el alcance.
6. **Cola local en la PWA**: si no hay señal en el local, el acta se guarda en el
   dispositivo con su hash de foto y se sincroniza al recuperar conexión. La
   validación se repite en el servidor: la PWA no es fuente de verdad.

---

## 6. Decisiones de diseño que conviene conocer

* **El voto se cuenta por organización política.** En un acta municipal el
  elector marca una vez al partido para alcalde y una vez para regidores; no se
  vota regidor por regidor. Por eso `detalle_votos_acta` referencia
  `organizacion_id` (y opcionalmente `candidato_id`, para las columnas de un solo
  cargo, que habilitan el ranking nominal y un eventual voto preferencial).
* **INI EI ≠ RENIEC.** Paucarpata es `040112` (INEI) y `040109` (RENIEC); en
  Arequipa 85 de los 109 distritos difieren. El ubigeo canónico del sistema es el
  INEI, se guarda también el RENIEC, y el crawler del JNE usa **RENIEC** porque es
  el que responde su API.
* **Los datos del padrón, locales y mesas son de demostración**
  (`frontend/public/data/locales_mesas_demo.json` y el seed SQL). En producción se
  cargan del padrón oficial de la ONPE antes de la jornada.
* **Sin OCR automático en esta entrega**: la digitación es manual y asistida por
  las reglas. El OCR (`app/services/vision.py`) puede precargar casillas, pero el
  acta siempre pasa por la validación aquí descrita.

## 7. Verificación ejecutable

```bash
cd backend && python tests/test_acta_validator.py        # 14 pruebas de las reglas
cd backend && python tests/test_importar_candidatos.py   # importador (unidades + integración real)
cd backend && python tests/test_auth.py                  # 20 pruebas de auth/RBAC/alcance
cd backend && python tools/validate_schema.py            # coherencia estructural del DDL
```

Las dos capas que no se pueden falsificar se prueban contra un PostgreSQL real
(ambos scripts corren en una transacción que termina en `ROLLBACK`):

```bash
psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/tests/sql/actas_integracion.sql
psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/tests/sql/actas_hostil.sql
```

`actas_integracion.sql` recorre el camino correcto (41 comprobaciones: acta
consistente que entra, descuadres y excesos de padrón que no, duplicidad, vistas,
RLS). `actas_hostil.sql` intenta **esquivar** las reglas por vías alternas
(bandera `validacion` forzada a mano, descuadre sólo en la columna secundaria,
detalle tocado después de contabilizar, observación colgada a un acta cerrada) y
exige que la base rechace todos los intentos.

Y de punta a punta, con el backend arriba:

```bash
curl -X POST localhost:8000/api/actas/validar -H 'Content-Type: application/json' -d @acta.json
curl -X POST localhost:8000/api/actas/movil   -H 'Content-Type: application/json' -d @acta.json
```

`/api/actas/validar` solo evalúa (lo usa la PWA en cada tecleo);
`/api/actas/movil` evalúa y **solo si el acta cuadra** la contabiliza; si no,
responde `409` con los hallazgos y el acta queda observada.

## 8. Autenticación, roles y alcance territorial

La API es privada: **toda** ruta exige `Authorization: Bearer <token>` salvo
`/api/health` y `POST /api/auth/login`. Las credenciales se validan con
**bcrypt** (cost 12, formato `$2a$/$2b$`, el mismo que genera el seed SQL con
`pgcrypto gen_salt('bf', 12)`).

**Sesiones, no JWT stateless.** El login emite un token opaco de 256 bits que
se guarda en la base **solo como SHA-256** (una fuga de la base no revela
tokens válidos), con expiración a 12 h. `POST /api/auth/refresh` rota el token
(revoca y emite otro); `POST /api/auth/logout` lo revoca. 5 intentos fallidos
en 15 min bloquean la cuenta 15 min (HTTP 423). Cada intento queda en la
bitácora `accesos_log` (email, exitoso, ip, user-agent, detalle).

**Los cuatro roles** (mismos que el esquema PostgreSQL):

| Rol | Puede |
|---|---|
| `SUPER_ADMIN` | Todo: administra usuarios y consulta la bitácora |
| `COORD_PROVINCIAL` | Supervisa los locales de **su provincia y sus distritos** |
| `RESPONSABLE_DISTRITAL` | Supervisa y corrige actas de su distrito |
| `PERSONERO` | Carga actas de su distrito; no corrige (PUT → 403) |

**El alcance territorial es jerárquico**: el ubigeo `040100` (provincia)
alcanza a todos los locales `0401xx`; un distrital solo ve su `040112`. Los
endpoints de lectura (`/api/actas/*`, `/api/analytics/*`) filtran por ese
alcance y la escritura lo valida antes de tocar la fila (403 si el local queda
fuera).

**Contexto RLS por petición**: cada petición autenticada ejecuta
`set_config('app.usuario_id', …, true)` y `set_config('app.rol_actual', …, true)`
en su transacción; es lo que las políticas RLS del esquema PostgreSQL leen para
la defensa en profundidad por fila. En el prototipo SQLite es un no-op
registrado; con PostgreSQL real aplica.

Usuarios demo (contraseñas en `backend/sql/seed_auth_arequipa.sql`, el seed del
prototipo usa las mismas):

| Rol | Email | Contraseña | Alcance |
|---|---|---|---|
| `SUPER_ADMIN` | `admin@computoarequipa.gob.pe` | `Admin.Arequipa2026` | Toda la región |
| `COORD_PROVINCIAL` | `coord.arequipa@computoarequipa.gob.pe` | `Coord.Arequipa2026` | Provincia Arequipa (`040100`) |
| `COORD_PROVINCIAL` | `coord.caylloma@computoarequipa.gob.pe` | `Coord.Caylloma2026` | Provincia Caylloma (`040500`) |
| `RESPONSABLE_DISTRITAL` | `resp.paucarpata@computoarequipa.gob.pe` | `Distrital.Paucarpata2026` | Paucarpata (`040112`) |
| `RESPONSABLE_DISTRITAL` | `resp.yanahuara@computoarequipa.gob.pe` | `Distrital.Yanahuara2026` | Yanahuara (`040126`) |
| `PERSONERO` | `personero.paucarpata@computoarequipa.gob.pe` | `Personero.Paucarpata2026` | Paucarpata (`040112`) |

**Pruebas** (`python tests/test_auth.py`, 20 casos sobre base temporal, sin red):
bcrypt y tokens, login/401/423, 403 por rol, rotación de token, revocación,
jerarquía de alcance (Caylloma no ve Paucarpata), auditoría en `accesos_log` y
hash-only de tokens. La PWA (`actas-movil.html`) y el dashboard React piden
login y adjuntan `Authorization` en cada llamada.
