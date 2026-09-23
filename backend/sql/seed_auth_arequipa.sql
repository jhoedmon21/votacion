-- ============================================================================
--  Seed de usuarios, roles (RBAC descentralizado) y locales/mesas de prueba
--  Región Arequipa
--
--  Requiere haber ejecutado antes: schema_arequipa.sql y seed_ubigeo_arequipa.sql
--  Uso: psql -d computo_arequipa -f backend/sql/seed_auth_arequipa.sql
--
--  Las contraseñas se hashean con crypt(..., gen_salt('bf', 12)) = bcrypt real
--  ($2a$), compatible con la librería `bcrypt` de Python que usa el backend.
--  Todas las cuentas nacen con debe_cambiar_clave = TRUE.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. USUARIOS DEMO — un ejemplo por cada rol del sistema
-- ---------------------------------------------------------------------------
INSERT INTO usuarios (email, dni, nombres, apellidos, telefono, password_hash, rol)
VALUES
    ('admin@computoarequipa.gob.pe',        '40000001', 'Rosa',    'Delgado Vela',    '959000001',
     crypt('Admin.Arequipa2026',  gen_salt('bf', 12)), 'SUPER_ADMIN'),
    ('coord.arequipa@computoarequipa.gob.pe','40000002', 'Iván',    'Paredes Chávez',  '959000002',
     crypt('Coord.Arequipa2026',  gen_salt('bf', 12)), 'COORD_PROVINCIAL'),
    ('coord.caylloma@computoarequipa.gob.pe','40000003', 'Milagros','Huanca Sullo',    '959000003',
     crypt('Coord.Caylloma2026',  gen_salt('bf', 12)), 'COORD_PROVINCIAL'),
    ('resp.paucarpata@computoarequipa.gob.pe','40000004', 'Jorge',  'Mamani Quispe',   '959000004',
     crypt('Distrital.Paucarpata2026', gen_salt('bf', 12)), 'RESPONSABLE_DISTRITAL'),
    ('resp.yanahuara@computoarequipa.gob.pe','40000005', 'Lucía',    'Bustinza Flores', '959000005',
     crypt('Distrital.Yanahuara2026', gen_salt('bf', 12)), 'RESPONSABLE_DISTRITAL'),
    ('personero.paucarpata@computoarequipa.gob.pe', '40000006', 'Abel', 'Cáceres Puma', '959000006',
     crypt('Personero.Paucarpata2026', gen_salt('bf', 12)), 'PERSONERO')
ON CONFLICT (email) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. ALCANCE TERRITORIAL
--    SUPER_ADMIN no necesita filas (ve toda la región).
--    COORD_PROVINCIAL -> ubigeo de la provincia (nivel PROVINCIA).
--    RESPONSABLE_DISTRITAL / PERSONERO -> ubigeo de su distrito.
-- ---------------------------------------------------------------------------
INSERT INTO usuario_alcance (usuario_id, ubigeo)
SELECT u.id, v.ubigeo
  FROM usuarios u
  JOIN (VALUES
        ('coord.arequipa@computoarequipa.gob.pe',  '040100'),  -- Provincia de Arequipa
        ('coord.caylloma@computoarequipa.gob.pe',  '040500'),  -- Provincia de Caylloma
        ('resp.paucarpata@computoarequipa.gob.pe', '040112'),  -- Distrito de Paucarpata (INEI)
        ('resp.yanahuara@computoarequipa.gob.pe',  '040126'),  -- Distrito de Yanahuara (INEI)
        ('personero.paucarpata@computoarequipa.gob.pe', '040112')
       ) AS v(email, ubigeo) ON v.email = u.email
ON CONFLICT DO NOTHING;

-- El ubigeo del alcance debe existir; si la base no está sembrada, avisamos.
DO $$
DECLARE
    v_faltantes INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_faltantes
      FROM (VALUES ('040100'), ('040500'), ('040112'), ('040126')) AS t(ubigeo)
     WHERE NOT EXISTS (SELECT 1 FROM ubigeo u WHERE u.ubigeo = t.ubigeo);

    IF v_faltantes > 0 THEN
        RAISE WARNING 'Faltan % ubigeo(s): ejecute antes seed_ubigeo_arequipa.sql', v_faltantes;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. LOCALES Y MESAS DE DEMOSTRACIÓN (Paucarpata y Yanahuara)
-- ---------------------------------------------------------------------------
INSERT INTO locales_votacion (ubigeo, codigo_local, nombre, direccion, latitud, longitud, electores_habiles)
SELECT v.ubigeo, v.codigo, v.nombre, v.direccion, v.lat, v.lon, v.electores
  FROM (VALUES
        ('040112', '023001', 'I.E. Manuel Veramendi',      'Av. Arequipa 123, Paucarpata', -16.432778, -71.504722, 2400),
        ('040112', '023002', 'I.E. Teobaldo Paredes',      'Calle Grau 456, Paucarpata',   -16.441100, -71.523300, 2100),
        ('040112', '023003', 'I.E. Campo Marte',           'Av. Campo Marte 789',          -16.450000, -71.510000, 1800),
        ('040126', '023101', 'I.E. San José',              'Calle San José 111, Yanahuara',-16.390000, -71.540000, 1500)
       ) AS v(ubigeo, codigo, nombre, direccion, lat, lon, electores)
 WHERE EXISTS (SELECT 1 FROM ubigeo u WHERE u.ubigeo = v.ubigeo)
ON CONFLICT (ubigeo, codigo_local) DO NOTHING;

-- 4 mesas de 250 electores por local, con numeración ONPE explícita de 6 dígitos.
-- Se listan una por una a propósito: numero_mesa es CHAR(6), así que cualquier
-- concatenación mal armada se truncaría en silencio y colapsaría en duplicados.
INSERT INTO mesas (local_id, numero_mesa, electores_habiles, pabellon, piso, numero_orden)
SELECT l.id, m.numero, 250, 'A', '1', m.orden
  FROM (VALUES
        -- I.E. Manuel Veramendi (Paucarpata)
        ('023001', '023001', 1), ('023001', '023002', 2),
        ('023001', '023003', 3), ('023001', '023004', 4),
        -- I.E. Teobaldo Paredes (Paucarpata)
        ('023002', '023005', 1), ('023002', '023006', 2),
        ('023002', '023007', 3), ('023002', '023008', 4),
        -- I.E. Campo Marte (Paucarpata)
        ('023003', '023009', 1), ('023003', '023010', 2),
        ('023003', '023011', 3), ('023003', '023012', 4),
        -- I.E. San José (Yanahuara)
        ('023101', '023101', 1), ('023101', '023102', 2),
        ('023101', '023103', 3), ('023101', '023104', 4)
       ) AS m(codigo_local, numero, orden)
  JOIN locales_votacion l ON l.codigo_local = m.codigo_local
ON CONFLICT (local_id, numero_mesa) DO NOTHING;

COMMIT;

-- ============================================================================
--  Verificación rápida
-- ============================================================================
-- SELECT u.rol, u.email, array_agg(ua.ubigeo) AS alcance
--   FROM usuarios u LEFT JOIN usuario_alcance ua ON ua.usuario_id = u.id
--  GROUP BY u.rol, u.email ORDER BY u.rol;
--
-- SELECT l.codigo_local, l.nombre, count(m.id) AS mesas, sum(m.electores_habiles) AS electores
--   FROM locales_votacion l JOIN mesas m ON m.local_id = l.id
--  GROUP BY l.codigo_local, l.nombre;
--
-- Login (bcrypt) desde Python, con la misma semilla:
--   import bcrypt
--   bcrypt.checkpw(b'Admin.Arequipa2026', hash_de_la_db.encode())
