-- ============================================================================
--  Test HOSTIL de integridad del conteo — PostgreSQL real
--
--  El test de integración comprueba que las reglas funcionan por el camino
--  correcto. Este comprueba lo contrario: que NO se pueden esquivar. Cada
--  ataque intenta colar un acta que no debería entrar al cómputo y el script
--  exige que la base lo rechace; si alguno pasa, el test falla.
--
--    1. Insertar un acta directamente CONTABILIZADA y sin validación.
--    2. Contabilizar un acta descuadrada con la columna `validacion` forzada a
--       mano a TRUE (bandera mentirosa).
--    3. Contabilizar un acta con la columna SECUNDARIA descuadrada y la
--       principal cuadrada (la regla R1 se aplica por columna).
--    4. Meter o modificar detalle de votos sobre un acta ya CONTABILIZADA.
--    5. Colgar una observación BLOQUEANTE a un acta ya CONTABILIZADA.
--    6. Reabrirla, descuadrarla de nuevo y recontabilizarla.
--
--  Requisitos: esquema + seed de ubigeo cargados.
--  Uso:
--      psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/tests/sql/actas_hostil.sql
--
--  Todo corre en una transacción que termina en ROLLBACK: no ensucia la base.
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.ok(p_cond boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond IS NOT TRUE THEN
        RAISE EXCEPTION 'FALLO DE TEST: %', p_msg;
    END IF;
    RAISE NOTICE '  ok  %', p_msg;
END;
$$;

-- Ejecuta SQL dinámico que DEBE fallar; verifica el fragmento del error.
CREATE FUNCTION pg_temp.debe_fallar(p_sql text, p_fragmento text, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        RAISE EXCEPTION 'FALLO DE TEST: % (no se lanzó ningún error)', p_msg;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM ILIKE '%' || p_fragmento || '%' THEN
                RAISE NOTICE '  ok  % [rechazado: %]', p_msg, SQLSTATE;
            ELSE
                RAISE EXCEPTION 'FALLO DE TEST: % — error inesperado: % (%)',
                    p_msg, SQLERRM, SQLSTATE;
            END IF;
    END;
END;
$$;

-- ---------------------------------------------------------------------------
-- Fixture aislado (códigos propios para no chocar con actas_integracion.sql)
-- ---------------------------------------------------------------------------
INSERT INTO usuarios (email, dni, nombres, apellidos, password_hash, rol)
VALUES ('hostil@computoarequipa.gob.pe', '88888888', 'Hostil', 'Test',
        crypt('Hostil.2026', gen_salt('bf', 4)), 'SUPER_ADMIN');

INSERT INTO organizaciones_politicas (nombre, tipo, color_hex)
VALUES ('PARTIDO HOSTIL A', 'PARTIDO_NACIONAL', '#111111');

INSERT INTO locales_votacion (ubigeo, codigo_local, nombre, electores_habiles)
VALUES ('040112', '900901', 'LOCAL PRUEBA HOSTIL', 1000);

INSERT INTO mesas (local_id, numero_mesa, electores_habiles)
SELECT l.id, m.n, 250 FROM locales_votacion l
CROSS JOIN (VALUES ('900901'), ('900902'), ('900903'), ('900904')) AS m(n)
WHERE l.codigo_local = '900901';

CREATE TEMP TABLE ctx AS
SELECT (SELECT id FROM usuarios WHERE dni = '88888888')            AS usuario_id,
       (SELECT id FROM organizaciones_politicas
         WHERE nombre = 'PARTIDO HOSTIL A')                        AS org,
       (SELECT id FROM mesas WHERE numero_mesa = '900901')         AS mesa1,
       (SELECT id FROM mesas WHERE numero_mesa = '900902')         AS mesa2,
       (SELECT id FROM mesas WHERE numero_mesa = '900903')         AS mesa3,
       (SELECT id FROM mesas WHERE numero_mesa = '900904')         AS mesa4;

ALTER TABLE ctx ADD COLUMN acta1 BIGINT, ADD COLUMN acta2 BIGINT,
                  ADD COLUMN acta3 BIGINT, ADD COLUMN acta4 BIGINT;

INSERT INTO actas (mesa_id, tipo_eleccion, estado, electores_habiles)
SELECT mesa1, 'DISTRITAL'::tipo_eleccion, 'DIGITADA'::estado_acta, 250 FROM ctx
UNION ALL SELECT mesa2, 'DISTRITAL', 'DIGITADA', 250 FROM ctx
UNION ALL SELECT mesa3, 'DISTRITAL', 'DIGITADA', 250 FROM ctx
UNION ALL SELECT mesa4, 'DISTRITAL', 'DIGITADA', 250 FROM ctx;

UPDATE ctx SET
    acta1 = (SELECT a.id FROM actas a WHERE a.mesa_id = ctx.mesa1 AND a.tipo_eleccion = 'DISTRITAL'),
    acta2 = (SELECT a.id FROM actas a WHERE a.mesa_id = ctx.mesa2 AND a.tipo_eleccion = 'DISTRITAL'),
    acta3 = (SELECT a.id FROM actas a WHERE a.mesa_id = ctx.mesa3 AND a.tipo_eleccion = 'DISTRITAL'),
    acta4 = (SELECT a.id FROM actas a WHERE a.mesa_id = ctx.mesa4 AND a.tipo_eleccion = 'DISTRITAL');

-- ===========================================================================
-- ATAQUE 1 — acta directamente CONTABILIZADA y vacía
-- ===========================================================================
\echo '  -> ATAQUE 1: insertar un acta ya CONTABILIZADA sin validación'
SELECT pg_temp.debe_fallar(
    format('INSERT INTO actas (mesa_id, tipo_eleccion, estado, electores_habiles)
            SELECT mesa1, ''PROVINCIAL'', ''CONTABILIZADA'', 250 FROM ctx'),
    'actas_contabilizada_completa',
    'no se puede insertar un acta CONTABILIZADA sin validador ni resultado'
);

-- ===========================================================================
-- ATAQUE 2 — descuadrada con la bandera `validacion` mentirosa
--
-- La columna de alcalde declara 999 votantes y las casillas suman 10. El
-- atacante fuerza `validacion = TRUE` y `diferencia_suma = 0` a mano, y pone
-- validada_por/contabilizada_at para satisfacer el CHECK de completitud: así
-- lo único que puede frenarlo es el trigger, recalculando por su cuenta.
-- ===========================================================================
\echo '  -> ATAQUE 2: descuadrada con la bandera validacion forzada a TRUE'

INSERT INTO detalle_votos_acta (columna_id, organizacion_id, votos)
SELECT ac.id, ctx.org, 10 FROM acta_columnas ac, ctx
 WHERE ac.acta_id = ctx.acta2 AND ac.columna = 'ALCALDE';
UPDATE acta_columnas SET total_votantes = 999
 WHERE acta_id = (SELECT acta2 FROM ctx) AND columna = 'ALCALDE';
UPDATE actas SET validacion = TRUE, diferencia_suma = 0 WHERE id = (SELECT acta2 FROM ctx);

SELECT pg_temp.ok(
    (SELECT validacion FROM actas WHERE id = (SELECT acta2 FROM ctx)) IS TRUE,
    'la bandera mentirosa quedó guardada tal cual (el trigger no confía en ella)'
);
SELECT pg_temp.ok(
    (SELECT descuadre FROM fn_descuadres_acta((SELECT acta2 FROM ctx))) = 989,
    'fn_descuadres_acta ve el descuadre real de 989 votos'
);

SELECT pg_temp.debe_fallar(
    format('UPDATE actas SET estado = ''CONTABILIZADA'', validada_por = %s,
                    validada_at = now(), contabilizada_at = now() WHERE id = %s',
           (SELECT usuario_id FROM ctx), (SELECT acta2 FROM ctx)),
    'ACTA_INCONSISTENTE',
    'el trigger recalcula y rechaza el acta descuadrada'
);
SELECT pg_temp.ok(
    (SELECT estado FROM actas WHERE id = (SELECT acta2 FROM ctx)) <> 'CONTABILIZADA',
    'el acta quedó fuera del cómputo'
);

-- ===========================================================================
-- ATAQUE 3 — descuadre en la columna SECUNDARIA (regidores)
-- ===========================================================================
\echo '  -> ATAQUE 3: columna A cuadrada y columna B descuadrada'

INSERT INTO detalle_votos_acta (columna_id, organizacion_id, votos)
SELECT ac.id, ctx.org, 100 FROM acta_columnas ac, ctx
 WHERE ac.acta_id = ctx.acta3 AND ac.columna = 'ALCALDE';
UPDATE acta_columnas SET total_votantes = 100
 WHERE acta_id = (SELECT acta3 FROM ctx) AND columna = 'ALCALDE';

INSERT INTO detalle_votos_acta (columna_id, organizacion_id, votos)
SELECT ac.id, ctx.org, 40 FROM acta_columnas ac, ctx
 WHERE ac.acta_id = ctx.acta3 AND ac.columna = 'REGIDORES';
UPDATE acta_columnas SET total_votantes = 200
 WHERE acta_id = (SELECT acta3 FROM ctx) AND columna = 'REGIDORES';

SELECT pg_temp.ok(
    (SELECT diferencia_suma FROM actas WHERE id = (SELECT acta3 FROM ctx)) = 0,
    'la columna principal cuadra (la cabecera reporta diferencia 0)'
);
SELECT pg_temp.ok(
    (SELECT validacion FROM actas WHERE id = (SELECT acta3 FROM ctx)) IS FALSE,
    'aun así el acta no es consistente: la columna B descuadra'
);
SELECT pg_temp.debe_fallar(
    format('UPDATE actas SET estado = ''CONTABILIZADA'', validada_por = %s,
                    validada_at = now(), contabilizada_at = now() WHERE id = %s',
           (SELECT usuario_id FROM ctx), (SELECT acta3 FROM ctx)),
    'REGIDORES',
    'un descuadre sólo en la columna secundaria también bloquea la contabilización'
);

-- ===========================================================================
-- ATAQUE 4 — tocar el detalle de un acta ya CONTABILIZADA
-- ===========================================================================
\echo '  -> ATAQUE 4: alterar los votos de un acta ya contabilizada'

-- Se cuadra y contabiliza legítimamente
INSERT INTO detalle_votos_acta (columna_id, organizacion_id, votos)
SELECT ac.id, ctx.org, 200 FROM acta_columnas ac, ctx
 WHERE ac.acta_id = ctx.acta4 AND ac.columna = 'ALCALDE';
UPDATE acta_columnas SET total_votantes = 200
 WHERE acta_id = (SELECT acta4 FROM ctx) AND columna = 'ALCALDE';
UPDATE actas SET estado = 'CONTABILIZADA', validada_por = (SELECT usuario_id FROM ctx),
       validada_at = now(), contabilizada_at = now()
 WHERE id = (SELECT acta4 FROM ctx);
SELECT pg_temp.ok(
    (SELECT estado FROM actas WHERE id = (SELECT acta4 FROM ctx)) = 'CONTABILIZADA',
    'el acta cuadrada sí se contabiliza'
);

-- Añadir otro bloque de votos a la columna ya contada
SELECT pg_temp.debe_fallar(
    format('INSERT INTO detalle_votos_acta (columna_id, organizacion_id, votos)
            SELECT ac.id, ctx.org, 300 FROM acta_columnas ac, ctx
             WHERE ac.acta_id = %s AND ac.columna = ''ALCALDE''',
           (SELECT acta4 FROM ctx)),
    'detalle_unico_por_columna',
    'no se puede añadir otro bloque de votos a una columna ya cargada'
);

-- Modificar los votos de una columna de un acta contabilizada
SELECT pg_temp.debe_fallar(
    format('UPDATE detalle_votos_acta SET votos = 7
             WHERE columna_id IN (SELECT id FROM acta_columnas
                                   WHERE acta_id = %s AND columna = ''ALCALDE'')',
           (SELECT acta4 FROM ctx)),
    'actas_contabilizada_completa',
    'al recalcularse el acta contabilizada deja de cuadrar y la base lo rechaza'
);
SELECT pg_temp.ok(
    (SELECT votos_validos FROM actas WHERE id = (SELECT acta4 FROM ctx)) = 200,
    'el acta contabilizada conserva sus votos intactos'
);

-- ===========================================================================
-- ATAQUE 5 — colgar una observación BLOQUEANTE a un acta CONTABILIZADA
-- ===========================================================================
\echo '  -> ATAQUE 5: observar un acta ya contabilizada sin reabrirla'
SELECT pg_temp.debe_fallar(
    format('INSERT INTO acta_observaciones (acta_id, regla, severidad, mensaje)
            VALUES (%s, ''R7_FIRMA_FALTANTE'', ''BLOQUEANTE'', ''firma faltante'')',
           (SELECT acta4 FROM ctx)),
    'ACTA_YA_CONTABILIZADA',
    'no puede existir un bloqueante abierto sobre un acta CONTABILIZADA'
);
SELECT pg_temp.ok(
    (SELECT count(*) FROM acta_observaciones
      WHERE acta_id = (SELECT acta4 FROM ctx) AND NOT resuelta) = 0,
    'el acta contabilizada quedó sin observaciones abiertas'
);

-- Y por el camino correcto: primero se reabre, y la reversión queda auditada
UPDATE actas SET estado = 'OBSERVADA' WHERE id = (SELECT acta4 FROM ctx);
INSERT INTO acta_observaciones (acta_id, regla, severidad, mensaje)
VALUES ((SELECT acta4 FROM ctx), 'R7_FIRMA_FALTANTE', 'BLOQUEANTE', 'firma faltante');
SELECT pg_temp.ok(
    (SELECT count(*) FROM acta_eventos
      WHERE acta_id = (SELECT acta4 FROM ctx) AND estado_nuevo = 'OBSERVADA') >= 1,
    'reabrir el acta sí se permite y la reversión queda en la bitácora'
);

-- ===========================================================================
-- ATAQUE 6 — reabrir, desordenar el detalle y recontabilizar
-- ===========================================================================
\echo '  -> ATAQUE 6: recontabilizar tras descuadrar de nuevo'

UPDATE acta_observaciones
   SET resuelta = TRUE, resuelta_por = (SELECT usuario_id FROM ctx),
       resuelta_at = now(), sustento = 'Cotejado con el acta física'
 WHERE acta_id = (SELECT acta4 FROM ctx);

UPDATE detalle_votos_acta SET votos = 300
 WHERE columna_id IN (SELECT id FROM acta_columnas
                       WHERE acta_id = (SELECT acta4 FROM ctx) AND columna = 'ALCALDE');
UPDATE acta_columnas SET total_votantes = 200
 WHERE acta_id = (SELECT acta4 FROM ctx) AND columna = 'ALCALDE';
SELECT pg_temp.ok(
    (SELECT validacion FROM actas WHERE id = (SELECT acta4 FROM ctx)) IS FALSE,
    'el acta volvió a quedar inconsistente tras cambiar el detalle'
);

SELECT pg_temp.debe_fallar(
    format('UPDATE actas SET estado = ''CONTABILIZADA'', validada_por = %s,
                    validada_at = now(), contabilizada_at = now() WHERE id = %s',
           (SELECT usuario_id FROM ctx), (SELECT acta4 FROM ctx)),
    'ACTA_INCONSISTENTE',
    'no se puede recontabilizar un acta descuadrada'
);

-- ===========================================================================
-- Veredicto global: ninguna acta CONTABILIZADA puede estar descuadrada
-- ===========================================================================
\echo '  -> VEREDICTO GLOBAL'
SELECT pg_temp.ok(
    (SELECT count(*)
       FROM actas a
       JOIN mesas m            ON m.id = a.mesa_id
       JOIN locales_votacion l ON l.id = m.local_id
      WHERE l.codigo_local = '900901'
        AND a.estado = 'CONTABILIZADA'
        AND (a.validacion IS NOT TRUE
             OR EXISTS (SELECT 1 FROM fn_descuadres_acta(a.id)))) = 0,
    'no quedó ninguna acta CONTABILIZADA descuadrada ni inconsistente'
);

ROLLBACK;

\echo ''
\echo '  ============================================'
\echo '   TODOS LOS ATAQUES FUERON RECHAZADOS'
\echo '  ============================================'
