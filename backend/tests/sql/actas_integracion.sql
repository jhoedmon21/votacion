-- ============================================================================
--  Test de integración de las reglas de negocio del acta — PostgreSQL real
--
--  Comprueba, contra un servidor de verdad, que:
--    1. Un acta consistente SÍ se contabiliza.
--    2. Un acta descuadrada NO se contabiliza (el trigger la rechaza).
--    3. Un acta que excede el padrón tampoco.
--    4. Un descuadre en la columna SECUNDARIA (regidores) tampoco: la regla R1
--       se aplica columna por columna, no sólo a la principal.
--    5. Un acta con observaciones bloqueantes abiertas tampoco, y a un acta
--       CONTABILIZADA no se le puede colgar un bloqueante sin reabrirla.
--    6. La misma mesa no puede tener dos actas de la misma elección.
--    7. La misma foto no puede respaldar dos actas.
--    8. Los totales se recalculan solos al cambiar el detalle.
--    9. La bitácora y las vistas responden.
--   10. Aislamiento territorial (RLS).
--
--  Requisitos: esquema + seed de ubigeo cargados.
--  Uso:
--      psql -d computo_arequipa -v ON_ERROR_STOP=1 -f backend/tests/sql/actas_integracion.sql
--
--  Todo corre dentro de una transacción que termina en ROLLBACK: no ensucia la
--  base. Si alguna comprobación falla, el script termina en error (exit != 0).
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- Utilidades de aserción
-- ---------------------------------------------------------------------------
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
-- Datos de prueba (aislados dentro de la transacción)
-- ---------------------------------------------------------------------------
INSERT INTO usuarios (email, dni, nombres, apellidos, password_hash, rol)
VALUES ('test@computoarequipa.gob.pe', '99999999', 'Test', 'Validador',
        crypt('Test.2026', gen_salt('bf', 4)), 'SUPER_ADMIN');

INSERT INTO organizaciones_politicas (nombre, tipo, color_hex)
VALUES ('PARTIDO TEST A', 'PARTIDO_NACIONAL', '#002B66'),
       ('PARTIDO TEST B', 'PARTIDO_NACIONAL', '#D97706');

INSERT INTO candidatos (organizacion_id, ubigeo, tipo_eleccion, cargo, numero_lista,
                        dni, nombres, apellidos, nombre_completo)
SELECT op.id, '040112', 'DISTRITAL', 'ALCALDE_DISTRITAL', 1,
       '9000000' || row_number() OVER (), 'Alcalde', op.nombre, 'de ' || op.nombre
  FROM organizaciones_politicas op
 WHERE op.nombre LIKE 'PARTIDO TEST %';

INSERT INTO locales_votacion (ubigeo, codigo_local, nombre, electores_habiles)
VALUES ('040112', '999001', 'LOCAL DE PRUEBA', 1000);

INSERT INTO mesas (local_id, numero_mesa, electores_habiles)
SELECT id, m.numero, m.electores
  FROM locales_votacion l
 CROSS JOIN (VALUES ('999001', 250), ('999002', 250)) AS m(numero, electores)
 WHERE l.codigo_local = '999001';

CREATE TEMP TABLE ctx AS
SELECT
    (SELECT id FROM locales_votacion WHERE codigo_local = '999001') AS local_id,
    (SELECT id FROM mesas WHERE numero_mesa = '999001')             AS mesa_id,
    (SELECT id FROM mesas WHERE numero_mesa = '999002')             AS mesa2_id,
    (SELECT id FROM usuarios WHERE dni = '99999999')                AS usuario_id,
    (SELECT id FROM organizaciones_politicas WHERE nombre = 'PARTIDO TEST A') AS org_a,
    (SELECT id FROM organizaciones_politicas WHERE nombre = 'PARTIDO TEST B') AS org_b;

-- ---------------------------------------------------------------------------
-- CASO 1 — acta consistente: se contabiliza
-- ---------------------------------------------------------------------------
\echo '  -> CASO 1: acta consistente'
INSERT INTO actas (mesa_id, tipo_eleccion, estado, electores_habiles, created_at)
SELECT mesa_id, 'DISTRITAL', 'DIGITADA', 250, now() FROM ctx
RETURNING id \gset acta_ok_

-- Las columnas A y B se crean solas (trigger fn_crear_columnas_acta)
SELECT pg_temp.ok(
    (SELECT count(*) FROM acta_columnas WHERE acta_id = :acta_ok_id) = 2,
    'el acta nace con sus dos columnas (ALCALDE y REGIDORES)'
);

SELECT pg_temp.ok(
    (SELECT string_agg(columna::text, ',' ORDER BY columna) FROM acta_columnas WHERE acta_id = :acta_ok_id)
        = 'ALCALDE,REGIDORES',
    'las columnas son las que corresponden a una elección distrital'
);

-- Columna A: 120 + 80 válidos + 10 blancos + 5 nulos + 5 impugnados = 220
INSERT INTO detalle_votos_acta (columna_id, organizacion_id, candidato_id, votos)
SELECT ac.id, ctx.org_a, (SELECT id FROM candidatos WHERE organizacion_id = ctx.org_a LIMIT 1), 120
  FROM acta_columnas ac, ctx WHERE ac.acta_id = :acta_ok_id AND ac.columna = 'ALCALDE'
UNION ALL
SELECT ac.id, ctx.org_b, (SELECT id FROM candidatos WHERE organizacion_id = ctx.org_b LIMIT 1), 80
  FROM acta_columnas ac, ctx WHERE ac.acta_id = :acta_ok_id AND ac.columna = 'ALCALDE';

UPDATE acta_columnas SET votos_blancos = 10, votos_nulos = 5, votos_impugnados = 5, total_votantes = 220
 WHERE acta_id = :acta_ok_id AND columna = 'ALCALDE';

-- Columna B: 100 + 90 + 12 blancos + 10 nulos + 8 impugnados = 220
INSERT INTO detalle_votos_acta (columna_id, organizacion_id, votos)
SELECT ac.id, ctx.org_a, 100 FROM acta_columnas ac, ctx WHERE ac.acta_id = :acta_ok_id AND ac.columna = 'REGIDORES'
UNION ALL
SELECT ac.id, ctx.org_b, 90  FROM acta_columnas ac, ctx WHERE ac.acta_id = :acta_ok_id AND ac.columna = 'REGIDORES';

UPDATE acta_columnas SET votos_blancos = 12, votos_nulos = 10, votos_impugnados = 8, total_votantes = 220
 WHERE acta_id = :acta_ok_id AND columna = 'REGIDORES';

-- El detalle se recalcula solo en la cabecera
SELECT pg_temp.ok(
    (SELECT total_votantes FROM actas WHERE id = :acta_ok_id) = 220,
    'la cabecera tomó el total de votantes de la columna principal (220)'
);
SELECT pg_temp.ok(
    (SELECT votos_validos FROM actas WHERE id = :acta_ok_id) = 200,
    'la cabecera sumó los votos válidos del detalle (120+80)'
);
SELECT pg_temp.ok(
    (SELECT validacion FROM actas WHERE id = :acta_ok_id) IS TRUE,
    'el acta quedó marcada como consistente'
);

UPDATE actas
   SET estado = 'CONTABILIZADA',
       validada_por = (SELECT usuario_id FROM ctx),
       validada_at = now(),
       contabilizada_at = now()
 WHERE id = :acta_ok_id;

SELECT pg_temp.ok(
    (SELECT estado FROM actas WHERE id = :acta_ok_id) = 'CONTABILIZADA',
    'un acta consistente SÍ se contabiliza'
);
SELECT pg_temp.ok(
    (SELECT count(*) FROM acta_eventos WHERE acta_id = :acta_ok_id) >= 3,
    'la bitácora registró creación, recálculo y contabilización'
);

-- ---------------------------------------------------------------------------
-- CASO 2 — acta descuadrada: el trigger la rechaza
-- ---------------------------------------------------------------------------
\echo '  -> CASO 2: acta descuadrada'
INSERT INTO actas (mesa_id, tipo_eleccion, estado, electores_habiles)
SELECT mesa2_id, 'DISTRITAL', 'DIGITADA', 250 FROM ctx
RETURNING id \gset acta_mala_

INSERT INTO detalle_votos_acta (columna_id, organizacion_id, votos)
SELECT ac.id, ctx.org_a, 50 FROM acta_columnas ac, ctx
 WHERE ac.acta_id = :acta_mala_id AND ac.columna = 'ALCALDE';

-- El papel dice 100 pero las casillas suman 50: diferencia +50
UPDATE acta_columnas SET total_votantes = 100
 WHERE acta_id = :acta_mala_id AND columna = 'ALCALDE';

SELECT pg_temp.ok(
    (SELECT validacion FROM actas WHERE id = :acta_mala_id) IS FALSE,
    'el acta quedó marcada como inconsistente'
);
SELECT pg_temp.ok(
    (SELECT diferencia_suma FROM actas WHERE id = :acta_mala_id) = 50,
    'la diferencia calculada es +50'
);

SELECT pg_temp.debe_fallar(
    format('UPDATE actas SET estado = ''CONTABILIZADA'', validada_por = %s,
                    validada_at = now(), contabilizada_at = now() WHERE id = %s',
           (SELECT usuario_id FROM ctx), :acta_mala_id),
    'ACTA_INCONSISTENTE',
    'un acta descuadrada NO se contabiliza'
);

-- Así la marca el backend cuando el validador la encuentra inconsistente:
-- se guarda tal como está en el papel y entra a la cola de revisión.
UPDATE actas SET estado = 'OBSERVADA' WHERE id = :acta_mala_id;
SELECT pg_temp.ok(
    (SELECT estado FROM actas WHERE id = :acta_mala_id) = 'OBSERVADA',
    'el acta descuadrada puede guardarse como OBSERVADA (no se pierde el dato)'
);

-- ---------------------------------------------------------------------------
-- CASO 3 — acta que excede los electores hábiles
-- ---------------------------------------------------------------------------
\echo '  -> CASO 3: acta sobre el padrón (misma mesa, otra elección)'
INSERT INTO actas (mesa_id, tipo_eleccion, estado, electores_habiles)
SELECT mesa_id, 'PROVINCIAL', 'DIGITADA', 200 FROM ctx
RETURNING id \gset acta_padron_

INSERT INTO detalle_votos_acta (columna_id, organizacion_id, votos)
SELECT ac.id, ctx.org_a, 260 FROM acta_columnas ac, ctx
 WHERE ac.acta_id = :acta_padron_id AND ac.columna = 'ALCALDE';
UPDATE acta_columnas SET total_votantes = 260
 WHERE acta_id = :acta_padron_id AND columna = 'ALCALDE';

SELECT pg_temp.ok(
    (SELECT validacion FROM actas WHERE id = :acta_padron_id) IS TRUE,
    'la suma sí cuadra (el problema es el tope, no la aritmética)'
);
SELECT pg_temp.debe_fallar(
    format('UPDATE actas SET estado = ''CONTABILIZADA'', validada_por = %s,
                    validada_at = now(), contabilizada_at = now() WHERE id = %s',
           (SELECT usuario_id FROM ctx), :acta_padron_id),
    'ACTA_EXCEDE_PADRON',
    'un acta con más votantes que electores hábiles NO se contabiliza'
);

-- ---------------------------------------------------------------------------
-- CASO 3 bis — descuadre en la COLUMNA SECUNDARIA (regidores)
--
-- Regresión: el acta trae dos cómputos independientes y la regla R1 se evalúa
-- POR COLUMNA. Antes, un acta con la columna de alcalde cuadrada y la de
-- regidores descuadrada se contabilizaba: el conteo entraba al cómputo con una
-- columna que no suma.
-- ---------------------------------------------------------------------------
\echo '  -> CASO 3 bis: descuadre en la columna de regidores'
INSERT INTO actas (mesa_id, tipo_eleccion, estado, electores_habiles)
SELECT mesa2_id, 'PROVINCIAL', 'DIGITADA', 250 FROM ctx
RETURNING id \gset acta_b_

-- Columna A: 100 + 0 + 0 + 0 = 100, cuadra
INSERT INTO detalle_votos_acta (columna_id, organizacion_id, votos)
SELECT ac.id, ctx.org_a, 100 FROM acta_columnas ac, ctx
 WHERE ac.acta_id = :acta_b_id AND ac.columna = 'ALCALDE';
UPDATE acta_columnas SET total_votantes = 100
 WHERE acta_id = :acta_b_id AND columna = 'ALCALDE';

-- Columna B: el papel dice 200 pero las casillas suman 40, descuadre de 160
INSERT INTO detalle_votos_acta (columna_id, organizacion_id, votos)
SELECT ac.id, ctx.org_a, 40 FROM acta_columnas ac, ctx
 WHERE ac.acta_id = :acta_b_id AND ac.columna = 'REGIDORES';
UPDATE acta_columnas SET total_votantes = 200
 WHERE acta_id = :acta_b_id AND columna = 'REGIDORES';

SELECT pg_temp.ok(
    (SELECT count(*) FROM fn_descuadres_acta(:acta_b_id)) = 1,
    'fn_descuadres_acta reporta exactamente una columna descuadrada'
);
SELECT pg_temp.ok(
    (SELECT descuadre FROM fn_descuadres_acta(:acta_b_id)) = 160,
    'el descuadre reportado es el de la columna de regidores (160)'
);
SELECT pg_temp.ok(
    (SELECT columna FROM fn_descuadres_acta(:acta_b_id)) = 'REGIDORES',
    'la columna señalada es REGIDORES, no la principal'
);
SELECT pg_temp.ok(
    (SELECT diferencia_suma FROM actas WHERE id = :acta_b_id) = 0,
    'la cabecera sigue resumiendo la columna principal (diferencia 0)'
);
SELECT pg_temp.ok(
    (SELECT validacion FROM actas WHERE id = :acta_b_id) IS FALSE,
    'pero el acta NO es consistente: basta que una columna descuadre'
);

SELECT pg_temp.debe_fallar(
    format('UPDATE actas SET estado = ''CONTABILIZADA'', validada_por = %s,
                    validada_at = now(), contabilizada_at = now() WHERE id = %s',
           (SELECT usuario_id FROM ctx), :acta_b_id),
    'ACTA_INCONSISTENTE',
    'un descuadre en la columna secundaria también bloquea la contabilización'
);

-- Se guarda tal como está en el papel, en la cola de revisión
UPDATE actas SET estado = 'OBSERVADA' WHERE id = :acta_b_id;
SELECT pg_temp.ok(
    (SELECT count(*) FROM v_actas_observadas
      WHERE acta_id = :acta_b_id AND columnas_descuadradas = 1) = 1,
    'v_actas_observadas indica cuántas columnas descuadran'
);

-- Corregida la digitación (faltaba cargar la otra organización en la columna B:
-- 40 + 160 = 200, que es el total impreso), el acta sí entra al cómputo
INSERT INTO detalle_votos_acta (columna_id, organizacion_id, votos)
SELECT ac.id, ctx.org_b, 160 FROM acta_columnas ac, ctx
 WHERE ac.acta_id = :acta_b_id AND ac.columna = 'REGIDORES';
SELECT pg_temp.ok(
    (SELECT validacion FROM actas WHERE id = :acta_b_id) IS TRUE,
    'con las casillas cuadradas el acta vuelve a ser consistente'
);
UPDATE actas
   SET estado = 'CONTABILIZADA',
       validada_por = (SELECT usuario_id FROM ctx),
       validada_at = now(), contabilizada_at = now()
 WHERE id = :acta_b_id;
SELECT pg_temp.ok(
    (SELECT estado FROM actas WHERE id = :acta_b_id) = 'CONTABILIZADA',
    'corregida la columna B, el acta se contabiliza'
);

-- ---------------------------------------------------------------------------
-- CASO 4 — observación bloqueante abierta
-- ---------------------------------------------------------------------------
\echo '  -> CASO 4: observación bloqueante sin resolver'

-- A un acta CONTABILIZADA no se le puede colgar un bloqueante: hay que reabrirla
-- primero, y esa reversión queda en la bitácora.
SELECT pg_temp.debe_fallar(
    format('INSERT INTO acta_observaciones (acta_id, regla, severidad, mensaje)
            VALUES (%s, ''R7_FIRMA_FALTANTE'', ''BLOQUEANTE'', ''Falta la firma del personero'')',
           :acta_ok_id),
    'ACTA_YA_CONTABILIZADA',
    'no se puede observar un acta CONTABILIZADA sin reabrirla'
);

UPDATE actas SET estado = 'OBSERVADA' WHERE id = :acta_ok_id;
SELECT pg_temp.ok(
    (SELECT estado FROM actas WHERE id = :acta_ok_id) = 'OBSERVADA',
    'reabrir el acta (CONTABILIZADA -> OBSERVADA) sí está permitido'
);

INSERT INTO acta_observaciones (acta_id, regla, severidad, mensaje)
VALUES (:acta_ok_id, 'R7_FIRMA_FALTANTE', 'BLOQUEANTE', 'Falta la firma del personero');

SELECT pg_temp.debe_fallar(
    format('UPDATE actas SET estado = ''CONTABILIZADA'', validada_por = %s,
                    validada_at = now(), contabilizada_at = now() WHERE id = %s',
           (SELECT usuario_id FROM ctx), :acta_ok_id),
    'ACTA_CON_OBSERVACIONES',
    'un acta con observaciones bloqueantes abiertas NO se contabiliza'
);

-- Al resolverla con sustento, sí se permite volver a contabilizar
UPDATE acta_observaciones
   SET resuelta = TRUE, resuelta_por = (SELECT usuario_id FROM ctx),
       resuelta_at = now(), sustento = 'Cotejado con el acta física'
 WHERE acta_id = :acta_ok_id;

UPDATE actas SET estado = 'DIGITADA' WHERE id = :acta_ok_id;
UPDATE actas
   SET estado = 'CONTABILIZADA',
       validada_por = (SELECT usuario_id FROM ctx),
       validada_at = now(), contabilizada_at = now()
 WHERE id = :acta_ok_id;
SELECT pg_temp.ok(
    (SELECT estado FROM actas WHERE id = :acta_ok_id) = 'CONTABILIZADA',
    'resuelta la observación con sustento, el acta sí se contabiliza'
);

-- ---------------------------------------------------------------------------
-- CASO 5 — duplicidad de mesa + tipo de elección
-- ---------------------------------------------------------------------------
\echo '  -> CASO 5: acta duplicada'
SELECT pg_temp.debe_fallar(
    format('INSERT INTO actas (mesa_id, tipo_eleccion, estado, electores_habiles)
            SELECT mesa_id, ''DISTRITAL'', ''PENDIENTE'', 250 FROM ctx'),
    'actas_unica_por_mesa_eleccion',
    'la misma mesa no admite dos actas distritales'
);

-- ---------------------------------------------------------------------------
-- CASO 6 — la misma foto en dos actas
-- ---------------------------------------------------------------------------
\echo '  -> CASO 6: evidencia fotográfica duplicada'
INSERT INTO acta_adjuntos (acta_id, tipo, url, hash_sha256)
VALUES (:acta_ok_id, 'FOTO_ACTA', '/storage/actas/a.jpg',
        repeat('ab', 32));

SELECT pg_temp.debe_fallar(
    format('INSERT INTO acta_adjuntos (acta_id, tipo, url, hash_sha256)
            VALUES (%s, ''FOTO_ACTA'', ''/storage/actas/b.jpg'', repeat(''ab'', 32))',
           :acta_mala_id),
    'FOTO_DUPLICADA',
    'la misma fotografía no puede respaldar dos actas'
);

-- ---------------------------------------------------------------------------
-- CASO 7 — consolidación automática al corregir el detalle
-- ---------------------------------------------------------------------------
\echo '  -> CASO 7: recálculo automático'
UPDATE detalle_votos_acta SET votos = 0
 WHERE columna_id IN (SELECT id FROM acta_columnas WHERE acta_id = :acta_mala_id AND columna = 'ALCALDE');

SELECT pg_temp.ok(
    (SELECT votos_validos FROM actas WHERE id = :acta_mala_id) = 0,
    'al poner el detalle en cero, la cabecera se actualizó sola'
);

-- ---------------------------------------------------------------------------
-- CASO 8 — vistas del cómputo
-- ---------------------------------------------------------------------------
\echo '  -> CASO 8: vistas'
SELECT pg_temp.ok(
    (SELECT count(*) FROM v_acta_consolidada WHERE acta_id = :acta_ok_id) = 1,
    'v_acta_consolidada devuelve el acta con su local y distrito'
);
SELECT pg_temp.ok(
    (SELECT sum(votos) FROM v_resultados_organizacion
      WHERE ubigeo = '040112' AND columna = 'ALCALDE'
        AND tipo_eleccion = 'DISTRITAL') = 200,
    'v_resultados_organizacion suma 200 votos de alcalde en la columna A'
);
SELECT pg_temp.ok(
    (SELECT sum(votos) FROM v_resultados_organizacion
      WHERE ubigeo = '040112' AND columna = 'REGIDORES'
        AND tipo_eleccion = 'DISTRITAL') = 190,
    'la columna B (regidores) se cuenta aparte: 190 votos'
);
SELECT pg_temp.ok(
    (SELECT sum(votos) FROM v_resultados_organizacion
      WHERE ubigeo = '040112' AND columna = 'REGIDORES'
        AND tipo_eleccion = 'PROVINCIAL') = 200,
    'el acta provincial corregida (CASO 3 bis) entró al cómputo con sus 200 de regidores'
);
SELECT pg_temp.ok(
    (SELECT count(*) FROM v_actas_observadas) >= 1,
    'v_actas_observadas lista la cola de revisión'
);
SELECT pg_temp.ok(
    (SELECT count(*) FROM v_avance_distrito WHERE ubigeo = '040112') = 1,
    'v_avance_distrito resume el distrito'
);

-- ---------------------------------------------------------------------------
-- CASO 9 — aislamiento territorial (RLS sobre actas)
-- ---------------------------------------------------------------------------
\echo '  -> CASO 9: aislamiento territorial (RLS)'

-- El usuario de prueba queda habilitado sólo para el distrito 040112
INSERT INTO usuario_alcance (usuario_id, ubigeo)
SELECT usuario_id, '040112' FROM ctx;

CREATE ROLE rls_demo_arequipa;
GRANT USAGE ON SCHEMA public TO rls_demo_arequipa;
-- ubigeo es necesaria porque la política p_actas_alcance la consulta para
-- determinar si el alcance del usuario es de nivel PROVINCIA
GRANT SELECT ON actas, mesas, locales_votacion, usuario_alcance, ubigeo TO rls_demo_arequipa;

DO $$
DECLARE
    v_uid        BIGINT  := (SELECT usuario_id FROM ctx);
    v_mesa       BIGINT  := (SELECT mesa_id FROM ctx);
    v_otro_rol   INTEGER;
    v_sin_ctx    INTEGER;
    v_super      INTEGER;
    v_con_alcance INTEGER;
    v_ajeno      INTEGER;
    v_provincial INTEGER;
    v_provincial_ajena INTEGER;
BEGIN
    SET LOCAL ROLE rls_demo_arequipa;

    -- 1) Sin contexto de sesión, la política no deja ver nada
    SELECT count(*) INTO v_sin_ctx FROM actas;

    -- 2) SUPER_ADMIN ve toda la región
    PERFORM set_config('app.rol_actual', 'SUPER_ADMIN', true);
    SELECT count(*) INTO v_super FROM actas;

    -- 3) Un rol territorial sin usuario asociado no ve nada
    PERFORM set_config('app.rol_actual', 'COORD_PROVINCIAL', true);
    SELECT count(*) INTO v_otro_rol FROM actas;

    -- 4) Con usuario_id cuyo alcance incluye el distrito del acta, sí la ve
    PERFORM set_config('app.usuario_id', v_uid::text, true);
    SELECT count(*) INTO v_con_alcance FROM actas;

    -- 5) Un usuario con alcance en OTRO distrito no ve estas actas
    SET LOCAL ROLE postgres;
    UPDATE usuario_alcance SET ubigeo = '040101' WHERE usuario_id = v_uid;
    SET LOCAL ROLE rls_demo_arequipa;
    SELECT count(*) INTO v_ajeno FROM actas;
    RESET ROLE;

    -- 6) COORD_PROVINCIAL de Arequipa (040100): por jerarquía ve las actas de
    --    SUS distritos (04-01-xx) aunque su alcance no sea exacto
    SET LOCAL ROLE postgres;
    UPDATE usuario_alcance SET ubigeo = '040100' WHERE usuario_id = v_uid;
    SET LOCAL ROLE rls_demo_arequipa;
    SELECT count(*) INTO v_provincial FROM actas;
    RESET ROLE;

    -- 7) Pero un alcance provincial de CAYLLOMA (040500) no ve las de Arequipa
    SET LOCAL ROLE postgres;
    UPDATE usuario_alcance SET ubigeo = '040500' WHERE usuario_id = v_uid;
    SET LOCAL ROLE rls_demo_arequipa;
    SELECT count(*) INTO v_provincial_ajena FROM actas;
    RESET ROLE;

    PERFORM pg_temp.ok(v_sin_ctx = 0,     'sin contexto de sesión el usuario no ve ninguna acta');
    PERFORM pg_temp.ok(v_super >= 3,      'SUPER_ADMIN ve las actas de toda la región (' || v_super || ')');
    PERFORM pg_temp.ok(v_otro_rol = 0,    'un rol territorial sin usuario asociado no ve nada');
    PERFORM pg_temp.ok(v_con_alcance >= 3,'con alcance en su distrito ve las actas de su ámbito (' || v_con_alcance || ')');
    PERFORM pg_temp.ok(v_ajeno = 0,       'con alcance en otro distrito no ve estas actas');
    PERFORM pg_temp.ok(v_provincial >= 3, 'COORD_PROVINCIAL de Arequipa (040100) ve las actas de sus distritos');
    PERFORM pg_temp.ok(v_provincial_ajena = 0, 'COORD_PROVINCIAL de otra provincia (040500) no las ve');
    -- La mesa 999001 tiene 2 actas: la distrital (CASO 1) y la provincial (CASO 3)
    PERFORM pg_temp.ok(
        (SELECT count(*) FROM actas WHERE mesa_id = v_mesa) = 2,
        'el dueño de la tabla sigue viendo todo (RLS no aplica al owner)');
END;
$$;

-- ---------------------------------------------------------------------------
-- Fin: se deshace todo
-- ---------------------------------------------------------------------------
ROLLBACK;

\echo ''
\echo '  ============================================'
\echo '   TODAS LAS COMPROBACIONES PASARON'
\echo '  ============================================'
