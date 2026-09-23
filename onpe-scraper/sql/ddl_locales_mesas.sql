-- ============================================================================
--  Padrón electoral — Locales de votación y mesas de la REGIÓN AREQUIPA (ONPE)
--  DDL productivo: PostgreSQL 13+ (variante MySQL 8 al pie del archivo).
--
--  Uso (PostgreSQL):
--      createdb padron_arequipa
--      psql -d padron_arequipa -v ON_ERROR_STOP=1 -f onpe-scraper/sql/ddl_locales_mesas.sql
--
--  Cobertura: departamento AREQUIPA (ubigeo base '04') y sus 8 provincias:
--      AREQUIPA, CAMANA, CARAVELI, CASTILLA, CAYLLOMA, CONDESUYOS, ISLAY, LA UNION
--      (109 distritos INEI; ver backend/app/core/ubigeo_catalogo.py).
--
--  CONVIVENCIA CON OTROS ESQUEMAS DEL REPO:
--    * `backend/sql/schema_arequipa.sql` ya define `locales_votacion` y `mesas`
--      con OTRA forma (electoral-operativa). NO aplique ambos DDL en el mismo
--      schema: use un schema dedicado para el padrón crudo:
--          CREATE SCHEMA padron;
--          SET search_path TO padron, public;
--          \i onpe-scraper/sql/ddl_locales_mesas.sql
--      o una base de datos separada (recomendado: `padron_arequipa`).
--    * El loader (`onpe-scraper/scraper_padron_arequipa.py`) acepta
--      PADRON_SCHEMA=padron para calificar los INSERT (ver .env.example).
--
--  Idempotente: re-ejecutable sin daño (IF NOT EXISTS + UNIQUE + ON CONFLICT
--  en el loader). Las cargas son UPSERT: re-correr el scraper actualiza en
--  lugar de duplicar.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
--  1. LOCALES DE VOTACIÓN
--  Un local pertenece a UN distrito (ubigeo CHAR(6) INEI). `codigo_local` es el
--  código oficial ONPE del recinto; la unicidad real es (ubigeo, codigo_local)
--  porque el mismo código puede repetirse entre distritos.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS locales_votacion (
    id              BIGSERIAL   PRIMARY KEY,
    ubigeo          CHAR(6)     NOT NULL,   -- INEI del distrito (040101..040812)
    departamento    VARCHAR(60) NOT NULL DEFAULT 'AREQUIPA',
    provincia       VARCHAR(60) NOT NULL,   -- una de las 8 provincias
    distrito        VARCHAR(60) NOT NULL,
    codigo_local    VARCHAR(20) NOT NULL DEFAULT 'SIN-CODIGO',
    nombre_local    VARCHAR(160) NOT NULL,  -- nombre oficial del recinto
    direccion       VARCHAR(260),           -- dirección física exacta
    referencia      VARCHAR(220),           -- referencia para llegar (ej. "frente al parque")
    latitud         NUMERIC(10, 6),         -- NULL si la fuente no la trae
    longitud        NUMERIC(10, 6),
    total_mesas     INTEGER     NOT NULL DEFAULT 0,  -- derivado: mesas del local
    fuente          VARCHAR(40) NOT NULL DEFAULT 'ONPE',  -- ONPE | ETLV | MANUAL
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT locales_ubigeo_formato
        CHECK (ubigeo ~ '^[0-9]{6}$'),
    CONSTRAINT locales_ubigeo_arequipa
        CHECK (ubigeo LIKE '04%'),
    CONSTRAINT locales_coordenadas_rango
        CHECK (
            (latitud  IS NULL OR (latitud  BETWEEN -90 AND 90))
            AND (longitud IS NULL OR (longitud BETWEEN -180 AND 180))
        ),
    CONSTRAINT locales_total_mesas_no_negativo
        CHECK (total_mesas >= 0),
    CONSTRAINT locales_codigo_por_ubigeo
        UNIQUE (ubigeo, codigo_local)
);

CREATE INDEX IF NOT EXISTS idx_locales_ubigeo    ON locales_votacion (ubigeo);
CREATE INDEX IF NOT EXISTS idx_locales_provincia ON locales_votacion (provincia);
CREATE INDEX IF NOT EXISTS idx_locales_nombre    ON locales_votacion (nombre_local);

COMMENT ON TABLE locales_votacion IS
'Padrón crudo ONPE: un recinto de votación por distrito de Arequipa (dep 04). total_mesas se recalcula en cada carga.';
COMMENT ON COLUMN locales_votacion.codigo_local IS
'Código oficial ONPE del recinto; único dentro de su ubigeo, no a nivel nacional.';

-- Migración para bases ya creadas con la v1 del DDL (sin `referencia`).
ALTER TABLE locales_votacion ADD COLUMN IF NOT EXISTS referencia VARCHAR(220);

-- ----------------------------------------------------------------------------
--  2. MESAS DE VOTACIÓN (detalle por local)
--  `numero_mesa` se guarda como texto para preservar ceros a la izquierda
--  ('023001'). `estado_acta`: PENDIENTE | DIGITADA | OBSERVADA | CONTABILIZADA.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mesas_votacion (
    id              BIGSERIAL   PRIMARY KEY,
    local_id        BIGINT      NOT NULL REFERENCES locales_votacion (id)
                        ON DELETE CASCADE ON UPDATE CASCADE,
    numero_mesa     CHAR(6)     NOT NULL,   -- ej. '023001'
    electores_habiles INTEGER,              -- padrón de la mesa (tope regla R2)
    estado_acta     VARCHAR(20) NOT NULL DEFAULT 'PENDIENTE',
    fecha_registro  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT mesas_numero_formato
        CHECK (numero_mesa ~ '^[0-9]{6}$'),
    CONSTRAINT mesas_estado_valido
        CHECK (estado_acta IN ('PENDIENTE', 'DIGITADA', 'OBSERVADA',
                               'CONTABILIZADA', 'ANULADA')),
    CONSTRAINT mesas_electores_no_negativos
        CHECK (electores_habiles IS NULL OR electores_habiles >= 0),
    CONSTRAINT mesas_unica_por_local
        UNIQUE (local_id, numero_mesa)
);

CREATE INDEX IF NOT EXISTS idx_mesas_local  ON mesas_votacion (local_id);
CREATE INDEX IF NOT EXISTS idx_mesas_numero ON mesas_votacion (numero_mesa);
CREATE INDEX IF NOT EXISTS idx_mesas_estado ON mesas_votacion (estado_acta);

COMMENT ON TABLE mesas_votacion IS
'Detalle de mesas por local (FK -> locales_votacion). numero_mesa es texto para conservar ceros a la izquierda.';

-- ----------------------------------------------------------------------------
--  3. MANTENIMIENTO AUTOMÁTICO
-- ----------------------------------------------------------------------------

-- updated_at automático en ambas tablas.
CREATE OR REPLACE FUNCTION fn_set_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_locales_updated ON locales_votacion;
CREATE TRIGGER trg_locales_updated
    BEFORE UPDATE ON locales_votacion
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

DROP TRIGGER IF EXISTS trg_mesas_updated ON mesas_votacion;
CREATE TRIGGER trg_mesas_updated
    BEFORE UPDATE ON mesas_votacion
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- total_mesas derivado: se recalcula solo con el conteo real de mesas del local
-- (llamado por el loader tras cada UPSERT provincial; también usable a mano).
CREATE OR REPLACE FUNCTION fn_recalcular_totales_locales()
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    n INTEGER;
BEGIN
    WITH conteo AS (
        SELECT local_id, COUNT(*)::INTEGER AS mesas
          FROM mesas_votacion GROUP BY local_id
    )
    UPDATE locales_votacion l
       SET total_mesas = COALESCE(c.mesas, 0)
      FROM conteo c WHERE c.local_id = l.id;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

COMMENT ON FUNCTION fn_recalcular_totales_locales() IS
'Recalcula locales_votacion.total_mesas desde mesas_votacion. Retorna locales tocados.';

-- ----------------------------------------------------------------------------
--  4. VISTA OPERATIVA — padrón plano por distrito (lo que consume el ETL
--     inverso y los reportes: un local con sus mesas agregadas).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vista_padron_arequipa AS
SELECT l.ubigeo, l.departamento, l.provincia, l.distrito,
       l.codigo_local, l.nombre_local, l.direccion,
       l.latitud, l.longitud, l.total_mesas,
       COUNT(m.id) AS mesas_registradas
  FROM locales_votacion l
  LEFT JOIN mesas_votacion m ON m.local_id = l.id
 GROUP BY l.id
 ORDER BY l.ubigeo, l.nombre_local;

COMMENT ON VIEW vista_padron_arequipa IS
'Padrón plano de Arequipa: locales con conteo de mesas registradas.';

COMMIT;

-- ============================================================================
--  5. CONSULTAS DE OPERACIÓN (descomentar para usar)
-- ============================================================================
-- -- Avance del padrón por provincia:
-- SELECT provincia, COUNT(*) AS locales, SUM(total_mesas) AS mesas
--   FROM locales_votacion GROUP BY provincia ORDER BY provincia;
--
-- -- Distritos sin locales cargados (cruce contra los 109 oficiales):
-- --   (cargar primero backend/sql/seed_ubigeo_arequipa.sql en otra conexión
-- --    y comparar: SELECT u.ubigeo FROM ubigeo u LEFT JOIN locales_votacion l
-- --    ON l.ubigeo = u.ubigeo WHERE u.nivel = 'DISTRITO' AND l.id IS NULL;)
--
-- -- Mesas huérfanas de electores (sin padrón declarado):
-- SELECT m.numero_mesa, l.nombre_local, l.ubigeo
--   FROM mesas_votacion m JOIN locales_votacion l ON l.id = m.local_id
--  WHERE m.electores_habiles IS NULL ORDER BY m.numero_mesa;
--
-- -- Recalcular totales a mano:
-- SELECT fn_recalcular_totales_locales();

-- ============================================================================
--  6. VARIANTE MySQL 8 (si el despliegue es MySQL en lugar de PostgreSQL)
-- ============================================================================
-- CREATE TABLE IF NOT EXISTS locales_votacion (
--     id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
--     ubigeo CHAR(6) NOT NULL,
--     departamento VARCHAR(60) NOT NULL DEFAULT 'AREQUIPA',
--     provincia VARCHAR(60) NOT NULL,
--     distrito VARCHAR(60) NOT NULL,
--     codigo_local VARCHAR(20) NOT NULL DEFAULT 'SIN-CODIGO',
--     nombre_local VARCHAR(160) NOT NULL,
--     direccion VARCHAR(260) NULL,
--     referencia VARCHAR(220) NULL,
--     latitud DECIMAL(10,6) NULL,
--     longitud DECIMAL(10,6) NULL,
--     total_mesas INT NOT NULL DEFAULT 0,
--     fuente VARCHAR(40) NOT NULL DEFAULT 'ONPE',
--     created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
--     updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
--         ON UPDATE CURRENT_TIMESTAMP,
--     CONSTRAINT chk_locales_ubigeo CHECK (ubigeo REGEXP '^[0-9]{6}$'),
--     UNIQUE KEY uq_locales_codigo (ubigeo, codigo_local),
--     KEY idx_locales_ubigeo (ubigeo),
--     KEY idx_locales_provincia (provincia)
-- ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
--
-- CREATE TABLE IF NOT EXISTS mesas_votacion (
--     id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
--     local_id INT UNSIGNED NOT NULL,
--     numero_mesa CHAR(6) NOT NULL,
--     electores_habiles INT NULL,
--     estado_acta VARCHAR(20) NOT NULL DEFAULT 'PENDIENTE',
--     fecha_registro TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
--     created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
--     updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
--         ON UPDATE CURRENT_TIMESTAMP,
--     CONSTRAINT fk_mesas_local FOREIGN KEY (local_id)
--         REFERENCES locales_votacion (id) ON DELETE CASCADE ON UPDATE CASCADE,
--     CONSTRAINT chk_mesas_numero CHECK (numero_mesa REGEXP '^[0-9]{6}$'),
--     UNIQUE KEY uq_mesas_local (local_id, numero_mesa),
--     KEY idx_mesas_numero (numero_mesa)
-- ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
-- -- UPSERT MySQL: INSERT ... ON DUPLICATE KEY UPDATE ...
