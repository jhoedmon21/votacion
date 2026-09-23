-- ============================================================
-- SISTEMA DE EXTRACCIÓN DE DATOS ONPE
-- Esquema DDL para locales de votación y mesas electorales
-- PostgreSQL / MySQL
-- ============================================================

-- ------------------------------------------------------------
-- 1. TABLA: departamentos
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS departamentos (
    id_departamento    VARCHAR(2)   NOT NULL PRIMARY KEY,
    nombre_departamento VARCHAR(100) NOT NULL
);

-- ------------------------------------------------------------
-- 2. TABLA: provincias
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provincias (
    id_provincia       VARCHAR(4)   NOT NULL PRIMARY KEY,
    nombre_provincia   VARCHAR(100) NOT NULL,
    id_departamento    VARCHAR(2)   NOT NULL,
    FOREIGN KEY (id_departamento) REFERENCES departamentos(id_departamento)
);

-- ------------------------------------------------------------
-- 3. TABLA: distritos
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS distritos (
    ubigeo            VARCHAR(6)   NOT NULL PRIMARY KEY,
    nombre_distrito   VARCHAR(150) NOT NULL,
    id_provincia      VARCHAR(4)   NOT NULL,
    id_departamento   VARCHAR(2)   NOT NULL,
    FOREIGN KEY (id_provincia)    REFERENCES provincias(id_provincia),
    FOREIGN KEY (id_departamento) REFERENCES departamentos(id_departamento)
);

-- ------------------------------------------------------------
-- 4. TABLA: locales_votacion
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS locales_votacion (
    id_local          SERIAL       NOT NULL PRIMARY KEY,
    ubigeo            VARCHAR(6)   NOT NULL,
    codigo_local      VARCHAR(20),           -- Código interno ONPE del local
    nombre_local      VARCHAR(255) NOT NULL,
    direccion         TEXT,
    referencia        TEXT,
    departamento      VARCHAR(100),
    provincia         VARCHAR(100),
    distrito          VARCHAR(150),
    cantidad_mesas    INTEGER      DEFAULT 0,
    fecha_extraccion  TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    fuente            VARCHAR(50)  DEFAULT 'API',  -- 'API' | 'DATOS_ABIERTOS'
    hash_fila         VARCHAR(64),               -- Para detección de cambios
    UNIQUE (ubigeo, codigo_local, nombre_local)
);

CREATE INDEX IF NOT EXISTS idx_locales_ubigeo ON locales_votacion(ubigeo);

-- ------------------------------------------------------------
-- 5. TABLA: mesas_votacion
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mesas_votacion (
    id_mesa           SERIAL       NOT NULL PRIMARY KEY,
    id_local          INTEGER      NOT NULL,
    numero_mesa       VARCHAR(20)  NOT NULL,
    ubigeo            VARCHAR(6),
    tipo_mesa         VARCHAR(50)  DEFAULT 'ORDINARIA',  -- ORDINARIA, ESPECIAL, etc.
    fecha_extraccion  TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (id_local) REFERENCES locales_votacion(id_local) ON DELETE CASCADE,
    UNIQUE (id_local, numero_mesa)
);

CREATE INDEX IF NOT EXISTS idx_mesas_id_local ON mesas_votacion(id_local);
CREATE INDEX IF NOT EXISTS idx_mesas_numero   ON mesas_votacion(numero_mesa);

-- ------------------------------------------------------------
-- 6. VISTA: vista_locales_completa
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vista_locales_completa AS
SELECT
    l.id_local,
    l.ubigeo,
    l.departamento,
    l.provincia,
    l.distrito,
    l.nombre_local,
    l.direccion,
    l.referencia,
    l.cantidad_mesas,
    COUNT(m.id_mesa) AS mesas_contadas,
    STRING_AGG(m.numero_mesa, ', ' ORDER BY m.numero_mesa) AS lista_mesas,
    l.fecha_extraccion,
    l.fuente
FROM locales_votacion l
LEFT JOIN mesas_votacion m ON l.id_local = m.id_local
GROUP BY l.id_local, l.ubigeo, l.departamento, l.provincia, l.distrito,
         l.nombre_local, l.direccion, l.referencia, l.cantidad_mesas,
         l.fecha_extraccion, l.fuente
ORDER BY l.ubigeo, l.nombre_local;

-- ------------------------------------------------------------
-- 7. FUNCIÓN DE ACTUALIZACIÓN (UPSERT para locales)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION upsert_local(
    p_ubigeo         VARCHAR(6),
    p_codigo_local   VARCHAR(20),
    p_nombre_local   VARCHAR(255),
    p_direccion      TEXT,
    p_referencia     TEXT,
    p_departamento   VARCHAR(100),
    p_provincia      VARCHAR(100),
    p_distrito       VARCHAR(150),
    p_cantidad_mesas INTEGER,
    p_fuente         VARCHAR(50)
) RETURNS INTEGER AS $$
DECLARE
    v_id_local INTEGER;
    v_hash     VARCHAR(64);
BEGIN
    -- Calcular hash para detectar cambios
    v_hash := MD5(CONCAT_WS('|',
        p_nombre_local, p_direccion, p_referencia,
        p_cantidad_mesas::TEXT
    ));

    -- UPSERT
    INSERT INTO locales_votacion (
        ubigeo, codigo_local, nombre_local, direccion, referencia,
        departamento, provincia, distrito, cantidad_mesas, fuente, hash_fila
    ) VALUES (
        p_ubigeo, p_codigo_local, p_nombre_local, p_direccion, p_referencia,
        p_departamento, p_provincia, p_distrito, p_cantidad_mesas, p_fuente, v_hash
    )
    ON CONFLICT (ubigeo, codigo_local, nombre_local) DO UPDATE SET
        direccion      = EXCLUDED.direccion,
        referencia     = EXCLUDED.referencia,
        cantidad_mesas = EXCLUDED.cantidad_mesas,
        fuente         = EXCLUDED.fuente,
        hash_fila      = EXCLUDED.hash_fila,
        fecha_extraccion = CURRENT_TIMESTAMP
    WHERE locales_votacion.hash_fila IS DISTINCT FROM EXCLUDED.hash_fila
       OR locales_votacion.hash_fila IS NULL
    RETURNING id_local INTO v_id_local;

    RETURN v_id_local;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- 8. FUNCIÓN DE INSERCIÓN DE MESA (UPSERT)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION upsert_mesa(
    p_id_local  INTEGER,
    p_numero_mesa VARCHAR(20),
    p_ubigeo    VARCHAR(6)
) RETURNS INTEGER AS $$
DECLARE
    v_id_mesa INTEGER;
BEGIN
    INSERT INTO mesas_votacion (id_local, numero_mesa, ubigeo)
    VALUES (p_id_local, p_numero_mesa, p_ubigeo)
    ON CONFLICT (id_local, numero_mesa) DO NOTHING
    RETURNING id_mesa INTO v_id_mesa;

    RETURN v_id_mesa;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FIN DEL ESQUEMA
-- ============================================================