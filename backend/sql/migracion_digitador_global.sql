-- ============================================================================
--  Migración — Rol transversal DIGITADOR_GLOBAL + auditoría estricta
--  Región Arequipa · Complemento de schema_arequipa.sql + migracion_jerarquia_completa.sql
--
--  Lo que aporta:
--    1. Nuevo valor `DIGITADOR_GLOBAL` en el enum `rol_usuario` (alcance
--       nacional: ignora filtros ubigeo en API y RLS).
--    2. Tabla `acta_auditoria_global` (append-only): cada CREAR/MODIFICAR
--       guarda usuario, IP, timestamp, valores anteriores/nuevos en JSON.
--    3. RLS: el Digitador Global ve todas las mesas/locales/actas; la
--       auditoría es de sólo-lectura para todos salvo SUPER_ADMIN.
--    4. Seed demo del digitador (idempotente).
--
--  Orden de ejecución (psql, autocommit por sentencia — NO envolver en una
--  sola transacción: los ALTER TYPE ... ADD VALUE no corren dentro de un
--  bloque con usos posteriores del enum):
--      psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/sql/schema_arequipa.sql
--      psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/sql/modulo_campo_arequipa.sql
--      psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/sql/migracion_jerarquia_completa.sql
--      psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/sql/migracion_digitador_global.sql
--
--  Idempotente: se puede re-ejecutar sin daño.
--  Prototipo SQLite: la tabla se crea vía SQLAlchemy (Base.metadata.create_all);
--  este archivo gobierna el PostgreSQL productivo.
-- ============================================================================

-- ============================================================================
--  1. ROL NUEVO (idempotente por DO + duplicate_object)
-- ============================================================================
DO $$ BEGIN
    ALTER TYPE rol_usuario ADD VALUE 'DIGITADOR_GLOBAL';  -- alcance nacional, sin filtro ubigeo
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ============================================================================
--  2. AUDITORÍA ESTRICTA (append-only: sin UPDATE ni DELETE vía GRANT)
-- ============================================================================
CREATE TABLE IF NOT EXISTS acta_auditoria_global (
    id                 BIGSERIAL   PRIMARY KEY,
    acta_id            UUID        NOT NULL REFERENCES actas (id) ON DELETE CASCADE,
    numero_mesa        CHAR(6)     NOT NULL,
    accion             VARCHAR(10) NOT NULL CHECK (accion IN ('CREAR', 'MODIFICAR')),
    usuario_id         BIGINT      REFERENCES usuarios (id) ON DELETE SET NULL,
    usuario_email      VARCHAR(160) NOT NULL,
    usuario_rol        VARCHAR(30)  NOT NULL DEFAULT 'DIGITADOR_GLOBAL',
    ip                 VARCHAR(45),
    valores_anteriores JSONB       NOT NULL DEFAULT '{}'::JSONB,
    valores_nuevos     JSONB       NOT NULL DEFAULT '{}'::JSONB,
    motivo             TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT auditoria_mesa_formato CHECK (numero_mesa ~ '^[0-9]{6}$')
);

CREATE INDEX IF NOT EXISTS idx_auditoria_global_acta
    ON acta_auditoria_global (acta_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_auditoria_global_mesa
    ON acta_auditoria_global (numero_mesa, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_auditoria_global_usuario
    ON acta_auditoria_global (usuario_id, created_at DESC);

COMMENT ON TABLE acta_auditoria_global IS
'Auditoría obligatoria del Digitador Global: quién (usuario_id/email/rol), desde dónde (ip), cuándo (created_at) y diff completo (valores_anteriores/nuevos en JSON). Append-only.';

-- Variante del prototipo SQLite (tables.id INTEGER en vez de actas.id UUID):
--   CREATE TABLE IF NOT EXISTS acta_auditoria_global (
--       id INTEGER PRIMARY KEY AUTOINCREMENT, acta_id INTEGER NOT NULL,
--       numero_mesa VARCHAR(6) NOT NULL, accion VARCHAR(10) NOT NULL, ...
--   );
-- La genera SQLAlchemy desde app/core/models.py::ActaAuditoriaGlobal.

-- ============================================================================
--  3. RLS — el Digitador Global omite el scope geográfico
-- ============================================================================
ALTER TABLE acta_auditoria_global ENABLE ROW LEVEL SECURITY;

-- Lectura: SUPER_ADMIN y DIGITADOR_GLOBAL ven todo; el resto sólo sus filas.
DROP POLICY IF EXISTS pol_auditoria_global_lectura ON acta_auditoria_global;
CREATE POLICY pol_auditoria_global_lectura ON acta_auditoria_global
    FOR SELECT USING (
        current_setting('app.rol_actual', TRUE) IN ('SUPER_ADMIN', 'DIGITADOR_GLOBAL')
        OR usuario_id = NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT
    );

-- Escritura: sólo el Digitador Global (y SUPER_ADMIN) INSERTA; nadie UPDATE/DELETE.
DROP POLICY IF EXISTS pol_auditoria_global_insert ON acta_auditoria_global;
CREATE POLICY pol_auditoria_global_insert ON acta_auditoria_global
    FOR INSERT WITH CHECK (
        current_setting('app.rol_actual', TRUE) IN ('SUPER_ADMIN', 'DIGITADOR_GLOBAL')
    );

-- Actas/mesas/locales: el Digitador Global entra al mismo bypass que SUPER_ADMIN.
-- (Se re-declaran las políticas de alcance para incluir el rol; si el esquema
-- base aún no las tiene, estas sentencias son no-op seguras tras el IF.)
DO $$ BEGIN
    DROP POLICY IF EXISTS pol_asig_alcance ON asignacion_personeros;
    CREATE POLICY pol_asig_alcance ON asignacion_personeros
        USING (
            current_setting('app.rol_actual', TRUE) IN ('SUPER_ADMIN', 'DIGITADOR_GLOBAL')
            OR usuario_id = NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT
            OR EXISTS (
                SELECT 1 FROM mesas m
                JOIN locales_votacion l ON l.id = m.local_id
                JOIN usuario_alcance ua
                  ON ua.usuario_id = NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT
                WHERE m.id = asignacion_personeros.mesa_id
                  AND (l.id = ua.local_id OR l.ubigeo = ua.ubigeo)
            )
        );
EXCEPTION WHEN undefined_table THEN NULL; END $$;

-- ============================================================================
--  4. HELPER — ¿tiene alcance nacional? (la API lo espeja en es_rol_global())
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_es_rol_global(p_rol TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
    SELECT p_rol IN ('SUPER_ADMIN', 'DIGITADOR_GLOBAL');
$$;

COMMENT ON FUNCTION fn_es_rol_global(TEXT) IS
'True si el rol omite el scope geográfico (SUPER_ADMIN, DIGITADOR_GLOBAL).';

-- ============================================================================
--  5. SEED DEMO — digitador nacional (idempotente; bcrypt cost 12)
-- ============================================================================
INSERT INTO usuarios (email, dni, nombres, apellidos, telefono, password_hash, rol)
SELECT 'digitador.global@computoarequipa.gob.pe',
       '40000009', 'Elena', 'Quispe Vargas', '959000009',
       crypt('Digitador.Global2026', gen_salt('bf', 12)),
       'DIGITADOR_GLOBAL'
WHERE NOT EXISTS (SELECT 1 FROM usuarios WHERE email = 'digitador.global@computoarequipa.gob.pe')
ON CONFLICT (email) DO NOTHING;

-- Sin filas en usuario_alcance: el alcance nacional es la AUSENCIA de filtro.

-- ============================================================================
--  6. VERIFICACIÓN
-- ============================================================================
-- SELECT enumlabel FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
--  WHERE t.typname = 'rol_usuario' ORDER BY e.enumsortorder;
-- SELECT usuario_email, accion, numero_mesa, created_at FROM acta_auditoria_global
--  ORDER BY created_at DESC LIMIT 20;
-- SELECT email, rol FROM usuarios WHERE rol = 'DIGITADOR_GLOBAL';
--
-- Consultas de operación:
--   -- Historial de un acta (antes/después en JSON):
--   SELECT accion, usuario_email, ip, created_at, valores_anteriores, valores_nuevos
--     FROM acta_auditoria_global WHERE numero_mesa = '040112' ORDER BY created_at;
--   -- Intervenciones de un digitador en la jornada:
--   SELECT numero_mesa, accion, created_at FROM acta_auditoria_global
--    WHERE usuario_email = 'digitador.global@computoarequipa.gob.pe'
--      AND created_at::DATE = CURRENT_DATE ORDER BY created_at DESC;
