-- ============================================================================
--  Sistema de Registro, OCR y Cómputo Electoral en Tiempo Real — ONPE
--  Esquema productivo PostgreSQL 15+ / Supabase
--
--  Uso:
--      createdb computo_onpe
--      psql -d computo_onpe -f backend/sql/schema.sql
--
--  Decisiones:
--    * PKs UUID (gen_random_uuid): aptas para ingesta distribuida y réplicas.
--    * `ubigeo` conserva su código INEI CHAR(6) como PK natural (es el código
--      oficial; los UUID no aportan nada aquí).
--    * La matemática ONPE (R1/R2) se valida en la API (`/api/v1/actas/registrar`)
--      y se expone como función SQL (`fn_validar_acta`) para auditoría y
--      reportes; la base GUARDA el acta tal como está en el papel (con estado
--      OBSERVADA/IMPUGNADA) y nunca la rechaza en INSERT.
--    * Auditoría de cambios con valor original/corregido/motivo
--      (`acta_auditoria` + trigger), según el flujo de trazabilidad del brief.
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()

-- ============================================================================
--  1. ENUMERADOS
-- ============================================================================

CREATE TYPE tipo_eleccion AS ENUM ('REGIONAL', 'PROVINCIAL', 'DISTRITAL');

CREATE TYPE estado_acta AS ENUM (
    'NORMAL',      -- cuadró la matemática, entra al cómputo
    'OBSERVADA',   -- inconsistencia aritmética o de padrón: va a revisión
    'IMPUGNADA'    -- impugnación de identidad / disconformidad en el papel
);

-- ============================================================================
--  2. UBIGEO (catálogo territorial INEI)
-- ============================================================================

CREATE TABLE ubigeo (
    ubigeo       CHAR(6)     PRIMARY KEY,
    departamento VARCHAR(60) NOT NULL,
    provincia    VARCHAR(60),
    distrito     VARCHAR(60),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ubigeo_formato CHECK (ubigeo ~ '^[0-9]{6}$')
);

-- ============================================================================
--  3. ORGANIZACIONES POLÍTICAS
-- ============================================================================

CREATE TABLE organizaciones_politicas (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre       VARCHAR(160) NOT NULL UNIQUE,
    nombre_corto VARCHAR(60),
    tipo         VARCHAR(40) NOT NULL DEFAULT 'PARTIDO_NACIONAL'
                 CHECK (tipo IN ('PARTIDO_NACIONAL', 'MOVIMIENTO_REGIONAL',
                                 'ALIANZA_ELECTORAL')),
    color_hex    CHAR(7)     NOT NULL DEFAULT '#6b7280',
    logo_url     TEXT,
    activo       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT org_color_formato CHECK (color_hex ~* '^#[0-9a-f]{6}$')
);

-- ============================================================================
--  4. MESAS DE SUFRAGIO (padrón ONPE)
-- ============================================================================

CREATE TABLE mesas (
    id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    numero_mesa       CHAR(6)      NOT NULL UNIQUE,   -- 6 dígitos del acta
    ubigeo            CHAR(6)      NOT NULL REFERENCES ubigeo (ubigeo),
    local_nombre      VARCHAR(160) NOT NULL,          -- centro educativo
    local_direccion   VARCHAR(220),
    electores_habiles INTEGER      NOT NULL,          -- tope de la regla R2
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT mesas_numero_formato     CHECK (numero_mesa ~ '^[0-9]{6}$'),
    CONSTRAINT mesas_electores_positivo CHECK (electores_habiles > 0)
);

CREATE INDEX idx_mesas_ubigeo ON mesas (ubigeo);

-- ============================================================================
--  5. ACTAS (cabecera del escrutinio)
-- ============================================================================

CREATE TABLE actas (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    mesa_id          UUID          NOT NULL REFERENCES mesas (id) ON DELETE RESTRICT,
    tipo_eleccion    tipo_eleccion NOT NULL,
    estado           estado_acta   NOT NULL DEFAULT 'NORMAL',

    -- Cómputo del papel (columna principal del acta física)
    electores_habiles INTEGER      NOT NULL,   -- copia del padrón al digitar
    total_emitidos    INTEGER      NOT NULL DEFAULT 0,
    votos_blancos     INTEGER      NOT NULL DEFAULT 0,
    votos_nulos       INTEGER      NOT NULL DEFAULT 0,
    votos_impugnados  INTEGER      NOT NULL DEFAULT 0,  -- impugnación de identidad

    -- Evidencia y trazabilidad
    foto_url         TEXT,
    foto_hash_sha256 CHAR(64),
    observacion      TEXT,          -- motivo de OBSERVADA / IMPUGNADA
    registrada_por   VARCHAR(160),  -- email del digitador
    registrada_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),

    -- Una mesa tiene a lo más un acta por tipo de elección (anti-duplicado)
    CONSTRAINT actas_unica_por_mesa_eleccion UNIQUE (mesa_id, tipo_eleccion),
    CONSTRAINT actas_no_negativas CHECK (
        total_emitidos >= 0 AND votos_blancos >= 0 AND votos_nulos >= 0
        AND votos_impugnados >= 0 AND electores_habiles > 0
    ),
    CONSTRAINT actas_hash_formato
        CHECK (foto_hash_sha256 IS NULL OR foto_hash_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE INDEX idx_actas_mesa   ON actas (mesa_id);
CREATE INDEX idx_actas_estado ON actas (estado);
CREATE INDEX idx_actas_tipo   ON actas (tipo_eleccion, estado);
CREATE UNIQUE INDEX idx_actas_foto_hash ON actas (foto_hash_sha256)
    WHERE foto_hash_sha256 IS NOT NULL;

-- ============================================================================
--  6. DETALLE DE VOTOS (por organización política)
-- ============================================================================

CREATE TABLE detalle_votos_acta (
    id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    acta_id         UUID    NOT NULL REFERENCES actas (id) ON DELETE CASCADE,
    organizacion_id UUID    NOT NULL REFERENCES organizaciones_politicas (id)
                                     ON DELETE RESTRICT,
    votos           INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT detalle_votos_no_negativos CHECK (votos >= 0),
    CONSTRAINT detalle_unico_por_acta     UNIQUE (acta_id, organizacion_id)
);

CREATE INDEX idx_detalle_acta ON detalle_votos_acta (acta_id);
CREATE INDEX idx_detalle_org  ON detalle_votos_acta (organizacion_id);

-- ============================================================================
--  7. AUDITORÍA (usuario, timestamp, original, corregido, motivo)
-- ============================================================================

CREATE TABLE acta_auditoria (
    id               BIGSERIAL   PRIMARY KEY,
    acta_id          UUID        NOT NULL REFERENCES actas (id) ON DELETE CASCADE,
    usuario          VARCHAR(160) NOT NULL,   -- quién corrigió
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    campo            VARCHAR(60) NOT NULL,    -- 'votos:<org>' | 'estado' | ...
    valor_original   TEXT        NOT NULL,
    valor_corregido  TEXT        NOT NULL,
    motivo           TEXT        NOT NULL
);

CREATE INDEX idx_auditoria_acta ON acta_auditoria (acta_id, created_at DESC);

-- updated_at automático
CREATE OR REPLACE FUNCTION fn_set_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_org_updated     BEFORE UPDATE ON organizaciones_politicas FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_mesas_updated    BEFORE UPDATE ON mesas                   FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_actas_updated    BEFORE UPDATE ON actas                   FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_detalle_updated  BEFORE UPDATE ON detalle_votos_acta      FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- Auditoría de cambios de estado del acta
CREATE OR REPLACE FUNCTION fn_auditar_estado_acta() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO acta_auditoria (acta_id, usuario, campo,
                                    valor_original, valor_corregido, motivo)
        VALUES (NEW.id, COALESCE(NEW.registrada_por, 'sistema'), 'estado',
                OLD.estado::TEXT, NEW.estado::TEXT,
                COALESCE(NEW.observacion, 'cambio de estado'));
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_actas_auditar_estado
    AFTER UPDATE OF estado ON actas
    FOR EACH ROW EXECUTE FUNCTION fn_auditar_estado_acta();

-- ============================================================================
--  8. VALIDACIÓN MATEMÁTICA ONPE (función de lectura para la API y reportes)
--     R1: Σ votos + blancos + nulos + impugnados == total_emitidos
--     R2: total_emitidos <= electores_habiles
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_validar_acta(p_acta_id UUID)
RETURNS TABLE (r1_ok BOOLEAN, r2_ok BOOLEAN, suma_partes INTEGER, diferencia INTEGER)
LANGUAGE sql STABLE AS $$
    SELECT
        (COALESCE(d.suma, 0) + a.votos_blancos + a.votos_nulos + a.votos_impugnados
            = a.total_emitidos)                                    AS r1_ok,
        (a.total_emitidos <= a.electores_habiles)                  AS r2_ok,
        (COALESCE(d.suma, 0) + a.votos_blancos + a.votos_nulos
            + a.votos_impugnados)                                  AS suma_partes,
        (a.total_emitidos - (COALESCE(d.suma, 0) + a.votos_blancos
            + a.votos_nulos + a.votos_impugnados))                 AS diferencia
      FROM actas a
      LEFT JOIN (SELECT acta_id, SUM(votos)::INTEGER AS suma
                   FROM detalle_votos_acta GROUP BY acta_id) d
        ON d.acta_id = a.id
     WHERE a.id = p_acta_id;
$$;

-- ============================================================================
--  9. VISTA DE CÓMPUTO DISTRITAL EN TIEMPO REAL
--     Votos por ubigeo y partido (sólo actas NORMAL) + avance del cómputo.
-- ============================================================================

CREATE OR REPLACE VIEW vista_resultados_distritales AS
SELECT
    m.ubigeo,
    u.departamento,
    u.provincia,
    u.distrito,
    a.tipo_eleccion,
    op.id    AS organizacion_id,
    op.nombre AS organizacion,
    op.color_hex,
    SUM(d.votos)                 AS votos,
    COUNT(DISTINCT a.id)         AS actas_computadas,
    (SELECT COUNT(*) FROM actas ax
       JOIN mesas mx ON mx.id = ax.mesa_id
      WHERE mx.ubigeo = m.ubigeo AND ax.tipo_eleccion = a.tipo_eleccion) AS actas_totales,
    ROUND(100.0 * COUNT(DISTINCT a.id) / NULLIF((
        SELECT COUNT(*) FROM actas ax
         JOIN mesas mx ON mx.id = ax.mesa_id
        WHERE mx.ubigeo = m.ubigeo AND ax.tipo_eleccion = a.tipo_eleccion
    ), 0), 2)                    AS avance_pct
FROM detalle_votos_acta d
JOIN actas a                  ON a.id = d.acta_id
JOIN mesas m                  ON m.id = a.mesa_id
JOIN ubigeo u                 ON u.ubigeo = m.ubigeo
JOIN organizaciones_politicas op ON op.id = d.organizacion_id
WHERE a.estado = 'NORMAL'
GROUP BY m.ubigeo, u.departamento, u.provincia, u.distrito,
         a.tipo_eleccion, op.id, op.nombre, op.color_hex;

COMMENT ON VIEW vista_resultados_distritales IS
'Cómputo oficial en vivo por ubigeo y organización (sólo actas NORMAL).';

-- ============================================================================
--  11. UBIGEO: 29 DISTRITOS DE LA PROVINCIA DE AREQUIPA (orden oficial)
--     Jerarquía electoral estricta de navegación y cómputo:
--       1º REGIONAL (040000) → 2º PROVINCIAL (040100) → 3º DISTRITAL (0401xx)
-- ============================================================================

INSERT INTO ubigeo (ubigeo, departamento, provincia, distrito) VALUES
    ('040000', 'AREQUIPA', NULL, NULL),
    ('040100', 'AREQUIPA', 'AREQUIPA', NULL),
    ('040101', 'AREQUIPA', 'AREQUIPA', 'AREQUIPA'),
    ('040102', 'AREQUIPA', 'AREQUIPA', 'ALTO SELVA ALEGRE'),
    ('040103', 'AREQUIPA', 'AREQUIPA', 'CAYMA'),
    ('040104', 'AREQUIPA', 'AREQUIPA', 'CERRO COLORADO'),
    ('040105', 'AREQUIPA', 'AREQUIPA', 'CHARACATO'),
    ('040106', 'AREQUIPA', 'AREQUIPA', 'CHIGUATA'),
    ('040107', 'AREQUIPA', 'AREQUIPA', 'JACOBO HUNTER'),
    ('040108', 'AREQUIPA', 'AREQUIPA', 'LA JOYA'),
    ('040109', 'AREQUIPA', 'AREQUIPA', 'MARIANO MELGAR'),
    ('040110', 'AREQUIPA', 'AREQUIPA', 'MIRAFLORES'),
    ('040111', 'AREQUIPA', 'AREQUIPA', 'MOLLEBAYA'),
    ('040112', 'AREQUIPA', 'AREQUIPA', 'PAUCARPATA'),
    ('040113', 'AREQUIPA', 'AREQUIPA', 'POCSI'),
    ('040114', 'AREQUIPA', 'AREQUIPA', 'POLOBAYA'),
    ('040115', 'AREQUIPA', 'AREQUIPA', 'QUEQUEÑA'),
    ('040116', 'AREQUIPA', 'AREQUIPA', 'SABANDIA'),
    ('040117', 'AREQUIPA', 'AREQUIPA', 'SACHACA'),
    ('040118', 'AREQUIPA', 'AREQUIPA', 'SAN JUAN DE SIGUAS'),
    ('040119', 'AREQUIPA', 'AREQUIPA', 'SAN JUAN DE TARUCANI'),
    ('040120', 'AREQUIPA', 'AREQUIPA', 'SANTA ISABEL DE SIGUAS'),
    ('040121', 'AREQUIPA', 'AREQUIPA', 'SANTA RITA DE SIGUAS'),
    ('040122', 'AREQUIPA', 'AREQUIPA', 'SOCABAYA'),
    ('040123', 'AREQUIPA', 'AREQUIPA', 'TIABAYA'),
    ('040124', 'AREQUIPA', 'AREQUIPA', 'UCHUMAYO'),
    ('040125', 'AREQUIPA', 'AREQUIPA', 'VITOR'),
    ('040126', 'AREQUIPA', 'AREQUIPA', 'YANAHUARA'),
    ('040127', 'AREQUIPA', 'AREQUIPA', 'YARABAMBA'),
    ('040128', 'AREQUIPA', 'AREQUIPA', 'YURA'),
    ('040129', 'AREQUIPA', 'AREQUIPA', 'JOSE LUIS BUSTAMANTE Y RIVERO')
ON CONFLICT (ubigeo) DO NOTHING;

-- ============================================================================
--  12. VISTA DE CÓMPUTO DE LA PROVINCIA (filtrable por nivel y distrito)
-- ============================================================================

CREATE OR REPLACE VIEW vista_computo_arequipa AS
SELECT
    m.ubigeo,
    u.distrito,
    a.tipo_eleccion,
    -- Orden oficial de presentación: 1º Regional, 2º Provincial, 3º Distrital
    CASE a.tipo_eleccion
        WHEN 'REGIONAL'   THEN 1
        WHEN 'PROVINCIAL' THEN 2
        ELSE 3
    END                               AS orden_nivel,
    op.nombre                         AS organizacion,
    op.color_hex,
    SUM(d.votos)                      AS votos,
    COUNT(DISTINCT a.id)              AS actas_computadas,
    ROUND(100.0 * COUNT(DISTINCT a.id) / NULLIF((
        SELECT COUNT(*) FROM actas ax
         JOIN mesas mx ON mx.id = ax.mesa_id
        WHERE mx.ubigeo = m.ubigeo AND ax.tipo_eleccion = a.tipo_eleccion
    ), 0), 2)                         AS avance_pct
FROM detalle_votos_acta d
JOIN actas a                  ON a.id = d.acta_id
JOIN mesas m                  ON m.id = a.mesa_id
JOIN ubigeo u                 ON u.ubigeo = m.ubigeo
JOIN organizaciones_politicas op ON op.id = d.organizacion_id
WHERE a.estado = 'NORMAL'
  AND u.provincia = 'AREQUIPA'
GROUP BY m.ubigeo, u.distrito, a.tipo_eleccion, op.nombre, op.color_hex;

COMMENT ON VIEW vista_computo_arequipa IS
'Cómputo de la provincia de Arequipa filtrable por nivel (orden oficial R→P→D) y distrito.';

COMMIT;

-- ============================================================================
--  10. CONSULTAS DE OPERACIÓN
-- ============================================================================
-- Cómputo de un distrito:
--   SELECT organizacion, votos, avance_pct FROM vista_resultados_distritales
--    WHERE ubigeo = '040112' AND tipo_eleccion = 'DISTRITAL' ORDER BY votos DESC;
--
-- Cola de observadas con su descuadre:
--   SELECT m.numero_mesa, a.tipo_eleccion, v.diferencia, v.suma_partes,
--          a.total_emitidos, a.electores_habiles
--     FROM actas a JOIN mesas m ON m.id = a.mesa_id
--     JOIN LATERAL fn_validar_acta(a.id) v ON TRUE
--    WHERE a.estado = 'OBSERVADA';
