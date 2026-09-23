-- ============================================================================
--  Capa de ANALYTICS — Mapa de calor, alertas de integridad y desviación
--  sistemática. Se instala DESPUÉS de schema_arequipa.sql:
--
--      psql -d computo_arequipa -v ON_ERROR_STOP=1 \
--           -f backend/sql/views_analytics_arequipa.sql
--
--  Es idempotente (CREATE OR REPLACE) y sólo agrega VISTAS de lectura: no toca
--  ninguna tabla ni regla de negocio. Todo lo que suma votos lo hace sobre
--  `v_resultados_organizacion`, que ya filtra `estado = 'CONTABILIZADA'`; es
--  decir, un acta observada jamás aparece en estos tableros.
-- ============================================================================

BEGIN;

-- ============================================================================
--  1. ROLLUP POR PROVINCIA
--  v_avance_distrito ya trae el avance de los 109 distritos. Esto lo agrega a
--  las 8 provincias para el tablero regional (una fila por provincia).
-- ============================================================================
CREATE OR REPLACE VIEW v_avance_provincia AS
SELECT
    ub.ubigeo                                 AS ubigeo_provincia,
    ub.provincia,
    COUNT(DISTINCT d.ubigeo)                  AS distritos,
    SUM(d.mesas_totales)                      AS mesas_totales,
    SUM(d.actas_contabilizadas)               AS actas_contabilizadas,
    SUM(d.actas_observadas)                   AS actas_observadas,
    SUM(d.actas_pendientes)                   AS actas_pendientes,
    ROUND(
        100.0 * SUM(d.actas_contabilizadas) / NULLIF(SUM(d.mesas_totales), 0), 2
    )                                         AS avance_pct
FROM v_avance_distrito d
JOIN ubigeo ub
  ON ub.provincia = d.provincia
 AND ub.nivel = 'PROVINCIA'
GROUP BY ub.ubigeo, ub.provincia;

COMMENT ON VIEW v_avance_provincia IS
    'Avance del cómputo por provincia (8 filas). Base del semáforo regional.';

-- ============================================================================
--  2. MAPA DE CALOR POR DISTRITO
--  Una fila por distrito con: intensidad normalizada para el coropleta, banda
--  cualitativa (para leyenda y colores) y el ganador distrital en el momento.
--  Sin esto el tablero sólo tenía marcadores de local (analytics/map), no un
--  heat map territorial.
-- ============================================================================
CREATE OR REPLACE VIEW v_mapa_calor_distrito AS
SELECT
    d.ubigeo,
    d.distrito,
    d.provincia,
    ub.latitud,
    ub.longitud,
    d.mesas_totales,
    d.actas_contabilizadas,
    d.actas_observadas,
    d.avance_pct,
    -- Intensidad acotada a 0-100: es lo que consume el color del coropleta.
    LEAST(100, GREATEST(0, COALESCE(d.avance_pct, 0)))        AS intensidad,
    CASE
        WHEN d.avance_pct IS NULL OR d.avance_pct = 0 THEN 'SIN_DATOS'
        WHEN d.avance_pct >= 95                       THEN 'CERRADO'
        WHEN d.avance_pct >= 60                       THEN 'AVANZADO'
        WHEN d.avance_pct >= 25                       THEN 'EN_CURSO'
        ELSE 'INICIADO'
    END                                                       AS banda,
    -- Ganador distrital (columna ALCALDE de la elección DISTRITAL)
    g.organizacion                                            AS ganador,
    g.color_hex                                               AS ganador_color,
    g.votos                                                   AS ganador_votos,
    ROUND(
        100.0 * g.votos / NULLIF((
            SELECT SUM(x.votos)
              FROM v_resultados_organizacion x
             WHERE x.tipo_eleccion = 'DISTRITAL'
               AND x.columna       = 'ALCALDE'
               AND x.distrito      = d.distrito
        ), 0), 2
    )                                                         AS ganador_pct
FROM v_avance_distrito d
JOIN ubigeo ub ON ub.ubigeo = d.ubigeo
LEFT JOIN LATERAL (
    SELECT ro.organizacion, ro.color_hex, ro.votos
      FROM v_resultados_organizacion ro
     WHERE ro.tipo_eleccion = 'DISTRITAL'
       AND ro.columna       = 'ALCALDE'
       AND ro.distrito      = d.distrito
     ORDER BY ro.votos DESC
     LIMIT 1
) g ON TRUE;

COMMENT ON VIEW v_mapa_calor_distrito IS
    'Heat map territorial: avance + banda de color + ganador distrital. Para el nivel provincial/regional, cambiar tipo_eleccion/columna del LATERAL.';

-- ============================================================================
--  3. ALERTAS DE INTEGRIDAD
--  Un renglón por anomalía. Cada alerta lleva severidad y el dato que la
--  dispara, para que el dashboard no tenga que recalcular nada.
-- ============================================================================
CREATE OR REPLACE VIEW v_alertas_integridad AS

-- 3.1 R2 — la mesa declara más votantes que electores hábiles del padrón.
SELECT
    'R2_TOPE_ELECTORES'::TEXT AS alerta,
    'BLOQUEANTE'::TEXT        AS severidad,
    a.id                      AS acta_id,
    a.tipo_eleccion,
    ub.provincia,
    ub.distrito,
    me.numero_mesa,
    a.total_votantes          AS valor_acta,
    me.electores_habiles      AS valor_referencia,
    (a.total_votantes - me.electores_habiles) AS magnitud,
    a.updated_at,
    'Total de votantes excede el padrón de la mesa'::TEXT AS mensaje
FROM actas a
JOIN mesas me            ON me.id = a.mesa_id
JOIN locales_votacion lo ON lo.id = me.local_id
JOIN ubigeo ub           ON ub.ubigeo = lo.ubigeo
WHERE a.total_votantes IS NOT NULL
  AND a.total_votantes > me.electores_habiles

UNION ALL

-- 3.2 Participación fuera de rango en un acta ya contabilizada.
--     Por debajo del 30% suele ser una columna digitada a medias.
SELECT
    'PARTICIPACION_ANOMALA'::TEXT,
    'ADVERTENCIA'::TEXT,
    v.acta_id,
    v.tipo_eleccion,
    v.provincia,
    v.distrito,
    v.numero_mesa,
    v.participacion_pct,
    30,
    ROUND(30 - v.participacion_pct, 2),
    v.updated_at,
    'Participación por debajo del 30% de los electores hábiles'
FROM v_acta_consolidada v
WHERE v.estado = 'CONTABILIZADA'
  AND v.participacion_pct IS NOT NULL
  AND v.participacion_pct < 30

UNION ALL

-- 3.3 Descuadre aritmético abierto (R1) — el acta no puede entrar al cómputo.
SELECT
    'R1_DESCUADRE'::TEXT,
    'BLOQUEANTE'::TEXT,
    a.id,
    a.tipo_eleccion,
    ub.provincia,
    ub.distrito,
    me.numero_mesa,
    a.diferencia_suma,
    0,
    ABS(COALESCE(a.diferencia_suma, 0)),
    a.updated_at,
    'Descuadre en una columna del acta: debe resolverse antes de contabilizar'
FROM actas a
JOIN mesas me            ON me.id = a.mesa_id
JOIN locales_votacion lo ON lo.id = me.local_id
JOIN ubigeo ub           ON ub.ubigeo = lo.ubigeo
WHERE a.estado = 'OBSERVADA'
  AND EXISTS (SELECT 1 FROM fn_descuadres_acta(a.id))

UNION ALL

-- 3.4 SLA vencido — acta observada que nadie ha tocado en más de 24 h.
--     Es la alerta que evita que la cola de revisión quede dormida.
SELECT
    'OBSERVADA_SLA_VENCIDO'::TEXT,
    'ADVERTENCIA'::TEXT,
    a.id,
    a.tipo_eleccion,
    ub.provincia,
    ub.distrito,
    me.numero_mesa,
    ROUND(EXTRACT(EPOCH FROM (now() - a.updated_at)) / 3600.0, 1),
    24,
    ROUND(EXTRACT(EPOCH FROM (now() - a.updated_at)) / 3600.0 - 24, 1),
    a.updated_at,
    'Acta observada sin resolución por más de 24 horas'
FROM actas a
JOIN mesas me            ON me.id = a.mesa_id
JOIN locales_votacion lo ON lo.id = me.local_id
JOIN ubigeo ub           ON ub.ubigeo = lo.ubigeo
WHERE a.estado = 'OBSERVADA'
  AND a.updated_at < now() - INTERVAL '24 hours';

COMMENT ON VIEW v_alertas_integridad IS
    'Alertas de integridad del cómputo (R1, R2, participación anómala y SLA vencido). Ordenar por severidad y magnitud.';

-- ============================================================================
--  4. DESVIACIÓN SISTEMÁTICA CONTRA LA PROVINCIA
--  La comparación "distrito vs provincia" del brief: si una organización saca
--  en un distrito un porcentaje anómalo respecto de su propio promedio
--  provincial, es candidato a revisión dirigida (no prueba nada por sí solo,
--  pero prioriza dónde mirar).
--
--  z = (pct_distrito - pct_media_provincia) / desviación_estándar_provincia
--  Se exigen >= 3 distritos con datos para que la desviación tenga sentido.
-- ============================================================================
CREATE OR REPLACE VIEW v_desviacion_distrito AS
WITH base AS (
    SELECT ub.provincia,
           ub.distrito,
           op.id     AS organizacion_id,
           op.nombre AS organizacion,
           SUM(d.votos) AS votos
      FROM detalle_votos_acta d
      JOIN organizaciones_politicas op ON op.id = d.organizacion_id
      JOIN acta_columnas ac            ON ac.id = d.columna_id
      JOIN actas a                     ON a.id = ac.acta_id
      JOIN mesas me                    ON me.id = a.mesa_id
      JOIN locales_votacion lo         ON lo.id = me.local_id
      JOIN ubigeo ub                   ON ub.ubigeo = lo.ubigeo
     WHERE a.estado = 'CONTABILIZADA'
       AND ac.columna = 'ALCALDE'
     GROUP BY ub.provincia, ub.distrito, op.id, op.nombre
),
totales AS (
    SELECT provincia, distrito, SUM(votos) AS votos_distrito
      FROM base
     GROUP BY provincia, distrito
),
dist AS (
    SELECT b.provincia,
           b.distrito,
           b.organizacion_id,
           b.organizacion,
           100.0 * b.votos / NULLIF(t.votos_distrito, 0) AS pct_distrito
      FROM base b
      JOIN totales t USING (provincia, distrito)
),
prov AS (
    SELECT provincia,
           organizacion_id,
           organizacion,
           avg(pct_distrito)        AS pct_media_provincia,
           stddev_pop(pct_distrito) AS desv_provincia,
           count(*)                 AS distritos_con_datos
      FROM dist
     GROUP BY provincia, organizacion_id, organizacion
)
SELECT
    d.provincia,
    d.distrito,
    d.organizacion,
    ROUND(d.pct_distrito, 2)          AS pct_distrito,
    ROUND(p.pct_media_provincia, 2)   AS pct_media_provincia,
    ROUND(d.pct_distrito - p.pct_media_provincia, 2) AS desviacion_pp,
    ROUND(
        CASE WHEN p.desv_provincia > 0
             THEN (d.pct_distrito - p.pct_media_provincia) / p.desv_provincia
             ELSE 0 END, 2
    )                                 AS z_score,
    p.distritos_con_datos
FROM dist d
JOIN prov p
  ON p.provincia       = d.provincia
 AND p.organizacion_id = d.organizacion_id
WHERE p.distritos_con_datos >= 3
  AND abs(
        CASE WHEN p.desv_provincia > 0
             THEN (d.pct_distrito - p.pct_media_provincia) / p.desv_provincia
             ELSE 0 END
      ) >= 2.5
ORDER BY abs(
        CASE WHEN p.desv_provincia > 0
             THEN (d.pct_distrito - p.pct_media_provincia) / p.desv_provincia
             ELSE 0 END
      ) DESC;

COMMENT ON VIEW v_desviacion_distrito IS
    'Distritos donde una organización se aparta >= 2.5 desviaciones estándar de su propio promedio provincial (columna ALCALDE, sólo actas contabilizadas). Señal de priorización, no de fraude.';

-- ============================================================================
--  5. COLA DE REVISIÓN PRIORIZADA
--  v_actas_observadas lista la cola; esto la ordena por lo que más importa:
--  primero lo bloqueante, luego lo más viejo y lo de mayor magnitud.
-- ============================================================================
CREATE OR REPLACE VIEW v_cola_revision_priorizada AS
SELECT
    o.acta_id,
    o.tipo_eleccion,
    o.provincia,
    o.distrito,
    o.numero_mesa,
    o.columnas_descuadradas,
    o.descuadres,
    o.observaciones,
    o.diferencia_suma,
    o.updated_at,
    ROUND(EXTRACT(EPOCH FROM (now() - o.updated_at)) / 3600.0, 1) AS horas_en_cola,
    -- Puntaje de prioridad: bloqueantes primero, luego antigüedad y magnitud.
    (
        COALESCE(o.columnas_descuadradas, 0) * 1000
      + LEAST(EXTRACT(EPOCH FROM (now() - o.updated_at)) / 3600.0, 100)
      + LEAST(ABS(COALESCE(o.diferencia_suma, 0)), 200)
    )                                                             AS prioridad
FROM v_actas_observadas o
ORDER BY prioridad DESC;

COMMENT ON VIEW v_cola_revision_priorizada IS
    'Cola de observadas ordenada para el coordinador: bloqueantes, antigüedad y magnitud del descuadre.';

COMMIT;

-- ============================================================================
--  CONSULTAS DE OPERACIÓN
-- ============================================================================
-- Semáforo de las 8 provincias:
--   SELECT provincia, mesas_totales, actas_contabilizadas, avance_pct
--     FROM v_avance_provincia ORDER BY avance_pct DESC;
--
-- Heat map distrital (lo que pinta el coropleta):
--   SELECT ubigeo, distrito, avance_pct, intensidad, banda, ganador
--     FROM v_mapa_calor_distrito ORDER BY avance_pct;
--
-- Alertas abiertas, lo peor primero:
--   SELECT alerta, severidad, distrito, numero_mesa, mensaje, magnitud
--     FROM v_alertas_integridad
--    WHERE severidad = 'BLOQUEANTE'
--    ORDER BY magnitud DESC;
--
-- Desviaciones a investigar en una provincia:
--   SELECT distrito, organizacion, pct_distrito, pct_media_provincia, z_score
--     FROM v_desviacion_distrito WHERE provincia = 'AREQUIPA' LIMIT 20;
--
-- La cola que ve el COORD_PROVINCIAL al abrir el día:
--   SELECT * FROM v_cola_revision_priorizada WHERE provincia = 'AREQUIPA' LIMIT 50;
