-- ============================================================================
--  Migración — Jerarquía operativa completa de 5 niveles
--  Región Arequipa · Complemento de schema_arequipa.sql + modulo_campo_arequipa.sql
--
--  Jerarquía objetivo (brief §1):
--    SUPER_ADMIN → COORD_PROVINCIAL → COORD_DISTRITAL → COORD_LOCAL → DELEGADO_MESA
--
--  Lo que aporta sobre el esquema base:
--    1. Nuevos roles `COORD_LOCAL` (responsable de un centro educativo) y
--       `DELEGADO_MESA` (personero en mesa). El rol `RESPONSABLE_DISTRITAL`
--       existente se mantiene como equivalente del brief `COORD_DISTRITAL`.
--    2. `locales_votacion.coordinador_local_id`: quién dirige cada local.
--    3. `usuario_alcance.local_id`: alcance acotado a UN local (COORD_LOCAL),
--       sin tocar la semántica ubigeo de los demás roles.
--    4. RLS extendida (pol_asig_alcance / pol_incid_alcance, ya actualizadas en
--       modulo_campo_arequipa.sql) para que el coordinador de local vea y asigne
--       delegados únicamente de su centro educativo.
--    5. `fn_locales_del_usuario` (alcance → locales) y `v_delegados_mesa`
--       (matriz de delegados por mesa para el panel de asignación).
--
--  Orden de ejecución (psql, autocommit por sentencia — NO envolver en una
--  sola transacción: los ALTER TYPE de valores de enum quedan visibles entre
--  sentencias):
--      psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/sql/schema_arequipa.sql
--      psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/sql/modulo_campo_arequipa.sql
--      psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/sql/migracion_jerarquia_completa.sql
--
--  Idempotente: se puede re-ejecutar sin daño.
-- ============================================================================

-- ============================================================================
--  1. ROLES NUEVOS (valores de enum; idempotente por DO + duplicate_object)
-- ============================================================================
DO $$ BEGIN
    ALTER TYPE rol_usuario ADD VALUE 'COORD_LOCAL';      -- coordinador por centro educativo
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    ALTER TYPE rol_usuario ADD VALUE 'DELEGADO_MESA';    -- personero en una o más mesas
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ============================================================================
--  2. COORDINADOR DE LOCAL: responsable por centro educativo
-- ============================================================================
ALTER TABLE locales_votacion
    ADD COLUMN IF NOT EXISTS coordinador_local_id BIGINT REFERENCES usuarios (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_locales_coord
    ON locales_votacion (coordinador_local_id) WHERE coordinador_local_id IS NOT NULL;

-- ============================================================================
--  3. ALCANCE POR LOCAL (usuario_alcance.local_id)
--     El alcance sigue siendo por ubigeo para todos los roles; COORD_LOCAL
--     añade UNA fila con local_id = su centro educativo. Un usuario no puede
--     tener a la vez alcance ubigeo y local: la PK (usuario_id, ubigeo) exige
--     ubigeo, así que el COORD_LOCAL lleva su ubigeo distrital + local_id, y la
--     RLS (modulo_campo) estrecha la visibilidad al local exacto.
-- ============================================================================
ALTER TABLE usuario_alcance
    ADD COLUMN IF NOT EXISTS local_id BIGINT REFERENCES locales_votacion (id) ON DELETE CASCADE;

-- Un usuario con alcance local sólo puede tener uno
CREATE UNIQUE INDEX IF NOT EXISTS uq_alcance_local
    ON usuario_alcance (usuario_id) WHERE local_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_alcance_local
    ON usuario_alcance (local_id) WHERE local_id IS NOT NULL;

-- ============================================================================
--  4. FUNCIÓN: locales visibles para un usuario (ubigeo jerárquico + local)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_locales_del_usuario(p_usuario_id BIGINT)
RETURNS TABLE (local_id BIGINT, ubigeo CHAR(6))
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT l.id, l.ubigeo
      FROM locales_votacion l
      JOIN usuario_alcance ua ON ua.usuario_id = p_usuario_id
      LEFT JOIN ubigeo up     ON up.ubigeo = ua.ubigeo
     WHERE (l.ubigeo = ua.ubigeo)
        OR (up.nivel = 'PROVINCIA'
            AND substring(l.ubigeo, 1, 4) = substring(ua.ubigeo, 1, 4))
        OR (l.id = ua.local_id);
$$;

COMMENT ON FUNCTION fn_locales_del_usuario(BIGINT) IS
'Locales en el alcance de un usuario: distrito exacto, toda la provincia o un local concreto (COORD_LOCAL).';

-- ============================================================================
--  5. MATRIZ DE DELEGADOS POR MESA (panel de asignación del coordinador)
-- ============================================================================
CREATE OR REPLACE VIEW v_delegados_mesa AS
SELECT ap.id                          AS asignacion_id,
       ap.usuario_id                  AS delegado_id,
       u.dni                          AS delegado_dni,
       u.nombres,
       u.apellidos,
       u.telefono                     AS delegado_telefono,
       ap.tipo,
       ap.estado,
       ap.mesa_id,
       m.numero_mesa,
       m.electores_habiles            AS electores_mesa,
       m.pabellon,
       m.piso,
       l.id                           AS local_id,
       l.nombre                       AS local_nombre,
       l.codigo_local,
       ua.ubigeo,
       ua.distrito,
       ua.provincia,
       cl.ultimo_checkin,
       cl.dentro_de_radio             AS checkin_dentro_radio,
       cl.distancia_m                 AS checkin_distancia_m,
       ap.asignado_por                AS asignado_por,
       (SELECT uu.nombres || ' ' || uu.apellidos FROM usuarios uu WHERE uu.id = ap.asignado_por)
                                      AS asignado_por_nombre,
       ap.created_at                  AS asignado_en
  FROM asignacion_personeros ap
  JOIN mesas m              ON m.id = ap.mesa_id
  JOIN locales_votacion l   ON l.id = m.local_id
  JOIN ubigeo ua            ON ua.ubigeo = l.ubigeo
  JOIN usuarios u           ON u.id = ap.usuario_id
  LEFT JOIN LATERAL (
         SELECT created_at AS ultimo_checkin, dentro_de_radio, distancia_m
           FROM checkins_personero
          WHERE asignacion_id = ap.id
          ORDER BY created_at DESC
          LIMIT 1
     ) cl ON TRUE;

COMMENT ON VIEW v_delegados_mesa IS
'Matriz de delegados de mesa (DELEGADO_MESA / PERSONERO) por local y mesa, con su estado y último check-in. Fuente del panel de asignación del COORD_DISTRITAL y del COORD_LOCAL.';

-- ============================================================================
--  6. RLS: garantiza los nuevos roles aunque no se re-ejecute modulo_campo
--     (definiciones idénticas a las actualizadas en modulo_campo_arequipa.sql)
-- ============================================================================
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
               AND (l.id = ua.local_id
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
               AND (incidencias_campo.local_id = ua.local_id
                    OR incidencias_campo.ubigeo = ua.ubigeo
                    OR (EXISTS (SELECT 1 FROM ubigeo up
                                 WHERE up.ubigeo = ua.ubigeo
                                   AND up.nivel = 'PROVINCIA')
                        AND substring(incidencias_campo.ubigeo, 1, 4)
                            = substring(ua.ubigeo, 1, 4)))
        )
    );

-- ============================================================================
--  7. SEED DEMO — coordinador de local y delegado de mesa
--     Sólo aplica si ya existe el seed de locales/mesas (seed_auth_arequipa.sql):
--     I.E. Manuel Veramendi (023001, Paucarpata). En una base sin ese seed, no-op.
-- ============================================================================

-- 7.1 Coordinador del local 023001 (I.E. Manuel Veramendi)
INSERT INTO usuarios (email, dni, nombres, apellidos, telefono, password_hash, rol)
SELECT 'coord.local.veramendi@computoarequipa.gob.pe',
       '40000007', 'María', 'Paredes Apaza', '959000007',
       crypt('CoordLocal.Veramendi2026', gen_salt('bf', 12)),
       'COORD_LOCAL'
WHERE EXISTS (SELECT 1 FROM locales_votacion WHERE codigo_local = '023001')
ON CONFLICT (email) DO NOTHING;

-- 7.2 Delegado de mesa (I.E. Manuel Veramendi)
INSERT INTO usuarios (email, dni, nombres, apellidos, telefono, password_hash, rol)
SELECT 'delegado.veramendi@computoarequipa.gob.pe',
       '40000008', 'Sandro', 'Chambi Flores', '959000008',
       crypt('Delegado.Veramendi2026', gen_salt('bf', 12)),
       'DELEGADO_MESA'
WHERE EXISTS (SELECT 1 FROM locales_votacion WHERE codigo_local = '023001')
ON CONFLICT (email) DO NOTHING;

-- 7.3 Alcance del COORD_LOCAL: ubigeo distrital + local exacto
INSERT INTO usuario_alcance (usuario_id, ubigeo, local_id)
SELECT u.id, l.ubigeo, l.id
  FROM usuarios u
  JOIN locales_votacion l ON l.codigo_local = '023001'
 WHERE u.email = 'coord.local.veramendi@computoarequipa.gob.pe'
   AND l.coordinador_local_id IS NULL
ON CONFLICT DO NOTHING;

-- 7.4 Designación del coordinador sobre su local
UPDATE locales_votacion l
   SET coordinador_local_id = u.id
  FROM usuarios u
 WHERE u.email = 'coord.local.veramendi@computoarequipa.gob.pe'
   AND l.codigo_local = '023001';

-- 7.5 Asignación del delegado a la mesa 023001 (primer mesa del local)
INSERT INTO asignacion_personeros (usuario_id, mesa_id, tipo, estado, asignado_por)
SELECT du.id, me.id, 'TITULAR', 'ASIGNADO', cu.id
  FROM usuarios du
  JOIN locales_votacion l ON l.codigo_local = '023001'
  JOIN mesas me           ON me.local_id = l.id AND me.numero_mesa = '023001'
  JOIN usuarios cu        ON cu.email = 'coord.local.veramendi@computoarequipa.gob.pe'
 WHERE du.email = 'delegado.veramendi@computoarequipa.gob.pe'
ON CONFLICT (usuario_id, mesa_id, tipo) DO NOTHING;

-- ============================================================================
--  8. VERIFICACIÓN
-- ============================================================================
-- SELECT u.rol, u.email, ua.ubigeo, ua.local_id
--   FROM usuarios u LEFT JOIN usuario_alcance ua ON ua.usuario_id = u.id
--  WHERE u.rol IN ('COORD_LOCAL', 'DELEGADO_MESA');
--
-- SELECT l.codigo_local, l.nombre, u.nombres, u.apellidos
--   FROM locales_votacion l LEFT JOIN usuarios u ON u.id = l.coordinador_local_id;
--
-- SELECT d.nombre AS local, d.numero_mesa, d.nombres, d.apellidos, d.estado
--   FROM v_delegados_mesa d WHERE d.codigo_local = '023001';
--
-- SELECT * FROM fn_locales_del_usuario((SELECT id FROM usuarios
--               WHERE email = 'coord.local.veramendi@computoarequipa.gob.pe'));
--
-- Backend: el rol DELEGADO_MESA debe sumarse a ROLES_SISTEMA y ROLES_CAPTURA
-- (app/core/models.py y app/routers/actas.py) para que pueda cargar actas y
-- registrarse check-ins; COORD_LOCAL se suma a ROLES_SUPERVISION. Ver
-- docs/ENTREGABLES.md §1.
-- ============================================================================