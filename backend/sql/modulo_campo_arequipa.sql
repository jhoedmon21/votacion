-- ============================================================================
--  Módulo de Control Político en Campo — Cobertura e Incidencias
--  Región Arequipa · Complemento de schema_arequipa.sql
--
--  Uso:
--      psql -d computo_arequipa -f backend/sql/schema_arequipa.sql
--      psql -d computo_arequipa -f backend/sql/modulo_campo_arequipa.sql
--
--  Depende de: ubigeo, usuarios, locales_votacion, mesas, usuario_alcance
--  (schema_arequipa.sql). Idempotente: CREATE TABLE IF NOT EXISTS,
--  CREATE OR REPLACE FUNCTION y DO $$ ... $$ para los ENUM.
--
--  Cubre los requerimientos del brief que el esquema base no contempla:
--    §2 Monitoreo de cobertura de colegios y mesas (semáforo + check-in GPS)
--    §3 Incidencias en campo con triaje, prioridad, estado y adjuntos
-- ============================================================================

BEGIN;

-- ============================================================================
--  1. TIPOS ENUMERADOS
-- ============================================================================

-- Estado operativo de un personero en su mesa el día D
DO $$ BEGIN
    CREATE TYPE estado_personero AS ENUM (
        'ASIGNADO',      -- nombrado, aún sin confirmación de presencia
        'CONFIRMADO',    -- confirmó asistencia a distancia (WhatsApp/llamada)
        'PRESENTE',      -- hizo check-in GPS dentro del radio del local
        'RETIRADO',      -- se retiró del local (fin de jornada, reemplazo)
        'INHABILITADO'   -- dado de baja por el coordinador (ausencia injustificada)
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Ciclo de vida de una incidencia de campo
DO $$ BEGIN
    CREATE TYPE estado_incidencia AS ENUM (
        'REPORTADA', 'EN_ATENCION', 'RESUELTA', 'DESCARTADA', 'ESCALADA'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Prioridad de triaje (la categoría sugiere la prioridad por defecto)
DO $$ BEGIN
    CREATE TYPE prioridad_incidencia AS ENUM ('BAJA', 'MEDIA', 'ALTA', 'CRITICA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Semáforo de cobertura del brief §2.1
DO $$ BEGIN
    CREATE TYPE nivel_cobertura AS ENUM ('VERDE', 'AMARILLO', 'ROJO');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Secuencia dedicada para el código público INC-NNNNNN (independiente del id,
-- así un INSERT fallido no desincroniza código e identidad).
DO $$ BEGIN
    CREATE SEQUENCE seq_incid_codigo START 1;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ============================================================================
--  2. COBERTURA: ASIGNACIÓN Y ASISTENCIA DE PERSONEROS
-- ============================================================================

-- Asignación de personeros a mesas. Una mesa puede tener varios personeros
-- (titular + suplente); el semáforo de cobertura se calcula sobre esto.
CREATE TABLE IF NOT EXISTS asignacion_personeros (
    id              BIGSERIAL    PRIMARY KEY,
    usuario_id      BIGINT       NOT NULL REFERENCES usuarios (id) ON DELETE CASCADE,
    mesa_id         BIGINT       NOT NULL REFERENCES mesas (id) ON DELETE CASCADE,
    tipo            VARCHAR(10)  NOT NULL DEFAULT 'TITULAR'
                    CHECK (tipo IN ('TITULAR', 'SUPLENTE')),
    estado          estado_personero NOT NULL DEFAULT 'ASIGNADO',
    asignado_por    BIGINT       REFERENCES usuarios (id) ON DELETE SET NULL,
    notas           TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- Un personero no se asigna dos veces a la misma mesa con el mismo rol
    CONSTRAINT uq_personero_mesa_rol UNIQUE (usuario_id, mesa_id, tipo)
);

CREATE INDEX IF NOT EXISTS idx_ap_mesa    ON asignacion_personeros (mesa_id);
CREATE INDEX IF NOT EXISTS idx_ap_usuario ON asignacion_personeros (usuario_id);
CREATE INDEX IF NOT EXISTS idx_ap_estado  ON asignacion_personeros (estado);

-- Check-in GPS del personero al llegar al local (brief §2.2). La posición se
-- guarda tal como llegó del dispositivo; la API valida el radio con la función
-- fn_checkin_en_radio (Haversine) y fija dentro_de_radio + distancia_m.
CREATE TABLE IF NOT EXISTS checkins_personero (
    id              BIGSERIAL      PRIMARY KEY,
    asignacion_id   BIGINT         NOT NULL REFERENCES asignacion_personeros (id) ON DELETE CASCADE,
    latitud         NUMERIC(10, 7) NOT NULL CHECK (latitud  BETWEEN -19 AND 0),
    longitud        NUMERIC(10, 7) NOT NULL CHECK (longitud BETWEEN -82 AND -68),
    presicion_m     NUMERIC(8, 2),                 -- accuracy del GPS en metros
    dentro_de_radio BOOLEAN        NOT NULL DEFAULT FALSE,
    distancia_m     NUMERIC(10, 2),                -- distancia calculada al local
    dispositivo     VARCHAR(120),
    created_at      TIMESTAMPTZ    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_checkin_asig ON checkins_personero (asignacion_id, created_at DESC);

-- ============================================================================
--  3. INCIDENCIAS DE CAMPO
-- ============================================================================

-- Catálogo editable (alta de categorías sin DDL). prioridad_default alimenta
-- el triaje automático del trigger trg_incid_prioridad.
CREATE TABLE IF NOT EXISTS categorias_incidencia (
    id                SMALLSERIAL  PRIMARY KEY,
    codigo            VARCHAR(40)  NOT NULL UNIQUE,
    nombre            VARCHAR(120) NOT NULL,
    prioridad_default prioridad_incidencia NOT NULL DEFAULT 'MEDIA',
    activo            BOOLEAN      NOT NULL DEFAULT TRUE
);

INSERT INTO categorias_incidencia (codigo, nombre, prioridad_default) VALUES
    ('MESA_NO_INSTALADA',        'Mesa no instalada a la hora de inicio',  'ALTA'),
    ('AUSENTISMO_MIEMBROS_MESA', 'Ausentismo de miembros de mesa',         'ALTA'),
    ('AGRESION_INTIMIDACION',    'Agresión o intimidación',                'CRITICA'),
    ('MATERIAL_INCOMPLETO',      'Material electoral incompleto',          'MEDIA'),
    ('INTENTO_DE_FRAUDE',        'Intento de fraude',                      'CRITICA'),
    ('IMPUGNACION_VOTOS',        'Impugnación de votos',                   'ALTA'),
    ('SIN_SENAL_COMUNICACION',   'Sin señal de comunicación en el local',  'BAJA'),
    ('OTRO',                     'Otro (especificar en descripción)',      'BAJA')
ON CONFLICT (codigo) DO UPDATE
    SET nombre            = EXCLUDED.nombre,
        prioridad_default = EXCLUDED.prioridad_default;

-- Incidencia reportada desde el campo
CREATE TABLE IF NOT EXISTS incidencias_campo (
    id                    BIGSERIAL     PRIMARY KEY,
    codigo                VARCHAR(12)   UNIQUE,  -- NULL en INSERT; trg_incid_codigo lo llena antes de constraints
    categoria_id          SMALLINT      NOT NULL REFERENCES categorias_incidencia (id),
    ubigeo                CHAR(6)       NOT NULL REFERENCES ubigeo (ubigeo) ON UPDATE CASCADE,
    local_id              BIGINT        REFERENCES locales_votacion (id) ON DELETE SET NULL,
    mesa_id               BIGINT        REFERENCES mesas (id) ON DELETE SET NULL,
    reportado_por         BIGINT        REFERENCES usuarios (id) ON DELETE SET NULL,
    titulo                VARCHAR(160)  NOT NULL,
    descripcion           TEXT          NOT NULL,
    prioridad             prioridad_incidencia NOT NULL DEFAULT 'MEDIA',
    estado                estado_incidencia    NOT NULL DEFAULT 'REPORTADA',
    -- Escalamiento jerárquico (brief §1): quién atiende según el nivel
    asignada_a            BIGINT        REFERENCES usuarios (id) ON DELETE SET NULL,
    resuelta_en           TIMESTAMPTZ,
    tiempo_resolucion_min NUMERIC(10, 2),
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT incidencia_titulo_no_vacio CHECK (length(btrim(titulo)) > 0)
);

COMMENT ON COLUMN incidencias_campo.codigo IS
'Código público INC-NNNNNN (secuencia seq_incid_codigo). DEFAULT lo completa el trigger BEFORE INSERT.';

-- Coherencia territorial (la mesa pertenece al ubigeo declarado): los CHECK no
-- admiten subconsultas, así que se exige por trigger trg_incid_coherencia.
CREATE OR REPLACE FUNCTION fn_incid_coherencia() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_ok BOOLEAN;
BEGIN
    IF NEW.mesa_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT l.ubigeo = NEW.ubigeo
      INTO v_ok
      FROM mesas m
      JOIN locales_votacion l ON l.id = m.local_id
     WHERE m.id = NEW.mesa_id;
    IF v_ok IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'INCIDENCIA_INCOHERENTE: la mesa % no pertenece al ubigeo %',
                        NEW.mesa_id, NEW.ubigeo;
    END IF;
    RETURN NEW;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_incid_ubigeo ON incidencias_campo (ubigeo);
CREATE INDEX IF NOT EXISTS idx_incid_estado ON incidencias_campo (estado);
CREATE INDEX IF NOT EXISTS idx_incid_prior  ON incidencias_campo (prioridad);
CREATE INDEX IF NOT EXISTS idx_incid_local  ON incidencias_campo (local_id);
CREATE INDEX IF NOT EXISTS idx_incid_abiertas ON incidencias_campo (estado, prioridad, created_at)
    WHERE estado IN ('REPORTADA', 'EN_ATENCION', 'ESCALADA');

-- Adjuntos: fotos y audios del campo (mismo patrón que acta_adjuntos)
CREATE TABLE IF NOT EXISTS incidencia_adjuntos (
    id            BIGSERIAL   PRIMARY KEY,
    incidencia_id BIGINT      NOT NULL REFERENCES incidencias_campo (id) ON DELETE CASCADE,
    tipo          VARCHAR(20) NOT NULL DEFAULT 'FOTO'
                  CHECK (tipo IN ('FOTO', 'AUDIO', 'VIDEO', 'DOC')),
    url           TEXT        NOT NULL,
    hash_sha256   CHAR(64),
    subido_por    BIGINT      REFERENCES usuarios (id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT adj_incid_hash_formato
        CHECK (hash_sha256 IS NULL OR hash_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE INDEX IF NOT EXISTS idx_adj_incid ON incidencia_adjuntos (incidencia_id);

-- Bitácora de seguimiento (triaje y atención, con comentario del operador)
CREATE TABLE IF NOT EXISTS incidencia_seguimiento (
    id            BIGSERIAL   PRIMARY KEY,
    incidencia_id BIGINT      NOT NULL REFERENCES incidencias_campo (id) ON DELETE CASCADE,
    usuario_id    BIGINT      REFERENCES usuarios (id) ON DELETE SET NULL,
    estado_nuevo  estado_incidencia,
    comentario    TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_seguimiento_incid
    ON incidencia_seguimiento (incidencia_id, created_at DESC);

-- ============================================================================
--  4. FUNCIONES Y TRIGGERS
-- ============================================================================

-- 4.1 updated_at automático (espeja fn_set_updated_at del esquema base)
CREATE OR REPLACE FUNCTION fn_campo_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_asignacion_updated ON asignacion_personeros;
CREATE TRIGGER trg_asignacion_updated BEFORE UPDATE ON asignacion_personeros
    FOR EACH ROW EXECUTE FUNCTION fn_campo_updated_at();

DROP TRIGGER IF EXISTS trg_incid_updated ON incidencias_campo;
CREATE TRIGGER trg_incid_updated BEFORE UPDATE ON incidencias_campo
    FOR EACH ROW EXECUTE FUNCTION fn_campo_updated_at();

-- 4.2 Código público INC-NNNNNN desde la secuencia dedicada
CREATE OR REPLACE FUNCTION fn_incid_codigo() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.codigo IS NULL THEN
        NEW.codigo := 'INC-' || lpad(nextval('seq_incid_codigo')::TEXT, 6, '0');
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_incid_codigo ON incidencias_campo;
CREATE TRIGGER trg_incid_codigo BEFORE INSERT ON incidencias_campo
    FOR EACH ROW EXECUTE FUNCTION fn_incid_codigo();

-- 4.3 Coherencia mesa/ubigeo (sustituye al CHECK con subconsulta, no permitido)
DROP TRIGGER IF EXISTS trg_incid_coherencia ON incidencias_campo;
CREATE TRIGGER trg_incid_coherencia BEFORE INSERT OR UPDATE OF mesa_id, ubigeo
    ON incidencias_campo
    FOR EACH ROW EXECUTE FUNCTION fn_incid_coherencia();

-- 4.4 Triaje automático: si no viene prioridad explícita, usa la de la categoría
CREATE OR REPLACE FUNCTION fn_incid_prioridad_default() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    SELECT ci.prioridad_default INTO NEW.prioridad
      FROM categorias_incidencia ci
     WHERE ci.id = NEW.categoria_id;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_incid_prioridad ON incidencias_campo;
CREATE TRIGGER trg_incid_prioridad BEFORE INSERT ON incidencias_campo
    FOR EACH ROW EXECUTE FUNCTION fn_incid_prioridad_default();

-- 4.5 Check-in válido => personero PRESENTE (enciende el semáforo de la mesa)
CREATE OR REPLACE FUNCTION fn_checkin_presente() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.dentro_de_radio THEN
        UPDATE asignacion_personeros
           SET estado = 'PRESENTE'
         WHERE id = NEW.asignacion_id
           AND estado <> 'PRESENTE';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_checkin_presente ON checkins_personero;
CREATE TRIGGER trg_checkin_presente AFTER INSERT ON checkins_personero
    FOR EACH ROW EXECUTE FUNCTION fn_checkin_presente();

-- 4.6 Bitácora automática de transiciones de estado
CREATE OR REPLACE FUNCTION fn_incid_bitacora() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' OR OLD.estado <> NEW.estado THEN
        INSERT INTO incidencia_seguimiento (incidencia_id, usuario_id, estado_nuevo, comentario)
        VALUES (
            NEW.id,
            NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT,
            NEW.estado,
            CASE
                WHEN TG_OP = 'INSERT' THEN 'Incidencia registrada en el sistema'
                ELSE 'Estado actualizado de ' || OLD.estado || ' a ' || NEW.estado
            END
        );
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_incid_bitacora ON incidencias_campo;
CREATE TRIGGER trg_incid_bitacora AFTER INSERT OR UPDATE OF estado ON incidencias_campo
    FOR EACH ROW EXECUTE FUNCTION fn_incid_bitacora();

-- 4.7 Cierre: sella resuelta_en y calcula el tiempo de resolución
CREATE OR REPLACE FUNCTION fn_incid_cierre() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.estado IN ('RESUELTA', 'DESCARTADA') THEN
        IF NEW.resuelta_en IS NULL THEN
            NEW.resuelta_en := now();
        END IF;
        NEW.tiempo_resolucion_min :=
            round((EXTRACT(EPOCH FROM (NEW.resuelta_en - OLD.created_at)) / 60.0)::NUMERIC, 2);
    ELSE
        NEW.resuelta_en := NULL;
        NEW.tiempo_resolucion_min := NULL;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_incid_cierre ON incidencias_campo;
CREATE TRIGGER trg_incid_cierre BEFORE UPDATE OF estado ON incidencias_campo
    FOR EACH ROW EXECUTE FUNCTION fn_incid_cierre();

-- ============================================================================
--  5. SEMÁFORO DE COBERTURA (funciones de lectura)
-- ============================================================================

-- 5.1 Estado de cobertura de un local. Regla (brief §2.1):
--   ROJO     = al menos una mesa sin ningún personero asignado
--   AMARILLO = todas cubiertas con asignación, pero alguna sin personero PRESENTE
--   VERDE    = todas las mesas del local con ≥1 personero PRESENTE
CREATE OR REPLACE FUNCTION fn_estado_cobertura_local(p_local_id BIGINT)
RETURNS nivel_cobertura
LANGUAGE sql STABLE AS $$
    WITH cobertura AS (
        SELECT m.id AS mesa_id,
               bool_or(ap.estado = 'PRESENTE') AS con_presente,
               count(ap.id) > 0                AS con_asignado
          FROM mesas m
          LEFT JOIN asignacion_personeros ap ON ap.mesa_id = m.id
         WHERE m.local_id = p_local_id
         GROUP BY m.id
    )
    SELECT CASE
        WHEN count(*) FILTER (WHERE NOT con_asignado) > 0 THEN 'ROJO'::nivel_cobertura
        WHEN count(*) FILTER (WHERE NOT con_presente) > 0 THEN 'AMARILLO'::nivel_cobertura
        ELSE 'VERDE'::nivel_cobertura
    END
      FROM cobertura;
$$;

-- 5.2 ¿El punto GPS cae dentro del radio del local? (Haversine, 300 m por defecto)
CREATE OR REPLACE FUNCTION fn_checkin_en_radio(
    p_local_id BIGINT, p_lat NUMERIC, p_lon NUMERIC, p_radio_m NUMERIC DEFAULT 300
) RETURNS TABLE (dentro BOOLEAN, distancia_m NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT (6371000 * 2 * asin(sqrt(
                power(sin(radians(l.latitud  - p_lat) / 2), 2) +
                cos(radians(p_lat)) * cos(radians(l.latitud)) *
                power(sin(radians(l.longitud - p_lon) / 2), 2)
           ))) <= p_radio_m,
           round((6371000 * 2 * asin(sqrt(
                power(sin(radians(l.latitud  - p_lat) / 2), 2) +
                cos(radians(p_lat)) * cos(radians(l.latitud)) *
                power(sin(radians(l.longitud - p_lon) / 2), 2)
           )))::NUMERIC, 1)
      FROM locales_votacion l
     WHERE l.id = p_local_id;
$$;

-- ============================================================================
--  6. VISTAS ANALÍTICAS
-- ============================================================================

-- 6.1 Semáforo por local para el dashboard (una fila por local)
CREATE OR REPLACE VIEW v_cobertura_locales AS
WITH cobertura AS (
    SELECT m.local_id,
           m.id AS mesa_id,
           bool_or(ap.estado = 'PRESENTE') AS con_presente,
           count(ap.id) FILTER (
               WHERE ap.estado IN ('ASIGNADO', 'CONFIRMADO', 'PRESENTE')
           ) > 0 AS con_asignado
      FROM mesas m
      LEFT JOIN asignacion_personeros ap ON ap.mesa_id = m.id
     GROUP BY m.local_id, m.id
)
SELECT l.id                                                    AS local_id,
       l.codigo_local,
       l.nombre,
       u.ubigeo,
       u.distrito,
       u.provincia,
       count(cobertura.mesa_id)                                AS mesas_total,
       count(cobertura.mesa_id) FILTER (WHERE cobertura.con_presente)
                                                               AS mesas_con_presencia,
       count(cobertura.mesa_id) FILTER (WHERE NOT cobertura.con_asignado)
                                                               AS mesas_sin_personero,
       CASE
           WHEN count(*) FILTER (WHERE NOT cobertura.con_asignado) > 0
               THEN 'ROJO'::nivel_cobertura
           WHEN count(*) FILTER (WHERE NOT cobertura.con_presente) > 0
               THEN 'AMARILLO'::nivel_cobertura
           ELSE 'VERDE'::nivel_cobertura
       END                                                     AS nivel,
       -- Foco de atención: números de mesa críticas del local
       (SELECT string_agg(mm.numero_mesa, ', ' ORDER BY mm.numero_mesa)
          FROM mesas mm
         WHERE mm.local_id = l.id
           AND NOT EXISTS (SELECT 1 FROM asignacion_personeros x WHERE x.mesa_id = mm.id)
       )                                                       AS mesas_criticas
  FROM locales_votacion l
  JOIN ubigeo u ON u.ubigeo = l.ubigeo
  LEFT JOIN cobertura ON cobertura.local_id = l.id
 GROUP BY l.id, l.codigo_local, l.nombre, u.ubigeo, u.distrito, u.provincia;

COMMENT ON VIEW v_cobertura_locales IS
'Semáforo de cobertura por local: VERDE/AMARILLO/ROJO según personeros presentes/asignados.';

-- 6.2 Bandeja de incidencias abiertas, ya ordenada por triaje
CREATE OR REPLACE VIEW v_incidencias_abiertas AS
SELECT i.id,
       i.codigo,
       ci.nombre            AS categoria,
       i.prioridad,
       i.estado,
       i.titulo,
       i.ubigeo,
       u.provincia,
       u.distrito,
       l.nombre             AS local,
       m.numero_mesa        AS mesa,
       i.created_at,
       round((date_part('epoch', now() - i.created_at) / 60)::NUMERIC, 1) AS minutos_abierta,
       (SELECT count(*) FROM incidencia_adjuntos a
         WHERE a.incidencia_id = i.id)                           AS adjuntos
  FROM incidencias_campo i
  JOIN categorias_incidencia ci ON ci.id = i.categoria_id
  JOIN ubigeo u                 ON u.ubigeo = i.ubigeo
  LEFT JOIN locales_votacion l  ON l.id = i.local_id
  LEFT JOIN mesas m             ON m.id = i.mesa_id
 WHERE i.estado IN ('REPORTADA', 'EN_ATENCION', 'ESCALADA')
 ORDER BY CASE i.prioridad
              WHEN 'CRITICA' THEN 0
              WHEN 'ALTA'    THEN 1
              WHEN 'MEDIA'   THEN 2
              ELSE 3
          END,
          i.created_at;

-- 6.3 Semáforo agregado por distrito (mapa de calor del dashboard)
CREATE OR REPLACE VIEW v_cobertura_distrito AS
SELECT u.ubigeo,
       u.distrito,
       u.provincia,
       count(DISTINCT cl.id) AS locales_total,
       count(DISTINCT cl.id) FILTER (WHERE cov.nivel = 'VERDE')    AS locales_verdes,
       count(DISTINCT cl.id) FILTER (WHERE cov.nivel = 'AMARILLO') AS locales_amarillos,
       count(DISTINCT cl.id) FILTER (WHERE cov.nivel = 'ROJO')     AS locales_rojos,
       CASE
           WHEN count(DISTINCT cl.id) FILTER (WHERE cov.nivel = 'ROJO') > 0
               THEN 'ROJO'::nivel_cobertura
           WHEN count(DISTINCT cl.id) FILTER (WHERE cov.nivel = 'AMARILLO') > 0
               THEN 'AMARILLO'::nivel_cobertura
           WHEN count(DISTINCT cl.id) > 0
               THEN 'VERDE'::nivel_cobertura
           ELSE 'ROJO'::nivel_cobertura  -- distrito sin locales cubiertos
       END AS nivel
  FROM ubigeo u
  LEFT JOIN locales_votacion cl ON cl.ubigeo = u.ubigeo
  LEFT JOIN v_cobertura_locales cov ON cov.local_id = cl.id
 WHERE u.nivel = 'DISTRITO'
 GROUP BY u.ubigeo, u.distrito, u.provincia;

-- ============================================================================
--  7. SEGURIDAD A NIVEL DE FILA (RLS) — espeja el patrón del esquema base
-- ============================================================================
-- El backend fija por petición antes de abrir transacción:
--   SET LOCAL app.usuario_id = '42';
--   SET LOCAL app.rol_actual  = 'PERSONERO';
--
-- SUPER_ADMIN: ve todo (rol_actual). Personero: lo suyo. Coordinadores: las
-- filas de su ámbito territorial (distrito exacto o provincia completa).

ALTER TABLE asignacion_personeros ENABLE ROW LEVEL SECURITY;
ALTER TABLE incidencias_campo    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pol_asig_alcance ON asignacion_personeros;
CREATE POLICY pol_asig_alcance ON asignacion_personeros
    USING (
        current_setting('app.rol_actual', TRUE) = 'SUPER_ADMIN'
        OR usuario_id = NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT
        OR EXISTS (
            SELECT 1
              FROM mesas m
              JOIN locales_votacion l ON l.id = m.local_id
              JOIN usuario_alcance ua
                    ON ua.usuario_id
                       = NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT
             WHERE m.id = asignacion_personeros.mesa_id
               AND (l.id = ua.local_id                     -- COORD_LOCAL (migración de jerarquía)
                    OR l.ubigeo = ua.ubigeo
                    OR (EXISTS (SELECT 1 FROM ubigeo up
                                 WHERE up.ubigeo = ua.ubigeo
                                   AND up.nivel = 'PROVINCIA')
                        AND substring(l.ubigeo, 1, 4) = substring(ua.ubigeo, 1, 4)))
        )
    );

DROP POLICY IF EXISTS pol_incid_alcance ON incidencias_campo;
CREATE POLICY pol_incid_alcance ON incidencias_campo
    USING (
        current_setting('app.rol_actual', TRUE) = 'SUPER_ADMIN'
        OR reportado_por = NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT
        OR EXISTS (
            SELECT 1
              FROM usuario_alcance ua
             WHERE ua.usuario_id
                       = NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT
               AND (incidencias_campo.local_id = ua.local_id -- COORD_LOCAL (migración de jerarquía)
                    OR incidencias_campo.ubigeo = ua.ubigeo
                    OR (EXISTS (SELECT 1 FROM ubigeo up
                                 WHERE up.ubigeo = ua.ubigeo
                                   AND up.nivel = 'PROVINCIA')
                        AND substring(incidencias_campo.ubigeo, 1, 4)
                            = substring(ua.ubigeo, 1, 4)))
        )
    );

COMMIT;

-- ============================================================================
--  8. CONSULTAS DE OPERACIÓN
-- ============================================================================
-- Semáforo global para el header del dashboard:
--   SELECT nivel, count(*) FROM v_cobertura_locales GROUP BY nivel;
--
-- Locales rojos de una provincia con sus mesas críticas:
--   SELECT distrito, nombre, mesas_criticas
--     FROM v_cobertura_locales
--    WHERE provincia = 'AREQUIPA' AND nivel = 'ROJO'
--    ORDER BY mesas_sin_personero DESC;
--
-- Bandeja de triaje (ya ordenada por prioridad y antigüedad):
--   SELECT * FROM v_incidencias_abiertas LIMIT 50;
--
-- Check-in del personero (la API calcula dentro_de_radio/distancia antes):
--   SELECT * FROM fn_checkin_en_radio(7, -16.4039, -71.5375, 300);
--   INSERT INTO checkins_personero
--          (asignacion_id, latitud, longitud, presicion_m, dentro_de_radio, distancia_m)
--   VALUES (7, -16.4039, -71.5375, 12.5, TRUE, 45.2);
--   -- trg_checkin_presente eleva automáticamente al personero a PRESENTE
--
-- Escalar una incidencia al coordinador provincial:
--   UPDATE incidencias_campo
--      SET estado = 'ESCALADA', prioridad = 'CRITICA', asignada_a = 3
--    WHERE id = 12;
--   -- trg_incid_bitacora deja constancia en incidencia_seguimiento
-- ============================================================================
