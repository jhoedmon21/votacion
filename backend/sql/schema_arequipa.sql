-- ============================================================================
--  Plataforma de Cómputo Electoral y Control de Actas — Región Arequipa
--  Motor: PostgreSQL 15+ (compatible 13/14). Requiere pgcrypto y citext.
--
--  Uso:
--      createdb computo_arequipa
--      psql -d computo_arequipa -f backend/sql/schema_arequipa.sql
--
--  OJO: es un script de INSTALACIÓN LIMPIA (no idempotente) sobre una base
--  vacía. Si ya existe el esquema, recréela:
--      dropdb computo_arequipa && createdb computo_arequipa
--      psql -d computo_arequipa -f backend/sql/seed_ubigeo_arequipa.sql
--      psql -d computo_arequipa -f backend/sql/seed_auth_arequipa.sql
--
--  Convenciones:
--    * Nombres en snake_case, en español, como el resto del dominio electoral.
--    * Todo importe de votos es INTEGER >= 0 (jamás negativo).
--    * Los códigos ubigeo son CHAR(6) con CHECK de formato.
--    * Las reglas de consistencia ONPE (suma y tope) NO se aplican como CHECK
--      duro: el sistema debe poder almacenar el acta tal como está escrita en
--      el papel (quedando OBSERVADA). Se exigen por trigger recién al pasar a
--      CONTABILIZADA. Ver docs/REGLAS_DE_NEGOCIO.md.
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- crypt()/gen_salt() => bcrypt, digest()
CREATE EXTENSION IF NOT EXISTS citext;     -- emails y nombres sin distinguir mayúsculas

-- ============================================================================
--  1. TIPOS ENUMERADOS
-- ============================================================================

CREATE TYPE nivel_ubigeo AS ENUM ('DEPARTAMENTO', 'PROVINCIA', 'DISTRITO');

CREATE TYPE tipo_eleccion AS ENUM ('REGIONAL', 'PROVINCIAL', 'DISTRITAL');

-- Cargos de las tres instancias que se computan en Arequipa
CREATE TYPE cargo_eleccion AS ENUM (
    'GOBERNADOR',
    'VICE_GOBERNADOR',
    'CONSEJERO_REGIONAL',
    'ALCALDE_PROVINCIAL',
    'REGIDOR_PROVINCIAL',
    'ALCALDE_DISTRITAL',
    'REGIDOR_DISTRITAL'
);

-- Agrupación de cargos = columna del acta física (cada columna tiene su propio
-- blancos / nulos / impugnados / total de votantes en el papel)
CREATE TYPE columna_acta AS ENUM (
    'GOBERNADOR_VICE',      -- columna A: gobernador y vicegobernador
    'CONSEJEROS',           -- columna B: consejeros regionales
    'ALCALDE',              -- columna A: alcalde (provincial o distrital)
    'REGIDORES'             -- columna B: regidores (provincial o distrital)
);

CREATE TYPE estado_candidato AS ENUM (
    'INSCRITO', 'RENUNCIA', 'EXCLUIDO', 'FALLECIDO', 'SUSPENDIDO', 'RETIRADO'
);

CREATE TYPE tipo_organizacion AS ENUM (
    'PARTIDO_NACIONAL', 'MOVIMIENTO_REGIONAL', 'ALIANZA_ELECTORAL'
);

CREATE TYPE rol_usuario AS ENUM (
    'SUPER_ADMIN',            -- dashboard global de Arequipa
    'COORD_PROVINCIAL',       -- supervisa los distritos de su provincia
    'RESPONSABLE_DISTRITAL',  -- carga y valida actas de su distrito
    'PERSONERO'               -- sube fotos de acta desde el local de votación
);

-- Ciclo de vida del acta
CREATE TYPE estado_acta AS ENUM (
    'PENDIENTE',       -- mesa habilitada, aún sin acta
    'DIGITADA',        -- datos cargados, pendiente de validación automática
    'OBSERVADA',       -- quedó inconsistente u observada: va a revisión humana
    'CONTABILIZADA',   -- válida y sumada al cómputo oficial
    'ANULADA'          -- mesa anulada / acta reemplazada
);

CREATE TYPE origen_captura AS ENUM (
    'PWA_MOVIL', 'OCR_IA', 'DIGITACION_WEB', 'IMPORTACION_CSV'
);

CREATE TYPE severidad_observacion AS ENUM ('BLOQUEANTE', 'ADVERTENCIA', 'INFO');

CREATE TYPE codigo_regla AS ENUM (
    'R1_SUMA_VOTOS',            -- Σ votos + B + N + I != total de votantes
    'R2_TOPE_ELECTORES',        -- total de votantes > electores hábiles
    'R3_COLUMNAS_INCOHERENTES', -- las columnas del acta no cuadran entre sí
    'R4_ACTA_DUPLICADA',        -- misma mesa y elección cargada dos veces
    'R5_FOTO_AUSENTE',          -- no hay evidencia fotográfica
    'R6_ILEGIBLE',              -- campos ilegibles / ilegibilidad declarada
    'R7_FIRMA_FALTANTE',        -- faltan firmas de personeros
    'R8_DIFERENCIA_MANUAL'      -- diferencia detectada al cotejar con el papel
);

CREATE TYPE evento_acta AS ENUM (
    'CREADA', 'DIGITADA', 'RECALCULADA', 'OBSERVADA', 'ENVIADA_A_REVISION',
    'VALIDADA', 'CONTABILIZADA', 'ANULADA', 'REEMPLAZADA', 'OBSERVACION_RESUELTA'
);

-- ============================================================================
--  2. JERARQUÍA TERRITORIAL
-- ============================================================================

-- Base ubigeo oficial. Se cargan los 109 distritos y las 8 provincias de
-- Arequipa (seed_ubigeo_arequipa.sql). Se guardan AMBAS codificaciones porque
-- no son equivalentes: Paucarpata es 040112 (INEI) y 040109 (RENIEC), y la API
-- del JNE responde a la codificación RENIEC.
CREATE TABLE ubigeo (
    ubigeo               CHAR(6)      PRIMARY KEY,
    ubigeo_reniec        CHAR(6),
    departamento         VARCHAR(60)  NOT NULL,
    provincia            VARCHAR(60),
    distrito             VARCHAR(60),
    nivel                nivel_ubigeo NOT NULL,
    capital              VARCHAR(120),
    latitud              NUMERIC(10, 6),
    longitud             NUMERIC(10, 6),
    altitud              INTEGER,
    densidad_poblacional NUMERIC(12, 4),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- Necesaria para trg_ubigeo_updated (el seed idempotente hace UPDATE aquí)
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ubigeo_formato         CHECK (ubigeo ~ '^[0-9]{6}$'),
    CONSTRAINT ubigeo_reniec_formato  CHECK (ubigeo_reniec IS NULL OR ubigeo_reniec ~ '^[0-9]{6}$'),
    CONSTRAINT ubigeo_coherencia_nivel CHECK (
        (nivel = 'DEPARTAMENTO' AND provincia IS NULL     AND distrito IS NULL)
     OR (nivel = 'PROVINCIA'    AND provincia IS NOT NULL AND distrito IS NULL)
     OR (nivel = 'DISTRITO'     AND provincia IS NOT NULL AND distrito IS NOT NULL)
    ),
    CONSTRAINT ubigeo_latitud_rango  CHECK (latitud  IS NULL OR latitud  BETWEEN -19 AND  0),
    CONSTRAINT ubigeo_longitud_rango CHECK (longitud IS NULL OR longitud BETWEEN -82 AND -68)
);

CREATE INDEX idx_ubigeo_reniec    ON ubigeo (ubigeo_reniec);
CREATE INDEX idx_ubigeo_provincia ON ubigeo (provincia) WHERE distrito IS NULL;
CREATE INDEX idx_ubigeo_distritos ON ubigeo (provincia) WHERE distrito IS NOT NULL;

COMMENT ON TABLE ubigeo IS 'Base ubigeo INEI/RENIEC. Arequipa = 8 provincias / 109 distritos (dep 04).';

-- ---------------------------------------------------------------------------
-- Locales de votación (colegios, universidades, etc.)
-- ---------------------------------------------------------------------------
CREATE TABLE locales_votacion (
    id                BIGSERIAL    PRIMARY KEY,
    ubigeo            CHAR(6)      NOT NULL REFERENCES ubigeo (ubigeo) ON UPDATE CASCADE,
    codigo_local      VARCHAR(20)  NOT NULL,     -- código de local de la ONPE
    nombre            VARCHAR(160) NOT NULL,
    direccion         VARCHAR(220),
    referencia        VARCHAR(220),
    latitud           NUMERIC(10, 6),
    longitud          NUMERIC(10, 6),
    electores_habiles INTEGER      NOT NULL DEFAULT 0,
    activo            BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT locales_electores_no_negativos CHECK (electores_habiles >= 0),
    CONSTRAINT locales_codigo_por_ubigeo       UNIQUE (ubigeo, codigo_local)
);

CREATE INDEX idx_locales_ubigeo ON locales_votacion (ubigeo);

-- ---------------------------------------------------------------------------
-- Mesas de sufragio. numero_mesa es el código de 6 dígitos que aparece tanto en
-- el acta como en la cartilla de la ONPE (se guarda como texto para preservar
-- los ceros a la izquierda).
-- ---------------------------------------------------------------------------
CREATE TABLE mesas (
    id                BIGSERIAL   PRIMARY KEY,
    local_id          BIGINT      NOT NULL REFERENCES locales_votacion (id) ON DELETE CASCADE,
    numero_mesa       CHAR(6)     NOT NULL,
    electores_habiles INTEGER     NOT NULL,
    pabellon          VARCHAR(40),
    piso              VARCHAR(20),
    numero_orden      INTEGER,                       -- orden físico de la mesa en el local
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT mesas_numero_formato    CHECK (numero_mesa ~ '^[0-9]{6}$'),
    CONSTRAINT mesas_electores_positivo CHECK (electores_habiles > 0),
    CONSTRAINT mesas_unica_por_local   UNIQUE (local_id, numero_mesa)
);

CREATE INDEX idx_mesas_local ON mesas (local_id);

-- ============================================================================
--  3. USUARIOS, ROLES Y ALCANCE TERRITORIAL (RBAC descentralizado)
-- ============================================================================

CREATE TABLE usuarios (
    id               BIGSERIAL    PRIMARY KEY,
    email            CITEXT       NOT NULL UNIQUE,
    dni              CHAR(8)      NOT NULL UNIQUE,
    nombres          VARCHAR(80)  NOT NULL,
    apellidos        VARCHAR(80)  NOT NULL,
    telefono         VARCHAR(20),
    password_hash    TEXT         NOT NULL,   -- bcrypt ($2a$/$2b$ de pgcrypto o de Python)
    rol              rol_usuario  NOT NULL,
    activo           BOOLEAN      NOT NULL DEFAULT TRUE,
    intentos_fallidos SMALLINT    NOT NULL DEFAULT 0,
    bloqueado_hasta  TIMESTAMPTZ,
    ultimo_acceso    TIMESTAMPTZ,
    debe_cambiar_clave BOOLEAN    NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT usuarios_dni_formato CHECK (dni ~ '^[0-9]{8}$'),
    CONSTRAINT usuarios_email_formato CHECK (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
    CONSTRAINT usuarios_hash_bcrypt  CHECK (password_hash ~ '^\$2[aby]\$')
);

COMMENT ON COLUMN usuarios.password_hash IS 'Hash bcrypt: pgcrypto crypt(..., gen_salt(''bf'', 12)) o bcrypt de Python. Nunca texto plano.';

-- Alcance territorial: a qué provincia/distrito(s) puede acceder cada usuario.
-- SUPER_ADMIN no necesita filas aquí (ve toda la región).
CREATE TABLE usuario_alcance (
    usuario_id BIGINT       NOT NULL REFERENCES usuarios (id) ON DELETE CASCADE,
    ubigeo     CHAR(6)      NOT NULL REFERENCES ubigeo (ubigeo) ON UPDATE CASCADE,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, ubigeo)
);

CREATE INDEX idx_alcance_ubigeo ON usuario_alcance (ubigeo);

-- Sesiones / tokens de la PWA (permite revocar el acceso de un personero)
CREATE TABLE sesiones (
    id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id   BIGINT       NOT NULL REFERENCES usuarios (id) ON DELETE CASCADE,
    dispositivo  VARCHAR(120),
    ip           INET,
    expira_at    TIMESTAMPTZ  NOT NULL,
    revocada     BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_sesiones_usuario ON sesiones (usuario_id);

-- Bitácora de intentos de acceso (detección de fuerza bruta)
CREATE TABLE accesos_log (
    id          BIGSERIAL   PRIMARY KEY,
    email       CITEXT,
    exitoso     BOOLEAN     NOT NULL,
    ip          INET,
    user_agent  VARCHAR(220),
    detalle     VARCHAR(220),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_accesos_email_fecha ON accesos_log (email, created_at DESC);

-- ============================================================================
--  4. OFERTA ELECTORAL (organizaciones políticas y candidatos)
-- ============================================================================

CREATE TABLE organizaciones_politicas (
    id            BIGSERIAL         PRIMARY KEY,
    nombre        VARCHAR(160)      NOT NULL UNIQUE,
    nombre_corto  VARCHAR(60),
    tipo          tipo_organizacion NOT NULL,
    id_jne        INTEGER,          -- idOrganizacionPolitica del JNE
    logo_url      TEXT,
    color_hex     CHAR(7)           NOT NULL DEFAULT '#6b7280',
    activo        BOOLEAN           NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ       NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ       NOT NULL DEFAULT now(),
    CONSTRAINT organizaciones_color_formato CHECK (color_hex ~* '^#[0-9a-f]{6}$')
);

CREATE INDEX idx_org_jne ON organizaciones_politicas (id_jne);

-- Un candidato es la combinación (organización, ámbito territorial, cargo,
-- posición en la lista). El ámbito es el ubigeo del distrito para DISTRITAL, el
-- de la provincia para PROVINCIAL y 040000 para REGIONAL.
CREATE TABLE candidatos (
    id                BIGSERIAL      PRIMARY KEY,
    organizacion_id   BIGINT         NOT NULL REFERENCES organizaciones_politicas (id) ON DELETE CASCADE,
    ubigeo            CHAR(6)        NOT NULL REFERENCES ubigeo (ubigeo) ON UPDATE CASCADE,
    tipo_eleccion     tipo_eleccion  NOT NULL,
    cargo             cargo_eleccion NOT NULL,
    numero_lista      SMALLINT       NOT NULL,   -- posición en la lista (1 = primero)
    dni               CHAR(8),
    nombres           VARCHAR(120)   NOT NULL,
    apellidos         VARCHAR(120)   NOT NULL,
    nombre_completo   VARCHAR(240)   NOT NULL,
    foto_url          TEXT,
    hoja_vida_url     TEXT,
    estado            estado_candidato NOT NULL DEFAULT 'INSCRITO',
    created_at        TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ    NOT NULL DEFAULT now(),
    CONSTRAINT candidatos_dni_formato   CHECK (dni IS NULL OR dni ~ '^[0-9]{8}$'),
    CONSTRAINT candidatos_lista_positiva CHECK (numero_lista >= 1),
    -- Un mismo número de lista por organización/ámbito/cargo
    CONSTRAINT candidatos_lista_unica   UNIQUE (organizacion_id, ubigeo, cargo, numero_lista),
    -- Coherencia entre cargo y tipo de elección
    CONSTRAINT candidatos_cargo_coherente CHECK (
        (tipo_eleccion = 'REGIONAL'   AND cargo IN ('GOBERNADOR','VICE_GOBERNADOR','CONSEJERO_REGIONAL'))
     OR (tipo_eleccion = 'PROVINCIAL' AND cargo IN ('ALCALDE_PROVINCIAL','REGIDOR_PROVINCIAL'))
     OR (tipo_eleccion = 'DISTRITAL'  AND cargo IN ('ALCALDE_DISTRITAL','REGIDOR_DISTRITAL'))
    )
);

CREATE INDEX idx_candidatos_ambito   ON candidatos (tipo_eleccion, ubigeo, cargo, numero_lista);
CREATE INDEX idx_candidatos_org      ON candidatos (organizacion_id);
CREATE INDEX idx_candidatos_dni      ON candidatos (dni) WHERE dni IS NOT NULL;
CREATE INDEX idx_candidatos_busqueda ON candidatos (lower(nombre_completo) text_pattern_ops);

-- ============================================================================
--  5. ACTAS: CONTROL DE VOTACIÓN
-- ============================================================================

-- Cabecera del acta. UNIQUE (mesa_id, tipo_eleccion) es la regla anti-duplicado:
-- una mesa tiene a lo más un acta por cada tipo de elección.
CREATE TABLE actas (
    id                  BIGSERIAL      PRIMARY KEY,
    mesa_id             BIGINT         NOT NULL REFERENCES mesas (id) ON DELETE RESTRICT,
    tipo_eleccion       tipo_eleccion  NOT NULL,
    estado              estado_acta    NOT NULL DEFAULT 'PENDIENTE',
    origen              origen_captura NOT NULL DEFAULT 'PWA_MOVIL',
    electores_habiles   INTEGER        NOT NULL,   -- copia del padrón al momento de digitar

    -- Evidencia
    foto_url            TEXT,
    foto_hash_sha256    CHAR(64),
    foto_subida_por     BIGINT         REFERENCES usuarios (id) ON DELETE SET NULL,
    foto_subida_at      TIMESTAMPTZ,

    -- Consolidado del acta (suma de sus columnas) — se recalcula por trigger
    total_votantes      INTEGER,
    votos_blancos       INTEGER        NOT NULL DEFAULT 0,
    votos_nulos         INTEGER        NOT NULL DEFAULT 0,
    votos_impugnados    INTEGER        NOT NULL DEFAULT 0,
    votos_validos       INTEGER        NOT NULL DEFAULT 0,

    -- Resultado de la validación automática ONPE
    -- TRUE sólo si TODAS las columnas del acta cuadran (R1 se evalúa por columna)
    validacion          BOOLEAN,
    -- Descuadre de la COLUMNA PRINCIPAL: total_votantes - (votos + B + N + I)
    diferencia_suma     INTEGER,
    observaciones_count SMALLINT       NOT NULL DEFAULT 0,

    -- Trazabilidad
    digitada_por        BIGINT         REFERENCES usuarios (id) ON DELETE SET NULL,
    digitada_at         TIMESTAMPTZ,
    validada_por        BIGINT         REFERENCES usuarios (id) ON DELETE SET NULL,
    validada_at         TIMESTAMPTZ,
    contabilizada_at    TIMESTAMPTZ,
    resolucion_final    TEXT,                       -- sustento con el que se cierra una observada
    observacion_general TEXT,
    created_at          TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ    NOT NULL DEFAULT now(),

    CONSTRAINT actas_unica_por_mesa_eleccion UNIQUE (mesa_id, tipo_eleccion),
    CONSTRAINT actas_no_negativas CHECK (
        votos_blancos >= 0 AND votos_nulos >= 0 AND votos_impugnados >= 0
        AND (total_votantes IS NULL OR total_votantes >= 0)
        AND (votos_validos IS NULL OR votos_validos >= 0)
    ),
    CONSTRAINT actas_electores_positivos CHECK (electores_habiles > 0),
    CONSTRAINT actas_hash_formato CHECK (foto_hash_sha256 IS NULL OR foto_hash_sha256 ~ '^[0-9a-f]{64}$'),
    -- Un acta CONTABILIZADA siempre tiene validador, fecha y resultado consistente
    CONSTRAINT actas_contabilizada_completa CHECK (
        estado <> 'CONTABILIZADA'
        OR (validacion IS TRUE AND validada_por IS NOT NULL AND validada_at IS NOT NULL
            AND contabilizada_at IS NOT NULL)
    )
);

CREATE INDEX idx_actas_mesa       ON actas (mesa_id);
CREATE INDEX idx_actas_estado     ON actas (estado);
CREATE INDEX idx_actas_tipo       ON actas (tipo_eleccion, estado);
CREATE INDEX idx_actas_observadas ON actas (updated_at DESC) WHERE estado = 'OBSERVADA';
CREATE INDEX idx_actas_digitada   ON actas (digitada_por) WHERE digitada_por IS NOT NULL;
CREATE UNIQUE INDEX idx_actas_foto_hash ON actas (foto_hash_sha256) WHERE foto_hash_sha256 IS NOT NULL;

COMMENT ON CONSTRAINT actas_unica_por_mesa_eleccion ON actas IS
    'Evita digitación duplicada de la misma mesa para el mismo tipo de elección.';

-- ---------------------------------------------------------------------------
-- Columnas del acta. El acta física municipal trae dos columnas (alcalde y
-- regidores) y la regional también dos (gobernador/vice y consejeros); cada
-- columna tiene sus propios blancos, nulos, impugnados y total de votantes.
-- ---------------------------------------------------------------------------
CREATE TABLE acta_columnas (
    id                BIGSERIAL    PRIMARY KEY,
    acta_id           BIGINT       NOT NULL REFERENCES actas (id) ON DELETE CASCADE,
    columna           columna_acta NOT NULL,
    total_votantes    INTEGER      NOT NULL DEFAULT 0,
    votos_validos     INTEGER      NOT NULL DEFAULT 0,
    votos_blancos     INTEGER      NOT NULL DEFAULT 0,
    votos_nulos       INTEGER      NOT NULL DEFAULT 0,
    votos_impugnados  INTEGER      NOT NULL DEFAULT 0,
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT acta_columnas_unica       UNIQUE (acta_id, columna),
    CONSTRAINT acta_columnas_no_negativas CHECK (
        total_votantes >= 0 AND votos_validos >= 0 AND votos_blancos >= 0
        AND votos_nulos >= 0 AND votos_impugnados >= 0
    )
);

CREATE INDEX idx_columnas_acta ON acta_columnas (acta_id);

-- Detalle del acta: votos POR ORGANIZACIÓN POLÍTICA dentro de una columna.
--
-- Ojo con el modelo real: en un acta municipal el elector marca una sola vez la
-- organización política para alcalde y una sola vez para regidores; NO se vota
-- regidor por regidor, así que la unidad contable es la organización política.
-- Para las columnas de un solo cargo (ALCALDE, GOBERNADOR_VICE) se guarda
-- además la referencia al candidato concreto, que permite el ranking nominal y
-- el conteo de votos preferenciales si la norma lo habilita.
CREATE TABLE detalle_votos_acta (
    id               BIGSERIAL   PRIMARY KEY,
    columna_id       BIGINT      NOT NULL REFERENCES acta_columnas (id) ON DELETE CASCADE,
    organizacion_id  BIGINT      NOT NULL REFERENCES organizaciones_politicas (id) ON DELETE RESTRICT,
    candidato_id     BIGINT      REFERENCES candidatos (id) ON DELETE SET NULL,
    votos            INTEGER     NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT detalle_votos_no_negativos CHECK (votos >= 0),
    CONSTRAINT detalle_unico_por_columna  UNIQUE (columna_id, organizacion_id)
);

CREATE INDEX idx_detalle_columna   ON detalle_votos_acta (columna_id);
CREATE INDEX idx_detalle_org       ON detalle_votos_acta (organizacion_id);
CREATE INDEX idx_detalle_candidato ON detalle_votos_acta (candidato_id)
    WHERE candidato_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Observaciones (cola de actas observadas) y bitácora de eventos
-- ---------------------------------------------------------------------------
CREATE TABLE acta_observaciones (
    id              BIGSERIAL             PRIMARY KEY,
    acta_id         BIGINT                NOT NULL REFERENCES actas (id) ON DELETE CASCADE,
    columna_id      BIGINT                REFERENCES acta_columnas (id) ON DELETE CASCADE,
    regla           codigo_regla          NOT NULL,
    severidad       severidad_observacion NOT NULL DEFAULT 'BLOQUEANTE',
    mensaje         TEXT                  NOT NULL,
    diferencia      INTEGER,
    resuelta        BOOLEAN               NOT NULL DEFAULT FALSE,
    resuelta_por    BIGINT                REFERENCES usuarios (id) ON DELETE SET NULL,
    resuelta_at     TIMESTAMPTZ,
    sustento        TEXT,
    created_at      TIMESTAMPTZ           NOT NULL DEFAULT now(),
    CONSTRAINT observacion_resuelta_completa CHECK (
        NOT resuelta OR (resuelta_por IS NOT NULL AND resuelta_at IS NOT NULL AND sustento IS NOT NULL)
    )
);

CREATE INDEX idx_observaciones_acta   ON acta_observaciones (acta_id, resuelta);
CREATE INDEX idx_observaciones_abiertas ON acta_observaciones (severidad, created_at)
    WHERE NOT resuelta;

CREATE TABLE acta_eventos (
    id             BIGSERIAL   PRIMARY KEY,
    acta_id        BIGINT      NOT NULL REFERENCES actas (id) ON DELETE CASCADE,
    usuario_id     BIGINT      REFERENCES usuarios (id) ON DELETE SET NULL,
    evento         evento_acta NOT NULL,
    estado_anterior estado_acta,
    estado_nuevo   estado_acta,
    detalle        JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_eventos_acta ON acta_eventos (acta_id, created_at DESC);
CREATE INDEX idx_eventos_json ON acta_eventos USING GIN (detalle);

-- Adjuntos del acta (foto principal, foto del padrón, resolución del JEE, etc.)
CREATE TABLE acta_adjuntos (
    id          BIGSERIAL   PRIMARY KEY,
    acta_id     BIGINT      NOT NULL REFERENCES actas (id) ON DELETE CASCADE,
    tipo        VARCHAR(40) NOT NULL,   -- FOTO_ACTA | FOTO_PADRON | RESOLUCION_JEE | OTRO
    url         TEXT        NOT NULL,
    hash_sha256 CHAR(64),
    subido_por  BIGINT      REFERENCES usuarios (id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT adjuntos_hash_formato CHECK (hash_sha256 IS NULL OR hash_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE INDEX idx_adjuntos_acta ON acta_adjuntos (acta_id);

-- ============================================================================
--  6. FUNCIONES Y TRIGGERS
-- ============================================================================

-- 6.1 updated_at automático
CREATE OR REPLACE FUNCTION fn_set_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_ubigeo_updated      BEFORE UPDATE ON ubigeo               FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_locales_updated     BEFORE UPDATE ON locales_votacion     FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_mesas_updated       BEFORE UPDATE ON mesas                FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_usuarios_updated    BEFORE UPDATE ON usuarios             FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_org_updated         BEFORE UPDATE ON organizaciones_politicas FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_candidatos_updated  BEFORE UPDATE ON candidatos           FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_actas_updated       BEFORE UPDATE ON actas                FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_columnas_updated    BEFORE UPDATE ON acta_columnas        FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_detalle_updated     BEFORE UPDATE ON detalle_votos_acta   FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- 6.2 Recalcular totales de una columna: votos_validos = Σ detalle
CREATE OR REPLACE FUNCTION fn_recalcular_columna() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_columna_id BIGINT := COALESCE(NEW.columna_id, OLD.columna_id);
    v_suma       INTEGER;
BEGIN
    SELECT COALESCE(SUM(votos), 0) INTO v_suma
      FROM detalle_votos_acta
     WHERE columna_id = v_columna_id;

    UPDATE acta_columnas
       SET votos_validos = v_suma,
           updated_at    = now()
     WHERE id = v_columna_id;

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_detalle_recalcular
    AFTER INSERT OR UPDATE OR DELETE ON detalle_votos_acta
    FOR EACH ROW EXECUTE FUNCTION fn_recalcular_columna();

-- 6.3 a) Descuadres del acta, columna por columna (SOLO LECTURA).
--
-- El acta física trae DOS cómputos independientes: A (alcalde / gobernador y
-- vice) y B (regidores / consejeros). La regla R1 de la ONPE se aplica POR
-- COLUMNA, así que un descuadre en la columna B invalida el acta igual que uno
-- en la A. Devuelve una fila por columna que no cuadra (sin filas = cuadra).
--
-- Ojo con la cabecera de `actas`: `total_votantes`, `votos_validos` y
-- `diferencia_suma` resumen la COLUMNA PRINCIPAL (la que define el cargo
-- principal), y eso no cambia. Lo que sí exige esta función es que NINGUNA
-- columna descuadre para poder dar el acta por consistente.
CREATE OR REPLACE FUNCTION fn_descuadres_acta(p_acta_id BIGINT)
RETURNS TABLE (
    columna        columna_acta,
    total_votantes INTEGER,
    suma_partes    INTEGER,
    descuadre      INTEGER
) LANGUAGE sql STABLE AS $$
    SELECT ac.columna,
           ac.total_votantes,
           ac.votos_validos + ac.votos_blancos + ac.votos_nulos + ac.votos_impugnados,
           ac.total_votantes
             - (ac.votos_validos + ac.votos_blancos + ac.votos_nulos + ac.votos_impugnados)
      FROM acta_columnas ac
     WHERE ac.acta_id = p_acta_id
       AND ac.total_votantes
             <> (ac.votos_validos + ac.votos_blancos + ac.votos_nulos + ac.votos_impugnados)
     ORDER BY ac.columna;
$$;

-- 6.3 b) Totales consolidados del acta (SOLO LECTURA).
-- Devuelve la columna principal y sus totales, que son los que definen el
-- "total de votantes" del acta.
CREATE OR REPLACE FUNCTION fn_totales_acta(
    p_acta_id     BIGINT,
    OUT o_columna columna_acta,
    OUT o_total   INTEGER,
    OUT o_validos INTEGER,
    OUT o_blancos INTEGER,
    OUT o_nulos   INTEGER,
    OUT o_impugnados INTEGER,
    OUT o_diferencia INTEGER
) LANGUAGE plpgsql STABLE AS $$
BEGIN
    o_columna := CASE
        WHEN (SELECT tipo_eleccion FROM actas WHERE id = p_acta_id) = 'REGIONAL'
            THEN 'GOBERNADOR_VICE'::columna_acta
        ELSE 'ALCALDE'::columna_acta
    END;

    SELECT COALESCE(SUM(total_votantes), 0),
           COALESCE(SUM(votos_validos), 0),
           COALESCE(SUM(votos_blancos), 0),
           COALESCE(SUM(votos_nulos), 0),
           COALESCE(SUM(votos_impugnados), 0)
      INTO o_total, o_validos, o_blancos, o_nulos, o_impugnados
      FROM acta_columnas
     WHERE acta_id = p_acta_id
       AND columna = o_columna;

    o_diferencia := o_total - (o_validos + o_blancos + o_nulos + o_impugnados);
END;
$$;

-- 6.3 c) Sincronizar la cabecera del acta con sus columnas.
-- Lo invocan triggers AFTER (nunca BEFORE sobre la propia fila de actas, para
-- no reescribir la tupla que la sentencia externa todavía no ha guardado).
-- Cada recálculo que cambia algo queda en la bitácora como RECALCULADA, que es
-- lo que permite reconstruir después por qué un acta pasó a inconsistente.
CREATE OR REPLACE FUNCTION fn_consolidar_acta(p_acta_id BIGINT) RETURNS actas
LANGUAGE plpgsql AS $$
DECLARE
    v_acta   actas;
    v_previo actas;
    t        RECORD;
BEGIN
    SELECT * INTO v_previo FROM actas WHERE id = p_acta_id;
    SELECT * INTO t FROM fn_totales_acta(p_acta_id);

    UPDATE actas
       SET total_votantes   = t.o_total,
           votos_validos    = t.o_validos,
           votos_blancos    = t.o_blancos,
           votos_nulos      = t.o_nulos,
           votos_impugnados = t.o_impugnados,
           diferencia_suma  = t.o_diferencia,
           -- Consistente = NINGUNA columna descuadra (R1 se evalúa por columna)
           validacion       = NOT EXISTS (SELECT 1 FROM fn_descuadres_acta(p_acta_id))
     WHERE id = p_acta_id
    RETURNING * INTO v_acta;

    IF v_previo.id IS NOT NULL
       AND (v_previo.validacion      IS DISTINCT FROM v_acta.validacion
         OR v_previo.total_votantes  IS DISTINCT FROM v_acta.total_votantes
         OR v_previo.diferencia_suma IS DISTINCT FROM v_acta.diferencia_suma) THEN
        INSERT INTO acta_eventos (acta_id, evento, detalle)
        VALUES (p_acta_id, 'RECALCULADA', jsonb_build_object(
            'total_votantes', v_acta.total_votantes,
            'votos_validos',  v_acta.votos_validos,
            'diferencia',     v_acta.diferencia_suma,
            'consistente',    v_acta.validacion,
            'antes', jsonb_build_object(
                'total_votantes',  v_previo.total_votantes,
                'diferencia',      v_previo.diferencia_suma,
                'consistente',     v_previo.validacion)
        ));
    END IF;

    RETURN v_acta;
END;
$$;

-- Marcar el acta como inconsistente cuando la columna cambia
CREATE OR REPLACE FUNCTION fn_tras_cambio_columna() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_consolidar_acta(COALESCE(NEW.acta_id, OLD.acta_id));
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_columnas_consolidar
    AFTER INSERT OR UPDATE OR DELETE ON acta_columnas
    FOR EACH ROW EXECUTE FUNCTION fn_tras_cambio_columna();

-- 6.4 Generar automáticamente las dos columnas al crear el acta
CREATE OR REPLACE FUNCTION fn_crear_columnas_acta() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.tipo_eleccion = 'REGIONAL' THEN
        INSERT INTO acta_columnas (acta_id, columna) VALUES (NEW.id, 'GOBERNADOR_VICE'), (NEW.id, 'CONSEJEROS');
    ELSE
        INSERT INTO acta_columnas (acta_id, columna) VALUES (NEW.id, 'ALCALDE'), (NEW.id, 'REGIDORES');
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_actas_crear_columnas
    AFTER INSERT ON actas FOR EACH ROW EXECUTE FUNCTION fn_crear_columnas_acta();

-- 6.5 Auditoría automática de cambios de estado
CREATE OR REPLACE FUNCTION fn_auditar_acta() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_evento evento_acta;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO acta_eventos (acta_id, usuario_id, evento, estado_nuevo, detalle)
        VALUES (NEW.id, NEW.digitada_por, 'CREADA', NEW.estado,
                jsonb_build_object('origen', NEW.origen, 'tipo_eleccion', NEW.tipo_eleccion));
        RETURN NULL;
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        v_evento := CASE NEW.estado
            WHEN 'DIGITADA'      THEN 'DIGITADA'
            WHEN 'OBSERVADA'     THEN 'OBSERVADA'
            WHEN 'CONTABILIZADA' THEN 'CONTABILIZADA'
            WHEN 'ANULADA'       THEN 'ANULADA'
            WHEN 'PENDIENTE'     THEN 'REEMPLAZADA'
        END;
        INSERT INTO acta_eventos (acta_id, usuario_id, evento, estado_anterior, estado_nuevo)
        VALUES (NEW.id, COALESCE(NEW.validada_por, NEW.digitada_por), v_evento, OLD.estado, NEW.estado);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_actas_auditar
    AFTER INSERT OR UPDATE OF estado ON actas
    FOR EACH ROW EXECUTE FUNCTION fn_auditar_acta();

-- 6.6 Regla dura: no se contabiliza un acta inconsistente.
-- Es el corazón de las Reglas de Negocio: el dato se guarda como está en el
-- papel, pero sólo entra al cómputo cuando la matemática ONPE cuadra y las
-- observaciones bloqueantes están resueltas.
CREATE OR REPLACE FUNCTION fn_validar_contabilizacion() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_pendientes INTEGER;
    v_descuadres INTEGER;
    v_detalle    TEXT;
    t            RECORD;
BEGIN
    IF NEW.estado <> 'CONTABILIZADA' THEN
        RETURN NEW;
    END IF;

    -- Recalcula en memoria (sin escribir) para decidir con el dato vigente
    SELECT * INTO t FROM fn_totales_acta(NEW.id);
    NEW.total_votantes   := t.o_total;
    NEW.votos_validos    := t.o_validos;
    NEW.votos_blancos    := t.o_blancos;
    NEW.votos_nulos      := t.o_nulos;
    NEW.votos_impugnados := t.o_impugnados;
    NEW.diferencia_suma  := t.o_diferencia;

    -- R1 por COLUMNA. El acta física trae dos cómputos independientes (alcalde y
    -- regidores, o gobernador/vice y consejeros) y cada uno debe cuadrar con su
    -- propio total de votantes. Se recalcula AQUÍ, sin confiar en la columna
    -- `validacion` que traiga la fila: un descuadre de la columna secundaria
    -- también bloquea la contabilización, no solo el de la principal.
    SELECT COUNT(*),
           string_agg(format('%s (diferencia %s votos)', d.columna, d.descuadre),
                      '; ' ORDER BY d.columna)
      INTO v_descuadres, v_detalle
      FROM fn_descuadres_acta(NEW.id) d;

    NEW.validacion := (v_descuadres = 0);

    IF v_descuadres > 0 THEN
        RAISE EXCEPTION
            'ACTA_INCONSISTENTE: el acta % no cuadra en % columna(s): %. Debe resolverse la observación antes de contabilizar.',
            NEW.id, v_descuadres, v_detalle
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.total_votantes > NEW.electores_habiles THEN
        RAISE EXCEPTION
            'ACTA_EXCEDE_PADRON: el acta % registra % votantes sobre % electores hábiles.',
            NEW.id, NEW.total_votantes, NEW.electores_habiles
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COUNT(*) INTO v_pendientes
      FROM acta_observaciones
     WHERE acta_id = NEW.id AND NOT resuelta AND severidad = 'BLOQUEANTE';

    IF v_pendientes > 0 THEN
        RAISE EXCEPTION
            'ACTA_CON_OBSERVACIONES: el acta % tiene % observaciones bloqueantes sin resolver.',
            NEW.id, v_pendientes
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_actas_validar_contabilizacion
    BEFORE INSERT OR UPDATE OF estado ON actas
    FOR EACH ROW EXECUTE FUNCTION fn_validar_contabilizacion();

-- 6.6 bis El otro extremo de la misma regla: una observación BLOQUEANTE
-- abierta es incompatible con un acta CONTABILIZADA. Sin esto se podía
-- contabilizar un acta correcta y acto seguido colgarle un bloqueante: el
-- conteo quedaba cerrado pero la cola de revisión la señalaba, y el tablero
-- mostraba dos verdades a la vez. Lo correcto es lo que exige este trigger:
-- primero se revierte el estado (CONTABILIZADA -> OBSERVADA, transición que
-- queda auditada en acta_eventos) y después se registra la observación.
CREATE OR REPLACE FUNCTION fn_observacion_sobre_contabilizada() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_estado estado_acta;
BEGIN
    IF NEW.severidad <> 'BLOQUEANTE' OR NEW.resuelta THEN
        RETURN NEW;
    END IF;

    SELECT estado INTO v_estado FROM actas WHERE id = NEW.acta_id;

    IF v_estado = 'CONTABILIZADA' THEN
        RAISE EXCEPTION
            'ACTA_YA_CONTABILIZADA: no se puede observar el acta % (regla %) mientras está CONTABILIZADA. Revierte el estado a OBSERVADA para reabrirla, y la reversión quedará en la bitácora.',
            NEW.acta_id, NEW.regla
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_observaciones_no_sobre_contabilizada
    BEFORE INSERT OR UPDATE ON acta_observaciones
    FOR EACH ROW EXECUTE FUNCTION fn_observacion_sobre_contabilizada();

-- 6.7 La evidencia fotográfica no puede repetirse entre actas distintas
-- (la misma foto subida dos veces = intento de duplicar una mesa).
CREATE OR REPLACE FUNCTION fn_evitar_foto_duplicada() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_otro BIGINT;
BEGIN
    -- El propio acta queda excluido: sólo se rechaza el hash usado por OTRA acta.
    SELECT acta_id INTO v_otro
      FROM acta_adjuntos a
      JOIN actas ac ON ac.id = a.acta_id
     WHERE a.hash_sha256 = NEW.hash_sha256 AND a.acta_id <> NEW.acta_id
     LIMIT 1;

    IF v_otro IS NOT NULL THEN
        RAISE EXCEPTION 'FOTO_DUPLICADA: la imagen ya fue usada en el acta %', v_otro
            USING ERRCODE = 'unique_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_adjuntos_foto_unica
    BEFORE INSERT ON acta_adjuntos
    FOR EACH ROW WHEN (NEW.hash_sha256 IS NOT NULL)
    EXECUTE FUNCTION fn_evitar_foto_duplicada();

-- ============================================================================
--  7. VISTAS PARA EL CÓMPUTO Y LOS DASHBOARDS
-- ============================================================================

-- Estado consolidado de cada acta con el resultado de la validación ONPE
CREATE OR REPLACE VIEW v_acta_consolidada AS
SELECT
    a.id                                        AS acta_id,
    a.tipo_eleccion,
    a.estado,
    a.origen,
    ub.ubigeo,
    ub.provincia,
    ub.distrito,
    lo.codigo_local,
    lo.nombre                                  AS local_votacion,
    me.numero_mesa,
    me.electores_habiles,
    a.total_votantes,
    a.votos_validos,
    a.votos_blancos,
    a.votos_nulos,
    a.votos_impugnados,
    a.diferencia_suma,
    a.validacion,
    (SELECT COUNT(*) FROM fn_descuadres_acta(a.id)) AS columnas_descuadradas,
    a.foto_url IS NOT NULL                     AS tiene_foto,
    ROUND(
        100.0 * (a.votos_validos + a.votos_blancos + a.votos_nulos + a.votos_impugnados)
        / NULLIF(me.electores_habiles, 0), 2
    )                                          AS participacion_pct,
    a.digitada_por,
    a.validada_por,
    a.updated_at,
    (SELECT COUNT(*) FROM acta_observaciones o
      WHERE o.acta_id = a.id AND NOT o.resuelta) AS observaciones_abiertas
FROM actas a
JOIN mesas me            ON me.id = a.mesa_id
JOIN locales_votacion lo ON lo.id = me.local_id
JOIN ubigeo ub           ON ub.ubigeo = lo.ubigeo;

-- Ranking en vivo por ORGANIZACIÓN POLÍTICA y ámbito (el conteo oficial)
CREATE OR REPLACE VIEW v_resultados_organizacion AS
SELECT
    op.id                             AS organizacion_id,
    op.nombre                         AS organizacion,
    op.color_hex,
    ac.columna,
    a.tipo_eleccion,
    ub.ubigeo,
    ub.provincia,
    ub.distrito,
    SUM(d.votos)                      AS votos,
    COUNT(DISTINCT a.id)              AS actas_contabilizadas
FROM detalle_votos_acta d
JOIN organizaciones_politicas op ON op.id = d.organizacion_id
JOIN acta_columnas ac            ON ac.id = d.columna_id
JOIN actas a                     ON a.id = ac.acta_id
JOIN mesas me                    ON me.id = a.mesa_id
JOIN locales_votacion lo         ON lo.id = me.local_id
JOIN ubigeo ub                   ON ub.ubigeo = lo.ubigeo
WHERE a.estado = 'CONTABILIZADA'
GROUP BY op.id, op.nombre, op.color_hex, ac.columna, a.tipo_eleccion, ub.ubigeo, ub.provincia, ub.distrito;

-- Ranking nominal de alcaldes/gobernadores (columnas de un solo cargo)
CREATE OR REPLACE VIEW v_resultados_candidato AS
SELECT
    c.id                              AS candidato_id,
    c.nombre_completo,
    c.cargo,
    c.tipo_eleccion,
    c.ubigeo,
    op.nombre                         AS organizacion,
    op.color_hex,
    SUM(d.votos)                      AS votos,
    COUNT(DISTINCT a.id)              AS actas_contabilizadas
FROM detalle_votos_acta d
JOIN candidatos c                ON c.id = d.candidato_id
JOIN organizaciones_politicas op ON op.id = d.organizacion_id
JOIN acta_columnas ac            ON ac.id = d.columna_id
JOIN actas a                     ON a.id = ac.acta_id
WHERE a.estado = 'CONTABILIZADA' AND d.candidato_id IS NOT NULL
GROUP BY c.id, c.nombre_completo, c.cargo, c.tipo_eleccion, c.ubigeo, op.nombre, op.color_hex;

-- Cola de trabajo para COORD_PROVINCIAL / RESPONSABLE_DISTRITAL
CREATE OR REPLACE VIEW v_actas_observadas AS
SELECT
    a.id AS acta_id,
    a.tipo_eleccion,
    ub.distrito,
    ub.provincia,
    me.numero_mesa,
    a.diferencia_suma,
    (SELECT COUNT(*) FROM fn_descuadres_acta(a.id)) AS columnas_descuadradas,
    (SELECT string_agg(d.columna::TEXT || ' (diferencia ' || d.descuadre || ')',
                       ' | ' ORDER BY d.columna)
       FROM fn_descuadres_acta(a.id) d)            AS descuadres,
    a.total_votantes,
    a.electores_habiles,
    a.updated_at,
    string_agg(o.regla::TEXT || ' [' || o.severidad || ']', ' | ' ORDER BY o.regla) AS observaciones
FROM actas a
JOIN mesas me            ON me.id = a.mesa_id
JOIN locales_votacion lo ON lo.id = me.local_id
JOIN ubigeo ub           ON ub.ubigeo = lo.ubigeo
LEFT JOIN acta_observaciones o ON o.acta_id = a.id AND NOT o.resuelta
WHERE a.estado = 'OBSERVADA'
GROUP BY a.id, a.tipo_eleccion, ub.distrito, ub.provincia, me.numero_mesa,
         a.diferencia_suma, a.total_votantes, a.electores_habiles, a.updated_at;

-- Avance por distrito (tablero SUPER_ADMIN y coordinadores)
CREATE OR REPLACE VIEW v_avance_distrito AS
SELECT
    ub.ubigeo,
    ub.provincia,
    ub.distrito,
    COUNT(DISTINCT me.id)                                             AS mesas_totales,
    COUNT(DISTINCT a.id) FILTER (WHERE a.estado = 'CONTABILIZADA')     AS actas_contabilizadas,
    COUNT(DISTINCT a.id) FILTER (WHERE a.estado = 'OBSERVADA')        AS actas_observadas,
    COUNT(DISTINCT a.id) FILTER (WHERE a.estado IN ('PENDIENTE','DIGITADA')) AS actas_pendientes,
    ROUND(
        100.0 * COUNT(DISTINCT a.id) FILTER (WHERE a.estado = 'CONTABILIZADA')
        / NULLIF(COUNT(DISTINCT me.id), 0), 2
    )                                                                 AS avance_pct
FROM ubigeo ub
JOIN locales_votacion lo ON lo.ubigeo = ub.ubigeo
JOIN mesas me            ON me.local_id = lo.id
LEFT JOIN actas a        ON a.mesa_id = me.id
WHERE ub.nivel = 'DISTRITO'
GROUP BY ub.ubigeo, ub.provincia, ub.distrito;

-- ============================================================================
--  8. RLS (opcional): aislamiento por ámbito territorial
--     El backend igualmente valida el alcance; esto es defensa en profundidad.
-- ============================================================================
ALTER TABLE actas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_actas_super_admin ON actas;
CREATE POLICY p_actas_super_admin ON actas
    FOR ALL
    USING (current_setting('app.rol_actual', TRUE) = 'SUPER_ADMIN');

DROP POLICY IF EXISTS p_actas_alcance ON actas;
CREATE POLICY p_actas_alcance ON actas
    FOR ALL
    USING (
        EXISTS (
            SELECT 1
              FROM mesas me
              JOIN locales_votacion lo ON lo.id = me.local_id
              JOIN usuario_alcance ua  ON ua.usuario_id
                    = NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT
             WHERE me.id = actas.mesa_id
               AND (
                   -- Distrito: alcance exacto
                   lo.ubigeo = ua.ubigeo
                   -- Provincia: todo distrito 04-01-xx cuelga de 040100
                   OR (length(ua.ubigeo) = 6 AND substring(lo.ubigeo, 1, 4) = substring(ua.ubigeo, 1, 4)
                       AND EXISTS (SELECT 1 FROM ubigeo up
                                    WHERE up.ubigeo = ua.ubigeo AND up.nivel = 'PROVINCIA'))
               )
        )
    );

-- El backend debe fijar el contexto por petición:
--   SET LOCAL app.usuario_id = '42';
--   SET LOCAL app.rol_actual = 'COORD_PROVINCIAL';

COMMIT;

-- ============================================================================
--  9. CONSULTAS DE OPERACIÓN ÚTILES
-- ============================================================================
-- Cola de observadas de una provincia:
--   SELECT * FROM v_actas_observadas WHERE provincia = 'AREQUIPA' ORDER BY updated_at;
--
-- Avance de los 109 distritos:
--   SELECT provincia, SUM(mesas_totales) mesas, SUM(actas_contabilizadas) contab,
--          ROUND(100.0*SUM(actas_contabilizadas)/NULLIF(SUM(mesas_totales),0),2) pct
--     FROM v_avance_distrito GROUP BY provincia ORDER BY pct DESC;
--
-- Intentar contabilizar un acta observada falla (a propósito):
--   UPDATE actas SET estado = 'CONTABILIZADA' WHERE id = 12;
--   -- ERROR: ACTA_INCONSISTENTE: el acta 12 no cuadra en 1 columna(s):
--   --        ALCALDE (diferencia -3 votos). Debe resolverse la observación...
--
-- Descuadres por columna de un acta (la cabecera resume la principal):
--   SELECT * FROM fn_descuadres_acta(12);
--   SELECT acta_id, columnas_descuadradas, descuadres FROM v_actas_observadas;
