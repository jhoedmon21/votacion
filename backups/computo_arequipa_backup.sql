--
-- PostgreSQL database dump
--

-- Dumped from database version 16.9
-- Dumped by pg_dump version 16.9

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: cargo_eleccion; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.cargo_eleccion AS ENUM (
    'GOBERNADOR',
    'VICE_GOBERNADOR',
    'CONSEJERO_REGIONAL',
    'ALCALDE_PROVINCIAL',
    'REGIDOR_PROVINCIAL',
    'ALCALDE_DISTRITAL',
    'REGIDOR_DISTRITAL'
);


--
-- Name: codigo_regla; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.codigo_regla AS ENUM (
    'R1_SUMA_VOTOS',
    'R2_TOPE_ELECTORES',
    'R3_COLUMNAS_INCOHERENTES',
    'R4_ACTA_DUPLICADA',
    'R5_FOTO_AUSENTE',
    'R6_ILEGIBLE',
    'R7_FIRMA_FALTANTE',
    'R8_DIFERENCIA_MANUAL'
);


--
-- Name: columna_acta; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.columna_acta AS ENUM (
    'GOBERNADOR_VICE',
    'CONSEJEROS',
    'ALCALDE',
    'REGIDORES'
);


--
-- Name: estado_acta; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.estado_acta AS ENUM (
    'PENDIENTE',
    'DIGITADA',
    'OBSERVADA',
    'CONTABILIZADA',
    'ANULADA'
);


--
-- Name: estado_candidato; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.estado_candidato AS ENUM (
    'INSCRITO',
    'RENUNCIA',
    'EXCLUIDO',
    'FALLECIDO',
    'SUSPENDIDO',
    'RETIRADO'
);


--
-- Name: estado_incidencia; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.estado_incidencia AS ENUM (
    'REPORTADA',
    'EN_ATENCION',
    'RESUELTA',
    'DESCARTADA',
    'ESCALADA'
);


--
-- Name: estado_personero; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.estado_personero AS ENUM (
    'ASIGNADO',
    'CONFIRMADO',
    'PRESENTE',
    'RETIRADO',
    'INHABILITADO'
);


--
-- Name: evento_acta; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.evento_acta AS ENUM (
    'CREADA',
    'DIGITADA',
    'RECALCULADA',
    'OBSERVADA',
    'ENVIADA_A_REVISION',
    'VALIDADA',
    'CONTABILIZADA',
    'ANULADA',
    'REEMPLAZADA',
    'OBSERVACION_RESUELTA'
);


--
-- Name: nivel_cobertura; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.nivel_cobertura AS ENUM (
    'VERDE',
    'AMARILLO',
    'ROJO'
);


--
-- Name: nivel_ubigeo; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.nivel_ubigeo AS ENUM (
    'DEPARTAMENTO',
    'PROVINCIA',
    'DISTRITO'
);


--
-- Name: origen_captura; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.origen_captura AS ENUM (
    'PWA_MOVIL',
    'OCR_IA',
    'DIGITACION_WEB',
    'IMPORTACION_CSV'
);


--
-- Name: prioridad_incidencia; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.prioridad_incidencia AS ENUM (
    'BAJA',
    'MEDIA',
    'ALTA',
    'CRITICA'
);


--
-- Name: rol_usuario; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.rol_usuario AS ENUM (
    'SUPER_ADMIN',
    'COORD_PROVINCIAL',
    'RESPONSABLE_DISTRITAL',
    'PERSONERO',
    'DIGITADOR_GLOBAL'
);


--
-- Name: severidad_observacion; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.severidad_observacion AS ENUM (
    'BLOQUEANTE',
    'ADVERTENCIA',
    'INFO'
);


--
-- Name: tipo_eleccion; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.tipo_eleccion AS ENUM (
    'REGIONAL',
    'PROVINCIAL',
    'DISTRITAL'
);


--
-- Name: tipo_organizacion; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.tipo_organizacion AS ENUM (
    'PARTIDO_NACIONAL',
    'MOVIMIENTO_REGIONAL',
    'ALIANZA_ELECTORAL'
);


--
-- Name: fn_auditar_acta(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_auditar_acta() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_evento evento_acta;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO acta_eventos (acta_id, usuario_id, evento, estado_nuevo, detalle)
        VALUES (NEW.id, NEW.digitada_por, 'CREADA', NEW.estado,
                jsonb_build_object('origen', NEW.origen, 'tipo_eleccion', NEW.tipo_eleccion));
        RETURN NULL;
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        v_evento := CASE NEW.estado
            WHEN 'DIGITADA'      THEN 'DIGITADA'
            WHEN 'OBSERVADA'     THEN 'OBSERVADA'
            WHEN 'CONTABILIZADA' THEN 'CONTABILIZADA'
            WHEN 'ANULADA'       THEN 'ANULADA'
            WHEN 'PENDIENTE'     THEN 'REEMPLAZADA'
        END;
        INSERT INTO acta_eventos (acta_id, usuario_id, evento, estado_anterior, estado_nuevo)
        VALUES (NEW.id, COALESCE(NEW.validada_por, NEW.digitada_por), v_evento, OLD.estado, NEW.estado);
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: fn_campo_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_campo_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;


--
-- Name: fn_checkin_en_radio(bigint, numeric, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_checkin_en_radio(p_local_id bigint, p_lat numeric, p_lon numeric, p_radio_m numeric DEFAULT 300) RETURNS TABLE(dentro boolean, distancia_m numeric)
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: fn_checkin_presente(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_checkin_presente() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: actas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.actas (
    id bigint NOT NULL,
    mesa_id bigint NOT NULL,
    tipo_eleccion public.tipo_eleccion NOT NULL,
    estado public.estado_acta DEFAULT 'PENDIENTE'::public.estado_acta NOT NULL,
    origen public.origen_captura DEFAULT 'PWA_MOVIL'::public.origen_captura NOT NULL,
    electores_habiles integer NOT NULL,
    foto_url text,
    foto_hash_sha256 character(64),
    foto_subida_por bigint,
    foto_subida_at timestamp with time zone,
    total_votantes integer,
    votos_blancos integer DEFAULT 0 NOT NULL,
    votos_nulos integer DEFAULT 0 NOT NULL,
    votos_impugnados integer DEFAULT 0 NOT NULL,
    votos_validos integer DEFAULT 0 NOT NULL,
    validacion boolean,
    diferencia_suma integer,
    observaciones_count smallint DEFAULT 0 NOT NULL,
    digitada_por bigint,
    digitada_at timestamp with time zone,
    validada_por bigint,
    validada_at timestamp with time zone,
    contabilizada_at timestamp with time zone,
    resolucion_final text,
    observacion_general text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT actas_contabilizada_completa CHECK (((estado <> 'CONTABILIZADA'::public.estado_acta) OR ((validacion IS TRUE) AND (validada_por IS NOT NULL) AND (validada_at IS NOT NULL) AND (contabilizada_at IS NOT NULL)))),
    CONSTRAINT actas_electores_positivos CHECK ((electores_habiles > 0)),
    CONSTRAINT actas_hash_formato CHECK (((foto_hash_sha256 IS NULL) OR (foto_hash_sha256 ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT actas_no_negativas CHECK (((votos_blancos >= 0) AND (votos_nulos >= 0) AND (votos_impugnados >= 0) AND ((total_votantes IS NULL) OR (total_votantes >= 0)) AND ((votos_validos IS NULL) OR (votos_validos >= 0))))
);


--
-- Name: fn_consolidar_acta(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_consolidar_acta(p_acta_id bigint) RETURNS public.actas
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_acta   actas;
    v_previo actas;
    t        RECORD;
BEGIN
    SELECT * INTO v_previo FROM actas WHERE id = p_acta_id;
    SELECT * INTO t FROM fn_totales_acta(p_acta_id);

    UPDATE actas
       SET total_votantes   = t.o_total,
           votos_validos    = t.o_validos,
           votos_blancos    = t.o_blancos,
           votos_nulos      = t.o_nulos,
           votos_impugnados = t.o_impugnados,
           diferencia_suma  = t.o_diferencia,
           -- Consistente = NINGUNA columna descuadra (R1 se evalúa por columna)
           validacion       = NOT EXISTS (SELECT 1 FROM fn_descuadres_acta(p_acta_id))
     WHERE id = p_acta_id
    RETURNING * INTO v_acta;

    IF v_previo.id IS NOT NULL
       AND (v_previo.validacion      IS DISTINCT FROM v_acta.validacion
         OR v_previo.total_votantes  IS DISTINCT FROM v_acta.total_votantes
         OR v_previo.diferencia_suma IS DISTINCT FROM v_acta.diferencia_suma) THEN
        INSERT INTO acta_eventos (acta_id, evento, detalle)
        VALUES (p_acta_id, 'RECALCULADA', jsonb_build_object(
            'total_votantes', v_acta.total_votantes,
            'votos_validos',  v_acta.votos_validos,
            'diferencia',     v_acta.diferencia_suma,
            'consistente',    v_acta.validacion,
            'antes', jsonb_build_object(
                'total_votantes',  v_previo.total_votantes,
                'diferencia',      v_previo.diferencia_suma,
                'consistente',     v_previo.validacion)
        ));
    END IF;

    RETURN v_acta;
END;
$$;


--
-- Name: fn_crear_columnas_acta(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_crear_columnas_acta() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.tipo_eleccion = 'REGIONAL' THEN
        INSERT INTO acta_columnas (acta_id, columna) VALUES (NEW.id, 'GOBERNADOR_VICE'), (NEW.id, 'CONSEJEROS');
    ELSE
        INSERT INTO acta_columnas (acta_id, columna) VALUES (NEW.id, 'ALCALDE'), (NEW.id, 'REGIDORES');
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: fn_descuadres_acta(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_descuadres_acta(p_acta_id bigint) RETURNS TABLE(columna public.columna_acta, total_votantes integer, suma_partes integer, descuadre integer)
    LANGUAGE sql STABLE
    AS $$
    SELECT ac.columna,
           ac.total_votantes,
           ac.votos_validos + ac.votos_blancos + ac.votos_nulos + ac.votos_impugnados,
           ac.total_votantes
             - (ac.votos_validos + ac.votos_blancos + ac.votos_nulos + ac.votos_impugnados)
      FROM acta_columnas ac
     WHERE ac.acta_id = p_acta_id
       AND ac.total_votantes
             <> (ac.votos_validos + ac.votos_blancos + ac.votos_nulos + ac.votos_impugnados)
     ORDER BY ac.columna;
$$;


--
-- Name: fn_es_rol_global(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_es_rol_global(p_rol text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT p_rol IN ('SUPER_ADMIN', 'DIGITADOR_GLOBAL');
$$;


--
-- Name: FUNCTION fn_es_rol_global(p_rol text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fn_es_rol_global(p_rol text) IS 'True si el rol omite el scope geográfico (SUPER_ADMIN, DIGITADOR_GLOBAL).';


--
-- Name: fn_estado_cobertura_local(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_estado_cobertura_local(p_local_id bigint) RETURNS public.nivel_cobertura
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: fn_evitar_foto_duplicada(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_evitar_foto_duplicada() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_otro BIGINT;
BEGIN
    -- El propio acta queda excluido: sólo se rechaza el hash usado por OTRA acta.
    SELECT acta_id INTO v_otro
      FROM acta_adjuntos a
      JOIN actas ac ON ac.id = a.acta_id
     WHERE a.hash_sha256 = NEW.hash_sha256 AND a.acta_id <> NEW.acta_id
     LIMIT 1;

    IF v_otro IS NOT NULL THEN
        RAISE EXCEPTION 'FOTO_DUPLICADA: la imagen ya fue usada en el acta %', v_otro
            USING ERRCODE = 'unique_violation';
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: fn_incid_bitacora(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_incid_bitacora() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: fn_incid_cierre(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_incid_cierre() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: fn_incid_codigo(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_incid_codigo() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.codigo IS NULL THEN
        NEW.codigo := 'INC-' || lpad(nextval('seq_incid_codigo')::TEXT, 6, '0');
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: fn_incid_coherencia(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_incid_coherencia() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: fn_incid_prioridad_default(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_incid_prioridad_default() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT ci.prioridad_default INTO NEW.prioridad
      FROM categorias_incidencia ci
     WHERE ci.id = NEW.categoria_id;
    RETURN NEW;
END;
$$;


--
-- Name: fn_observacion_sobre_contabilizada(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_observacion_sobre_contabilizada() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_estado estado_acta;
BEGIN
    IF NEW.severidad <> 'BLOQUEANTE' OR NEW.resuelta THEN
        RETURN NEW;
    END IF;

    SELECT estado INTO v_estado FROM actas WHERE id = NEW.acta_id;

    IF v_estado = 'CONTABILIZADA' THEN
        RAISE EXCEPTION
            'ACTA_YA_CONTABILIZADA: no se puede observar el acta % (regla %) mientras está CONTABILIZADA. Revierte el estado a OBSERVADA para reabrirla, y la reversión quedará en la bitácora.',
            NEW.acta_id, NEW.regla
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: fn_recalcular_columna(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_recalcular_columna() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_columna_id BIGINT := COALESCE(NEW.columna_id, OLD.columna_id);
    v_suma       INTEGER;
BEGIN
    SELECT COALESCE(SUM(votos), 0) INTO v_suma
      FROM detalle_votos_acta
     WHERE columna_id = v_columna_id;

    UPDATE acta_columnas
       SET votos_validos = v_suma,
           updated_at    = now()
     WHERE id = v_columna_id;

    RETURN NULL;
END;
$$;


--
-- Name: fn_set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;


--
-- Name: fn_totales_acta(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_totales_acta(p_acta_id bigint, OUT o_columna public.columna_acta, OUT o_total integer, OUT o_validos integer, OUT o_blancos integer, OUT o_nulos integer, OUT o_impugnados integer, OUT o_diferencia integer) RETURNS record
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    o_columna := CASE
        WHEN (SELECT tipo_eleccion FROM actas WHERE id = p_acta_id) = 'REGIONAL'
            THEN 'GOBERNADOR_VICE'::columna_acta
        ELSE 'ALCALDE'::columna_acta
    END;

    SELECT COALESCE(SUM(total_votantes), 0),
           COALESCE(SUM(votos_validos), 0),
           COALESCE(SUM(votos_blancos), 0),
           COALESCE(SUM(votos_nulos), 0),
           COALESCE(SUM(votos_impugnados), 0)
      INTO o_total, o_validos, o_blancos, o_nulos, o_impugnados
      FROM acta_columnas
     WHERE acta_id = p_acta_id
       AND columna = o_columna;

    o_diferencia := o_total - (o_validos + o_blancos + o_nulos + o_impugnados);
END;
$$;


--
-- Name: fn_tras_cambio_columna(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_tras_cambio_columna() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM fn_consolidar_acta(COALESCE(NEW.acta_id, OLD.acta_id));
    RETURN NULL;
END;
$$;


--
-- Name: fn_validar_contabilizacion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_validar_contabilizacion() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_pendientes INTEGER;
    v_descuadres INTEGER;
    v_detalle    TEXT;
    t            RECORD;
BEGIN
    IF NEW.estado <> 'CONTABILIZADA' THEN
        RETURN NEW;
    END IF;

    -- Recalcula en memoria (sin escribir) para decidir con el dato vigente
    SELECT * INTO t FROM fn_totales_acta(NEW.id);
    NEW.total_votantes   := t.o_total;
    NEW.votos_validos    := t.o_validos;
    NEW.votos_blancos    := t.o_blancos;
    NEW.votos_nulos      := t.o_nulos;
    NEW.votos_impugnados := t.o_impugnados;
    NEW.diferencia_suma  := t.o_diferencia;

    -- R1 por COLUMNA. El acta física trae dos cómputos independientes (alcalde y
    -- regidores, o gobernador/vice y consejeros) y cada uno debe cuadrar con su
    -- propio total de votantes. Se recalcula AQUÍ, sin confiar en la columna
    -- `validacion` que traiga la fila: un descuadre de la columna secundaria
    -- también bloquea la contabilización, no solo el de la principal.
    SELECT COUNT(*),
           string_agg(format('%s (diferencia %s votos)', d.columna, d.descuadre),
                      '; ' ORDER BY d.columna)
      INTO v_descuadres, v_detalle
      FROM fn_descuadres_acta(NEW.id) d;

    NEW.validacion := (v_descuadres = 0);

    IF v_descuadres > 0 THEN
        RAISE EXCEPTION
            'ACTA_INCONSISTENTE: el acta % no cuadra en % columna(s): %. Debe resolverse la observación antes de contabilizar.',
            NEW.id, v_descuadres, v_detalle
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.total_votantes > NEW.electores_habiles THEN
        RAISE EXCEPTION
            'ACTA_EXCEDE_PADRON: el acta % registra % votantes sobre % electores hábiles.',
            NEW.id, NEW.total_votantes, NEW.electores_habiles
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COUNT(*) INTO v_pendientes
      FROM acta_observaciones
     WHERE acta_id = NEW.id AND NOT resuelta AND severidad = 'BLOQUEANTE';

    IF v_pendientes > 0 THEN
        RAISE EXCEPTION
            'ACTA_CON_OBSERVACIONES: el acta % tiene % observaciones bloqueantes sin resolver.',
            NEW.id, v_pendientes
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: accesos_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accesos_log (
    id integer NOT NULL,
    email character varying(160),
    exitoso boolean NOT NULL,
    ip character varying(45),
    user_agent character varying(220),
    detalle character varying(220),
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: accesos_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.accesos_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: accesos_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.accesos_log_id_seq OWNED BY public.accesos_log.id;


--
-- Name: acta_adjuntos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.acta_adjuntos (
    id bigint NOT NULL,
    acta_id bigint NOT NULL,
    tipo character varying(40) NOT NULL,
    url text NOT NULL,
    hash_sha256 character(64),
    subido_por bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT adjuntos_hash_formato CHECK (((hash_sha256 IS NULL) OR (hash_sha256 ~ '^[0-9a-f]{64}$'::text)))
);


--
-- Name: acta_adjuntos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.acta_adjuntos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: acta_adjuntos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.acta_adjuntos_id_seq OWNED BY public.acta_adjuntos.id;


--
-- Name: acta_auditoria_global; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.acta_auditoria_global (
    id integer NOT NULL,
    acta_id integer NOT NULL,
    numero_mesa character varying(6) NOT NULL,
    accion character varying(10) NOT NULL,
    usuario_id integer,
    usuario_email character varying(160) NOT NULL,
    usuario_rol character varying(30) NOT NULL,
    ip character varying(45),
    valores_anteriores text NOT NULL,
    valores_nuevos text NOT NULL,
    motivo text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE acta_auditoria_global; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.acta_auditoria_global IS 'Auditoría obligatoria del Digitador Global: quién (usuario_id/email/rol), desde dónde (ip), cuándo (created_at) y diff completo (valores_anteriores/nuevos en JSON). Append-only.';


--
-- Name: acta_auditoria_global_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.acta_auditoria_global_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: acta_auditoria_global_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.acta_auditoria_global_id_seq OWNED BY public.acta_auditoria_global.id;


--
-- Name: acta_columnas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.acta_columnas (
    id bigint NOT NULL,
    acta_id bigint NOT NULL,
    columna public.columna_acta NOT NULL,
    total_votantes integer DEFAULT 0 NOT NULL,
    votos_validos integer DEFAULT 0 NOT NULL,
    votos_blancos integer DEFAULT 0 NOT NULL,
    votos_nulos integer DEFAULT 0 NOT NULL,
    votos_impugnados integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT acta_columnas_no_negativas CHECK (((total_votantes >= 0) AND (votos_validos >= 0) AND (votos_blancos >= 0) AND (votos_nulos >= 0) AND (votos_impugnados >= 0)))
);


--
-- Name: acta_columnas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.acta_columnas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: acta_columnas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.acta_columnas_id_seq OWNED BY public.acta_columnas.id;


--
-- Name: acta_eventos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.acta_eventos (
    id bigint NOT NULL,
    acta_id bigint NOT NULL,
    usuario_id bigint,
    evento public.evento_acta NOT NULL,
    estado_anterior public.estado_acta,
    estado_nuevo public.estado_acta,
    detalle jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: acta_eventos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.acta_eventos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: acta_eventos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.acta_eventos_id_seq OWNED BY public.acta_eventos.id;


--
-- Name: acta_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.acta_metadata (
    id integer NOT NULL,
    table_id integer NOT NULL,
    votos_blancos integer,
    votos_nulos integer,
    votos_impugnados integer,
    total_electores integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    total_votantes integer
);


--
-- Name: acta_metadata_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.acta_metadata_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: acta_metadata_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.acta_metadata_id_seq OWNED BY public.acta_metadata.id;


--
-- Name: acta_observaciones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.acta_observaciones (
    id bigint NOT NULL,
    acta_id bigint NOT NULL,
    columna_id bigint,
    regla public.codigo_regla NOT NULL,
    severidad public.severidad_observacion DEFAULT 'BLOQUEANTE'::public.severidad_observacion NOT NULL,
    mensaje text NOT NULL,
    diferencia integer,
    resuelta boolean DEFAULT false NOT NULL,
    resuelta_por bigint,
    resuelta_at timestamp with time zone,
    sustento text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT observacion_resuelta_completa CHECK (((NOT resuelta) OR ((resuelta_por IS NOT NULL) AND (resuelta_at IS NOT NULL) AND (sustento IS NOT NULL))))
);


--
-- Name: acta_observaciones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.acta_observaciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: acta_observaciones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.acta_observaciones_id_seq OWNED BY public.acta_observaciones.id;


--
-- Name: actas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.actas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: actas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.actas_id_seq OWNED BY public.actas.id;


--
-- Name: asignacion_personeros; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.asignacion_personeros (
    id integer NOT NULL,
    usuario_id integer NOT NULL,
    mesa_id integer NOT NULL,
    tipo character varying(10) NOT NULL,
    estado character varying(20) NOT NULL,
    asignado_por integer,
    notas text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: asignacion_personeros_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.asignacion_personeros_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: asignacion_personeros_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.asignacion_personeros_id_seq OWNED BY public.asignacion_personeros.id;


--
-- Name: candidatos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.candidatos (
    id bigint NOT NULL,
    organizacion_id bigint NOT NULL,
    ubigeo character(6) NOT NULL,
    tipo_eleccion public.tipo_eleccion NOT NULL,
    cargo public.cargo_eleccion NOT NULL,
    numero_lista smallint NOT NULL,
    dni character(8),
    nombres character varying(120) NOT NULL,
    apellidos character varying(120) NOT NULL,
    nombre_completo character varying(240) NOT NULL,
    foto_url text,
    hoja_vida_url text,
    estado public.estado_candidato DEFAULT 'INSCRITO'::public.estado_candidato NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT candidatos_cargo_coherente CHECK ((((tipo_eleccion = 'REGIONAL'::public.tipo_eleccion) AND (cargo = ANY (ARRAY['GOBERNADOR'::public.cargo_eleccion, 'VICE_GOBERNADOR'::public.cargo_eleccion, 'CONSEJERO_REGIONAL'::public.cargo_eleccion]))) OR ((tipo_eleccion = 'PROVINCIAL'::public.tipo_eleccion) AND (cargo = ANY (ARRAY['ALCALDE_PROVINCIAL'::public.cargo_eleccion, 'REGIDOR_PROVINCIAL'::public.cargo_eleccion]))) OR ((tipo_eleccion = 'DISTRITAL'::public.tipo_eleccion) AND (cargo = ANY (ARRAY['ALCALDE_DISTRITAL'::public.cargo_eleccion, 'REGIDOR_DISTRITAL'::public.cargo_eleccion]))))),
    CONSTRAINT candidatos_dni_formato CHECK (((dni IS NULL) OR (dni ~ '^[0-9]{8}$'::text))),
    CONSTRAINT candidatos_lista_positiva CHECK ((numero_lista >= 1))
);


--
-- Name: candidatos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.candidatos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: candidatos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.candidatos_id_seq OWNED BY public.candidatos.id;


--
-- Name: categorias_incidencia; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categorias_incidencia (
    id smallint NOT NULL,
    codigo character varying(40) NOT NULL,
    nombre character varying(120) NOT NULL,
    prioridad_default public.prioridad_incidencia DEFAULT 'MEDIA'::public.prioridad_incidencia NOT NULL,
    activo boolean DEFAULT true NOT NULL
);


--
-- Name: categorias_incidencia_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.categorias_incidencia_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: categorias_incidencia_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.categorias_incidencia_id_seq OWNED BY public.categorias_incidencia.id;


--
-- Name: checkins_personero; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.checkins_personero (
    id integer NOT NULL,
    asignacion_id integer NOT NULL,
    latitud double precision NOT NULL,
    longitud double precision NOT NULL,
    presicion_m double precision,
    dentro_de_radio boolean NOT NULL,
    distancia_m double precision,
    dispositivo character varying(120),
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: checkins_personero_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.checkins_personero_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: checkins_personero_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.checkins_personero_id_seq OWNED BY public.checkins_personero.id;


--
-- Name: consejero_candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.consejero_candidates (
    id integer NOT NULL,
    name character varying NOT NULL,
    party character varying,
    ubigeo character varying(6),
    color character varying,
    symbol character varying,
    photo_url character varying,
    sort_order integer
);


--
-- Name: consejero_candidates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.consejero_candidates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: consejero_candidates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.consejero_candidates_id_seq OWNED BY public.consejero_candidates.id;


--
-- Name: detalle_votos_acta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.detalle_votos_acta (
    id bigint NOT NULL,
    columna_id bigint NOT NULL,
    organizacion_id bigint NOT NULL,
    candidato_id bigint,
    votos integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT detalle_votos_no_negativos CHECK ((votos >= 0))
);


--
-- Name: detalle_votos_acta_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.detalle_votos_acta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: detalle_votos_acta_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.detalle_votos_acta_id_seq OWNED BY public.detalle_votos_acta.id;


--
-- Name: district_candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.district_candidates (
    id integer NOT NULL,
    name character varying NOT NULL,
    party character varying,
    ubigeo character varying(6),
    color character varying,
    symbol character varying,
    photo_url character varying,
    sort_order integer
);


--
-- Name: district_candidates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.district_candidates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: district_candidates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.district_candidates_id_seq OWNED BY public.district_candidates.id;


--
-- Name: incidencia_adjuntos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.incidencia_adjuntos (
    id bigint NOT NULL,
    incidencia_id bigint NOT NULL,
    tipo character varying(20) DEFAULT 'FOTO'::character varying NOT NULL,
    url text NOT NULL,
    hash_sha256 character(64),
    subido_por bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT adj_incid_hash_formato CHECK (((hash_sha256 IS NULL) OR (hash_sha256 ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT incidencia_adjuntos_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['FOTO'::character varying, 'AUDIO'::character varying, 'VIDEO'::character varying, 'DOC'::character varying])::text[])))
);


--
-- Name: incidencia_adjuntos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.incidencia_adjuntos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: incidencia_adjuntos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.incidencia_adjuntos_id_seq OWNED BY public.incidencia_adjuntos.id;


--
-- Name: incidencia_seguimiento; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.incidencia_seguimiento (
    id bigint NOT NULL,
    incidencia_id bigint NOT NULL,
    usuario_id bigint,
    estado_nuevo public.estado_incidencia,
    comentario text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: incidencia_seguimiento_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.incidencia_seguimiento_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: incidencia_seguimiento_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.incidencia_seguimiento_id_seq OWNED BY public.incidencia_seguimiento.id;


--
-- Name: incidencias_campo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.incidencias_campo (
    id bigint NOT NULL,
    codigo character varying(12),
    categoria_id smallint NOT NULL,
    ubigeo character(6) NOT NULL,
    local_id bigint,
    mesa_id bigint,
    reportado_por bigint,
    titulo character varying(160) NOT NULL,
    descripcion text NOT NULL,
    prioridad public.prioridad_incidencia DEFAULT 'MEDIA'::public.prioridad_incidencia NOT NULL,
    estado public.estado_incidencia DEFAULT 'REPORTADA'::public.estado_incidencia NOT NULL,
    asignada_a bigint,
    resuelta_en timestamp with time zone,
    tiempo_resolucion_min numeric(10,2),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT incidencia_titulo_no_vacio CHECK ((length(btrim((titulo)::text)) > 0))
);


--
-- Name: COLUMN incidencias_campo.codigo; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.incidencias_campo.codigo IS 'Código público INC-NNNNNN (secuencia seq_incid_codigo). DEFAULT lo completa el trigger BEFORE INSERT.';


--
-- Name: incidencias_campo_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.incidencias_campo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: incidencias_campo_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.incidencias_campo_id_seq OWNED BY public.incidencias_campo.id;


--
-- Name: locales_votacion; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.locales_votacion (
    id bigint NOT NULL,
    ubigeo character(6) NOT NULL,
    codigo_local character varying(20) NOT NULL,
    nombre character varying(160) NOT NULL,
    direccion character varying(220),
    referencia character varying(220),
    latitud numeric(10,6),
    longitud numeric(10,6),
    electores_habiles integer DEFAULT 0 NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    coordinador_local_id bigint,
    CONSTRAINT locales_electores_no_negativos CHECK ((electores_habiles >= 0))
);


--
-- Name: locales_votacion_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.locales_votacion_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: locales_votacion_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.locales_votacion_id_seq OWNED BY public.locales_votacion.id;


--
-- Name: mesas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mesas (
    id bigint NOT NULL,
    local_id bigint NOT NULL,
    numero_mesa character(6) NOT NULL,
    electores_habiles integer NOT NULL,
    pabellon character varying(40),
    piso character varying(20),
    numero_orden integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT mesas_electores_positivo CHECK ((electores_habiles > 0)),
    CONSTRAINT mesas_numero_formato CHECK ((numero_mesa ~ '^[0-9]{6}$'::text))
);


--
-- Name: mesas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mesas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mesas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mesas_id_seq OWNED BY public.mesas.id;


--
-- Name: organizaciones_politicas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizaciones_politicas (
    id bigint NOT NULL,
    nombre character varying(160) NOT NULL,
    nombre_corto character varying(60),
    tipo public.tipo_organizacion NOT NULL,
    id_jne integer,
    logo_url text,
    color_hex character(7) DEFAULT '#6b7280'::bpchar NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT organizaciones_color_formato CHECK ((color_hex ~* '^#[0-9a-f]{6}$'::text))
);


--
-- Name: organizaciones_politicas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.organizaciones_politicas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organizaciones_politicas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.organizaciones_politicas_id_seq OWNED BY public.organizaciones_politicas.id;


--
-- Name: provincial_candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provincial_candidates (
    id integer NOT NULL,
    name character varying NOT NULL,
    party character varying,
    ubigeo character varying(6),
    color character varying,
    symbol character varying,
    photo_url character varying,
    sort_order integer
);


--
-- Name: provincial_candidates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.provincial_candidates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: provincial_candidates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.provincial_candidates_id_seq OWNED BY public.provincial_candidates.id;


--
-- Name: records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.records (
    id integer NOT NULL,
    table_id integer NOT NULL,
    candidate_type character varying NOT NULL,
    candidate_id integer NOT NULL,
    votes integer,
    verified boolean,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.records_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.records_id_seq OWNED BY public.records.id;


--
-- Name: regional_candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.regional_candidates (
    id integer NOT NULL,
    name character varying NOT NULL,
    party character varying,
    ubigeo character varying(6),
    color character varying,
    symbol character varying,
    photo_url character varying,
    sort_order integer
);


--
-- Name: regional_candidates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.regional_candidates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: regional_candidates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.regional_candidates_id_seq OWNED BY public.regional_candidates.id;


--
-- Name: seq_incid_codigo; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_incid_codigo
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sesiones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sesiones (
    id integer NOT NULL,
    usuario_id integer NOT NULL,
    token_hash character varying(64) NOT NULL,
    dispositivo character varying(120),
    ip character varying(45),
    expira_at timestamp with time zone NOT NULL,
    revocada boolean NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: sesiones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sesiones_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sesiones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sesiones_id_seq OWNED BY public.sesiones.id;


--
-- Name: tables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tables (
    id integer NOT NULL,
    venue_id integer NOT NULL,
    numero_mesa character varying NOT NULL,
    electores_habiles integer,
    processed boolean,
    requires_review boolean,
    status character varying,
    ocr_confidence double precision,
    image_url character varying,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: tables_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tables_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tables_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tables_id_seq OWNED BY public.tables.id;


--
-- Name: ubigeo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ubigeo (
    ubigeo character(6) NOT NULL,
    ubigeo_reniec character(6),
    departamento character varying(60) NOT NULL,
    provincia character varying(60),
    distrito character varying(60),
    nivel public.nivel_ubigeo NOT NULL,
    capital character varying(120),
    latitud numeric(10,6),
    longitud numeric(10,6),
    altitud integer,
    densidad_poblacional numeric(12,4),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ubigeo_coherencia_nivel CHECK ((((nivel = 'DEPARTAMENTO'::public.nivel_ubigeo) AND (provincia IS NULL) AND (distrito IS NULL)) OR ((nivel = 'PROVINCIA'::public.nivel_ubigeo) AND (provincia IS NOT NULL) AND (distrito IS NULL)) OR ((nivel = 'DISTRITO'::public.nivel_ubigeo) AND (provincia IS NOT NULL) AND (distrito IS NOT NULL)))),
    CONSTRAINT ubigeo_formato CHECK ((ubigeo ~ '^[0-9]{6}$'::text)),
    CONSTRAINT ubigeo_latitud_rango CHECK (((latitud IS NULL) OR ((latitud >= ('-19'::integer)::numeric) AND (latitud <= (0)::numeric)))),
    CONSTRAINT ubigeo_longitud_rango CHECK (((longitud IS NULL) OR ((longitud >= ('-82'::integer)::numeric) AND (longitud <= ('-68'::integer)::numeric)))),
    CONSTRAINT ubigeo_reniec_formato CHECK (((ubigeo_reniec IS NULL) OR (ubigeo_reniec ~ '^[0-9]{6}$'::text)))
);


--
-- Name: TABLE ubigeo; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.ubigeo IS 'Base ubigeo INEI/RENIEC. Arequipa = 8 provincias / 109 distritos (dep 04).';


--
-- Name: usuario_alcance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usuario_alcance (
    usuario_id integer NOT NULL,
    ubigeo character varying(6) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    local_id bigint
);


--
-- Name: usuarios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usuarios (
    id integer NOT NULL,
    email character varying(160) NOT NULL,
    dni character varying(8) NOT NULL,
    nombres character varying(80) NOT NULL,
    apellidos character varying(80) NOT NULL,
    telefono character varying(20),
    password_hash character varying(100) NOT NULL,
    rol character varying(30) NOT NULL,
    activo boolean NOT NULL,
    intentos_fallidos integer NOT NULL,
    bloqueado_hasta timestamp with time zone,
    ultimo_acceso timestamp with time zone,
    debe_cambiar_clave boolean NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: COLUMN usuarios.password_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.usuarios.password_hash IS 'Hash bcrypt: pgcrypto crypt(..., gen_salt(''bf'', 12)) o bcrypt de Python. Nunca texto plano.';


--
-- Name: usuarios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.usuarios_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: usuarios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.usuarios_id_seq OWNED BY public.usuarios.id;


--
-- Name: v_acta_consolidada; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_acta_consolidada AS
 SELECT a.id AS acta_id,
    a.tipo_eleccion,
    a.estado,
    a.origen,
    ub.ubigeo,
    ub.provincia,
    ub.distrito,
    lo.codigo_local,
    lo.nombre AS local_votacion,
    me.numero_mesa,
    me.electores_habiles,
    a.total_votantes,
    a.votos_validos,
    a.votos_blancos,
    a.votos_nulos,
    a.votos_impugnados,
    a.diferencia_suma,
    a.validacion,
    ( SELECT count(*) AS count
           FROM public.fn_descuadres_acta(a.id) fn_descuadres_acta(columna, total_votantes, suma_partes, descuadre)) AS columnas_descuadradas,
    (a.foto_url IS NOT NULL) AS tiene_foto,
    round(((100.0 * ((((a.votos_validos + a.votos_blancos) + a.votos_nulos) + a.votos_impugnados))::numeric) / (NULLIF(me.electores_habiles, 0))::numeric), 2) AS participacion_pct,
    a.digitada_por,
    a.validada_por,
    a.updated_at,
    ( SELECT count(*) AS count
           FROM public.acta_observaciones o
          WHERE ((o.acta_id = a.id) AND (NOT o.resuelta))) AS observaciones_abiertas
   FROM (((public.actas a
     JOIN public.mesas me ON ((me.id = a.mesa_id)))
     JOIN public.locales_votacion lo ON ((lo.id = me.local_id)))
     JOIN public.ubigeo ub ON ((ub.ubigeo = lo.ubigeo)));


--
-- Name: v_actas_observadas; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_actas_observadas AS
 SELECT a.id AS acta_id,
    a.tipo_eleccion,
    ub.distrito,
    ub.provincia,
    me.numero_mesa,
    a.diferencia_suma,
    ( SELECT count(*) AS count
           FROM public.fn_descuadres_acta(a.id) fn_descuadres_acta(columna, total_votantes, suma_partes, descuadre)) AS columnas_descuadradas,
    ( SELECT string_agg(((((d.columna)::text || ' (diferencia '::text) || d.descuadre) || ')'::text), ' | '::text ORDER BY d.columna) AS string_agg
           FROM public.fn_descuadres_acta(a.id) d(columna, total_votantes, suma_partes, descuadre)) AS descuadres,
    a.total_votantes,
    a.electores_habiles,
    a.updated_at,
    string_agg(((((o.regla)::text || ' ['::text) || o.severidad) || ']'::text), ' | '::text ORDER BY o.regla) AS observaciones
   FROM ((((public.actas a
     JOIN public.mesas me ON ((me.id = a.mesa_id)))
     JOIN public.locales_votacion lo ON ((lo.id = me.local_id)))
     JOIN public.ubigeo ub ON ((ub.ubigeo = lo.ubigeo)))
     LEFT JOIN public.acta_observaciones o ON (((o.acta_id = a.id) AND (NOT o.resuelta))))
  WHERE (a.estado = 'OBSERVADA'::public.estado_acta)
  GROUP BY a.id, a.tipo_eleccion, ub.distrito, ub.provincia, me.numero_mesa, a.diferencia_suma, a.total_votantes, a.electores_habiles, a.updated_at;


--
-- Name: v_avance_distrito; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_avance_distrito AS
 SELECT ub.ubigeo,
    ub.provincia,
    ub.distrito,
    count(DISTINCT me.id) AS mesas_totales,
    count(DISTINCT a.id) FILTER (WHERE (a.estado = 'CONTABILIZADA'::public.estado_acta)) AS actas_contabilizadas,
    count(DISTINCT a.id) FILTER (WHERE (a.estado = 'OBSERVADA'::public.estado_acta)) AS actas_observadas,
    count(DISTINCT a.id) FILTER (WHERE (a.estado = ANY (ARRAY['PENDIENTE'::public.estado_acta, 'DIGITADA'::public.estado_acta]))) AS actas_pendientes,
    round(((100.0 * (count(DISTINCT a.id) FILTER (WHERE (a.estado = 'CONTABILIZADA'::public.estado_acta)))::numeric) / (NULLIF(count(DISTINCT me.id), 0))::numeric), 2) AS avance_pct
   FROM (((public.ubigeo ub
     JOIN public.locales_votacion lo ON ((lo.ubigeo = ub.ubigeo)))
     JOIN public.mesas me ON ((me.local_id = lo.id)))
     LEFT JOIN public.actas a ON ((a.mesa_id = me.id)))
  WHERE (ub.nivel = 'DISTRITO'::public.nivel_ubigeo)
  GROUP BY ub.ubigeo, ub.provincia, ub.distrito;


--
-- Name: v_cobertura_locales; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_cobertura_locales AS
 WITH cobertura AS (
         SELECT m.local_id,
            m.id AS mesa_id,
            bool_or(((ap.estado)::text = 'PRESENTE'::text)) AS con_presente,
            (count(ap.id) FILTER (WHERE ((ap.estado)::text = ANY ((ARRAY['ASIGNADO'::character varying, 'CONFIRMADO'::character varying, 'PRESENTE'::character varying])::text[]))) > 0) AS con_asignado
           FROM (public.mesas m
             LEFT JOIN public.asignacion_personeros ap ON ((ap.mesa_id = m.id)))
          GROUP BY m.local_id, m.id
        )
 SELECT l.id AS local_id,
    l.codigo_local,
    l.nombre,
    u.ubigeo,
    u.distrito,
    u.provincia,
    count(cobertura.mesa_id) AS mesas_total,
    count(cobertura.mesa_id) FILTER (WHERE cobertura.con_presente) AS mesas_con_presencia,
    count(cobertura.mesa_id) FILTER (WHERE (NOT cobertura.con_asignado)) AS mesas_sin_personero,
        CASE
            WHEN (count(*) FILTER (WHERE (NOT cobertura.con_asignado)) > 0) THEN 'ROJO'::public.nivel_cobertura
            WHEN (count(*) FILTER (WHERE (NOT cobertura.con_presente)) > 0) THEN 'AMARILLO'::public.nivel_cobertura
            ELSE 'VERDE'::public.nivel_cobertura
        END AS nivel,
    ( SELECT string_agg((mm.numero_mesa)::text, ', '::text ORDER BY ((mm.numero_mesa)::text)) AS string_agg
           FROM public.mesas mm
          WHERE ((mm.local_id = l.id) AND (NOT (EXISTS ( SELECT 1
                   FROM public.asignacion_personeros x
                  WHERE (x.mesa_id = mm.id)))))) AS mesas_criticas
   FROM ((public.locales_votacion l
     JOIN public.ubigeo u ON ((u.ubigeo = l.ubigeo)))
     LEFT JOIN cobertura ON ((cobertura.local_id = l.id)))
  GROUP BY l.id, l.codigo_local, l.nombre, u.ubigeo, u.distrito, u.provincia;


--
-- Name: VIEW v_cobertura_locales; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.v_cobertura_locales IS 'Semáforo de cobertura por local: VERDE/AMARILLO/ROJO según personeros presentes/asignados.';


--
-- Name: v_cobertura_distrito; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_cobertura_distrito AS
 SELECT u.ubigeo,
    u.distrito,
    u.provincia,
    count(DISTINCT cl.id) AS locales_total,
    count(DISTINCT cl.id) FILTER (WHERE (cov.nivel = 'VERDE'::public.nivel_cobertura)) AS locales_verdes,
    count(DISTINCT cl.id) FILTER (WHERE (cov.nivel = 'AMARILLO'::public.nivel_cobertura)) AS locales_amarillos,
    count(DISTINCT cl.id) FILTER (WHERE (cov.nivel = 'ROJO'::public.nivel_cobertura)) AS locales_rojos,
        CASE
            WHEN (count(DISTINCT cl.id) FILTER (WHERE (cov.nivel = 'ROJO'::public.nivel_cobertura)) > 0) THEN 'ROJO'::public.nivel_cobertura
            WHEN (count(DISTINCT cl.id) FILTER (WHERE (cov.nivel = 'AMARILLO'::public.nivel_cobertura)) > 0) THEN 'AMARILLO'::public.nivel_cobertura
            WHEN (count(DISTINCT cl.id) > 0) THEN 'VERDE'::public.nivel_cobertura
            ELSE 'ROJO'::public.nivel_cobertura
        END AS nivel
   FROM ((public.ubigeo u
     LEFT JOIN public.locales_votacion cl ON ((cl.ubigeo = u.ubigeo)))
     LEFT JOIN public.v_cobertura_locales cov ON ((cov.local_id = cl.id)))
  WHERE (u.nivel = 'DISTRITO'::public.nivel_ubigeo)
  GROUP BY u.ubigeo, u.distrito, u.provincia;


--
-- Name: v_incidencias_abiertas; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_incidencias_abiertas AS
 SELECT i.id,
    i.codigo,
    ci.nombre AS categoria,
    i.prioridad,
    i.estado,
    i.titulo,
    i.ubigeo,
    u.provincia,
    u.distrito,
    l.nombre AS local,
    m.numero_mesa AS mesa,
    i.created_at,
    round(((date_part('epoch'::text, (now() - i.created_at)) / (60)::double precision))::numeric, 1) AS minutos_abierta,
    ( SELECT count(*) AS count
           FROM public.incidencia_adjuntos a
          WHERE (a.incidencia_id = i.id)) AS adjuntos
   FROM ((((public.incidencias_campo i
     JOIN public.categorias_incidencia ci ON ((ci.id = i.categoria_id)))
     JOIN public.ubigeo u ON ((u.ubigeo = i.ubigeo)))
     LEFT JOIN public.locales_votacion l ON ((l.id = i.local_id)))
     LEFT JOIN public.mesas m ON ((m.id = i.mesa_id)))
  WHERE (i.estado = ANY (ARRAY['REPORTADA'::public.estado_incidencia, 'EN_ATENCION'::public.estado_incidencia, 'ESCALADA'::public.estado_incidencia]))
  ORDER BY
        CASE i.prioridad
            WHEN 'CRITICA'::public.prioridad_incidencia THEN 0
            WHEN 'ALTA'::public.prioridad_incidencia THEN 1
            WHEN 'MEDIA'::public.prioridad_incidencia THEN 2
            ELSE 3
        END, i.created_at;


--
-- Name: v_resultados_candidato; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_resultados_candidato AS
 SELECT c.id AS candidato_id,
    c.nombre_completo,
    c.cargo,
    c.tipo_eleccion,
    c.ubigeo,
    op.nombre AS organizacion,
    op.color_hex,
    sum(d.votos) AS votos,
    count(DISTINCT a.id) AS actas_contabilizadas
   FROM ((((public.detalle_votos_acta d
     JOIN public.candidatos c ON ((c.id = d.candidato_id)))
     JOIN public.organizaciones_politicas op ON ((op.id = d.organizacion_id)))
     JOIN public.acta_columnas ac ON ((ac.id = d.columna_id)))
     JOIN public.actas a ON ((a.id = ac.acta_id)))
  WHERE ((a.estado = 'CONTABILIZADA'::public.estado_acta) AND (d.candidato_id IS NOT NULL))
  GROUP BY c.id, c.nombre_completo, c.cargo, c.tipo_eleccion, c.ubigeo, op.nombre, op.color_hex;


--
-- Name: v_resultados_organizacion; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_resultados_organizacion AS
 SELECT op.id AS organizacion_id,
    op.nombre AS organizacion,
    op.color_hex,
    ac.columna,
    a.tipo_eleccion,
    ub.ubigeo,
    ub.provincia,
    ub.distrito,
    sum(d.votos) AS votos,
    count(DISTINCT a.id) AS actas_contabilizadas
   FROM ((((((public.detalle_votos_acta d
     JOIN public.organizaciones_politicas op ON ((op.id = d.organizacion_id)))
     JOIN public.acta_columnas ac ON ((ac.id = d.columna_id)))
     JOIN public.actas a ON ((a.id = ac.acta_id)))
     JOIN public.mesas me ON ((me.id = a.mesa_id)))
     JOIN public.locales_votacion lo ON ((lo.id = me.local_id)))
     JOIN public.ubigeo ub ON ((ub.ubigeo = lo.ubigeo)))
  WHERE (a.estado = 'CONTABILIZADA'::public.estado_acta)
  GROUP BY op.id, op.nombre, op.color_hex, ac.columna, a.tipo_eleccion, ub.ubigeo, ub.provincia, ub.distrito;


--
-- Name: venues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.venues (
    id integer NOT NULL,
    name character varying NOT NULL,
    sector character varying NOT NULL,
    address character varying,
    latitude double precision NOT NULL,
    longitude double precision NOT NULL,
    ubigeo character varying(6),
    total_tables integer,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: venues_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.venues_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: venues_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.venues_id_seq OWNED BY public.venues.id;


--
-- Name: accesos_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accesos_log ALTER COLUMN id SET DEFAULT nextval('public.accesos_log_id_seq'::regclass);


--
-- Name: acta_adjuntos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_adjuntos ALTER COLUMN id SET DEFAULT nextval('public.acta_adjuntos_id_seq'::regclass);


--
-- Name: acta_auditoria_global id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_auditoria_global ALTER COLUMN id SET DEFAULT nextval('public.acta_auditoria_global_id_seq'::regclass);


--
-- Name: acta_columnas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_columnas ALTER COLUMN id SET DEFAULT nextval('public.acta_columnas_id_seq'::regclass);


--
-- Name: acta_eventos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_eventos ALTER COLUMN id SET DEFAULT nextval('public.acta_eventos_id_seq'::regclass);


--
-- Name: acta_metadata id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_metadata ALTER COLUMN id SET DEFAULT nextval('public.acta_metadata_id_seq'::regclass);


--
-- Name: acta_observaciones id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_observaciones ALTER COLUMN id SET DEFAULT nextval('public.acta_observaciones_id_seq'::regclass);


--
-- Name: actas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actas ALTER COLUMN id SET DEFAULT nextval('public.actas_id_seq'::regclass);


--
-- Name: asignacion_personeros id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asignacion_personeros ALTER COLUMN id SET DEFAULT nextval('public.asignacion_personeros_id_seq'::regclass);


--
-- Name: candidatos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidatos ALTER COLUMN id SET DEFAULT nextval('public.candidatos_id_seq'::regclass);


--
-- Name: categorias_incidencia id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorias_incidencia ALTER COLUMN id SET DEFAULT nextval('public.categorias_incidencia_id_seq'::regclass);


--
-- Name: checkins_personero id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.checkins_personero ALTER COLUMN id SET DEFAULT nextval('public.checkins_personero_id_seq'::regclass);


--
-- Name: consejero_candidates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consejero_candidates ALTER COLUMN id SET DEFAULT nextval('public.consejero_candidates_id_seq'::regclass);


--
-- Name: detalle_votos_acta id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.detalle_votos_acta ALTER COLUMN id SET DEFAULT nextval('public.detalle_votos_acta_id_seq'::regclass);


--
-- Name: district_candidates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.district_candidates ALTER COLUMN id SET DEFAULT nextval('public.district_candidates_id_seq'::regclass);


--
-- Name: incidencia_adjuntos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencia_adjuntos ALTER COLUMN id SET DEFAULT nextval('public.incidencia_adjuntos_id_seq'::regclass);


--
-- Name: incidencia_seguimiento id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencia_seguimiento ALTER COLUMN id SET DEFAULT nextval('public.incidencia_seguimiento_id_seq'::regclass);


--
-- Name: incidencias_campo id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencias_campo ALTER COLUMN id SET DEFAULT nextval('public.incidencias_campo_id_seq'::regclass);


--
-- Name: locales_votacion id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locales_votacion ALTER COLUMN id SET DEFAULT nextval('public.locales_votacion_id_seq'::regclass);


--
-- Name: mesas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesas ALTER COLUMN id SET DEFAULT nextval('public.mesas_id_seq'::regclass);


--
-- Name: organizaciones_politicas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizaciones_politicas ALTER COLUMN id SET DEFAULT nextval('public.organizaciones_politicas_id_seq'::regclass);


--
-- Name: provincial_candidates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provincial_candidates ALTER COLUMN id SET DEFAULT nextval('public.provincial_candidates_id_seq'::regclass);


--
-- Name: records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.records ALTER COLUMN id SET DEFAULT nextval('public.records_id_seq'::regclass);


--
-- Name: regional_candidates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regional_candidates ALTER COLUMN id SET DEFAULT nextval('public.regional_candidates_id_seq'::regclass);


--
-- Name: sesiones id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sesiones ALTER COLUMN id SET DEFAULT nextval('public.sesiones_id_seq'::regclass);


--
-- Name: tables id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tables ALTER COLUMN id SET DEFAULT nextval('public.tables_id_seq'::regclass);


--
-- Name: usuarios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuarios ALTER COLUMN id SET DEFAULT nextval('public.usuarios_id_seq'::regclass);


--
-- Name: venues id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venues ALTER COLUMN id SET DEFAULT nextval('public.venues_id_seq'::regclass);


--
-- Data for Name: accesos_log; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.accesos_log (id, email, exitoso, ip, user_agent, detalle, created_at) FROM stdin;
1	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 18:58:19-05
2	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 18:58:45-05
3	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 18:58:45-05
4	coord.caylloma@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 18:58:45-05
5	personero.paucarpata@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 1)	2026-09-15 18:58:45-05
6	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 18:59:22-05
7	coord.caylloma@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 18:59:23-05
8	resp.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 18:59:23-05
9	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 1)	2026-09-15 18:59:24-05
10	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 2)	2026-09-15 18:59:24-05
11	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 3)	2026-09-15 18:59:24-05
12	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 4)	2026-09-15 18:59:24-05
13	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 5) => bloqueado 15 min	2026-09-15 18:59:24-05
14	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	cuenta bloqueada	2026-09-15 18:59:24-05
15	resp.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:00:23-05
16	coord.caylloma@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:00:24-05
17	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:00:24-05
18	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:00:25-05
19	coord.arequipa@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:00:25-05
20	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:07:55-05
21	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:07:55-05
22	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.112 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-15 19:24:09-05
23	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:29:07-05
24	coord.caylloma@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:29:08-05
25	resp.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:29:08-05
26	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:37:03-05
27	coord.caylloma@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:37:04-05
28	resp.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:37:04-05
29	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:37:04-05
30	admin@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 1)	2026-09-15 19:37:05-05
31	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 1)	2026-09-15 19:37:05-05
32	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 2)	2026-09-15 19:37:05-05
33	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 3)	2026-09-15 19:37:06-05
34	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 4)	2026-09-15 19:37:06-05
35	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	clave incorrecta (intento 5) => bloqueado 15 min	2026-09-15 19:37:06-05
36	resp.yanahuara@computoarequipa.gob.pe	f	127.0.0.1	curl/8.14.1	cuenta bloqueada	2026-09-15 19:37:06-05
37	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:38:18-05
38	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	curl/8.14.1	login ok	2026-09-15 19:47:40-05
39	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.112 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-15 19:48:24-05
40	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-16 03:01:05-05
41	coord.arequipa@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36 Avast/152.0.0.0	login ok	2026-09-16 03:04:57-05
42	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.116 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-16 18:21:10-05
43	coord.arequipa@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-16 18:22:03-05
44	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.116 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-16 18:24:47-05
45	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-16 18:47:47-05
46	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-16 18:49:43-05
47	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-16 18:49:57-05
48	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-16 18:50:24-05
49	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-16 18:50:53-05
50	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-16 18:50:59-05
51	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-16 18:51:05-05
52	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-16 18:51:38-05
53	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-16 18:52:14-05
54	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-16 18:53:07-05
55	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-16 18:53:27-05
56	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-16 18:54:19-05
57	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-16 19:24:37-05
58	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-16 19:24:45-05
59	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-16 19:25:38-05
60	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT; Windows NT 10.0; es-PE) WindowsPowerShell/5.1.26100.6899	login ok	2026-09-17 01:23:01-05
61	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT; Windows NT 10.0; es-PE) WindowsPowerShell/5.1.26100.6899	login ok	2026-09-17 01:31:45-05
62	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT; Windows NT 10.0; es-PE) WindowsPowerShell/5.1.26100.6899	login ok	2026-09-17 01:34:23-05
63	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT; Windows NT 10.0; es-PE) WindowsPowerShell/5.1.26100.6899	login ok	2026-09-17 01:36:43-05
64	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT; Windows NT 10.0; es-PE) WindowsPowerShell/5.1.26100.6899	login ok	2026-09-17 01:40:44-05
65	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 02:38:23-05
66	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36 Avast/152.0.0.0	login ok	2026-09-17 02:41:51-05
67	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36 Avast/152.0.0.0	login ok	2026-09-17 03:37:15-05
68	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:44:05-05
69	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:44:45-05
70	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:50:32-05
71	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:51:10-05
72	coord.islay@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:51:20-05
73	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:51:29-05
74	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:52:08-05
75	coord.islay@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:52:19-05
76	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:52:31-05
77	personero.mollendo@computoarequipa.gob.pe	f	127.0.0.1	Python-urllib/3.12	cuenta desactivada	2026-09-17 03:52:46-05
78	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:52:50-05
79	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:53:36-05
80	coord.islay@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:53:46-05
81	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:53:59-05
82	personero.mollendo@computoarequipa.gob.pe	f	127.0.0.1	Python-urllib/3.12	cuenta desactivada	2026-09-17 03:54:13-05
83	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:54:18-05
84	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:55:20-05
85	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 03:55:22-05
86	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:09:46-05
87	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:10:08-05
88	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:14:16-05
89	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:14:59-05
90	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:15:21-05
91	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:15:56-05
92	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:17:09-05
93	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:17:26-05
94	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 04:19:49-05
95	coord.arequipa@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 04:21:27-05
96	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 04:24:26-05
97	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:28:15-05
98	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 04:29:26-05
99	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:34:25-05
100	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:34:33-05
101	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:36:41-05
102	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:36:50-05
103	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 04:37:48-05
104	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:44:08-05
105	coord.islay@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:44:13-05
106	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:44:17-05
107	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:46:05-05
108	coord.islay@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:46:09-05
109	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:46:14-05
110	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:47:04-05
111	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:47:06-05
112	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 04:47:42-05
113	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:53:21-05
114	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:53:23-05
115	coord.islay@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 04:53:26-05
116	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 04:54:38-05
117	resp.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 04:55:04-05
118	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 04:57:44-05
119	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 04:58:04-05
120	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 05:00:54-05
121	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:03:06-05
122	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 05:03:14-05
123	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:29:06-05
124	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:29:45-05
125	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:35:36-05
126	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:36:33-05
127	personero.mollendo@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:38:17-05
128	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:39:48-05
129	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:48:44-05
130	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:53:18-05
131	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:55:30-05
132	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:57:50-05
133	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-17 05:58:01-05
134	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36 Avast/152.0.0.0	login ok	2026-09-17 14:39:09-05
135	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Mobile Safari/537.36	login ok	2026-09-17 14:43:42-05
136	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 22:19:58-05
137	personero.paucarpata@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 22:27:47-05
138	resp.yanahuara@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 22:29:37-05
139	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-17 23:03:10-05
140	jhoedmon@gmail.com	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-18 02:35:32-05
141	digitador.global@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-18 03:04:56-05
142	digitador.global@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-18 03:19:20-05
143	jhoedmon@gmail.com	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-18 03:33:33-05
144	digitador.global@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-18 03:49:52-05
145	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-18 04:35:16-05
146	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-18 04:35:19-05
147	digitador.global@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-18 04:56:11-05
148	digitador.global@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-18 04:56:29-05
149	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-18 04:56:29-05
150	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-18 04:58:27-05
151	jhoedmon@gmail.com	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36 Avast/152.0.0.0	login ok	2026-09-19 13:45:42-05
152	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-22 16:46:13-05
153	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.133 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-22 16:51:50-05
154	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-22 17:02:55-05
155	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-23 01:17:27-05
156	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-23 01:36:09-05
157	admin@votoperu.pe	f	testclient	testclient	usuario desconocido	2026-09-23 01:43:40-05
158	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-23 01:44:00-05
159	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.133 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-23 01:53:54-05
160	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-23 02:34:40-05
161	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-23 12:45:26-05
162	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.135 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-23 12:54:36-05
163	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-23 18:18:45-05
164	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-24 23:25:04-05
165	admin@gmail.com	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-24 23:28:07-05
166	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-25 00:06:11-05
167	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.145 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-25 01:31:33-05
168	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-25 01:42:13-05
169	admin@gmail.com	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.145 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-25 01:45:23-05
170	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-25 02:10:19-05
171	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-25 02:10:44-05
172	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-25 02:19:01-05
173	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-25 02:21:27-05
174	admin@computoarequipa.gob.pe	t	127.0.0.1	Python-urllib/3.12	login ok	2026-09-25 02:21:30-05
175	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-25 02:23:06-05
176	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-25 02:24:02-05
177	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-24 21:49:24.838153-05
178	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-24 21:50:11.245737-05
179	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-24 22:01:51.438616-05
180	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-24 22:21:50.049737-05
181	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-24 22:23:13.320999-05
182	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-24 22:25:17.83206-05
183	admin@computoarequipa.gob.pe	t	testclient	testclient	login ok	2026-09-24 22:45:50.215943-05
184	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-24 22:54:13.345204-05
185	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-24 22:57:17.638471-05
186	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-24 23:09:38.516684-05
187	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-24 23:50:09.869376-05
189	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.145 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-24 23:50:35.072955-05
188	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.145 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-24 23:50:35.070796-05
190	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-25 09:32:07.818363-05
191	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-25 09:32:18.599761-05
192	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-25 09:32:25.071695-05
193	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-25 09:37:16.985081-05
194	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.147 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-25 09:38:11.723604-05
195	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36 Avast/152.0.0.0	login ok	2026-09-26 08:48:31.256316-05
196	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 08:50:59.013968-05
197	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.147 Chrome/130.0.6723.191 Electron/33.4.11 Safari/537.36	login ok	2026-09-26 08:53:41.947583-05
198	admin@computoarequipa.gob.pe	t	127.0.0.1	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36	login ok	2026-09-26 08:54:58.945099-05
199	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 08:55:47.048884-05
200	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 08:57:26.809516-05
201	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 09:30:29.376055-05
202	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 09:32:54.80859-05
203	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 10:19:32.854051-05
204	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 10:20:07.0241-05
205	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 10:21:02.513092-05
206	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 10:32:11.408356-05
207	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 10:32:28.610611-05
208	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 10:32:38.702867-05
209	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 10:32:50.286227-05
210	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 11:31:26.47313-05
211	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 11:32:11.4183-05
212	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 11:32:53.46988-05
213	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 11:33:44.844192-05
214	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 11:34:31.192257-05
215	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 11:35:19.814384-05
216	admin@computoarequipa.gob.pe	t	127.0.0.1	curl/8.21.0	login ok	2026-09-26 11:53:01.045478-05
\.


--
-- Data for Name: acta_adjuntos; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.acta_adjuntos (id, acta_id, tipo, url, hash_sha256, subido_por, created_at) FROM stdin;
\.


--
-- Data for Name: acta_auditoria_global; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.acta_auditoria_global (id, acta_id, numero_mesa, accion, usuario_id, usuario_email, usuario_rol, ip, valores_anteriores, valores_nuevos, motivo, created_at) FROM stdin;
\.


--
-- Data for Name: acta_columnas; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.acta_columnas (id, acta_id, columna, total_votantes, votos_validos, votos_blancos, votos_nulos, votos_impugnados, updated_at) FROM stdin;
\.


--
-- Data for Name: acta_eventos; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.acta_eventos (id, acta_id, usuario_id, evento, estado_anterior, estado_nuevo, detalle, created_at) FROM stdin;
\.


--
-- Data for Name: acta_metadata; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.acta_metadata (id, table_id, votos_blancos, votos_nulos, votos_impugnados, total_electores, created_at, updated_at, total_votantes) FROM stdin;
2	3036	0	0	0	250	2026-09-23 02:05:24-05	2026-09-23 02:05:59-05	\N
4	3225	5	3	2	250	2026-09-25 02:19:01-05	2026-09-25 02:19:01-05	\N
8	1311	5	2	0	40	2026-09-26 10:21:02.952021-05	2026-09-26 10:21:02.952021-05	30
9	1312	5	2	0	40	2026-09-26 10:21:03.236726-05	2026-09-26 10:21:03.236726-05	37
10	1313	5	0	0	40	2026-09-26 10:21:03.503226-05	2026-09-26 10:21:03.503226-05	50
1	1307	0	0	0	250	2026-09-23 01:18:35-05	2026-09-26 10:34:27.216444-05	0
6	1308	2	1	0	37	2026-09-26 09:32:55.477691-05	2026-09-26 10:34:46.824847-05	0
7	1309	0	0	0	250	2026-09-26 09:37:08.598301-05	2026-09-26 10:34:56.002106-05	0
3	1321	1	1	1	250	2026-09-23 02:36:25-05	2026-09-26 10:51:16.18519-05	0
\.


--
-- Data for Name: acta_observaciones; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.acta_observaciones (id, acta_id, columna_id, regla, severidad, mensaje, diferencia, resuelta, resuelta_por, resuelta_at, sustento, created_at) FROM stdin;
\.


--
-- Data for Name: actas; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.actas (id, mesa_id, tipo_eleccion, estado, origen, electores_habiles, foto_url, foto_hash_sha256, foto_subida_por, foto_subida_at, total_votantes, votos_blancos, votos_nulos, votos_impugnados, votos_validos, validacion, diferencia_suma, observaciones_count, digitada_por, digitada_at, validada_por, validada_at, contabilizada_at, resolucion_final, observacion_general, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: asignacion_personeros; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.asignacion_personeros (id, usuario_id, mesa_id, tipo, estado, asignado_por, notas, created_at, updated_at) FROM stdin;
1	1	1305	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
2	1	4677	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
3	1	4678	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
4	1	4679	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
5	1	4680	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
6	1	4681	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
7	1	4682	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
8	1	4683	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
9	1	1307	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
10	1	1308	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
11	1	1309	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
12	1	1310	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
13	1	1311	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
14	1	1312	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
15	1	1313	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
16	1	1314	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
17	1	1315	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
18	1	1316	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
19	1	1317	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
20	1	1318	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
21	1	1319	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
22	1	1320	TITULAR	PRESENTE	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
23	1	1321	TITULAR	CONFIRMADO	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
24	1	1322	TITULAR	CONFIRMADO	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
25	1	1323	TITULAR	CONFIRMADO	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
26	1	1324	TITULAR	CONFIRMADO	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
27	1	1325	TITULAR	CONFIRMADO	1	seed demo de cobertura	2026-09-22 16:46:13-05	2026-09-22 16:46:13-05
28	10	1917	TITULAR	ASIGNADO	1	\N	2026-09-23 02:50:06-05	2026-09-23 02:50:06-05
29	6	1495	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
30	6	1496	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
31	6	1497	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
32	6	1498	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
33	6	1499	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
34	6	1500	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
35	6	1501	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
36	6	1502	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
37	6	1503	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
38	6	1504	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
39	6	1505	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
40	6	1506	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
41	6	1507	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
42	6	1508	TITULAR	ASIGNADO	1	\N	2026-09-23 03:35:53-05	2026-09-23 03:35:53-05
\.


--
-- Data for Name: candidatos; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.candidatos (id, organizacion_id, ubigeo, tipo_eleccion, cargo, numero_lista, dni, nombres, apellidos, nombre_completo, foto_url, hoja_vida_url, estado, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: categorias_incidencia; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.categorias_incidencia (id, codigo, nombre, prioridad_default, activo) FROM stdin;
1	MESA_NO_INSTALADA	Mesa no instalada a la hora de inicio	ALTA	t
2	AUSENTISMO_MIEMBROS_MESA	Ausentismo de miembros de mesa	ALTA	t
3	AGRESION_INTIMIDACION	Agresión o intimidación	CRITICA	t
4	MATERIAL_INCOMPLETO	Material electoral incompleto	MEDIA	t
5	INTENTO_DE_FRAUDE	Intento de fraude	CRITICA	t
6	IMPUGNACION_VOTOS	Impugnación de votos	ALTA	t
7	SIN_SENAL_COMUNICACION	Sin señal de comunicación en el local	BAJA	t
8	OTRO	Otro (especificar en descripción)	BAJA	t
\.


--
-- Data for Name: checkins_personero; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.checkins_personero (id, asignacion_id, latitud, longitud, presicion_m, dentro_de_radio, distancia_m, dispositivo, created_at) FROM stdin;
\.


--
-- Data for Name: consejero_candidates; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.consejero_candidates (id, name, party, ubigeo, color, symbol, photo_url, sort_order) FROM stdin;
1	LILY MARGOTH JUAREZ SALAZAR	ALIANZA PARA EL PROGRESO	040100	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	\N	1
2	PERCY RUBEN MAMANI MAMANI	ACCION POPULAR	040100	#EC4899	/storage/partidos/partido_accion_popular.png	\N	3
3	JOSE RAUL SUAREZ LLERENA	AHORA NACION - AN	040100	#D97706	/storage/partidos/partido_ahora_nacion_an.png	\N	8
4	FRANCISCO VITO TRELLES SAICO	PARTIDO DEMOCRATICO SOMOS PERU	040100	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	\N	9
5	KELLY PATRICIA CHIRINOS TEJADA	PARTIDO APRISTA PERUANO	040100	#7C3AED	/storage/partidos/partido_partido_aprista_peruano.png	\N	10
6	EDGARDO EDWARD ALVAREZ HUERTAS	ALIANZA ELECTORAL VENCEREMOS	040100	#8B5CF6	/storage/partidos/partido_alianza_electoral_venceremos.png	\N	11
7	CECILIA ALEJANDRINA JARITA PADILLA	YO AREQUIPA	040100	#EC4899	/storage/partidos/partido_yo_arequipa.png	\N	12
8	CRISTHIAN MARIO CUADROS TREVIÑO	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040100	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	\N	13
9	RAÚL HUANACO BAUTISTA	AREQUIPA, TRADICION Y FUTURO	040100	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	\N	14
10	OSCAR ALFREDO AYALA ARENAS	FUERZA AREQUIPEÑA	040100	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	\N	15
11	CLAUDIA ROSA NUÑEZ VARGAS	ALIANZA PARA EL PROGRESO	040200	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	\N	1
12	ALI ANYELO CHIOCK AMESQUITA	ACCION POPULAR	040200	#EC4899	/storage/partidos/partido_accion_popular.png	\N	3
13	MANUEL MARTIN MARTINEZ MOLLESACA	AHORA NACION - AN	040200	#D97706	/storage/partidos/partido_ahora_nacion_an.png	\N	8
14	EDDER JUAN MIGUEL ARIAS CHALCO	PARTIDO DEMOCRATICO SOMOS PERU	040200	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	\N	9
15	WILMER MANUEL ROBERTO BEGAZO GONZALES	PARTIDO APRISTA PERUANO	040200	#7C3AED	/storage/partidos/partido_partido_aprista_peruano.png	\N	10
16	ELIZABETH BERNA MOTTA ROJAS	ALIANZA ELECTORAL VENCEREMOS	040200	#8B5CF6	/storage/partidos/partido_alianza_electoral_venceremos.png	\N	11
17	NOHELIA ALEXANDRA CABRERA CALISAYA	YO AREQUIPA	040200	#EC4899	/storage/partidos/partido_yo_arequipa.png	\N	12
18	MARTÍN JOSÉ ZEVALLOS SOTO	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040200	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	\N	13
19	YENIFER CRISTEL JACOBO SUAREZ	FUERZA AREQUIPEÑA	040200	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	\N	15
20	ROSARIO ESTELA FUÑO UMPIRE DE MORAN	ACCION POPULAR	040300	#EC4899	/storage/partidos/partido_accion_popular.png	\N	3
21	LINA MARIANA UGARTE ANGULO	AHORA NACION - AN	040300	#D97706	/storage/partidos/partido_ahora_nacion_an.png	\N	8
22	GLORIA PILAR ESPINOZA BUSTAMANTE	PARTIDO DEMOCRATICO SOMOS PERU	040300	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	\N	9
23	ROBERTO JESUS SOTO RIVEROS	ALIANZA ELECTORAL VENCEREMOS	040300	#8B5CF6	/storage/partidos/partido_alianza_electoral_venceremos.png	\N	11
24	AARON ALEXANDER MALDONADO LOPEZ	YO AREQUIPA	040300	#EC4899	/storage/partidos/partido_yo_arequipa.png	\N	12
25	ROSS ALICE LUJAN CARHUAYO	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040300	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	\N	13
26	SHEYLA GUIANELLA ROSPIGLIOSI SANDOVAL	AREQUIPA, TRADICION Y FUTURO	040300	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	\N	14
27	DIEGO ARTURO MONTESINOS NEYRA	FUERZA AREQUIPEÑA	040300	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	\N	15
28	MARIA DEL CARMEN LACUTA CHUQUITAYPE	ALIANZA PARA EL PROGRESO	040400	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	\N	1
29	OSCAR FAUSTINO SARMIENTO BERROSPIDE	ACCION POPULAR	040400	#EC4899	/storage/partidos/partido_accion_popular.png	\N	3
30	MAX ELIAS MORON ALVAREZ	AHORA NACION - AN	040400	#D97706	/storage/partidos/partido_ahora_nacion_an.png	\N	8
31	EDUARDO JELBER GAMERO	PARTIDO DEMOCRATICO SOMOS PERU	040400	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	\N	9
32	RUTH GELEN CRUZ CONDORI	PARTIDO APRISTA PERUANO	040400	#7C3AED	/storage/partidos/partido_partido_aprista_peruano.png	\N	10
33	DENIT QUISCA YUCRA	ALIANZA ELECTORAL VENCEREMOS	040400	#8B5CF6	/storage/partidos/partido_alianza_electoral_venceremos.png	\N	11
34	ANA LUZ OVIEDO LOPEZ DE ARENAS	YO AREQUIPA	040400	#EC4899	/storage/partidos/partido_yo_arequipa.png	\N	12
35	ANTONIO LIZANDRO LLERENA SALAS	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040400	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	\N	13
36	YORK DENNIS YAÑEZ ROJAS	AREQUIPA, TRADICION Y FUTURO	040400	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	\N	14
37	MARTHA MARCELINA HUAMANI CASTRO	FUERZA AREQUIPEÑA	040400	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	\N	15
38	LUZ KAROL DEL CARPIO ARGUELLES	ALIANZA PARA EL PROGRESO	040500	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	\N	1
39	MAYRA LUCIA LLAZA NIFLA	ACCION POPULAR	040500	#EC4899	/storage/partidos/partido_accion_popular.png	\N	3
40	RUBEN BRAULIO BOLAÑOS TACURI	AHORA NACION - AN	040500	#D97706	/storage/partidos/partido_ahora_nacion_an.png	\N	8
41	HUBER RENE TACO CHOQUEHUAYTA	PARTIDO DEMOCRATICO SOMOS PERU	040500	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	\N	9
42	JULIAN GUILLERMO CAYANI VALCARCEL	PARTIDO APRISTA PERUANO	040500	#7C3AED	/storage/partidos/partido_partido_aprista_peruano.png	\N	10
43	KATHERINE LAURA SUCASACA	ALIANZA ELECTORAL VENCEREMOS	040500	#8B5CF6	/storage/partidos/partido_alianza_electoral_venceremos.png	\N	11
44	AURELIA MONICA GUERRA MENDOZA	YO AREQUIPA	040500	#EC4899	/storage/partidos/partido_yo_arequipa.png	\N	12
45	EDY MILAGROS CASCO CANO	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040500	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	\N	13
46	JUANA ROSA NINA APAZA	AREQUIPA, TRADICION Y FUTURO	040500	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	\N	14
47	KAROLINE LISSED CHAVEZ TICONA	FUERZA AREQUIPEÑA	040500	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	\N	15
48	KATHERINE BELINA SANCHEZ CRUZ	ALIANZA PARA EL PROGRESO	040600	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	\N	1
49	NELLY SUSANA AQUINO HUAYLLA DE ABARCA	ACCION POPULAR	040600	#EC4899	/storage/partidos/partido_accion_popular.png	\N	3
50	GALO MIGUEL SARMIENTO SANCHEZ	AHORA NACION - AN	040600	#D97706	/storage/partidos/partido_ahora_nacion_an.png	\N	8
51	IVAN GREGORIO RAMIREZ LAZARO	PARTIDO DEMOCRATICO SOMOS PERU	040600	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	\N	9
52	VICTORIA AHUATE VARGAS	YO AREQUIPA	040600	#EC4899	/storage/partidos/partido_yo_arequipa.png	\N	12
53	UBER VICTORIANO CABRERA CARPIO	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040600	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	\N	13
54	EDWAR ANDRES VELARDE ALLAZO	AREQUIPA, TRADICION Y FUTURO	040600	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	\N	14
55	KAROLA AMPARO MANCHEGO LLERENA	FUERZA AREQUIPEÑA	040600	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	\N	15
56	JUAN LUIS QUIJAHUAMAN ARTETA	ALIANZA PARA EL PROGRESO	040700	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	\N	1
57	MIGUEL ANGEL RODRIGUEZ CHILE	ACCION POPULAR	040700	#EC4899	/storage/partidos/partido_accion_popular.png	\N	3
58	BEATRIZ VERONICA COASACA BELIZARIO	AHORA NACION - AN	040700	#D97706	/storage/partidos/partido_ahora_nacion_an.png	\N	8
59	BETSABE SAMIRA RODRIGUEZ VARGAS	PARTIDO DEMOCRATICO SOMOS PERU	040700	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	\N	9
60	MARIA DEL CARMEN PEREA LEON	PARTIDO APRISTA PERUANO	040700	#7C3AED	/storage/partidos/partido_partido_aprista_peruano.png	\N	10
61	DANIEL HERNAN TORANZO CASTILLO	ALIANZA ELECTORAL VENCEREMOS	040700	#8B5CF6	/storage/partidos/partido_alianza_electoral_venceremos.png	\N	11
62	JAIME ARTURO PEREA DIAZ	YO AREQUIPA	040700	#EC4899	/storage/partidos/partido_yo_arequipa.png	\N	12
63	LISSET FIORELLA IBARRA RODRIGUEZ	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040700	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	\N	13
64	HENRY GUSTAVO GARCIA ORTEGA	AREQUIPA, TRADICION Y FUTURO	040700	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	\N	14
65	JOSE TORIBIO TITO ZAPATA	FUERZA AREQUIPEÑA	040700	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	\N	15
66	KHEY ORIANA PALOMINO CORNEJO	ALIANZA PARA EL PROGRESO	040800	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	\N	1
67	YUBELL EDGARDO LLAMOCA NINA	ACCION POPULAR	040800	#EC4899	/storage/partidos/partido_accion_popular.png	\N	3
68	CESAR CONCEPCION BELLIDO ANGULO	AHORA NACION - AN	040800	#D97706	/storage/partidos/partido_ahora_nacion_an.png	\N	8
69	CESAR ROLANDO TOTOCAYO AYMARA	PARTIDO DEMOCRATICO SOMOS PERU	040800	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	\N	9
70	JUAN ANDRIU PERALTA CRUZ	PARTIDO APRISTA PERUANO	040800	#7C3AED	/storage/partidos/partido_partido_aprista_peruano.png	\N	10
71	OTO MANUEL CARRILLO ANTAYHUA	ALIANZA ELECTORAL VENCEREMOS	040800	#8B5CF6	/storage/partidos/partido_alianza_electoral_venceremos.png	\N	11
72	LESLI MILAGROS GONZALES LUPO	YO AREQUIPA	040800	#EC4899	/storage/partidos/partido_yo_arequipa.png	\N	12
73	KARIN AMANDA MARTINEZ CHIRINOS	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040800	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	\N	13
74	ABELINO INDALECIO RONCALLA QUISPE	AREQUIPA, TRADICION Y FUTURO	040800	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	\N	14
75	LIBORIO TEOFILO MARROQUIN GIRON	FUERZA AREQUIPEÑA	040800	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	\N	15
\.


--
-- Data for Name: detalle_votos_acta; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.detalle_votos_acta (id, columna_id, organizacion_id, candidato_id, votos, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: district_candidates; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.district_candidates (id, name, party, ubigeo, color, symbol, photo_url, sort_order) FROM stdin;
1	LUIS JUSTO MAYTA LIVISI	ACCION POPULAR	040112	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_29460883.jpg	4
2	JULIO CESAR APAZA CHOQUEPATA	AHORA NACION - AN	040112	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29619602.jpg	7
3	GEHOVA MICHELE MEDINA ARENAS	ALIANZA PARA EL PROGRESO	040112	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29649422.jpg	1
4	JUAN ANGEL MAMANI QUEA	BATALLA PERU	040112	#EC4899	/storage/partidos/partido_batalla_peru.png	/storage/candidatos/candidato_29572059.jpg	6
6	EDUARDO ESTOFANERO MOLLEAPAZA	JUNTOS POR EL PERU	040112	#DC2626	/storage/partidos/partido_juntos_por_el_peru.png	/storage/candidatos/candidato_29462869.jpg	3
7	EDWIN WILLY VILCA MAMANI	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040112	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_44030684.jpg	12
8	MARCIO FELIX SOTO RIVERA	PARTIDO DEL BUEN GOBIERNO	040112	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_29693741.jpg	8
9	WILDER ROGGER RODRIGUEZ ARAPA	PARTIDO DEMOCRATICO SOMOS PERU	040112	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_43547791.jpg	9
10	JIAN CARLOS CHAVEZ CARBAJAL	PARTIDO MORADO	040112	#0056B3	/storage/partidos/partido_partido_morado.png	/storage/candidatos/candidato_47569046.jpg	10
11	RODOLFO ALFREDO VELASQUEZ PUMACALLAHUI	PARTIDO POLITICO NACIONAL PERU LIBRE	040112	#10B981	/storage/partidos/partido_partido_politico_nacional_peru_libre.png	/storage/candidatos/candidato_72942205.jpg	2
12	GLADYS SORIANA MAMANI QUISPE	RENOVACION POPULAR PERU	040112	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_42825292.jpg	5
13	RICARDO ABEL VILAVILA MAMANI	YO AREQUIPA	040112	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_75227708.jpg	11
14	DANIEL RICARDO DELGADO QUILLA	ACCION POPULAR	040102	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_42040127.jpg	2
15	JOSE LUIS NARRO ORTIZ	AHORA NACION - AN	040102	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_40343403.jpg	4
16	JESSICA ESTRELLA CANO ALARCON	AREQUIPA, TRADICION Y FUTURO	040102	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_72655243.jpg	9
17	DAVID ADOLFO BARRIGA MIRANDA	FUERZA AREQUIPEÑA	040102	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_41448246.jpg	10
18	GLENNY MARCOS SANCHEZ ORIHUELA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040102	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_40012164.jpg	8
19	JESUS ANTONIO GAMERO MARQUEZ	PARTIDO APRISTA PERUANO	040102	#7C3AED	/storage/partidos/partido_partido_aprista_peruano.png	/storage/candidatos/candidato_29285064.jpg	6
20	KELVIN SAMIR PACHECO JIMENEZ	PARTIDO DEL BUEN GOBIERNO	040102	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_46254291.jpg	5
21	DOMINGO SUCLLE ARAGON	PARTIDO POLITICO NACIONAL PERU LIBRE	040102	#10B981	/storage/partidos/partido_partido_politico_nacional_peru_libre.png	/storage/candidatos/candidato_29706930.jpg	1
22	RICARDO TOMAS RAMIREZ OCHOA	PARTIDO POLITICO PERU PRIMERO	040102	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_43419758.jpg	3
23	ERNESTO OSWALDO OLAZABAL OLAZABAL	PERU MODERNO	040102	#10B981	/storage/partidos/partido_peru_moderno.png	/storage/candidatos/candidato_40191499.jpg	7
24	MOISES JESUS CHUCTAYA HUARCA	AHORA NACION - AN	040103	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29723036.jpg	4
25	JOSE RENATO CARREON ECHEGARAY	BATALLA PERU	040103	#EC4899	/storage/partidos/partido_batalla_peru.png	/storage/candidatos/candidato_29554296.jpg	3
27	HARBERTH RAUL ZUÑIGA HERRERA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040103	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29427261.jpg	8
28	LUIS ANGEL PASTOR ARAMBURU	PARTIDO DEL BUEN GOBIERNO	040103	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_29723310.jpg	6
29	IVAN EBERT VELASQUEZ RAMOS	PARTIDO DEMOCRATA VERDE	040103	#DC2626	/storage/partidos/partido_partido_democrata_verde.png	/storage/candidatos/candidato_43985370.jpg	2
30	JULIO CESAR PACCO CHACMA	PERU MODERNO	040103	#10B981	/storage/partidos/partido_peru_moderno.png	/storage/candidatos/candidato_48262300.jpg	7
31	JAIME PEDRO CHAVEZ FLORES	PROGRESEMOS	040103	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_30560678.jpg	5
32	VICTOR HUGO POLAR GUTIERREZ	RENOVACION POPULAR PERU	040103	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_46267301.jpg	1
33	MIRTHA MAVEL RUELAS CASILLAS	AHORA NACION - AN	040104	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29557433.jpg	7
35	YULEX ALONSO BERNAL AGUEDO	LIBERTAD POPULAR	040104	#CA8A04	/storage/partidos/partido_libertad_popular.png	/storage/candidatos/candidato_29723509.jpg	5
36	HERMES NICOLAS OSCCO POLAR	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040104	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_40380190.jpg	10
37	JESÚS ANTONIO RAYME CUTIPA	PARTIDO CIVICO OBRAS	040104	#002B66	/storage/partidos/partido_partido_civico_obras.png	/storage/candidatos/candidato_29734813.jpg	2
38	VICTOR RAUL DIAZ ESTREMADOYRO	PARTIDO DEL BUEN GOBIERNO	040104	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_43299211.jpg	8
39	MICHAEL RAUL ATENCIO CASTRO	PARTIDO DEMOCRATA VERDE	040104	#DC2626	/storage/partidos/partido_partido_democrata_verde.png	/storage/candidatos/candidato_43364562.jpg	4
40	RAFAEL VALENTINO VELASQUEZ SIVINCHA	PARTIDO FRENTE DE LA ESPERANZA 2021	040104	#DC2626	/storage/partidos/partido_partido_frente_de_la_esperanza_2021.png	/storage/candidatos/candidato_40243653.jpg	1
41	ALBERTO FLORES CCAMA	PARTIDO POLITICO PERU PRIMERO	040104	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_29616388.jpg	6
42	MARIA DE LOURDES ARIAS VERA	RENOVACION POPULAR PERU	040104	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_10275684.jpg	3
44	JORGE ALFREDO VILCA AGUILAR	AHORA NACION - AN	040105	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29542484.jpg	4
45	JESUS GODOFREDO AGUILAR GUILLEN	ALIANZA ELECTORAL VENCEREMOS	040105	#8B5CF6	/storage/partidos/partido_alianza_electoral_venceremos.png	/storage/candidatos/candidato_29351728.jpg	7
46	MAURO MARCOS RUELAS HUACASI	AREQUIPA, TRADICION Y FUTURO	040105	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29351161.jpg	10
48	MARIBEL EFIGENIA LINARES LUQUE	JUNTOS POR EL PERU	040105	#DC2626	/storage/partidos/partido_juntos_por_el_peru.png	/storage/candidatos/candidato_29351945.jpg	1
49	PERCY JUAN HERRERA MORALES	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040105	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29350908.jpg	9
50	MIGUEL ANGEL PUMA CRUZ	PARTIDO DEMOCRATA VERDE	040105	#DC2626	/storage/partidos/partido_partido_democrata_verde.png	/storage/candidatos/candidato_45494625.jpg	2
51	JORGE RONY PORTILLA PORTILLA	PARTIDO POLITICO PERU PRIMERO	040105	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_44394369.jpg	3
52	AURELIO MARTIN FLORES HUAMAN	PODEMOS PERU	040105	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_00454084.jpg	6
53	RUTH MARY PORTILLA PINTO	PROGRESEMOS	040105	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_29621649.jpg	5
55	MOISES URBANO VIZCARRA ANDAMAYO	AHORA NACION - AN	040106	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29697653.jpg	6
56	JESUS FELIPE EGOABIL OLIVA	ALIANZA PARA EL PROGRESO	040106	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29646349.jpg	1
58	EMILIANO VILCA RUIZ	JUNTOS POR EL PERU	040106	#DC2626	/storage/partidos/partido_juntos_por_el_peru.png	/storage/candidatos/candidato_29364809.jpg	2
59	GREGORIO ANGEL CORRALES DELGADO	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040106	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29353897.jpg	9
60	ROBERT ANIBAL VALDEZ PUMA	PARTIDO CIVICO OBRAS	040106	#002B66	/storage/partidos/partido_partido_civico_obras.png	/storage/candidatos/candidato_29590910.jpg	3
61	BENITO RICHARD YANQUI QUISPE	PARTIDO DEMOCRATA UNIDO PERU	040106	#D97706	/storage/partidos/partido_partido_democrata_unido_peru.png	/storage/candidatos/candidato_29735515.jpg	5
62	GERALDINE SORELI BENAVENTE AVALOS	PARTIDO DEMOCRATA VERDE	040106	#DC2626	/storage/partidos/partido_partido_democrata_verde.png	/storage/candidatos/candidato_71380587.jpg	4
63	PITER VILCA GALLEGOS	PERU MODERNO	040106	#10B981	/storage/partidos/partido_peru_moderno.png	/storage/candidatos/candidato_29354011.jpg	7
65	ERIK JOHN NUÑEZ MAMANI	ACCION POPULAR	040107	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_42303377.jpg	2
66	RENE ADOLFO CAMARGO LOPEZ	AHORA NACION - AN	040107	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_42033345.jpg	4
67	JHON RICHARD CONDORI POCCO	COOPERACION, VERDAD Y HONRADEZ	040107	#D97706	/storage/partidos/partido_cooperacion_verdad_y_honradez.png	/storage/candidatos/candidato_42008707.jpg	3
69	ROGER ANDIA ROMERO	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040107	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29710727.jpg	8
70	YESENIA CARRILLO YUCRA	PARTIDO DEL BUEN GOBIERNO	040107	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_29723848.jpg	6
71	SERGIO ALFREDO BARRIGA RODRIGUEZ	PERU MODERNO	040107	#10B981	/storage/partidos/partido_peru_moderno.png	/storage/candidatos/candidato_01218898.jpg	7
72	AURELIA LUPE PILA BARREDA	PROGRESEMOS	040107	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_29615237.jpg	5
73	LEONARDO JESUS ALVAREZ TICONA	SALVEMOS AL PERU	040107	#8B5CF6	/storage/partidos/partido_salvemos_al_peru.png	/storage/candidatos/candidato_29625188.jpg	1
74	ERICK MAICOLL APAZA PALO	AHORA NACION - AN	040108	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_46884996.jpg	3
75	CAMILO CARPIO CONCHA	ALIANZA PARA EL PROGRESO	040108	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_42878173.jpg	1
76	DORIAN JAVIER LARICO ZENAYUCA	AREQUIPA, TRADICION Y FUTURO	040108	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_40850978.jpg	6
78	VICTOR GIAN - PIERRE DIAZ SALAS	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040108	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_73674617.jpg	5
79	ALFREDO EMIGDIO LAGUNA GALLEGOS	PARTIDO DEMOCRATICO SOMOS PERU	040108	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_40565826.jpg	4
80	HELMUTH ANDREE VASQUEZ RIVERA	PARTIDO POLITICO PERU PRIMERO	040108	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_46831068.jpg	2
81	ANGEL GERARDO ESQUIVEL QUISPE	ACCION POPULAR	040109	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_29363450.jpg	1
82	CARLOS ALEJANDRO ANDRADE PAREJA	AHORA NACION - AN	040109	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29565509.jpg	2
83	SERGIO GONZALES APAZA	AREQUIPA, TRADICION Y FUTURO	040109	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_80263302.jpg	6
85	PERCY LUIS CORNEJO BARRAGAN	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040109	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29566574.jpg	5
86	IRENE SALAZAR ARIAS DE RODRIGUEZ	PARTIDO DEL BUEN GOBIERNO	040109	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_29705969.jpg	3
87	EDWIN ROLANDO TITO OROZCO	PARTIDO DEMOCRATICO SOMOS PERU	040109	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_80146883.jpg	4
88	JIM ROBERT CAMA HUARICALLO	ACCION POPULAR	040110	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_29734053.jpg	2
89	HUBERT JESUS ALVAREZ MAMANI	AHORA NACION - AN	040110	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_40198998.jpg	4
90	PERCY ALEX BELLIDO REYES	ALIANZA PARA EL PROGRESO	040110	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29625415.jpg	1
92	MARCO ANTONIO CENTTY LOPEZ	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040110	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29624367.jpg	9
93	LUIS MAGNO AGUIRRE CHAVEZ	PARTIDO APRISTA PERUANO	040110	#7C3AED	/storage/partidos/partido_partido_aprista_peruano.png	/storage/candidatos/candidato_29399027.jpg	6
94	DANIEL EDUARDO ZEA LOAIZA	PARTIDO DEL BUEN GOBIERNO	040110	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_42616011.jpg	5
95	JESUS MIGUEL RAMOS PARI	PARTIDO POLITICO PERU PRIMERO	040110	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_29548782.jpg	3
96	JOHAN BRANDOM CCARITA OLIVERA	PERU MODERNO	040110	#10B981	/storage/partidos/partido_peru_moderno.png	/storage/candidatos/candidato_46709192.jpg	7
98	ANA KARINA TACCA RAMIREZ	ACCION POPULAR	040111	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_43027338.jpg	1
99	JIMMY MANUEL SALAS ARENAS	AHORA NACION - AN	040111	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_40254985.jpg	3
101	MARIO FELIPE CARNERO TACO	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040111	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29447830.jpg	4
102	MANUEL EMILIO ACEVEDO GUILLEN	PARTIDO PAIS PARA TODOS	040111	#0056B3	/storage/partidos/partido_partido_pais_para_todos.png	/storage/candidatos/candidato_29429218.jpg	2
103	EMILIO GERONIMO HERRERA CORNEJO	AHORA NACION - AN	040113	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29468464.jpg	2
104	LEIBNIZ GEORJE CORNEJO SOTO	ALIANZA PARA EL PROGRESO	040113	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_44701245.jpg	1
106	EMILIANO PERCY MORALES CORNEJO	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040113	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29427090.jpg	5
107	ALVARO JULIO TICONA LAJO	PARTIDO DEMOCRATICO SOMOS PERU	040113	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_46175906.jpg	3
110	EDGAR FLORENCIO CORNEJO CHOQUECOTA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040114	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_30962183.jpg	1
111	LAURA ISABEL LOPEZ DAVALOS	AHORA NACION - AN	040115	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_40019431.jpg	4
112	JOSE ANTONIO PALOMINO AGUILAR	ALIANZA PARA EL PROGRESO	040115	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29429782.jpg	1
114	MILTON FAUSTO CORRALES CONDORI	PARTIDO PAIS PARA TODOS	040115	#0056B3	/storage/partidos/partido_partido_pais_para_todos.png	/storage/candidatos/candidato_46561069.jpg	3
115	ANGEL ROSENDO BAUTISTA RAMOS	PARTIDO POLITICO PERU PRIMERO	040115	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_29567191.jpg	2
116	AYRTON ANTHONY PORTUGAL PAUCA	ACCION POPULAR	040116	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_70360790.jpg	2
117	LESLIE NOELIA STEPHANY CASTILLO RODRIGUEZ	ALIANZA PARA EL PROGRESO	040116	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_44639711.jpg	1
119	SANTOS ALBERTO SALINAS VALENCIA	PROGRESEMOS	040116	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_29473155.jpg	3
120	RUSVEL PEPE SUCARI PRADO	AHORA NACION - AN	040117	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29542701.jpg	3
121	ALEXANDER BERENI ESPINOZA VALENCIA	ALIANZA PARA EL PROGRESO	040117	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29714272.jpg	1
122	GERALDINE LIUSKA ABARCA ALPACA	AREQUIPA, TRADICION Y FUTURO	040117	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_46313882.jpg	7
124	ALEX ARTURO GARCIA SALAZAR	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040117	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29480648.jpg	6
125	JESUS ALBERTO ANAYA ALCAHUAMAN	PARTIDO DEL BUEN GOBIERNO	040117	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_48568788.jpg	4
126	MARIO RUBEN CALDERON VALENCIA	PARTIDO DEMOCRATICO SOMOS PERU	040117	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_29665136.jpg	5
127	LANIA NINOSKA MIRANDA REINOSO	PARTIDO POLITICO PERU PRIMERO	040117	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_44809319.jpg	2
128	WILMER RAFAEL DIAZ RIQUELME	ACCION POPULAR	040118	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_29481389.jpg	2
129	JUAN MARCOS CHAVEZ CONDORI	AHORA NACION - AN	040118	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_72297776.jpg	5
130	ELARD JESUS VALENCIA OBANDO	ALIANZA PARA EL PROGRESO	040118	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_41297585.jpg	1
131	GELBER JOHN SUAREZ HUARCAYA	PARTIDO PATRIOTICO DEL PERU	040118	#7C3AED	/storage/partidos/partido_partido_patriotico_del_peru.png	/storage/candidatos/candidato_29580170.jpg	4
132	HILDA PAMELA SUCASACA MENESES	PARTIDO POLITICO PERU PRIMERO	040118	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_42974774.jpg	3
133	VICENTE LARICO MAMANI	ALIANZA PARA EL PROGRESO	040119	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_40502850.jpg	1
134	ORLINK CHOQUE VELASQUEZ	AREQUIPA, TRADICION Y FUTURO	040119	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_42661876.jpg	6
136	SOCRATES CHOQUE RODRIGUEZ	JUNTOS POR EL PERU	040119	#DC2626	/storage/partidos/partido_juntos_por_el_peru.png	/storage/candidatos/candidato_40157139.jpg	2
137	HELMUT SAUL QUISPE VILCA	PARTIDO DEMOCRATICO SOMOS PERU	040119	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_48578563.jpg	3
138	ESCOLASTICO QUISPE VALERO	PERU MODERNO	040119	#10B981	/storage/partidos/partido_peru_moderno.png	/storage/candidatos/candidato_29482921.jpg	4
140	CHRISS MILAGROS ROJAS PACHECO	AHORA NACION - AN	040120	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_43825025.jpg	1
142	LUIS ZELA ZELA	ALIANZA PARA EL PROGRESO	040121	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29595880.jpg	1
143	RUFO DEMETRIO MINAYA CONTRERAS	AREQUIPA, TRADICION Y FUTURO	040121	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29314353.jpg	2
144	JORGE LUIS JOVE MANRIQUE	ACCION POPULAR	040122	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_70414588.jpg	1
145	ALEXI GUILLERMO RIVERA CANO	AHORA NACION - AN	040122	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29498641.jpg	4
146	ROMULO FREDDY TERAN TRIGOSO SOTO	AREQUIPA, TRADICION Y FUTURO	040122	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29548785.jpg	8
147	VICTOR FLORENCIO MANCHEGO ORTEGA	AVANZA PAIS - PARTIDO DE INTEGRACION SOCIAL	040122	#0D9488	/storage/partidos/partido_avanza_pais_partido_de_integracion_social.png	/storage/candidatos/candidato_29421714.jpg	2
149	MARCELINO ROBERTO MUÑOZ PILA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040122	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29638641.jpg	7
150	DIEGO ARMANDO VILELA ALBÁN	PARTIDO POLITICO PERU PRIMERO	040122	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_46566540.jpg	3
151	ROMEL MIGUEL MEDINA ROMERO PAREDES	PODEMOS PERU	040122	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_29419186.jpg	5
153	ROGER LUIS CONDORI YUJRA	AHORA NACION - AN	040123	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_02417834.jpg	2
155	KELLY YURIDIA SANTILLANA ABRIL	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040123	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_42417245.jpg	3
156	HARDIN JOSE ABRIL VELARDE	PARTIDO POLITICO PERU PRIMERO	040123	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_08963756.jpg	1
157	ALFREDO LOZANO DIAZ	AHORA NACION - AN	040124	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_43507529.jpg	3
158	DARIO MANUEL CENTENO HUAMANI	ALIANZA ELECTORAL VENCEREMOS	040124	#8B5CF6	/storage/partidos/partido_alianza_electoral_venceremos.png	/storage/candidatos/candidato_71504475.jpg	4
160	LEON DANIEL HUARAYA MURILLO	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040124	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29515390.jpg	5
161	JORGE ALFREDO TAPIA NEIRA	PARTIDO POLITICO PERU PRIMERO	040124	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_29515241.jpg	1
162	JUAN HUGO CARRASCO CHUCHULLO	PARTIDO UNIDAD Y PAZ	040124	#D97706	/storage/partidos/partido_partido_unidad_y_paz.png	/storage/candidatos/candidato_29513757.jpg	2
163	FELIX HUAMAN QUIROZ	AHORA NACION - AN	040125	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_43594439.jpg	3
164	IVAN RENE CASTRO CALDERON	ALIANZA PARA EL PROGRESO	040125	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_41155692.jpg	1
165	JOSE MANUEL CALDERON HUAMANI	PARTIDO DEMOCRATICO SOMOS PERU	040125	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_71454068.jpg	5
166	SABINO JULIO MOSCOSO DEL CARPIO	PARTIDO POLITICO PERU PRIMERO	040125	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_29343537.jpg	2
167	JUAQUIN RICARDO MANTILLA BUSTAMANTE	PROGRESEMOS	040125	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_70840305.jpg	4
168	ROGER ANGHELO HUERTA PRESBITERO	AHORA NACION - AN	040126	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29657899.jpg	4
169	JOSE AUGUSTO ARCE PAREDES	ALIANZA PARA EL PROGRESO	040126	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_45839518.jpg	1
171	ORLANDO VENTURA MOLLO MEDINA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040126	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29326794.jpg	6
172	ALFONSO GRADOS ROSAS	PARTIDO DEL BUEN GOBIERNO	040126	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_41129846.jpg	5
173	CESAR EDUARDO PALMA GALINDO	PARTIDO POPULAR CRISTIANO - PPC	040126	#8B5CF6	/storage/partidos/partido_partido_popular_cristiano_ppc.png	/storage/candidatos/candidato_29634809.jpg	3
174	HECTOR HENRY ARISTA CORNEJO	RENOVACION POPULAR PERU	040126	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_29537466.jpg	2
175	ROBERTO GUZMAN CCUNO CHURA	ACCION POPULAR	040127	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_41082193.jpg	2
176	JAIME ALEXANDER TUEROS RAMOS	ALIANZA PARA EL PROGRESO	040127	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29603075.jpg	1
178	EDILFONSO EDY TORRES VALDIVIA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040127	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29530785.jpg	5
179	OMAR AUGUSTO PRADO POLANCO	PARTIDO DEMOCRATICO SOMOS PERU	040127	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_29724901.jpg	4
180	JUAN ARTURO QUEQUEZANA MARIN	PARTIDO POLITICO PERU PRIMERO	040127	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_29722450.jpg	3
181	MIGUEL ANGEL VILCA GUTIERREZ	AHORA NACION - AN	040128	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29553315.jpg	4
182	LUIS HARRY GOMEZ RAMIREZ	ALIANZA PARA EL PROGRESO	040128	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29635975.jpg	1
184	LUIS JAVIER FUENTES SALAS	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040128	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29532578.jpg	8
185	TEDDY AMNY CASTRO QUISPE	PARTIDO DEL BUEN GOBIERNO	040128	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_43763922.jpg	5
186	JULIO JOSE FUENTES BARRIGA	PARTIDO POLITICO PERU PRIMERO	040128	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_42616627.jpg	3
187	JULIO HIRVIN RAMOS MENDOZA	PERU MODERNO	040128	#10B981	/storage/partidos/partido_peru_moderno.png	/storage/candidatos/candidato_72292596.jpg	7
188	ANGELO ISIDRO BARRA HUAMANI	PODEMOS PERU	040128	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_43261358.jpg	6
189	HERRY MARTIN VARGAS ZEBALLOS	RENOVACION POPULAR PERU	040128	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_30858796.jpg	2
190	MARIA MERCEDES SILVA DONAYRE	ACCION POPULAR	040129	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_29425488.jpg	2
191	JIMMY RENZO OJEDA ARNICA	AHORA NACION - AN	040129	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_41365233.jpg	7
192	JORGE ARTURO ALONSO LAUREL PONCE	ALIANZA PARA EL PROGRESO	040129	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_44753363.jpg	1
193	DIEGO ALONSO ESCAPA TEJADA	AVANZA PAIS - PARTIDO DE INTEGRACION SOCIAL	040129	#0D9488	/storage/partidos/partido_avanza_pais_partido_de_integracion_social.png	/storage/candidatos/candidato_71532733.jpg	4
194	GUILLERMO PABLO REINOSO BARLETTI	BATALLA PERU	040129	#EC4899	/storage/partidos/partido_batalla_peru.png	/storage/candidatos/candidato_29592519.jpg	6
196	SHIRLEY ELBA ALCOCER PAUCA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040129	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29720029.jpg	10
197	KAZAN OCAMPO CARPIO	PARTIDO DEMOCRATICO SOMOS PERU	040129	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_29517156.jpg	8
198	RODOLFO CRISTIAN TEJADA ZANABRIA	PARTIDO POLITICO PERU PRIMERO	040129	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_41110266.jpg	5
199	CARLO RAMIRO ALIAGA NUÑEZ	RENOVACION POPULAR PERU	040129	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_80263406.jpg	3
201	MOISES MANUEL MARTIN PASTOR CACERES	ACCION POPULAR	040202	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_30410037.jpg	1
202	RUBEN KEYVI RIEGA CRUZ	AHORA NACION - AN	040202	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_42575915.jpg	2
203	CARLOS ENRIQUE PEÑA JULCA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040202	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_30410032.jpg	5
204	ELVIS WILBER MEDINA COPA	PARTIDO DEMOCRATICO SOMOS PERU	040202	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_29618138.jpg	4
205	JULIO CESAR MONTOYA MONROY	PROGRESEMOS	040202	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_30410231.jpg	3
206	OMAR TONNY MONTALVO MAYHUIRE	ACCION POPULAR	040203	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_30481804.jpg	1
207	ELMER FERNELI GARCIA FEBRES	AHORA NACION - AN	040203	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_30480172.jpg	3
209	LUIS MIGUEL LAVA FRANCO	PARTIDO POLITICO PERU PRIMERO	040203	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30488067.jpg	2
210	HUMBERTO CHAHUARA LLIMPI	ACCION POPULAR	040204	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_30413195.jpg	1
211	JAIME ISAIAS MAMANI ALVAREZ	AHORA NACION - AN	040204	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_30422980.jpg	2
212	EDWIN ROLANDO MEJIA TRONCOSO	PROGRESEMOS	040204	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_30413581.jpg	3
213	LUIS FERNANDO PIERR PRADO DAVILA	ACCION POPULAR	040205	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_43501894.jpg	1
214	NELSON RICARDO TITO EGUIA	AHORA NACION - AN	040205	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_45451807.jpg	4
215	HENRY CERVANTES MEDINA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040205	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_41915502.jpg	6
216	YENY KARINA RAMOS ALVAREZ	PARTIDO POLITICO PERU PRIMERO	040205	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30422762.jpg	3
217	OLIVER ABEL CHAVEZ CALDERON	RENOVACION POPULAR PERU	040205	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_10344881.jpg	2
219	CESAR AUGUSTO MAMANI GALINDO	AHORA NACION - AN	040206	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_30428264.jpg	1
220	MARILU JANETH GONZALES PORRAS	AREQUIPA, TRADICION Y FUTURO	040206	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_30417993.jpg	3
221	ALAN JESUS CARNERO LIRA	PROGRESEMOS	040206	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_42204448.jpg	2
222	HERNANDO HUGO ALARCON HUAMANI	AHORA NACION - AN	040207	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_30655452.jpg	2
223	WINDER VALDERRAMA JUAREZ	PARTIDO DEMOCRATICO SOMOS PERU	040207	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_40251474.jpg	4
224	ROGER ELOY AVILA RAMIREZ	PARTIDO POLITICO PERU PRIMERO	040207	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_46049715.jpg	1
225	CARLOS CABRERA RODRIGUEZ	PROGRESEMOS	040207	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_30409511.jpg	3
226	GIOMARO JASHUB RONDON PASTOR	ACCION POPULAR	040208	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_71650219.jpg	1
227	WILBER SERGIO JAHUIRA APAZA	AHORA NACION - AN	040208	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_42255066.jpg	4
228	JULIO PERCY CUTIPA MAMANI	AREQUIPA, TRADICION Y FUTURO	040208	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_01299391.jpg	8
229	GILBERT GRIMALDO CRUZ CAMPOS	PARTIDO DEMOCRATICO SOMOS PERU	040208	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30429328.jpg	6
230	BASILIO SOLIS HUAMANI	PARTIDO POLITICO PERU PRIMERO	040208	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30430702.jpg	3
231	ANTONIO MARIO MENESES MAMANI	PROGRESEMOS	040208	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_30420622.jpg	5
232	DUWAN VICENTE GUTIERREZ TACO	RENOVACION POPULAR PERU	040208	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_74913289.jpg	2
234	MIGUEL ANGEL FLORES BERNAHOLA	AHORA NACION - AN	040302	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_09436439.jpg	3
235	JOSE ESTEBAN CASALINO ROMERO	PARTIDO POLITICO PERU PRIMERO	040302	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_07238973.jpg	2
236	JOSE ANTONIO LUJAN MONGE	PODEMOS PERU	040302	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_06384790.jpg	5
237	DANTE ROGERS BERNAOLA SORIA	PROGRESEMOS	040302	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_10455322.jpg	4
238	BLANCA ELIZABETH MELGAR CARDENAS	RENOVACION POPULAR PERU	040302	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_42504409.jpg	1
239	VICTOR ARTURO GONZALES CANDIA	PARTIDO DEL BUEN GOBIERNO	040303	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_30487896.jpg	3
240	MAURO MILTON MEDINA URDAY	PARTIDO DEMOCRATICO SOMOS PERU	040303	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30488007.jpg	4
241	MILAGRITOS MELISSA HURTADO CAMPOS	PARTIDO POPULAR CRISTIANO - PPC	040303	#8B5CF6	/storage/partidos/partido_partido_popular_cristiano_ppc.png	/storage/candidatos/candidato_41667224.jpg	1
242	RAUL EVILTON NEYRA QUISPE	PROGRESEMOS	040303	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_43065330.jpg	2
243	ANDRES MARTINEZ MONTOYA	RENOVACION POPULAR PERU	040304	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_30486305.jpg	1
244	DANIEL EDWIN SAIME TORRES	ALIANZA PARA EL PROGRESO	040305	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_10646736.jpg	1
245	CRISTIAN YORDAN CASALINO HUAMANI	PARTIDO DEMOCRATICO SOMOS PERU	040305	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_45362988.jpg	3
246	ALAN CARLOS GONZALO VIZCARRA VALDIVIA	PROGRESEMOS	040305	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_41151448.jpg	2
248	ALEXANDER HERALDO VALDIVIEZO PERALTA	FE EN EL PERU	040306	#0056B3	/storage/partidos/partido_fe_en_el_peru.png	/storage/candidatos/candidato_10347978.jpg	1
249	MARITTSA FRANCO HUAMAN	PODEMOS PERU	040306	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_41471810.jpg	3
250	JULIO CESAR SAYAVERDE ROSPIGLIOSI	PROGRESEMOS	040306	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_73345506.jpg	2
251	VICTOR TOMAS PACHECO PUQUIO	ACCION POPULAR	040307	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_30493608.jpg	1
252	WILLI YAMES ARANGUREN DE LA TORRE	PODEMOS PERU	040307	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_22098647.jpg	4
253	MARIA TERESA LOUANA RODRIGUEZ MITMA	PROGRESEMOS	040307	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_76272469.jpg	3
254	JOSE LUIS LOPEZ LINARES	RENOVACION POPULAR PERU	040307	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_30494167.jpg	2
255	GERMAN CALLE CHIRINOS	AHORA NACION - AN	040308	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_70614318.jpg	2
256	CARMEN ISABEL MARTINA GARCIA CAUTTER	FE EN EL PERU	040308	#0056B3	/storage/partidos/partido_fe_en_el_peru.png	/storage/candidatos/candidato_06735769.jpg	1
258	OSCAR JUSTINIANO DURAN MITMA	PARTIDO MORADO	040308	#0056B3	/storage/partidos/partido_partido_morado.png	/storage/candidatos/candidato_47203496.jpg	5
259	RUDI ABAD ARAUJO TRELLES	PODEMOS PERU	040308	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_42669025.jpg	4
260	JOSE DANIEL SEBASTIAN LEON GAONA	PROGRESEMOS	040308	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_70554170.jpg	3
261	IVAN CIRILO ARENAS CCANAHUIRI	FE EN EL PERU	040309	#0056B3	/storage/partidos/partido_fe_en_el_peru.png	/storage/candidatos/candidato_45934139.jpg	1
262	FREDY CLEMENTE BENAVENTE ARANGURE	PARTIDO DEMOCRATICO SOMOS PERU	040309	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30487935.jpg	3
263	DAVID GERARDO CUTTI APAZA	PODEMOS PERU	040309	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_40374931.jpg	4
264	WALTER NICANOR HUAMANI BAUTISTA	PROGRESEMOS	040309	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_24804309.jpg	2
265	KAREN LIZBETH MODESTA MORON SIFUENTES	ALIANZA PARA EL PROGRESO	040310	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_10589069.jpg	1
266	ROGER YOEL CATAÑO CHACON	PARTIDO DEMOCRATICO SOMOS PERU	040310	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_42421794.jpg	4
267	MARCOS RUBEN CORONADO NAVARRO	PARTIDO POLITICO PERU PRIMERO	040310	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30497728.jpg	2
268	GUISELA MEDALID PADILLA ROJAS	PROGRESEMOS	040310	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_41042389.jpg	3
269	ALDO WINSTON ALVAREZ LIMA	ALIANZA PARA EL PROGRESO	040311	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_41928103.jpg	1
270	SEGUNDO TTITO CHOQUEVILCA	PROGRESEMOS	040311	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_22086456.jpg	3
271	VICTOR RAUL MEDINA QUISPE	RENOVACION POPULAR PERU	040311	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_30498849.jpg	2
272	JOSE ANTONIO BARRIENTOS CARPIO	PODEMOS PERU	040312	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_42006198.jpg	1
273	NELSON RAMOS CONDORI	PARTIDO MORADO	040313	#0056B3	/storage/partidos/partido_partido_morado.png	/storage/candidatos/candidato_42082378.jpg	4
274	ITALO FELIPE MALDONADO LOPEZ	PARTIDO POLITICO PERU PRIMERO	040313	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_43832573.jpg	1
275	MIGUEL ANGEL CARCAMO GALVAN	PODEMOS PERU	040313	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_30501465.jpg	3
276	MILMA YOLANDA ATOXSA NINA	PROGRESEMOS	040313	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_10000982.jpg	2
277	HUGO EDGAR LAZARTE RAMOS	AHORA NACION - AN	040402	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_42196421.jpg	2
278	KARIN ROSARIO TACO HUAMANI	AREQUIPA, TRADICION Y FUTURO	040402	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_74071886.jpg	3
279	JESUS JUAN PURGUAYA SANCHEZ	PARTIDO POLITICO PERU PRIMERO	040402	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30564983.jpg	1
280	HUBER JUAN BEGAZO GUTIERREZ	ALIANZA PARA EL PROGRESO	040403	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_30582755.jpg	1
281	JAINOR CONDO RIVEROS	AREQUIPA, TRADICION Y FUTURO	040403	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_41223616.jpg	3
283	MICHAEL ERIC VERA VILCA	PARTIDO POLITICO PERU PRIMERO	040403	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_42362837.jpg	2
284	EDWIN USBALDO HUAYHUA LOZADA	AREQUIPA, TRADICION Y FUTURO	040404	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_80355700.jpg	2
286	MARIO MAGDALENO ALCASIHUINCHA LAYME	PARTIDO POLITICO PERU PRIMERO	040404	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30567375.jpg	1
287	JUAN CARLOS YANCAPALLO CCAMA	AREQUIPA, TRADICION Y FUTURO	040405	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_46393007.jpg	2
288	RICHARD DENIS QUISPE QUILLUYA	PARTIDO POLITICO PERU PRIMERO	040405	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_40217144.jpg	1
289	ROOSEVELT TRIFONIO ARAGON CHURA	AREQUIPA, TRADICION Y FUTURO	040406	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_43629085.jpg	3
290	YURY ANDRE DE LA CRUZ QUIQUEA	PARTIDO DEMOCRATICO SOMOS PERU	040406	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_29646632.jpg	2
291	JESUS EUGENIO ARAGON PIZARRO	PARTIDO POLITICO PERU PRIMERO	040406	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_29540597.jpg	1
292	ANA MILAGROS FERNANDEZ SALAS	AHORA NACION - AN	040407	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29539419.jpg	2
293	BENITO EDMUNDO AMBRONCIO DE LA CRUZ	AREQUIPA, TRADICION Y FUTURO	040407	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_30571606.jpg	3
295	JONY MAMPARI CARDENAS URQUIZO	PARTIDO POLITICO PERU PRIMERO	040407	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30571182.jpg	1
296	EDGAR AURELIO YAURI MATHEY	BATALLA PERU	040408	#EC4899	/storage/partidos/partido_batalla_peru.png	/storage/candidatos/candidato_29303896.jpg	2
297	FLAVIO REYNALDO TACO SILVA	PARTIDO POLITICO PERU PRIMERO	040408	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30572811.jpg	1
298	SALOME KENIDE HUAMANI ANCO	PERU MODERNO	040408	#10B981	/storage/partidos/partido_peru_moderno.png	/storage/candidatos/candidato_29497406.jpg	4
299	RONY PACHAO CONDORI	PROGRESEMOS	040408	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_40815220.jpg	3
300	JUAN CARLOS LLERENA HUAMANI	AREQUIPA, TRADICION Y FUTURO	040409	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29419055.jpg	3
302	AURELIO NICOLAS VILCA GIRALDO	PARTIDO POLITICO PERU PRIMERO	040409	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30585896.jpg	1
303	CIRO CIRILO PINTO CONDORI	PROGRESEMOS	040409	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_30579675.jpg	2
304	VICENTE JUSTINO CARCAMO HUAMANI	AHORA NACION - AN	040410	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29342441.jpg	2
305	LEONEL ANDRES HUAMANI TACO	AREQUIPA, TRADICION Y FUTURO	040410	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_47182606.jpg	3
306	PAOLA ROCIO LAZO REVILLA	PARTIDO POLITICO PERU PRIMERO	040410	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_29561948.jpg	1
307	AMARILDO MARIO ALVAREZ IBARCENA	PARTIDO POLITICO PERU PRIMERO	040411	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_29341724.jpg	1
308	EDAR JAHAZIEL MENDOZA SOTO	PROGRESEMOS	040411	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_76193448.jpg	2
309	GUSTAVO RAMIRO LOPEZ DIAZ	ALIANZA PARA EL PROGRESO	040412	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_80161039.jpg	1
310	MOISES ALEJANDRO COPA SANCHEZ	AREQUIPA, TRADICION Y FUTURO	040412	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29329250.jpg	2
312	JULIO CESAR MARQUEZ QUISPE	ACCION POPULAR	040413	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_29642666.jpg	2
313	MANUEL FIDEL ALPACA POSTIGO	AHORA NACION - AN	040413	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_30581024.jpg	4
314	EVER JEANPIER ALI LIMA	ALIANZA PARA EL PROGRESO	040413	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_61039645.jpg	1
315	MARTHA SELIA RUELAS CONDORI	AREQUIPA, TRADICION Y FUTURO	040413	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29633170.jpg	6
317	MIGUEL ABDON MARTINEZ FERNANDEZ	PARTIDO POLITICO PERU PRIMERO	040413	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30580891.jpg	3
318	LUIS MIGUEL ESPEJO AYALA	PROGRESEMOS	040413	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_43498123.jpg	5
319	ALEX LUIS PUMA RAMOS	AHORA NACION - AN	040414	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_40228203.jpg	3
320	CLAUDIO FRANCISCO DIAZ FLORES	ALIANZA PARA EL PROGRESO	040414	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_06589913.jpg	1
321	JOSE ISAIAS VERA ALVAREZ	PARTIDO POLITICO PERU PRIMERO	040414	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_29678204.jpg	2
457	DALMER RODOLFO ZANABRIA LUDEÑA	AHORA NACION - AN	040805	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_30941609.jpg	3
322	RICHARD INOCENTE GALLEGOS HUERTAS	ALIANZA PARA EL PROGRESO	040502	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29548339.jpg	1
323	MARIO ALVARO OSCA CUSIHUAMAN	AREQUIPA, TRADICION Y FUTURO	040502	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_40674419.jpg	3
324	JOSE BENITO MERMA CAHUA	PARTIDO DEMOCRATICO SOMOS PERU	040502	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_43004562.jpg	2
325	REY ESTEBAN CASTRO TINTA	AHORA NACION - AN	040503	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_00985380.jpg	1
326	PEDRO ISAIAS GONZALES PASTOR	AREQUIPA, TRADICION Y FUTURO	040503	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29468683.jpg	3
328	GEOFFREY CHRISTIAN CAYANI BENAVIDES	PARTIDO DEMOCRATICO SOMOS PERU	040503	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_42035175.jpg	2
329	SUSY HAYDIT TACO PANIBRA	ALIANZA PARA EL PROGRESO	040504	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_43170581.jpg	1
330	FLORENCIO JOSUE VALDIVIA MAMANI	AREQUIPA, TRADICION Y FUTURO	040504	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_30647931.jpg	3
332	MAXIMIANO FLORENCIO HUAYTA GONZALES	PARTIDO POLITICO PERU PRIMERO	040504	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30647755.jpg	2
333	ELOY HUGO POCORI CHOQUEHUANCA	AHORA NACION - AN	040505	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_41672728.jpg	2
334	CECILIO MAURO YUCRA SOTO	AREQUIPA, TRADICION Y FUTURO	040505	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_43897007.jpg	4
335	ANIBAL ROSAS DELGADO	PARTIDO DEMOCRATICO SOMOS PERU	040505	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_41506667.jpg	3
336	BENANCIO CONDO CHIPA	PARTIDO POLITICO PERU PRIMERO	040505	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_72288488.jpg	1
337	PATRICIO OVISPO MEJIA CHOQUE	AHORA NACION - AN	040506	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_30651766.jpg	1
339	NESTOR SERAFIN MAMANI VILLCA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040506	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_42458588.jpg	3
340	JUAN BERNAL MALCOHUACCHA	PARTIDO DEMOCRATICO SOMOS PERU	040506	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_40457592.jpg	2
341	FELIPE GETULIO HUAIRA SOTO	AHORA NACION - AN	040507	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_44047318.jpg	2
342	GLENN JIMMY BEGAZO BEJARANO	ALIANZA PARA EL PROGRESO	040507	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_43931914.jpg	1
343	LUIS FERNANDO ALVAREZ ALVAREZ	AREQUIPA, TRADICION Y FUTURO	040507	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_71598700.jpg	4
345	MAGNO FERNANDO GAMA CHECA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040507	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_46809829.jpg	3
346	JAVIER WILFREDO VILCA NEIRA	AHORA NACION - AN	040508	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29643206.jpg	1
347	WILBERT ARIEL SEÑA HUARACHA	AREQUIPA, TRADICION Y FUTURO	040508	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_42663291.jpg	4
348	VIRGILIO DAVID VILCA TEVES	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040508	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_40337152.jpg	3
349	ESTANISLAO PEDRO VILCA NUÑEZ	PARTIDO DEMOCRATICO SOMOS PERU	040508	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_43340430.jpg	2
350	ABEL LUCIO SAICO FLORES	AHORA NACION - AN	040509	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_42121661.jpg	1
352	EDGAR AGUSTIN PONCE CHISE	PARTIDO DEMOCRATICO SOMOS PERU	040509	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30656026.jpg	2
353	ROMULO TEODORO SUYCO PANTA	PARTIDO DEMOCRATICO SOMOS PERU	040510	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_80322209.jpg	1
354	PAULINO WILFREDO VILCA VILCA	AHORA NACION - AN	040511	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29333809.jpg	3
355	CARLOS ALFREDO MAYCA HUAMANI	AREQUIPA, TRADICION Y FUTURO	040511	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_30670436.jpg	5
356	JULIO CESAR CHARAGUA FLORES	JUNTOS POR EL PERU	040511	#DC2626	/storage/partidos/partido_juntos_por_el_peru.png	/storage/candidatos/candidato_80386660.jpg	1
357	JUAN BRAULIO ZAPANA MORALES	PARTIDO DEMOCRATICO SOMOS PERU	040511	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_71079404.jpg	4
358	FELIX HERNAN CHOQUE JACOBO	PARTIDO POLITICO PERU PRIMERO	040511	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_15989879.jpg	2
359	EDGARDO ASIS HUARCAYA RAMOS	AHORA NACION - AN	040512	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_41705207.jpg	2
360	HUGO EULOGIO APAZA NINA	ALIANZA PARA EL PROGRESO	040512	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29328246.jpg	1
361	SIXTO INDALECIO ROSAS PARI	AREQUIPA, TRADICION Y FUTURO	040512	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29576545.jpg	4
363	ELIAS DANTE COAGUILA QUISPE	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040512	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_41778884.jpg	3
364	GUILLERMO NICOMEDES GARCIA HUANQUI	ALIANZA PARA EL PROGRESO	040513	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_42095073.jpg	1
365	DEMETRIO SENÓN FIGUEROA TEJADA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040513	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_30660581.jpg	3
366	FABRICIO WILDER HUANQUI CAYANI	PARTIDO DEMOCRATICO SOMOS PERU	040513	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_48310515.jpg	2
367	MAXIMO EDGARD CHOQUE ARHUIRE	PARTIDO DEMOCRATICO SOMOS PERU	040514	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30661941.jpg	1
368	ALDO FERNANDO MAMANI MAMANI	AHORA NACION - AN	040515	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_71077373.jpg	2
369	KEVYN ROLANDO MAMANI CHULLO	PARTIDO POLITICO NACIONAL PERU LIBRE	040515	#10B981	/storage/partidos/partido_partido_politico_nacional_peru_libre.png	/storage/candidatos/candidato_46886821.jpg	1
370	VIRGILIO FREDY RIVEROS SALAS	ALIANZA PARA EL PROGRESO	040516	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_25784195.jpg	1
371	ELMER FIDENCIO LLICA HUAMANI	AREQUIPA, TRADICION Y FUTURO	040516	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29666596.jpg	3
373	ENRIQUE TEJADA HUAMANI	PARTIDO DEMOCRATICO SOMOS PERU	040516	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_29669201.jpg	2
374	VITO HUANCA USCAMAYTA	AHORA NACION - AN	040517	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_42428056.jpg	3
375	NICO EDGAR MAQUE COLQUE	ALIANZA PARA EL PROGRESO	040517	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_30642531.jpg	1
376	WINDER ANCONEIRA MAQUE	PARTIDO POLITICO PERU PRIMERO	040517	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_41417235.jpg	2
377	WILBER YANQUE CALLA	AHORA NACION - AN	040518	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_42683854.jpg	2
378	MILIANA CCAPIRA MAQUE	ALIANZA PARA EL PROGRESO	040518	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_42327430.jpg	1
379	ERNESTO QUISPE MAMANI	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040518	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_40867360.jpg	4
380	PIO CUTIPA LLALLACACHI	PARTIDO DEMOCRATICO SOMOS PERU	040518	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30666605.jpg	3
381	FREDY ERNAN QUISPE YDME	AHORA NACION - AN	040519	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_41737585.jpg	1
382	BENIGNO DELFIN JALISTO NINATAYPE	PARTIDO DEL BUEN GOBIERNO	040519	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_30668122.jpg	2
383	MOISES ESTEBAN QUISPE QUISPE	PARTIDO DEMOCRATICO SOMOS PERU	040519	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_42353634.jpg	3
384	TONY ALDRYN DIAZ RIQUELME	ACCION POPULAR	040520	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_29481386.jpg	4
385	GLADYS SABINA CONDORI HUAMAN	AHORA NACION - AN	040520	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29516747.jpg	6
386	VICTOR MANUEL QUISCA YUCRA	ALIANZA ELECTORAL VENCEREMOS	040520	#8B5CF6	/storage/partidos/partido_alianza_electoral_venceremos.png	/storage/candidatos/candidato_70579413.jpg	10
387	FELIPE ORLANDO LUQUE VILLANUEVA	AREQUIPA, TRADICION Y FUTURO	040520	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_43588194.jpg	13
389	OSWALDO MAYTA QUISPE	JUNTOS POR EL PERU	040520	#DC2626	/storage/partidos/partido_juntos_por_el_peru.png	/storage/candidatos/candidato_02147160.jpg	2
390	RENEE DIONICIO CACERES FALLA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040520	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29284196.jpg	12
391	ANGEL DAVID CHARCA SOLIS	PARTIDO DEL BUEN GOBIERNO	040520	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_29343769.jpg	7
392	JAIME REYNALDO HUARCA USCA	PARTIDO DEMOCRATICO SOMOS PERU	040520	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_42287917.jpg	8
393	JUAN OCTAVIO ORTIZ QUICARA	PARTIDO FRENTE DE LA ESPERANZA 2021	040520	#DC2626	/storage/partidos/partido_partido_frente_de_la_esperanza_2021.png	/storage/candidatos/candidato_29593802.jpg	3
394	JAIME WILLIANS HUAMANI URACCAHUA	PARTIDO POLITICO PERU PRIMERO	040520	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_46021451.jpg	5
395	ANA MARIA PAUCAR HUAMANI	PODEMOS PERU	040520	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_30564119.jpg	9
396	JORGE ALFONSO VALENCIA PAREDES	SALVEMOS AL PERU	040520	#8B5CF6	/storage/partidos/partido_salvemos_al_peru.png	/storage/candidatos/candidato_40987126.jpg	1
398	CARLOS ALBERTO ALARCON ESCOBEDO	AHORA NACION - AN	040602	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_30763140.jpg	2
399	FREDDY RONAL CERVANTES DIAZ	AREQUIPA, TRADICION Y FUTURO	040602	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_30763223.jpg	4
401	JUAN CARLOS MARCAPURA LOPEZ	PARTIDO DEMOCRATICO SOMOS PERU	040602	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_72297969.jpg	3
402	GORKY ROSA EDGARDO CARRAZCO CASTRO	PARTIDO POLITICO PERU PRIMERO	040602	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30763124.jpg	1
403	PEDRO SERAPIO CONDORI HUAMANI	AHORA NACION - AN	040603	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_24803784.jpg	2
404	ROMALDO CCALLO CONDORI	ALIANZA PARA EL PROGRESO	040603	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_30765023.jpg	1
405	JOSE PEPE QUISPE HUAMANI	PARTIDO DEMOCRATICO SOMOS PERU	040603	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_45810891.jpg	3
406	ROBERT PABLO CASTRO CUEVA	PARTIDO DEMOCRATICO SOMOS PERU	040604	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_29625616.jpg	1
407	PEDRO VICTOR GONZALES LLERENA	AHORA NACION - AN	040605	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_07149120.jpg	1
408	LUIS ANTONIO VARGAS CHOQUE	AREQUIPA, TRADICION Y FUTURO	040605	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29614764.jpg	3
410	GUSTAVO ADOLFO URRUTIA PALOMINO	PARTIDO DEMOCRATICO SOMOS PERU	040605	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_76388818.jpg	2
411	JULIO CESAR CHECCYA FLORES	AHORA NACION - AN	040606	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_44518872.jpg	2
413	WILLAM CASTRO AZA	PARTIDO DEMOCRATICO SOMOS PERU	040606	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_41851620.jpg	3
414	PEDRO BERTHI HUASHUAYO CHAVEZ	PARTIDO POLITICO PERU PRIMERO	040606	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30776714.jpg	1
415	MIGUEL VICTOR MEDINA SORIA	AHORA NACION - AN	040607	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29726378.jpg	1
417	FERMIN HIPOLITO LLERENA CARPIO	PARTIDO DEMOCRATICO SOMOS PERU	040607	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30760547.jpg	2
418	VALENTIN ADOLFO HUAMANI HUAMANI	AHORA NACION - AN	040608	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_42275235.jpg	3
419	ANDRES JEMMIM CHAUCAYANQUI CARPIO	ALIANZA PARA EL PROGRESO	040608	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_30770714.jpg	1
420	ASENCIO JOAQUIN NEYRA FLORES	AREQUIPA, TRADICION Y FUTURO	040608	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_30421213.jpg	4
421	LEONEL HUAMANI CARPIO	COOPERACION, VERDAD Y HONRADEZ	040608	#D97706	/storage/partidos/partido_cooperacion_verdad_y_honradez.png	/storage/candidatos/candidato_29728836.jpg	2
423	JHONNY RAUL SOLIS GUTIERREZ	ACCION POPULAR	040702	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_30843391.jpg	2
424	AMPARO ARLI GALLEGOS HILASACA	AHORA NACION - AN	040702	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_40441790.jpg	4
425	JOAO ABEL SUAREZ APAZA	ALIANZA PARA EL PROGRESO	040702	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_46995902.jpg	1
426	FELIX FERNANDO SALAZAR RAMIREZ	FUERZA AREQUIPEÑA	040702	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29379481.jpg	8
427	ELMER FELIPE SANCHEZ FLORES	PARTIDO DEL BUEN GOBIERNO	040702	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_30843497.jpg	5
428	HILARIO JULIO CORNEJO REYNOSO	PARTIDO DEMOCRATICO SOMOS PERU	040702	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30840225.jpg	6
429	CELSO OCTAVIO CARI MAMANI	PARTIDO POLITICO PERU PRIMERO	040702	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30842833.jpg	3
430	HELAR HUGO VALENCIA JUAREZ	YO AREQUIPA	040702	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_29290153.jpg	7
431	JOSE IGNACIO PAREDES SANCHEZ	ACCION POPULAR	040703	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_30844081.jpg	2
432	ROLANDO PARIAPAZA MAMANI	ALIANZA PARA EL PROGRESO	040703	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_30846622.jpg	1
433	PEDRO LUCIO CALLE MAMANI	PARTIDO DEMOCRATA VERDE	040703	#DC2626	/storage/partidos/partido_partido_democrata_verde.png	/storage/candidatos/candidato_30846556.jpg	3
434	FRANCO VLADIMIR SALAS CONDORI	PARTIDO DEMOCRATICO SOMOS PERU	040703	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_43605311.jpg	4
436	GERALD ENRIQUE PALOMINO POMIER	ACCION POPULAR	040704	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_40344251.jpg	2
437	JERY PAOLA CANELO PACHECO	AHORA NACION - AN	040704	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_44955464.jpg	5
439	DEMETRIO ZAPANA DEZA	JUNTOS POR EL PERU	040704	#DC2626	/storage/partidos/partido_juntos_por_el_peru.png	/storage/candidatos/candidato_29579967.jpg	1
440	FERNANDO BRUCE ZUÑIGA CHAVEZ	PARTIDO POLITICO PERU PRIMERO	040704	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30834137.jpg	4
441	RICARDO JEAN PIERRE CANAZA MAMANI	RENOVACION POPULAR PERU	040704	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_47239660.jpg	3
443	JUANA ROSA ARENAS ASPILCUETA DE MEZA	ACCION POPULAR	040705	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_30850035.jpg	2
444	JUAN ALFREDO ARENAS DELGADO	ALIANZA PARA EL PROGRESO	040705	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_43811121.jpg	1
445	JUAN RAUL RODRIGUEZ TORRES	ACCION POPULAR	040706	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_29606869.jpg	2
446	OMAR MAGDIEL TALAVERA MENDOZA	AHORA NACION - AN	040706	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_80448207.jpg	4
447	GUSTAVO SENEN VELASQUEZ GALLEGOS	ALIANZA PARA EL PROGRESO	040706	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29612624.jpg	1
448	ROMY ANTONIA SANCHEZ DEL CARPIO	PARTIDO POLITICO PERU PRIMERO	040706	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_43305022.jpg	3
450	JULIO CARMELO TITO QUISPE	PARTIDO DEMOCRATICO SOMOS PERU	040802	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_44084997.jpg	2
451	JORDY LUIS MANRIQUE LOAYZA	PARTIDO POLITICO PERU PRIMERO	040802	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_70359949.jpg	1
452	MOISES RICARDO QUISPE HEREDIA	PARTIDO DEMOCRATICO SOMOS PERU	040803	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30945129.jpg	2
453	WILSON FRANCO MEDINA QUISPE	PARTIDO POLITICO PERU PRIMERO	040803	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_47826496.jpg	1
454	SILVIO CARHUAS PUMA	AHORA NACION - AN	040804	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_30946627.jpg	2
455	LUIS MIGUEL PUMA SIERRA	PARTIDO DEMOCRATICO SOMOS PERU	040804	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_48413813.jpg	3
456	VITALIANO GONZALES LLAMOCA	PARTIDO POLITICO PERU PRIMERO	040804	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_40718586.jpg	1
458	CARLOS MARTIN CHIRINOS ROMERO	ALIANZA PARA EL PROGRESO	040805	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_30953621.jpg	1
459	FELIX VIDAL PAUCARIMA PANIURA	PARTIDO DEMOCRATICO SOMOS PERU	040805	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_80448027.jpg	4
460	WILSON DANIEL TICLLA USCATA	PARTIDO POLITICO PERU PRIMERO	040805	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_48157355.jpg	2
461	DENIS JAVIER QUISPE AYMARA	AHORA NACION - AN	040806	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_41550257.jpg	2
462	CORPUS QUISPE MEDINA	AREQUIPA, TRADICION Y FUTURO	040806	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_43348705.jpg	5
463	ADAN HEREDIA BUIZA	PARTIDO DEMOCRATICO SOMOS PERU	040806	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30950658.jpg	3
464	CELSO VICTOR QUILLE TOTOCAYO	PARTIDO POPULAR CRISTIANO - PPC	040806	#8B5CF6	/storage/partidos/partido_partido_popular_cristiano_ppc.png	/storage/candidatos/candidato_30950128.jpg	1
465	RICHARD PACHAU QUILLE	PODEMOS PERU	040806	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_45737488.jpg	4
466	CIRO CERVANTES CANALES	PARTIDO DEMOCRATICO SOMOS PERU	040807	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_40776494.jpg	2
467	NOE RONALD PULCHA MEDINA	PARTIDO POLITICO PERU PRIMERO	040807	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_29575074.jpg	1
468	CASIMIRO CRECENCIO VARGAS ALVARADO	ALIANZA PARA EL PROGRESO	040808	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_29294444.jpg	1
469	JUAN CANCIO DAVALOS DAVALOS	PARTIDO DEMOCRATICO SOMOS PERU	040808	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_10033461.jpg	3
470	NILTHON VERA MEDINA	PARTIDO POLITICO PERU PRIMERO	040808	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_70395217.jpg	2
471	MARCOS ZACARIAS BARRIGA ACAPANA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040809	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_44224568.jpg	2
472	CESAR JORGE LLAMOCA BARRIGA	PARTIDO POLITICO PERU PRIMERO	040809	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_46614724.jpg	1
473	FRANCISCO PAUL HINOJOSA SOLIS	ACCION POPULAR	040810	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_30953684.jpg	1
474	CRISTIAN WINSTON ZEA HINOJOSA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040810	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_73079279.jpg	2
475	ROXANA MARISOL ANCASI GARCIA	AHORA NACION - AN	040811	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_42601831.jpg	3
476	FRAXIDES WILE ESPINAL MONTES	ALIANZA PARA EL PROGRESO	040811	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_30941091.jpg	1
477	AMADOR SILVESTRE ESPINAL HUAMANI	AREQUIPA, TRADICION Y FUTURO	040811	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_16135020.jpg	4
478	JOSE OMAR FLORES DUEÑAS	PARTIDO POLITICO PERU PRIMERO	040811	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_43994752.jpg	2
479	JAVIER RICHARD PALMA ARREDONDO	FUERZA AREQUIPEÑA	040103	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29569534.jpg	9
480	SATURNINO ALFREDO ALEJANDRO COYA	FUERZA AREQUIPEÑA	040104	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29728398.jpg	11
481	LUZ MARINA ZEBALLOS PATRON	YO AREQUIPA	040104	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_29410321.jpg	9
482	AUGUSTO GERMAN FUENTES PERALTILLA	FUERZA AREQUIPEÑA	040105	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_10753071.jpg	11
483	LISSET LETICIA ORE TAIPE	YO AREQUIPA	040105	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_70020698.jpg	8
484	PETER HUMBERTO BENAVENTE RAMOS	FUERZA AREQUIPEÑA	040106	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29285875.jpg	10
485	OSCAR JORGE CHANCOLLA MAMANI	YO AREQUIPA	040106	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_42462307.jpg	8
486	JORGE MUÑOZ VALLEJOS	FUERZA AREQUIPEÑA	040107	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_40844621.jpg	9
487	ARISTIDES CUADROS AYQUI	FUERZA AREQUIPEÑA	040108	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30863845.jpg	7
488	CASCELY WILLIAMS CALIZAYA MAMANI	FUERZA AREQUIPEÑA	040109	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29662205.jpg	7
489	HIPOLITO ARTURO VALDERRAMA CHAVEZ	FUERZA AREQUIPEÑA	040110	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29390073.jpg	10
490	ALVARO MIGUEL MACEDO CORDOVA	YO AREQUIPA	040110	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_70937837.jpg	8
491	LUIS ANGEL ORTIZ ZEGARRA	FUERZA AREQUIPEÑA	040111	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_47716954.jpg	5
492	ANTONIO ZAVALA VEGA	FUERZA AREQUIPEÑA	040112	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29543719.jpg	13
493	EDGAR YANKA CORNEJO CASTILLO	FUERZA AREQUIPEÑA	040113	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29712235.jpg	6
494	RAQUEL BRENDA VARGAS COAGUILA	YO AREQUIPA	040113	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_44462065.jpg	4
495	ANDRES HIPOLITO HUAHUACONDO HUASHUAYO	FUERZA AREQUIPEÑA	040114	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29501136.jpg	2
496	RICHARD EDGARD CALVO RAMOS	FUERZA AREQUIPEÑA	040115	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29611992.jpg	5
497	ABIGAIL PAMELA DEL CARPIO MARQUEZ	FUERZA AREQUIPEÑA	040116	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_47091231.jpg	4
498	DIEGO HERNAN SANCHEZ DELGADO	FUERZA AREQUIPEÑA	040117	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_71257793.jpg	8
499	FABIAN QUISPE MOLLAPAZA	FUERZA AREQUIPEÑA	040119	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29482953.jpg	7
500	LEONELA ROXANA CHOQUE CHOQUE	YO AREQUIPA	040119	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_72125144.jpg	5
501	RENZO GORDILLO PINTO	FUERZA AREQUIPEÑA	040120	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_44022246.jpg	2
502	RENEE ENCISO MIRANDA	FUERZA AREQUIPEÑA	040122	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_80197503.jpg	9
503	BEBETO FIDEL CASTRO ENDARA	YO AREQUIPA	040122	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_46996887.jpg	6
504	MIGUEL ANGEL CUADROS PAREDES	FUERZA AREQUIPEÑA	040123	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29505793.jpg	4
505	YACKELIN DIANA ROJAS VELASQUEZ	FUERZA AREQUIPEÑA	040124	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_42887423.jpg	6
506	ELVIS DAVID DELGADO BACIGALUPI	FUERZA AREQUIPEÑA	040126	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29521456.jpg	7
507	JOSE LUIS LUNA ZAPANA	FUERZA AREQUIPEÑA	040127	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_42045175.jpg	6
508	JULIO HUGO MENDOZA CHOQUEHUANCA	FUERZA AREQUIPEÑA	040128	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_42477663.jpg	9
509	RONALD PABLO IBAÑEZ BARREDA	FUERZA AREQUIPEÑA	040129	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29255700.jpg	11
510	WILBER DAVID CASTRO ARANCIBIA	YO AREQUIPA	040129	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_29425174.jpg	9
511	HELARF PORTOCARRERO CARNERO	FUERZA AREQUIPEÑA	040203	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30410762.jpg	4
512	HERMAN ALFREDO RAFAEL CANO	YO AREQUIPA	040205	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_30406276.jpg	5
513	DAVID JUAN SANCHEZ FLORES	YO AREQUIPA	040208	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_41473239.jpg	7
514	ARON ABEL MALDONADO MONTOYA	YO AREQUIPA	040305	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_30500566.jpg	4
515	GREGORIO TACO PAUCARA	FUERZA AREQUIPEÑA	040308	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_02164575.jpg	6
516	ANGELA EUFEMIA OVIEDO CACERES	FUERZA AREQUIPEÑA	040403	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_45442513.jpg	4
517	ALFONSO ESTEBAN LLAMOCA NINA	FUERZA AREQUIPEÑA	040404	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_09690779.jpg	3
518	JORGE ANTONIO MARTINEZ PALACIOS	FUERZA AREQUIPEÑA	040407	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30571838.jpg	4
519	FLORENCIO PATIÑO GIRALDO	FUERZA AREQUIPEÑA	040409	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_41451304.jpg	4
520	FREDY LEONIDAS LLAMOSAS AMEZQUITA	FUERZA AREQUIPEÑA	040412	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30579234.jpg	3
521	MANUEL INDALECIO LLERENA VELARDE	FUERZA AREQUIPEÑA	040413	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30582555.jpg	7
522	HENRY JULIO JIMENEZ BARRIOS	FUERZA AREQUIPEÑA	040503	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30645634.jpg	4
523	LUIS RICHARD CACERES USCAMAYTA	FUERZA AREQUIPEÑA	040504	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30663128.jpg	4
524	MANUEL MEJIA CHOQUE	FUERZA AREQUIPEÑA	040506	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30651776.jpg	4
525	DAVID NOE DE LA CRUZ ARCE	FUERZA AREQUIPEÑA	040507	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_44025958.jpg	5
526	JOSE LUIS AYAQUE HEREDIA	FUERZA AREQUIPEÑA	040509	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_41365338.jpg	3
527	CESAR AUGUSTO CHINO ANCO	FUERZA AREQUIPEÑA	040512	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29631624.jpg	5
528	ROBERT CLAUDIO ABRIL TEJADA	FUERZA AREQUIPEÑA	040516	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_42012105.jpg	4
529	VICTOR FERNANDO HUARCA USCA	FUERZA AREQUIPEÑA	040520	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29329221.jpg	14
530	OSIAS WILLINGTON ORTIZ IBAÑEZ	YO AREQUIPA	040520	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_42071595.jpg	11
531	EDDY RONALD FERNANDEZ CRUZ	FUERZA AREQUIPEÑA	040602	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_09411102.jpg	5
532	HILARIO VICTOR ANDIA ROMERO	FUERZA AREQUIPEÑA	040605	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_43594987.jpg	4
533	AUGUSTO GERMAN DEL CARPIO ALVARADO	FUERZA AREQUIPEÑA	040606	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30776791.jpg	4
534	JONAS HENRY HUISACAYNA ZUÑIGA	FUERZA AREQUIPEÑA	040607	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_42084110.jpg	3
535	WILMAR ALDO CHAUCAYANQUI HUAMANI	FUERZA AREQUIPEÑA	040608	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_43267101.jpg	5
536	GLADIS MORAIMA ALE CRUZ	YO AREQUIPA	040703	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_29364639.jpg	5
537	MARIETH ALESSANDRA ALVAREZ MAMANI	FUERZA AREQUIPEÑA	040704	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_71584056.jpg	7
538	GUSTAVO ADOLFO ROBLES FERNANDEZ	YO AREQUIPA	040704	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_29308649.jpg	6
539	LORENZO FILOMENO QUISPE HUAMANI	FUERZA AREQUIPEÑA	040802	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_09436697.jpg	3
\.


--
-- Data for Name: incidencia_adjuntos; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.incidencia_adjuntos (id, incidencia_id, tipo, url, hash_sha256, subido_por, created_at) FROM stdin;
\.


--
-- Data for Name: incidencia_seguimiento; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.incidencia_seguimiento (id, incidencia_id, usuario_id, estado_nuevo, comentario, created_at) FROM stdin;
\.


--
-- Data for Name: incidencias_campo; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.incidencias_campo (id, codigo, categoria_id, ubigeo, local_id, mesa_id, reportado_por, titulo, descripcion, prioridad, estado, asignada_a, resuelta_en, tiempo_resolucion_min, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: locales_votacion; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.locales_votacion (id, ubigeo, codigo_local, nombre, direccion, referencia, latitud, longitud, electores_habiles, activo, created_at, updated_at, coordinador_local_id) FROM stdin;
\.


--
-- Data for Name: mesas; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.mesas (id, local_id, numero_mesa, electores_habiles, pabellon, piso, numero_orden, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: organizaciones_politicas; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.organizaciones_politicas (id, nombre, nombre_corto, tipo, id_jne, logo_url, color_hex, activo, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: provincial_candidates; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.provincial_candidates (id, name, party, ubigeo, color, symbol, photo_url, sort_order) FROM stdin;
1	ANDRES ELISEO RISUEÑO PORTUGAL	ACCION POPULAR	040100	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_29364674.jpg	3
2	ALFREDO WILLY BENAVENTE GODOY	AHORA NACION - AN	040100	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29727520.jpg	6
3	ELIZABETH GENESIS AMADO QUISPE	ALIANZA PARA EL PROGRESO	040100	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_45214593.jpg	1
4	RENZO ALONSO SALAS HERRERA	AREQUIPA, TRADICION Y FUTURO	040100	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_41374442.jpg	16
6	JUAN ROBERTO MUÑOZ PINTO	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040100	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_41128751.jpg	15
7	YAMEL DEYSON ROMERO PERALTA	PARTIDO APRISTA PERUANO	040100	#7C3AED	/storage/partidos/partido_partido_aprista_peruano.png	/storage/candidatos/candidato_29254618.jpg	12
8	DEYANIRA YAJAIRA SALAZAR RIVERA	PARTIDO DEL BUEN GOBIERNO	040100	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_73944229.jpg	9
9	JOSE MIGUEL BRIONES SILVA	PARTIDO DEMOCRATICO SOMOS PERU	040100	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_43310641.jpg	11
10	ELMER ANGEL ACERO BRUNA	PARTIDO FRENTE DE LA ESPERANZA 2021	040100	#DC2626	/storage/partidos/partido_partido_frente_de_la_esperanza_2021.png	/storage/candidatos/candidato_29621367.jpg	2
11	JAVIER ANTONIO ONOFRE CCAMA	PARTIDO POLITICO PUEBLO CONSCIENTE	040100	#0D9488	/storage/partidos/partido_partido_politico_pueblo_consciente.png	/storage/candidatos/candidato_43019040.jpg	10
12	JORGE LUIS REYES LUJAN MARTINEZ	PARTIDO POPULAR CRISTIANO - PPC	040100	#8B5CF6	/storage/partidos/partido_partido_popular_cristiano_ppc.png	/storage/candidatos/candidato_30586982.jpg	5
13	ISIDRO FLORES SOSA	PODEMOS PERU	040100	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_29467681.jpg	13
14	RUCCY JUDITH OSCCO POLAR	PRIMERO LA GENTE - COMUNIDAD, ECOLOGIA, LIBERTAD Y PROGRESO	040100	#DC2626	/storage/partidos/partido_primero_la_gente_comunidad_ecologia_libertad_y_progreso.png	/storage/candidatos/candidato_40308443.jpg	7
15	TOMAS JOB DELGADO ZUÑIGA	PROGRESEMOS	040100	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_08870610.jpg	8
16	RICARDO ALFREDO RAMIREZ DEL VILLAR LLOSA	RENOVACION POPULAR PERU	040100	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_29271677.jpg	4
18	LUZ MARIA CARAZAS CARNERO	ACCION POPULAR	040200	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_08874252.jpg	2
19	JULIO CESAR MONROY QUISPE	AHORA NACION - AN	040200	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_30430755.jpg	6
20	IRVIN LUIS MARQUEZ CANALES	ALIANZA REGIONAL POR EL PERU	040200	#8B5CF6	/storage/partidos/partido_alianza_regional_por_el_peru.png	/storage/candidatos/candidato_71889531.jpg	4
22	FERNANDO EMILIO RIVAS ROSAS	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040200	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_30407339.jpg	11
23	DANTE LEONARDI MENDEZ MENESES	PARTIDO DEL BUEN GOBIERNO	040200	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_41519135.jpg	8
24	NOLVERTO MARIO CHAMBI LINARES	PARTIDO DEMOCRATICO SOMOS PERU	040200	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30424636.jpg	9
25	FRANK PASTOR MENDOZA	PARTIDO POLITICO INTEGRIDAD DEMOCRATICA	040200	#8B5CF6	/storage/partidos/partido_partido_politico_integridad_democratica.png	/storage/candidatos/candidato_30430824.jpg	1
26	WASHINGTON MANUEL QUILLA HUAYAPA	PARTIDO POLITICO PERU PRIMERO	040200	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30401778.jpg	5
27	YURBI ANGELA MOLINA DIAZ	PROGRESEMOS	040200	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_30425484.jpg	7
28	JONATHAN RONNY MACHADO RIVERA	RENOVACION POPULAR PERU	040200	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_70164641.jpg	3
30	MARCOS AMET LAURA DAVALOS	AHORA NACION - AN	040300	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_42788523.jpg	4
31	JUAN FLAVIO ARANGUREN MONTOYA	ALIANZA PARA EL PROGRESO	040300	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_30501418.jpg	1
32	AGUSTIN CONDORI MOTTA	FE EN EL PERU	040300	#0056B3	/storage/partidos/partido_fe_en_el_peru.png	/storage/candidatos/candidato_30486162.jpg	3
34	JOSE ANTONIO FLORES PONCE	PARTIDO DEL BUEN GOBIERNO	040300	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_30507153.jpg	6
35	TULIO ERNESTO NAVARRO NEYRA	PODEMOS PERU	040300	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_06382046.jpg	7
36	ROBERTO GERARDO VASQUEZ PISCO	PROGRESEMOS	040300	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_30482153.jpg	5
37	OSWALDO BALTAZAR VELASQUEZ HUARCAYA	RENOVACION POPULAR PERU	040300	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_22102400.jpg	2
38	ROBINSON ORLANDO HUACO MORENO	AHORA NACION - AN	040400	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_29343546.jpg	4
39	CESAR MARCELO DIAZ GAMERO	FRENTE POPULAR AGRICOLA FIA DEL PERU	040400	#CA8A04	/storage/partidos/partido_frente_popular_agricola_fia_del_peru.png	/storage/candidatos/candidato_42789139.jpg	2
41	LUIS MIGUEL CATERIANO WENDORFF	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040400	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_00255577.jpg	6
42	CHRISTIAN ROBERT FERNANDEZ JULCA	PARTIDO POLITICO PERU PRIMERO	040400	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_25817739.jpg	3
43	ANTONIO MANUEL QUISPE YAURI	PROGRESEMOS	040400	#7C3AED	/storage/partidos/partido_progresemos.png	/storage/candidatos/candidato_30586181.jpg	5
44	YEYMI NATALI PEREA MOLLO	RENOVACION POPULAR PERU	040400	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_42318906.jpg	1
45	JENNIFFER MARITZA NEIRA GONZALES	ALIANZA PARA EL PROGRESO	040500	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_45623610.jpg	1
46	ROMULO BRAULIO ANDRES TINTA CACERES	AREQUIPA, TRADICION Y FUTURO	040500	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29519426.jpg	8
47	SILVERIO FLORENCIO OPORTO OPORTO	FRENTE POPULAR AGRICOLA FIA DEL PERU	040500	#CA8A04	/storage/partidos/partido_frente_popular_agricola_fia_del_peru.png	/storage/candidatos/candidato_29481419.jpg	2
49	GUILLERMO ROMAN CUEVA ESPINEL	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040500	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_41773748.jpg	7
50	DAMASO GODOFREDO CONDORI TACO	PARTIDO DEL BUEN GOBIERNO	040500	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_29549748.jpg	4
51	CRISTHIAN VICTOR PANTA MAMANI	PARTIDO DEMOCRATICO SOMOS PERU	040500	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_43382024.jpg	5
52	JULIO CESAR CALSINA ORTIZ	PARTIDO POLITICO PERU PRIMERO	040500	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_45317862.jpg	3
54	RONAL MARCOS MEDINA TEJADA	AHORA NACION - AN	040600	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_40025851.jpg	2
55	LUIS ANTONIO GONZALES SUPA	AREQUIPA, TRADICION Y FUTURO	040600	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_07877425.jpg	4
57	TOMAS WUILE AYÑAYANQUE ROSAS	PARTIDO DEMOCRATICO SOMOS PERU	040600	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30760729.jpg	3
58	MIGUEL ANGEL MANCHEGO LLERENA	PARTIDO POLITICO PERU PRIMERO	040600	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30766836.jpg	1
59	MIGUEL ROMAN VALDIVIA	ACCION POPULAR	040700	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_30838191.jpg	2
60	DOMINGO ROMAN SUAREZ RAMOS	AHORA NACION - AN	040700	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_30841965.jpg	6
61	ABEL GREGORIO SUAREZ RAMOS	ALIANZA PARA EL PROGRESO	040700	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_30838402.jpg	1
63	MARCO ANTONIO MANUEL SANHUEZA LUQUE	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040700	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_80501146.jpg	9
64	GWYNETH AMERICA BARRERA ZUÑIGA	PARTIDO DEL BUEN GOBIERNO	040700	#EC4899	/storage/partidos/partido_partido_del_buen_gobierno.png	/storage/candidatos/candidato_42212690.jpg	7
65	FERNANDO ALFREDO CAMARGO HUAYNA	PARTIDO DEMOCRATA VERDE	040700	#DC2626	/storage/partidos/partido_partido_democrata_verde.png	/storage/candidatos/candidato_29639187.jpg	4
66	EDILBERTO DE LA CRUZ CESAREO SALAZAR ZENDER	PARTIDO DEMOCRATICO SOMOS PERU	040700	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30832256.jpg	8
67	ADA SOFIA PEREZ VASQUEZ	PARTIDO POLITICO PERU PRIMERO	040700	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30826277.jpg	5
68	CARLOS MANUEL GARCIA CORTEZ	RENOVACION POPULAR PERU	040700	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_40964779.jpg	3
69	MANUEL ENRIQUE ARAGON VILCAS	AHORA NACION - AN	040800	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_77658707.jpg	3
70	ETNER MOTA LOAIZA	ALIANZA PARA EL PROGRESO	040800	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_41829830.jpg	1
71	COSME RANIER MEJIA ESPINAL	AREQUIPA, TRADICION Y FUTURO	040800	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29437194.jpg	6
73	ANTONIO DIONICIO CASTRO FLORES	PARTIDO DEMOCRATICO SOMOS PERU	040800	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_30944353.jpg	4
74	MIGUEL SEBASTIAN GUZMAN HINOJOSA	PARTIDO POLITICO PERU PRIMERO	040800	#002B66	/storage/partidos/partido_partido_politico_peru_primero.png	/storage/candidatos/candidato_30953336.jpg	2
75	RODOLFO JUSTINIANO SANABRIA HINOJOSA	PODEMOS PERU	040800	#0D9488	/storage/partidos/partido_podemos_peru.png	/storage/candidatos/candidato_30940458.jpg	5
76	MANUEL ENRIQUE VERA PAREDES	FUERZA AREQUIPEÑA	040100	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_06660217.jpg	17
77	ALFREDO ALVAREZ DIAZ	YO AREQUIPA	040100	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_03506699.jpg	14
78	JULIO CESAR DAVILA DAVILA	FUERZA AREQUIPEÑA	040200	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30410013.jpg	12
79	MANUEL ERASMO GRANDA CARNERO	YO AREQUIPA	040200	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_30410173.jpg	10
80	ISAIAS CHALLCO FIGUEROA	FUERZA AREQUIPEÑA	040300	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30488550.jpg	8
81	HECTOR RAUL CACERES MUÑOZ	FUERZA AREQUIPEÑA	040400	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30581916.jpg	7
82	NELSON ESTANISLAO MAQUE ALFARO	FUERZA AREQUIPEÑA	040500	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_30642544.jpg	9
83	HERBERT OSWALDO CLAVERIAS VARGAS	YO AREQUIPA	040500	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_29611731.jpg	6
84	GUILLERMO VICTOR LAZO MANRIQUE	FUERZA AREQUIPEÑA	040600	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29267118.jpg	5
85	JULIO ESTEBAN MILON GUZMAN	FUERZA AREQUIPEÑA	040700	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29718755.jpg	10
86	DANNY KID MOGROVEJO POSTIGO	FUERZA AREQUIPEÑA	040800	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29726982.jpg	7
\.


--
-- Data for Name: records; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.records (id, table_id, candidate_type, candidate_id, votes, verified, created_at, updated_at) FROM stdin;
1	1307	regional	4	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
2	1307	regional	14	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
3	1307	regional	1	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
4	1307	regional	11	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
5	1307	regional	6	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
6	1307	regional	13	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
7	1307	regional	7	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
8	1307	regional	2	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
9	1307	regional	12	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
10	1307	regional	10	1	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
11	1307	regional	3	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
12	1307	regional	16	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
13	1307	regional	9	0	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
14	1307	regional	5	2	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
15	1307	regional	15	100	t	2026-09-23 01:18:35-05	2026-09-23 01:18:35-05
16	3036	regional	4	0	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
17	3036	regional	14	0	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
18	3036	regional	1	1	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
19	3036	regional	11	0	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
20	3036	regional	6	1	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
21	3036	regional	13	0	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
22	3036	regional	7	1	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
23	3036	regional	2	0	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
24	3036	regional	12	0	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
25	3036	regional	10	0	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
26	3036	regional	3	0	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
27	3036	regional	16	0	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
28	3036	regional	9	0	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
29	3036	regional	5	1	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
30	3036	regional	15	1	t	2026-09-23 02:05:24-05	2026-09-23 02:05:24-05
31	3036	provincial	3	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
32	3036	provincial	10	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
33	3036	provincial	1	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
34	3036	provincial	16	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
35	3036	provincial	12	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
36	3036	provincial	2	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
37	3036	provincial	14	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
38	3036	provincial	15	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
39	3036	provincial	8	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
40	3036	provincial	11	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
41	3036	provincial	9	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
42	3036	provincial	7	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
43	3036	provincial	13	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
44	3036	provincial	77	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
45	3036	provincial	6	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
46	3036	provincial	4	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
47	3036	provincial	76	0	t	2026-09-23 02:05:59-05	2026-09-23 02:05:59-05
48	3036	district	90	0	t	2026-09-23 02:06:21-05	2026-09-23 02:06:21-05
49	3036	district	88	0	t	2026-09-23 02:06:21-05	2026-09-23 02:06:21-05
50	3036	district	95	0	t	2026-09-23 02:06:21-05	2026-09-23 02:06:21-05
51	3036	district	89	1	t	2026-09-23 02:06:21-05	2026-09-23 02:06:21-05
52	3036	district	94	0	t	2026-09-23 02:06:21-05	2026-09-23 02:06:21-05
53	3036	district	93	0	t	2026-09-23 02:06:21-05	2026-09-23 02:06:21-05
54	3036	district	96	0	t	2026-09-23 02:06:21-05	2026-09-23 02:06:21-05
55	3036	district	490	0	t	2026-09-23 02:06:21-05	2026-09-23 02:06:21-05
56	3036	district	92	0	t	2026-09-23 02:06:21-05	2026-09-23 02:06:21-05
57	3036	district	489	0	t	2026-09-23 02:06:21-05	2026-09-23 02:06:21-05
58	1321	regional	4	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
59	1321	regional	14	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
60	1321	regional	1	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
61	1321	regional	11	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
62	1321	regional	6	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
63	1321	regional	13	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
64	1321	regional	7	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
65	1321	regional	2	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
66	1321	regional	12	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
67	1321	regional	10	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
68	1321	regional	3	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
69	1321	regional	16	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
70	1321	regional	9	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
71	1321	regional	5	1	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
72	1321	regional	15	12	t	2026-09-23 02:36:25-05	2026-09-23 02:36:25-05
73	1321	provincial	3	0	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
74	1321	provincial	10	0	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
75	1321	provincial	1	0	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
76	1321	provincial	16	0	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
77	1321	provincial	12	0	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
78	1321	provincial	2	0	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
79	1321	provincial	14	1	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
80	1321	provincial	15	1	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
81	1321	provincial	8	1	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
82	1321	provincial	11	1	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
83	1321	provincial	9	1	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
84	1321	provincial	7	1	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
85	1321	provincial	13	1	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
86	1321	provincial	77	1	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
87	1321	provincial	6	1	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
88	1321	provincial	4	1	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
89	1321	provincial	76	1	t	2026-09-23 02:43:44-05	2026-09-23 02:43:44-05
90	3225	regional	4	120	t	2026-09-25 02:19:01-05	2026-09-25 02:19:01-05
91	3225	regional	14	40	t	2026-09-25 02:19:01-05	2026-09-25 02:19:01-05
92	3225	consejero	1	100	t	2026-09-25 02:19:01-05	2026-09-25 02:19:01-05
93	3225	consejero	2	50	t	2026-09-25 02:19:01-05	2026-09-25 02:19:01-05
94	1308	consejero	1	21	f	2026-09-26 09:32:55.477691-05	2026-09-26 09:32:55.477691-05
95	1308	consejero	2	13	f	2026-09-26 09:32:55.477691-05	2026-09-26 09:32:55.477691-05
96	1309	regional	4	1	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
97	1309	regional	14	1	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
98	1309	regional	1	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
99	1309	regional	11	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
100	1309	regional	6	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
101	1309	regional	13	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
102	1309	regional	7	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
103	1309	regional	2	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
104	1309	regional	12	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
105	1309	regional	10	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
106	1309	regional	3	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
107	1309	regional	16	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
108	1309	regional	9	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
109	1309	regional	5	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
110	1309	regional	15	0	t	2026-09-26 09:37:08.598301-05	2026-09-26 09:37:08.598301-05
111	1309	consejero	1	0	t	2026-09-26 09:37:39.227143-05	2026-09-26 09:37:39.227143-05
112	1309	consejero	2	0	t	2026-09-26 09:37:39.227143-05	2026-09-26 09:37:39.227143-05
113	1309	consejero	3	0	t	2026-09-26 09:37:39.227143-05	2026-09-26 09:37:39.227143-05
114	1309	consejero	4	0	t	2026-09-26 09:37:39.227143-05	2026-09-26 09:37:39.227143-05
115	1309	consejero	5	0	t	2026-09-26 09:37:39.227143-05	2026-09-26 09:37:39.227143-05
116	1309	consejero	6	0	t	2026-09-26 09:37:39.227143-05	2026-09-26 09:37:39.227143-05
117	1309	consejero	7	0	t	2026-09-26 09:37:39.227143-05	2026-09-26 09:37:39.227143-05
118	1309	consejero	8	0	t	2026-09-26 09:37:39.227143-05	2026-09-26 09:37:39.227143-05
119	1309	consejero	9	0	t	2026-09-26 09:37:39.227143-05	2026-09-26 09:37:39.227143-05
120	1309	consejero	10	0	t	2026-09-26 09:37:39.227143-05	2026-09-26 09:37:39.227143-05
121	1309	provincial	3	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
122	1309	provincial	10	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
123	1309	provincial	1	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
124	1309	provincial	16	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
125	1309	provincial	12	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
126	1309	provincial	2	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
127	1309	provincial	14	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
128	1309	provincial	15	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
129	1309	provincial	8	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
130	1309	provincial	11	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
131	1309	provincial	9	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
132	1309	provincial	7	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
133	1309	provincial	13	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
134	1309	provincial	77	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
135	1309	provincial	6	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
136	1309	provincial	4	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
137	1309	provincial	76	0	t	2026-09-26 09:38:15.377349-05	2026-09-26 09:38:15.377349-05
138	1311	consejero	1	30	f	2026-09-26 10:21:02.952021-05	2026-09-26 10:21:02.952021-05
139	1312	consejero	1	30	f	2026-09-26 10:21:03.236726-05	2026-09-26 10:21:03.236726-05
140	1313	consejero	1	45	f	2026-09-26 10:21:03.503226-05	2026-09-26 10:21:03.503226-05
\.


--
-- Data for Name: regional_candidates; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.regional_candidates (id, name, party, ubigeo, color, symbol, photo_url, sort_order) FROM stdin;
1	PEDRO EDWIN MARTINEZ TALAVERA	ACCION POPULAR	040000	#EC4899	/storage/partidos/partido_accion_popular.png	/storage/candidatos/candidato_29384343.jpg	3
2	JENRY FEDERICO HUISA CALAPUJA	AHORA NACION - AN	040000	#D97706	/storage/partidos/partido_ahora_nacion_an.png	/storage/candidatos/candidato_72308954.jpg	8
3	JOSE LUIS ANCALLE GUTIERREZ	ALIANZA ELECTORAL VENCEREMOS	040000	#8B5CF6	/storage/partidos/partido_alianza_electoral_venceremos.png	/storage/candidatos/candidato_29681383.jpg	11
4	ELMER CACERES LLICA	ALIANZA PARA EL PROGRESO	040000	#0056B3	/storage/partidos/partido_alianza_para_el_progreso.png	/storage/candidatos/candidato_30642473.jpg	1
5	CESAR ANGEL HUAMANTUMA ALARCON	AREQUIPA, TRADICION Y FUTURO	040000	#DC2626	/storage/partidos/partido_arequipa_tradicion_y_futuro.png	/storage/candidatos/candidato_29669577.jpg	14
6	MILCO TORRES BARRIONUEVO	COALICION TRANSFORMADORA TIERRA VERDE	040000	#0D9488	/storage/partidos/partido_coalicion_transformadora_tierra_verde.png	/storage/candidatos/candidato_29640152.jpg	5
7	YACKELIN LOURDES HUARSAYA CALIZAYA DE LLACCHUA	FRENTE POPULAR AGRICOLA FIA DEL PERU	040000	#CA8A04	/storage/partidos/partido_frente_popular_agricola_fia_del_peru.png	/storage/candidatos/candidato_30676235.jpg	7
9	BENIGNO TEOFILO CORNEJO VALENCIA	MOVIMIENTO REGIONAL AREQUIPA AVANCEMOS	040000	#D97706	/storage/partidos/partido_movimiento_regional_arequipa_avancemos.png	/storage/candidatos/candidato_29345957.jpg	13
10	HUGO EFRAIN AGUILAR GONZALES	PARTIDO APRISTA PERUANO	040000	#7C3AED	/storage/partidos/partido_partido_aprista_peruano.png	/storage/candidatos/candidato_40521048.jpg	10
11	MIGUEL CORONADO ZARATE FLORES	PARTIDO CIVICO OBRAS	040000	#002B66	/storage/partidos/partido_partido_civico_obras.png	/storage/candidatos/candidato_29274395.jpg	4
12	HECTOR HUGO HERRERA HERRERA	PARTIDO DEMOCRATICO SOMOS PERU	040000	#D97706	/storage/partidos/partido_partido_democratico_somos_peru.png	/storage/candidatos/candidato_29364892.jpg	9
13	HAROLD EDGARD RODRIGUEZ QUISPE	RENOVACION POPULAR PERU	040000	#EC4899	/storage/partidos/partido_renovacion_popular_peru.png	/storage/candidatos/candidato_42155500.jpg	6
14	DAVID CESAR ARDILES SARAVIA	SALVEMOS AL PERU	040000	#8B5CF6	/storage/partidos/partido_salvemos_al_peru.png	/storage/candidatos/candidato_29566707.jpg	2
15	FLORENTINO ALFREDO ZEGARRA TEJADA	FUERZA AREQUIPEÑA	040000	#CA8A04	/storage/partidos/partido_fuerza_arequipe_a.png	/storage/candidatos/candidato_29276388.jpg	15
16	BERLY JOSE GONZALES ARIAS	YO AREQUIPA	040000	#EC4899	/storage/partidos/partido_yo_arequipa.png	/storage/candidatos/candidato_29567762.jpg	12
\.


--
-- Data for Name: sesiones; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.sesiones (id, usuario_id, token_hash, dispositivo, ip, expira_at, revocada, created_at) FROM stdin;
1	1	7e8777f248d8cd5d590527e116543edbf6c5e923146cc06c22a968000d9f49e0	\N	127.0.0.1	2026-09-16 06:58:19.482324-05	f	2026-09-15 18:58:19-05
2	1	e4b00eb2d96ff0a482411c34620684e35f8af9151dc98098e1d172ca8c6b6166	\N	127.0.0.1	2026-09-16 06:58:45.205836-05	f	2026-09-15 18:58:45-05
3	6	d099b46354085ffa39d13d98bf9b40308510ebbf69a51233e5896b2794453e4b	\N	127.0.0.1	2026-09-16 06:58:45.4346-05	f	2026-09-15 18:58:45-05
4	3	e383629f24fa5af9d354a5e38990d6ea6b5e2011ee27c95c3b4888b00f565de8	\N	127.0.0.1	2026-09-16 06:58:45.685259-05	t	2026-09-15 18:58:45-05
5	1	9d24d8761ce63b469bfd960c8c0ef777295fb73993fd2665694c02194ba322f1	\N	127.0.0.1	2026-09-16 06:59:22.952333-05	f	2026-09-15 18:59:22-05
6	3	3a0fb7e196e2482bdd44456cb15187bba625d569c3d40b041118cfe2570efb66	\N	127.0.0.1	2026-09-16 06:59:23.195943-05	f	2026-09-15 18:59:23-05
7	4	76ec723a7f0bbce27dccd6a48995f7cf6caa9f9bb4a4ba2a1ee0b427d17aec81	\N	127.0.0.1	2026-09-16 06:59:23.433735-05	t	2026-09-15 18:59:23-05
8	4	1c46503343081190d065df4a157e736ea1e00a4d310e150c480d57eeb7887d1a	\N	127.0.0.1	2026-09-16 06:59:23.657245-05	f	2026-09-15 18:59:23-05
9	4	6ddebd7df3426d7bc57162fdd2a6a68bc0102f196540172d131fb8d28a64f55f	\N	127.0.0.1	2026-09-16 07:00:23.744899-05	f	2026-09-15 19:00:23-05
10	3	f433c45c4a9431ad06ea265b797ff6371905be0e4cef0f0b875b05dc74d85cd9	\N	127.0.0.1	2026-09-16 07:00:24.097088-05	f	2026-09-15 19:00:24-05
11	1	da5afd126dbec224b4a46f9216ac4a0f00693b615b3a48f6be5f0ca3f9dc55f5	\N	127.0.0.1	2026-09-16 07:00:24.462072-05	f	2026-09-15 19:00:24-05
12	6	3b54070afc7e0cd84c1f8795f8193d067efe46b6612ebb225be5035549864921	\N	127.0.0.1	2026-09-16 07:00:25.055865-05	f	2026-09-15 19:00:25-05
13	2	475582fbe4072ac28603bccad4b5c8f9042d190bbde91948ebfe2aed470551d2	\N	127.0.0.1	2026-09-16 07:00:25.488621-05	f	2026-09-15 19:00:25-05
14	6	1f31d6f785b6a051c756a97aa2c7b6448cba69d1e9bde60f0f18587a8c4098c4	\N	127.0.0.1	2026-09-16 07:07:55.729222-05	f	2026-09-15 19:07:55-05
15	6	a1ac507c9a176fac1eee1efa0b46c693899743b016597becfa989c41eeaf6118	\N	127.0.0.1	2026-09-16 07:07:55.985366-05	f	2026-09-15 19:07:55-05
16	6	c3433310d959b683835621c59293c409cf4aaf905977d3ae94e1b5a926f1cbfd	Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Freebuff/0.0.112 Chrome/130.0.6723.191 	127.0.0.1	2026-09-16 07:24:09.660998-05	f	2026-09-15 19:24:09-05
17	1	65716f35ece56b6364768a19fde17874b97a190171312898d162efd40889a518	\N	127.0.0.1	2026-09-16 07:29:07.775092-05	f	2026-09-15 19:29:07-05
18	3	b5c3ba3de54e6e1ff7a33fe4fef1e1d562ff021d6bb1123a2479b270207f430d	\N	127.0.0.1	2026-09-16 07:29:08.029863-05	f	2026-09-15 19:29:08-05
19	4	52167229216b0ecd53248decf22c84cd0b06c5fa5c9cd9f41be81b162a63626d	\N	127.0.0.1	2026-09-16 07:29:08.267385-05	f	2026-09-15 19:29:08-05
20	1	9325e4c7002b680f60078a50c3869dab4cd0bf3ff52c18c9ae265e08bd1d23a9	\N	127.0.0.1	2026-09-16 07:37:03.86949-05	f	2026-09-15 19:37:03-05
21	3	ac3df009d7b4d6c9a825b9b0ce9c836d4165c9898ee306e205bb48f5f69fb303	\N	127.0.0.1	2026-09-16 07:37:04.109996-05	f	2026-09-15 19:37:04-05
22	4	7357e42c3902f2e4d542e3d598c052cb1ea8521b216b07e8a7b2e1664f950b29	\N	127.0.0.1	2026-09-16 07:37:04.364716-05	f	2026-09-15 19:37:04-05
23	6	a2813eca34b024717b886c5bf1cf3479a4cbb8df07e6c6d5f9f1b4c1f68951d8	\N	127.0.0.1	2026-09-16 07:37:04.856041-05	f	2026-09-15 19:37:04-05
24	6	ea3022acfe18eff1c4a860a8d2dcc79e6c8893ebdb5cf06612e1ee8a47ec98ac	\N	127.0.0.1	2026-09-16 07:38:18.198831-05	f	2026-09-15 19:38:18-05
25	6	8a4c6e29feae89aa37c49e8fd6b58f134c289b5fa4e967680ed7a44e59308d43	\N	127.0.0.1	2026-09-16 07:47:40.860815-05	f	2026-09-15 19:47:40-05
26	6	5469e34d92b19ac606ed5679ea983257f2865023d382dfd9c29a765550d18791	\N	127.0.0.1	2026-09-16 07:48:24.122867-05	f	2026-09-15 19:48:24-05
27	1	2325ccee1f5ae6b337541faaf0b54461ca54e1f4ba676e339d12b411ca62e89c	\N	127.0.0.1	2026-09-16 15:01:05.668781-05	f	2026-09-16 03:01:05-05
28	2	f317fd8b7b9c01a0d56d6bda3e88a132a8f038e8d9f9d72b901f05e392062aa1	\N	127.0.0.1	2026-09-16 15:04:57.161584-05	f	2026-09-16 03:04:57-05
29	1	49b2da4ce1e1045d95b084f025f62cc53eb49e790d2f44677b2d202c89af5d98	\N	127.0.0.1	2026-09-17 06:21:10.236185-05	f	2026-09-16 18:21:10-05
30	2	0dd535c8e5976bdab777b1dda4fea7144509910bfc48fed085f11ac84048b0fe	\N	127.0.0.1	2026-09-17 06:22:03.332693-05	f	2026-09-16 18:22:03-05
31	1	9b3929e48f3f3d3511249f2bd9b3443dfe80e974cbdec173a118b3e3f21d8e7c	\N	127.0.0.1	2026-09-17 06:24:47.965618-05	f	2026-09-16 18:24:47-05
32	1	6cf58c22077f17a7572274bd93be50bf4be4944a5aabb405658305dea66c715b	\N	testclient	2026-09-17 06:47:47.592439-05	f	2026-09-16 18:47:47-05
33	1	beef22a0b93ac24be54d782a600893eb0487057965075c41735351d67abe04b4	\N	testclient	2026-09-17 06:49:43.283156-05	f	2026-09-16 18:49:43-05
34	1	1a3e6ebef32d5ae583775e74fe9332a2ed834492d02b2c0165ea94d9218e5135	\N	testclient	2026-09-17 06:49:57.298103-05	f	2026-09-16 18:49:57-05
35	1	65b781cbeea8a2acfc8bc06bfbc3c83d0536f1afcaee1d372d6542c36e0b179a	\N	testclient	2026-09-17 06:50:24.550227-05	f	2026-09-16 18:50:24-05
36	1	0ffd7d94aa73ce30d0302b4676f7b6413a576d12d179bd521658d654ad322a67	\N	127.0.0.1	2026-09-17 06:50:53.461581-05	f	2026-09-16 18:50:53-05
37	1	8f2d241c0132663e14bcbc6e41029c4611d22947e0a767ee66d6477ad0fe099d	\N	127.0.0.1	2026-09-17 06:50:59.360097-05	f	2026-09-16 18:50:59-05
38	1	d2474dd475287b0a98d9a057e5198b5793dce6d65f8aa90df200139fb268952e	\N	127.0.0.1	2026-09-17 06:51:05.465197-05	f	2026-09-16 18:51:05-05
39	1	f6e364cae163de9c6d475af10b6876b94a5caf99e50aaf834fc66fd005f7dd57	\N	127.0.0.1	2026-09-17 06:51:38.615649-05	f	2026-09-16 18:51:38-05
40	1	f65d842c8e3660b395cb368b09b536d108be831603f3d864aa311e0db60137cc	\N	127.0.0.1	2026-09-17 06:52:14.548365-05	f	2026-09-16 18:52:14-05
41	1	df1066bc9987b9faa306faef2b3db119bb97b50e765c0e7a0017ec350b627397	\N	127.0.0.1	2026-09-17 06:53:07.739135-05	f	2026-09-16 18:53:07-05
42	1	1245fe371da1f520498b7d0cc8d323e5a2d9ce5706d193fefde12ce4629077a3	\N	127.0.0.1	2026-09-17 06:53:27.613758-05	f	2026-09-16 18:53:27-05
43	1	79e96738a7e61fdf3596f9c2522ec2a8cd42c844d2ec1c3f8abc199c2db05780	\N	127.0.0.1	2026-09-17 06:54:19.347815-05	f	2026-09-16 18:54:19-05
44	1	cb5538fe024125653e2b09b94067fb8de2aec228a38c11f929f1e67e054fbd31	\N	127.0.0.1	2026-09-17 07:24:37.928049-05	f	2026-09-16 19:24:37-05
45	1	2ccb2421fb9ef8984ae145d0a5bc99a7763b632a24836c32c1bae9d60085f205	\N	127.0.0.1	2026-09-17 07:24:45.001784-05	f	2026-09-16 19:24:45-05
46	1	a69d7be5202344651919c2829bb92c4c2447ee79efefccd78985903322ccf8b3	\N	127.0.0.1	2026-09-17 07:25:38.301137-05	f	2026-09-16 19:25:38-05
47	1	00838563c37daba2cb53ca666517b70385c5d475e4fae526805776767310eef3	\N	127.0.0.1	2026-09-17 13:23:01.762095-05	f	2026-09-17 01:23:01-05
48	1	b004a277acf6b7e2d0bbe443bf135b45317c11e459be1ece8a7ea490a8d652ae	\N	127.0.0.1	2026-09-17 13:31:45.79393-05	f	2026-09-17 01:31:45-05
49	1	8e5589beb5a2225d0f31b2d162daaedf2551059996942fc6cdb142632e92e37d	\N	127.0.0.1	2026-09-17 13:34:23.760691-05	f	2026-09-17 01:34:23-05
50	1	dc7b628cc1673437ca4bad3e4faa2981864066c9249fb271a2e20396dea2658d	\N	127.0.0.1	2026-09-17 13:36:43.025752-05	f	2026-09-17 01:36:43-05
51	1	f9916b90e6469a5852ad1d270b9f9f92387550f1ba6c4fad4abbc434b5ddb913	\N	127.0.0.1	2026-09-17 13:40:44.473673-05	f	2026-09-17 01:40:44-05
52	1	6ee4b538e60690b8aa766e50944a0e653a7d321ee41de3e77c1ddbdfc601faca	\N	127.0.0.1	2026-09-17 14:38:23.436486-05	f	2026-09-17 02:38:23-05
53	1	f32b408c870423eddda31eb42a7a0a8b04a3f00665f6c60487e6d16f38f2993b	\N	127.0.0.1	2026-09-17 14:41:51.389413-05	f	2026-09-17 02:41:51-05
54	1	56244432a90545aa72fb869b5176ae2a52574fe3d4616c98f532e10313945d0c	\N	127.0.0.1	2026-09-17 15:37:15.470811-05	f	2026-09-17 03:37:15-05
55	1	f876913903d077429537d7f473a26defc036c94c344fe21f419468435b955952	\N	127.0.0.1	2026-09-17 15:44:05.966245-05	f	2026-09-17 03:44:05-05
56	1	f7205fe86d743b2a26cd772e1e4089dd332d5c821145fb3e0f7527ca62d7a660	\N	127.0.0.1	2026-09-17 15:44:45.227889-05	f	2026-09-17 03:44:45-05
57	1	4c5f7c93e788c1ddfb54361e7e0a02c8d10e5d51ccaffe676cd81006d506aa7c	\N	127.0.0.1	2026-09-17 15:50:32.934766-05	f	2026-09-17 03:50:32-05
58	1	776dc1ee13616d5c4412c156bd6a851b56e5cfeae20252cf7dbb8d179c4ad7de	\N	127.0.0.1	2026-09-17 15:51:10.374747-05	f	2026-09-17 03:51:10-05
59	7	c7d7621ad3854a0cd21bfa6ce76c09ad549ca53fad324f705742f6c2ac71366c	\N	127.0.0.1	2026-09-17 15:51:20.854685-05	f	2026-09-17 03:51:20-05
60	9	a105bb318496735802e8c899b7287fd5bf9c8d124c47cb04a820b3b61f754db7	\N	127.0.0.1	2026-09-17 15:51:29.534015-05	f	2026-09-17 03:51:29-05
61	1	22d02a99087620dc0d1e41e40be23cb98f6e732224ad57cf7cfbc409ac2f22c1	\N	127.0.0.1	2026-09-17 15:52:08.600796-05	f	2026-09-17 03:52:08-05
62	7	7e32fbb3727e763db308383abd1080778e2bfa03e6315421f345e2a2df90687a	\N	127.0.0.1	2026-09-17 15:52:19.138488-05	f	2026-09-17 03:52:19-05
63	9	e3fa583fddbaa253be2e8317ffd7e1b3dbe66fcc8f9a6de509ee3d71d5c9c48f	\N	127.0.0.1	2026-09-17 15:52:31.732729-05	f	2026-09-17 03:52:31-05
64	9	2b22255c2651ec7365de22d03f7e74403946eb06bc404d018b86d6620320d9f2	\N	127.0.0.1	2026-09-17 15:52:50.532387-05	f	2026-09-17 03:52:50-05
65	1	a4fe6a034cf2f8cd571a2db98fbc6bd00a10c3fcc2278eb45ba84c96de2ebf4a	\N	127.0.0.1	2026-09-17 15:53:36.221185-05	f	2026-09-17 03:53:36-05
66	7	1c7c6fc8a2f171ac108b966b90b194aeec0fbf1562745fadb5c3dfbbef3a7d59	\N	127.0.0.1	2026-09-17 15:53:46.731737-05	f	2026-09-17 03:53:46-05
67	9	cdbcc865b08c6a6ed68aae9398881ed39aea0debd28007bc3a672f4897b80fd7	\N	127.0.0.1	2026-09-17 15:53:59.266323-05	f	2026-09-17 03:53:59-05
68	9	22c98dbbdad9334c015f1036f21fb5a0bdd5622205f6d17aef39d15fdc5c9173	\N	127.0.0.1	2026-09-17 15:54:18.064651-05	f	2026-09-17 03:54:18-05
69	9	c7b4c1941c46176c1be1c1a24cb9b4ec8122b574e4ae5e49d3cdd92f92e149db	\N	127.0.0.1	2026-09-17 15:55:20.079497-05	f	2026-09-17 03:55:20-05
70	1	d825fb5acaf65fdbf583f3a25bcf9ee8054f85f43353ed0bb62527db504acecd	\N	127.0.0.1	2026-09-17 15:55:22.359389-05	f	2026-09-17 03:55:22-05
71	1	c5bb3d6b6c284068fb3d3e431938b1db6025cd0e3a02fb51610726e9e4a170ab	\N	127.0.0.1	2026-09-17 16:09:46.265475-05	f	2026-09-17 04:09:46-05
72	1	1a6a7354e7a8761a9fd655c358db9bd014e4949cdc5dd688303166c5ec8f8218	\N	127.0.0.1	2026-09-17 16:10:08.198349-05	f	2026-09-17 04:10:08-05
73	1	f0e00c611ecd8f496e82b24602d1bab0db37077ad1e7d1bd9759d4abe0613981	\N	127.0.0.1	2026-09-17 16:14:16.475507-05	f	2026-09-17 04:14:16-05
74	1	9fb306dd496eafbf32bb174199cba015a373da0bdff4d9350b2a55d859f2fcb9	\N	127.0.0.1	2026-09-17 16:14:59.724668-05	f	2026-09-17 04:14:59-05
75	1	9456ea9caa98d63822dba24e3cb3253a5ff830f0a46a2904ecf19df5cb817b0c	\N	127.0.0.1	2026-09-17 16:15:21.96022-05	f	2026-09-17 04:15:21-05
76	1	ce4d02ab1a17f3c87890f4389caf03babc2243ba15e2153ee27707df713767a2	\N	127.0.0.1	2026-09-17 16:15:56.924823-05	f	2026-09-17 04:15:56-05
77	1	32bd813a36e6736a122a67c239e976495e18403148e4d7e59afcdd29c734100d	\N	127.0.0.1	2026-09-17 16:17:09.002397-05	f	2026-09-17 04:17:09-05
78	1	fb2fbc25feb068e0f2192aedb94adb673e16610caa0e83a882026bcd02952544	\N	127.0.0.1	2026-09-17 16:17:26.927316-05	f	2026-09-17 04:17:26-05
79	6	9a2388783ca2c3e826af81cababf9b3b8ee3ea6748890b9f716bec894842e79c	\N	127.0.0.1	2026-09-17 16:19:49.325966-05	f	2026-09-17 04:19:49-05
80	2	b36a2e65f49d044d910ccccc8dad7b181224fee6dec42c96b97ad79fc53b3886	\N	127.0.0.1	2026-09-17 16:21:27.682003-05	f	2026-09-17 04:21:27-05
81	1	c07f9654edea103d7ee1d6aa95640552636abd25b0526fe68f26e9eab9985758	\N	127.0.0.1	2026-09-17 16:24:26.135781-05	f	2026-09-17 04:24:26-05
82	1	4bc99439c86f6f16edd850f151b5b24cba6e1be82675a8d78f0eea140995d6ea	\N	127.0.0.1	2026-09-17 16:28:15.046553-05	f	2026-09-17 04:28:15-05
83	1	ac9ddbf2a9081a9b9c2220520b20f8a46a0177c44d01ca0c2577f9eeeb7410ab	\N	127.0.0.1	2026-09-17 16:29:26.982129-05	f	2026-09-17 04:29:26-05
84	1	202c023e67fa2f970f58ac8099dbb0503e52ec93883897da64fd11672243edb5	\N	127.0.0.1	2026-09-17 16:34:25.018218-05	f	2026-09-17 04:34:25-05
85	9	d3ab6ecaf50eb54608277173fe203eab6d68e29e1c6489283496becda08e489a	\N	127.0.0.1	2026-09-17 16:34:33.511458-05	f	2026-09-17 04:34:33-05
86	1	59542210a509462110d416d3774fc3f7cfaff26252ebacf4c1e05dbed87d5813	\N	127.0.0.1	2026-09-17 16:36:41.607092-05	f	2026-09-17 04:36:41-05
87	9	5abe275f6fc9efd1e7357e835dcb8e303febf0f79d76c4ca43cc7b66b5500297	\N	127.0.0.1	2026-09-17 16:36:50.048224-05	f	2026-09-17 04:36:50-05
88	1	e88d9194ee4073fd2660187f4d113df8bb19b2826e72295e0ee1a68ee08033a4	\N	127.0.0.1	2026-09-17 16:37:48.516033-05	f	2026-09-17 04:37:48-05
89	1	e705b4532745f2a0fe7260e96499f37f00bb5e8aad6d15dfcde0a90a3a50ffc4	\N	127.0.0.1	2026-09-17 16:44:08.78869-05	f	2026-09-17 04:44:08-05
90	7	174184f302df65957ef5261d895a294165c8977911c1891683608b2c3f2a3c83	\N	127.0.0.1	2026-09-17 16:44:13.23642-05	f	2026-09-17 04:44:13-05
91	9	406c2c24b91f7bb94b3fa58d260d37407f2868c18b83dab38cd96a64d7b8f097	\N	127.0.0.1	2026-09-17 16:44:17.669913-05	f	2026-09-17 04:44:17-05
92	1	1a0202257e354ec342c114714627e3b25a577301a1fa48cdeb9b57076d490b72	\N	127.0.0.1	2026-09-17 16:46:05.600598-05	f	2026-09-17 04:46:05-05
93	7	a4f768dc9833af77468b9655ab580719e352948221a00d899ff20fbaec74ec50	\N	127.0.0.1	2026-09-17 16:46:09.941657-05	f	2026-09-17 04:46:09-05
94	9	bd30c9eb76ad27052c44a4049fe3630bdf7347ed8417055f0ed22dbfaa53ce4a	\N	127.0.0.1	2026-09-17 16:46:14.235826-05	f	2026-09-17 04:46:14-05
95	1	aa140b05359b2b7d6f9641b786baa81948bdcda601b76643519c24f9409f0a84	\N	127.0.0.1	2026-09-17 16:47:04.444632-05	f	2026-09-17 04:47:04-05
96	9	9c835958531e05ca88911bd0f6d7b3e7babcd54cc25f42d831ebae2569258f84	\N	127.0.0.1	2026-09-17 16:47:06.678589-05	f	2026-09-17 04:47:06-05
97	6	baa10b24ffc446dd45d81535ff643d08f487c6418de07efb94598143c8578881	\N	127.0.0.1	2026-09-17 16:47:42.079337-05	f	2026-09-17 04:47:42-05
98	1	b1f667a4c5f284000544b5d912e7e673f8c60f73319d1e8c57c3d07cd767d11d	\N	127.0.0.1	2026-09-17 16:53:21.585183-05	f	2026-09-17 04:53:21-05
99	9	873adb4b9cda94c46e16d841f4ad3874ba38016ceb102c92b2e618860aaf37b7	\N	127.0.0.1	2026-09-17 16:53:23.836304-05	f	2026-09-17 04:53:23-05
100	7	539a2aa07d1507c9e49aab84b58ed1eb3ab4edbd69f97a8a39213d01700dc852	\N	127.0.0.1	2026-09-17 16:53:26.066934-05	f	2026-09-17 04:53:26-05
101	6	28d8170d168045ed27e29cd66307af6e1f739ebff5265fd26fd2dcdbd4369bb9	\N	127.0.0.1	2026-09-17 16:54:38.732233-05	f	2026-09-17 04:54:38-05
102	4	a22f57730c828b35ba0c74a8f68799a091983a73a54955d663962b8c7ab00bdd	\N	127.0.0.1	2026-09-17 16:55:04.669132-05	f	2026-09-17 04:55:04-05
103	6	1781a3f7b30fd919ef7921be839a2b299db15eb7129f53ede719ddae5b0b8da5	\N	127.0.0.1	2026-09-17 16:57:44.485919-05	f	2026-09-17 04:57:44-05
104	1	f33bd77dff9b4b928622edf07ec4f27d9d583c4fe288d22d053074659986a4c8	\N	127.0.0.1	2026-09-17 16:58:04.031021-05	f	2026-09-17 04:58:04-05
105	6	9c7a9bcef3d300c84ae18da30d5b20c77c5475c53bac4e89bbfabd31bd4a0b3b	\N	127.0.0.1	2026-09-17 17:00:54.93001-05	f	2026-09-17 05:00:54-05
106	1	f0ddefc1e0064f800992a2d3cfee30485b630c7972f0c87829f60154d2a6d5f2	\N	127.0.0.1	2026-09-17 17:03:06.796638-05	f	2026-09-17 05:03:06-05
107	1	235add07b02e913655ef450c58d609d388b31595120e55c9dae512be5cfe4a69	\N	127.0.0.1	2026-09-17 17:03:14.592186-05	f	2026-09-17 05:03:14-05
108	1	102773d79af3c4900a5b8bda2156f0a4fa7fb40296dc8b9791a3f2a4e352fc2e	\N	127.0.0.1	2026-09-17 17:29:06.035698-05	f	2026-09-17 05:29:06-05
109	1	2ec0f27cc6aa28f2f2693125a8e451907dc77feb12009abfc0708b7f1df10711	\N	127.0.0.1	2026-09-17 17:29:45.077115-05	f	2026-09-17 05:29:45-05
110	9	8c1e8f28d0bec51eb68d8c125373ffd740ccc7747d7c4be6621adefa8e76722d	\N	127.0.0.1	2026-09-17 17:35:36.791739-05	f	2026-09-17 05:35:36-05
111	9	8df7c64526229d2bdc5991ab7cd42d85ed074f057e1391f23112a90cde073a90	\N	127.0.0.1	2026-09-17 17:36:33.201761-05	f	2026-09-17 05:36:33-05
112	9	79fef9fa4352214f27b5a1bed72155d4fe07f1e4b67f4cc6c2ee0ac8f8c90535	\N	127.0.0.1	2026-09-17 17:38:17.030993-05	f	2026-09-17 05:38:17-05
113	1	ac59c09453578cf3d50605b0268e8f895620179d7cb2d2f66c9f8f1565bfff12	\N	127.0.0.1	2026-09-17 17:39:48.405117-05	f	2026-09-17 05:39:48-05
114	1	8d1dd0484ee66f009bafccd89ba57c2bc96448f0675c71d051dcfd30be3e09eb	\N	127.0.0.1	2026-09-17 17:48:44.426947-05	f	2026-09-17 05:48:44-05
115	1	49fcec8c98676dc06167da4f08bb55f912b045a6f112792722ef54307d622db3	\N	127.0.0.1	2026-09-17 17:53:18.550773-05	f	2026-09-17 05:53:18-05
116	1	8e4c9a567d1ad309f9d958ffab6096b49f51f3f0e3f1428cd4da26c215e9f908	\N	127.0.0.1	2026-09-17 17:55:30.063542-05	f	2026-09-17 05:55:30-05
117	1	841b7d2365e3a21004471c67e26c77bbfee1edd61420702ba2d06f7b1503e5f3	\N	127.0.0.1	2026-09-17 17:57:50.782923-05	f	2026-09-17 05:57:50-05
118	1	e4380d3275d1b1979c2c0d36ce75be88c48637251c9ff2d905390170cd2d43cd	\N	127.0.0.1	2026-09-17 17:58:01.642586-05	f	2026-09-17 05:58:01-05
119	6	0d2d07ab08826f695973084407f24e275fe1a3af145be591871a8907227ba300	\N	127.0.0.1	2026-09-18 02:39:09.977176-05	f	2026-09-17 14:39:09-05
120	1	f7c6d1cf72f44fea21eaf33f7eac8d753b2f18d641e466ebc09262946868338c	\N	127.0.0.1	2026-09-18 02:43:42.40735-05	f	2026-09-17 14:43:42-05
121	1	88a0569d997ddf4abf787dedcd7d62f1a7258fdc07ff0bc1c45ad4da7a638153	\N	127.0.0.1	2026-09-18 10:19:58.530241-05	f	2026-09-17 22:19:58-05
122	6	a3249318a964159ee600faa494c4580ce09cba0a64d0fe17316ed3c25b2eccff	\N	127.0.0.1	2026-09-18 10:27:47.710571-05	f	2026-09-17 22:27:47-05
123	5	95b3fcfef949358fe3cd3f64dc719f83688a466d34e7082abe36678ca0b8c599	\N	127.0.0.1	2026-09-18 10:29:37.078626-05	f	2026-09-17 22:29:37-05
124	1	5a680c19658786915908254b040752c08c68defd544ca443d471840b1af6dca0	\N	127.0.0.1	2026-09-18 11:03:10.953589-05	f	2026-09-17 23:03:10-05
125	13	925d1aa24f7fe8c0d4435d668ab40eb46ceca1d11c0deecda0a5caf2d7bc5837	\N	127.0.0.1	2026-09-18 14:35:32.290066-05	f	2026-09-18 02:35:32-05
126	12	997e826a0fc7e74152312f876c61c64778a79d034f60b2ba213101e04c6ec0e1	\N	127.0.0.1	2026-09-18 15:04:56.372899-05	f	2026-09-18 03:04:56-05
127	12	978015d9ce4382132769f961b29cdec84c01547b36b9e97605fc86f64739a4b3	\N	127.0.0.1	2026-09-18 15:19:20.488248-05	f	2026-09-18 03:19:20-05
128	13	398a092d435216f770f869c51c4e911ceab161b36a7cc400743dcef1a748ed7a	\N	127.0.0.1	2026-09-18 15:33:33.746801-05	f	2026-09-18 03:33:33-05
129	12	d90e79b388aa14167fa2de8d8631dce1056a2df2a71d33c85b3726e1b3013d0d	\N	127.0.0.1	2026-09-18 15:49:52.767984-05	f	2026-09-18 03:49:52-05
130	1	399466e8fe52c35e78811edcf4bb2a1ca5ce8351c97939a8b1d8848c095d8275	\N	127.0.0.1	2026-09-18 16:35:16.139782-05	f	2026-09-18 04:35:16-05
131	1	b5a3e3753ae824b2a0254104cf048a05a3e5772ba88a40f42348f4166cd8dcd5	\N	127.0.0.1	2026-09-18 16:35:19.157495-05	f	2026-09-18 04:35:19-05
132	12	fd194c1e18fac106237faca3678f4877a9a604edee4f8b265510e1889ba7a41f	\N	127.0.0.1	2026-09-18 16:56:11.860157-05	f	2026-09-18 04:56:11-05
133	12	a71e48e9dbe618934edb42e3baaa12c96a744c76f290f1800fa99d95f37ab586	\N	127.0.0.1	2026-09-18 16:56:29.310014-05	f	2026-09-18 04:56:29-05
134	1	c3179e6d422779d3941d6362dda2122f1471ba60eeae6af0d1a02d1205f78493	\N	127.0.0.1	2026-09-18 16:56:29.631666-05	f	2026-09-18 04:56:29-05
135	1	b45758e8b829af2b81aea1b62b998346a814939e7bc155cea60cac1129340622	\N	127.0.0.1	2026-09-18 16:58:27.015556-05	f	2026-09-18 04:58:27-05
136	13	03dec26b3c33b5c5475eed82ef865a01974cd433e3fe863b93523d958915fd83	\N	127.0.0.1	2026-09-20 01:45:42.301826-05	f	2026-09-19 13:45:42-05
137	1	d63e0acd12dfdbefb4d1e2d6937f11048ef6fb81313d6178da01c6f6b4173be9	\N	testclient	2026-09-23 04:46:13.55552-05	f	2026-09-22 16:46:13-05
138	1	39fe645cb88013c8720ce3a455fe3da16f6f93593e8e2e571c2f50ed586a7459	\N	127.0.0.1	2026-09-23 04:51:50.755206-05	f	2026-09-22 16:51:50-05
139	1	b86681ec0b0677f81ba97ce58749c1eefd5e7a2545cbc8424c5652e4770afc4c	\N	testclient	2026-09-23 05:02:55.023408-05	f	2026-09-22 17:02:55-05
140	1	b35cea56836f270acc94b2e1c01383c9ad9450fa6e67b8495d87e70fda10f0bc	\N	127.0.0.1	2026-09-23 13:17:27.850083-05	f	2026-09-23 01:17:27-05
141	1	ee1c9b6627fb9196b3cb3f843de1b83c3d98db0860a2617a6507b940fcc2e4f8	\N	127.0.0.1	2026-09-23 13:36:09.711045-05	f	2026-09-23 01:36:09-05
142	1	52aae1aceef946931f290a09210bf9fc8b8d58881f6e4eeabf0ee3f88b5ab7a7	\N	testclient	2026-09-23 13:44:00.411487-05	f	2026-09-23 01:44:00-05
143	1	3128d353bac3b43344d5103b6cab31d82baadd65e37bba83fdbac579cce1485c	\N	127.0.0.1	2026-09-23 13:53:54.597966-05	f	2026-09-23 01:53:54-05
144	1	2c0f94ca1e6c086bb0b0cb9d1dec636aaeadd7a6ea0ff4521725047c85800847	\N	127.0.0.1	2026-09-23 14:34:40.947203-05	f	2026-09-23 02:34:40-05
145	1	df1e69e1d31a98a99f0187e437695da148cc32680dfb63d700624b19d20a5a62	\N	127.0.0.1	2026-09-24 00:45:26.817724-05	f	2026-09-23 12:45:26-05
146	1	2600ce40ef4cdf107aae805f1fc2e979a11d0ccd45544dfacff18a9dfe43164c	\N	127.0.0.1	2026-09-24 00:54:36.365283-05	f	2026-09-23 12:54:36-05
147	1	4275d4c520d5cc0bb865e6219a564bb777fa00b023a6cfd453f74e0caf3d938e	\N	127.0.0.1	2026-09-24 06:18:45.400757-05	f	2026-09-23 18:18:45-05
148	1	c2aa00b393ab1acacc00e1550726f38c7b44a44eab204f21b870ce9b7236fa53	\N	127.0.0.1	2026-09-25 11:25:04.237847-05	f	2026-09-24 23:25:04-05
149	14	4abf3fb3c7c8475b25efbffc95937e729f15ebdbd3a29cb52b55b7974a5481c6	\N	127.0.0.1	2026-09-25 11:28:07.933938-05	f	2026-09-24 23:28:07-05
150	1	d6ad076322a07d27113bab691a8bba698cf1be19b1b95c6647a6b86334d8ecec	\N	127.0.0.1	2026-09-25 12:06:11.898138-05	f	2026-09-25 00:06:11-05
151	1	0881324e47e144fa0a45139d3ead89cdd5eff7c74835568601b9735a27c43872	\N	127.0.0.1	2026-09-25 13:31:33.838207-05	f	2026-09-25 01:31:33-05
152	1	a796126ad466583b878ff05fb5a07172cb111faaa48350c5cd6811c722a4cdf6	\N	127.0.0.1	2026-09-25 13:42:13.822742-05	f	2026-09-25 01:42:13-05
153	14	a94d986eace38f15c1f68bd5b615f5e5b40a973b9fdbe649e16b6895875aa22f	\N	127.0.0.1	2026-09-25 13:45:23.719695-05	f	2026-09-25 01:45:23-05
154	1	b169ad4311f0367da57b7b9338c5cc01595c046f7dcecb334c0ea1754cc96dae	\N	testclient	2026-09-25 14:10:19.941911-05	f	2026-09-25 02:10:19-05
155	1	0116e1051cce9ff3d518607479a796f169a88a8a001feb0c85ab6a90465169f1	\N	testclient	2026-09-25 14:10:44.883489-05	f	2026-09-25 02:10:44-05
156	1	733e655b23e465ba281e6217e1879cb9db40c38ac0688fe7dc7d341c69777ce4	\N	testclient	2026-09-25 14:19:01.679532-05	f	2026-09-25 02:19:01-05
157	1	4cb73b4e6a6b42edcf679974c39025bceac58d66197b473e02c047e435d70a0c	\N	127.0.0.1	2026-09-25 14:21:27.837065-05	f	2026-09-25 02:21:27-05
158	1	a25738b1c2819104f96a184fedc93ff4759264ec30e952d0a25d3ac00f1daa5f	\N	127.0.0.1	2026-09-25 14:21:30.269576-05	f	2026-09-25 02:21:30-05
159	1	81f04f462660cc339e7a0f19024819ab33dac4cc3f458090085382fedeab1c9f	\N	127.0.0.1	2026-09-25 14:23:06.122145-05	f	2026-09-25 02:23:06-05
160	1	50cd90138ab3a2af1a5131c542233f7b34c79c27861708022112d1bd3d349730	\N	127.0.0.1	2026-09-25 14:24:02.881113-05	f	2026-09-25 02:24:02-05
161	1	1b87c7802126f96ac7ed9ad47a6121700e1bb94a31a49d41291b3f006744bbd1	\N	testclient	2026-09-25 09:49:25.014579-05	f	2026-09-24 21:49:24.838153-05
162	1	47e53e07fc4e28b4089830f2becd280e828d7ee28796a8b48b791e32e2bc7a99	\N	127.0.0.1	2026-09-25 09:50:11.530299-05	f	2026-09-24 21:50:11.245737-05
163	1	1f6cd30c50b05c8962e56fa8c36d3dac6794e77dd1978ec43c3400dfef1034c9	\N	testclient	2026-09-25 10:01:51.613155-05	f	2026-09-24 22:01:51.438616-05
164	1	7aa9f08b1d763766904b62af09d155c3bd18a9d59ae9a1daadb06cd9ed0e912d	\N	testclient	2026-09-25 10:21:50.291126-05	f	2026-09-24 22:21:50.049737-05
165	1	76da3507cd2bea2ff1b6914dfa51a4291cc33a6275869d7913528f723ec43070	\N	testclient	2026-09-25 10:23:13.543227-05	f	2026-09-24 22:23:13.320999-05
166	1	8b3a3aec2e79e1d89995337f7326d6ee156f58c65e222db6590ac30eddcac1b3	\N	testclient	2026-09-25 10:25:18.053076-05	f	2026-09-24 22:25:17.83206-05
167	1	f327f4fb33032c9e3ceac7ad31a9ced2809a6200541d26a9e35ce093a7a62a9f	\N	testclient	2026-09-25 10:45:50.439092-05	f	2026-09-24 22:45:50.215943-05
168	1	57e28a483152a5019b4248c41d76e9b90d02ab8cd73cd5dc39f3f8bba4be3bb3	\N	127.0.0.1	2026-09-25 10:54:13.718331-05	f	2026-09-24 22:54:13.345204-05
169	1	30bba0c647bb7e7b4da8709eb5778751a0327b5e8a019db35e3f7f7c24c785bc	\N	127.0.0.1	2026-09-25 10:57:17.863643-05	f	2026-09-24 22:57:17.638471-05
170	1	11f1417a2b28d0f4c53f587d58d7ee63167b5e5edec7e111a8e5b077d54b7219	\N	127.0.0.1	2026-09-25 11:09:38.834159-05	f	2026-09-24 23:09:38.516684-05
171	1	874e31d2ba5ee661288704a5a993030788dd7ce36a474a7c9b2c13701bab62c7	\N	127.0.0.1	2026-09-25 11:50:10.15905-05	f	2026-09-24 23:50:09.869376-05
172	1	0e5ca24779c19dd05d891a59329c6296e0811aab23e00f8b6bf2429b6cc21dec	\N	127.0.0.1	2026-09-25 11:50:35.404557-05	f	2026-09-24 23:50:35.072955-05
173	1	c75b1c91f9ae63f15d06a8f3241b6db1ea962d02e291499791dd9225c32eb576	\N	127.0.0.1	2026-09-25 11:50:35.391554-05	f	2026-09-24 23:50:35.070796-05
174	1	029bf870c73757306ccb36c7ae8ff7da4bcd15c52e092f4d272a268be5e44c9d	\N	127.0.0.1	2026-09-25 21:32:08.12149-05	f	2026-09-25 09:32:07.818363-05
175	1	83d6650506d3072e6be19d436aa4aca15931aeb62a479e2fdf8c4db59c8c65a5	\N	127.0.0.1	2026-09-25 21:32:18.900455-05	f	2026-09-25 09:32:18.599761-05
176	1	ef84afc7dcd97c5d29f4aee28fc81ec45e1a1aff269e69412b465a215263aef8	\N	127.0.0.1	2026-09-25 21:32:25.3539-05	f	2026-09-25 09:32:25.071695-05
177	1	da62e3fbb6f34c767fac86b11ae11c0736f0eb66a7d47a108e0f65c524f993c5	\N	127.0.0.1	2026-09-25 21:37:17.163704-05	f	2026-09-25 09:37:16.985081-05
178	1	76536d4a23a2fa628595142caad2a36050f1b1a3376d63a4ff34be841d620eee	\N	127.0.0.1	2026-09-25 21:38:12.021384-05	f	2026-09-25 09:38:11.723604-05
179	1	f850c1cad5362464ea4a3cb67557558daa49a39569644ec54a340e6ad1fdc7ee	\N	127.0.0.1	2026-09-26 20:48:31.584362-05	f	2026-09-26 08:48:31.256316-05
180	1	3e516a5034475f1c945af3262443c3ccabf43fe9ab487bfb5ab60a90c994938b	\N	127.0.0.1	2026-09-26 20:50:59.309305-05	f	2026-09-26 08:50:59.013968-05
181	1	8f18486ed48ffb7a6f32c81458c5d3a33ae4845da278f99e81b87142db3fc578	\N	127.0.0.1	2026-09-26 20:53:42.187008-05	f	2026-09-26 08:53:41.947583-05
182	1	e8b03df75c34b605e1257a2f24561f3bb97c16ba5012f939bae1b840cfb74b53	\N	127.0.0.1	2026-09-26 20:54:59.202388-05	f	2026-09-26 08:54:58.945099-05
183	1	4ff6158c844a896ccec8937e51732bf0c881310f0dcd11f8a6d1d4a89424930c	\N	127.0.0.1	2026-09-26 20:55:47.355661-05	f	2026-09-26 08:55:47.048884-05
184	1	1342fd63d2f1a5bc02bca4d6d80477c8cb32a952c6b0d7b79de377693291dc39	\N	127.0.0.1	2026-09-26 20:57:27.167963-05	f	2026-09-26 08:57:26.809516-05
185	1	f02ece806cd387b92b571a1decb567ecd5707f8e1d6f3d12cb295e041b018c13	\N	127.0.0.1	2026-09-26 21:30:29.729531-05	f	2026-09-26 09:30:29.376055-05
186	1	21aa48ccd8c448328ccab10f532f01fdc00bc7448a51d6a61416492df1ceabde	\N	127.0.0.1	2026-09-26 21:32:55.159237-05	f	2026-09-26 09:32:54.80859-05
187	1	b6f79434352d71ae0682f98aebf5afc8826481945330ae2a985bb7b551e8a026	\N	127.0.0.1	2026-09-26 22:19:33.151647-05	f	2026-09-26 10:19:32.854051-05
188	1	d795f6d90279d2557af378e79d9c2475c8d43303cb6b89f967d66d750b623652	\N	127.0.0.1	2026-09-26 22:20:07.197946-05	f	2026-09-26 10:20:07.0241-05
189	1	4250f5635ae19b007d343c08b9542b6029980eeb3b87f2efa5db86d3c63ded97	\N	127.0.0.1	2026-09-26 22:21:02.684751-05	f	2026-09-26 10:21:02.513092-05
190	1	405c8cc1e7bc2fa9f07de16ebf5e0f39e9e85d802d5c8927c5efb6b442170391	\N	127.0.0.1	2026-09-26 22:32:11.586974-05	f	2026-09-26 10:32:11.408356-05
191	1	57e8edc9c01e10fa03cb9b0edcce21c1a1df41008ecf584e1df563763c15d5e0	\N	127.0.0.1	2026-09-26 22:32:28.78329-05	f	2026-09-26 10:32:28.610611-05
192	1	6fc3cdcf6631a03cc3c7c7096137b31f0a9accb7c1d297b16e23db09b93bd7e4	\N	127.0.0.1	2026-09-26 22:32:38.876477-05	f	2026-09-26 10:32:38.702867-05
193	1	9ca7aad399e8bfb4096d217c8ec6a67af8816db2dcdce45de3f801b1276c2d46	\N	127.0.0.1	2026-09-26 22:32:50.570269-05	f	2026-09-26 10:32:50.286227-05
194	1	326890eedf1e352c0e214e948f66078bfc80f844861060ecef6db2ca62427a96	\N	127.0.0.1	2026-09-26 23:31:26.645212-05	f	2026-09-26 11:31:26.47313-05
195	1	498bfecd0bb1a5b2188aeadfa2625675c0a6687bff2283c7fea03f785672a25a	\N	127.0.0.1	2026-09-26 23:32:11.737395-05	f	2026-09-26 11:32:11.4183-05
196	1	bdfe5bcee712e7af987bc75f5fcaad9e626c5ce8b05caa213edd2bcadbbe8527	\N	127.0.0.1	2026-09-26 23:32:53.647437-05	f	2026-09-26 11:32:53.46988-05
197	1	78ba3db0bc234ddb7cab6647aadc8b519d61bc3e3b58dba4a1449faa87f1e5c2	\N	127.0.0.1	2026-09-26 23:33:45.111217-05	f	2026-09-26 11:33:44.844192-05
198	1	d20327bd7ae576ea5bdaadd9c515e7eff4e2485e2a8e76c3e5e2142366dca01f	\N	127.0.0.1	2026-09-26 23:34:31.365045-05	f	2026-09-26 11:34:31.192257-05
199	1	b0f827df821c96ed83390eb5bd7d8d784a4101bcc10f1228f691ce0ff7bf9ecd	\N	127.0.0.1	2026-09-26 23:35:19.988415-05	f	2026-09-26 11:35:19.814384-05
200	1	50bd1c523cf846a63196a5ee4b56308c3bd411b5b5f9aa07748c8248cf663780	\N	127.0.0.1	2026-09-26 23:53:01.297067-05	f	2026-09-26 11:53:01.045478-05
\.


--
-- Data for Name: tables; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.tables (id, venue_id, numero_mesa, electores_habiles, processed, requires_review, status, ocr_confidence, image_url, created_at, updated_at) FROM stdin;
1305	227	008824	250	f	f	pending	\N	\N	2026-09-18 04:35:16-05	2026-09-18 04:35:16-05
1306	570	008825	248	f	f	pending	\N	\N	2026-09-18 04:35:16-05	2026-09-22 16:44:39-05
1310	228	005177	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1314	228	005181	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1315	228	005182	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1316	228	005183	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1317	228	005184	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1318	228	005185	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1319	228	005186	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1320	228	005187	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1322	229	005189	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1323	229	005190	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1324	229	005191	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1325	229	005192	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1326	229	005193	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1327	229	005194	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1328	229	005195	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1329	229	005196	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1330	229	005197	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1331	230	005198	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1332	230	005199	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1333	230	005200	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1334	230	005201	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1335	230	005202	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1336	230	005203	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1337	230	005204	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1338	230	005205	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1339	230	005206	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1340	230	005207	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1341	230	005208	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1342	230	005209	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1343	230	005210	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1344	230	005211	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1345	231	005212	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1346	231	005213	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1347	231	005214	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1348	231	005215	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1349	231	005216	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1350	231	005217	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1351	231	005218	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1352	231	005219	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1353	231	005220	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1354	231	005221	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1355	231	005222	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1356	231	005223	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1357	231	005224	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1358	231	005225	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1359	231	005226	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1360	231	005227	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1361	231	005228	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1362	231	005229	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1363	231	005230	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1364	231	005231	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1365	231	005232	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1366	231	005233	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1367	231	005234	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1368	231	005235	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1369	231	005236	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1370	231	005237	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1371	231	005238	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1372	231	005239	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1373	231	005240	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1374	231	005241	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1375	231	005242	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1376	231	005243	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1377	231	005244	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1378	231	005245	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1379	232	005246	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1380	232	005247	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1381	232	005248	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1382	232	005249	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1383	232	005250	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1384	232	005251	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1385	232	005252	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1386	232	005253	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1387	232	005254	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1388	232	005255	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1389	232	005256	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1390	232	005257	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1391	232	005258	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1392	232	005259	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1393	232	005260	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1394	232	005261	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1395	232	005262	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1396	232	005263	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1397	232	005264	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1398	232	005265	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1399	232	005266	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1400	232	005267	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1321	229	005188	250	t	f	processed	\N	/storage/actas/15daf259701f440ab55dd5c4f96d60b4.avif	2026-09-22 16:44:38-05	2026-09-26 10:58:44.624101-05
1312	228	005179	250	t	f	processed	1	/storage/actas/08b286e6dfe640aa894af6fbad0950a7.avif	2026-09-22 16:44:38-05	2026-09-26 10:44:43.375693-05
1307	228	005174	250	t	f	processed	\N	/storage/actas/2dc9065d73a04ab89535efacdb12ab18.avif	2026-09-22 16:44:38-05	2026-09-26 10:34:27.216444-05
1401	232	005268	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1402	232	005269	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1403	232	005270	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1404	232	005271	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1405	232	005272	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1406	232	005273	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1407	232	005274	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1408	232	005275	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1409	232	005276	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1410	232	005277	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1411	232	005278	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1412	232	005279	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1413	232	005280	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1414	233	005281	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1415	233	005282	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1416	233	005283	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1417	233	005284	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1418	233	005285	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1419	233	005286	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1420	233	005287	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1421	233	005288	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1422	234	005289	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1423	234	005290	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1424	234	005291	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1425	234	005292	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1426	234	005293	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1427	234	005294	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1428	234	005295	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1429	234	005296	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1430	234	005297	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1431	234	005298	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1432	234	005299	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1433	234	005300	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1434	234	005301	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1435	234	005302	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1436	234	005303	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1437	235	005304	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1438	235	005305	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1439	235	005306	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1440	235	005307	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1441	235	005308	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1442	235	005309	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1443	235	005310	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1444	235	005311	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1445	235	005312	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1446	235	005313	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1447	235	005314	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1448	235	005315	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1449	235	005316	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1450	235	005317	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1451	235	005318	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1452	235	005319	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1453	235	005320	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1454	235	005321	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1455	235	005322	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1456	235	005323	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1457	235	005324	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1458	235	005325	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1459	235	005326	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1460	235	005327	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1461	235	005328	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1462	235	005329	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1463	235	005330	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1464	235	005331	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1465	235	005332	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1466	235	005333	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1467	235	005334	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1468	235	005335	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1469	235	005336	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1470	236	005337	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1471	236	005338	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1472	236	005339	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1473	236	005340	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1474	236	005341	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1475	236	005342	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1476	236	005343	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1477	236	005344	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1478	236	005345	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1479	236	005346	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1480	236	005347	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1481	236	005348	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1482	236	005349	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1483	236	005350	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1484	236	005351	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1485	236	005352	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1486	236	005353	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1487	236	005354	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1488	236	005355	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1489	236	005356	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1490	236	005357	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1491	236	005358	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1492	236	005359	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1493	236	005360	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1494	236	005361	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1495	237	005362	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1496	237	005363	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1497	237	005364	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1498	237	005365	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1499	237	005366	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1500	237	005367	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1501	237	005368	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1502	237	005369	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1503	237	005370	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1504	237	005371	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1505	237	005372	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1506	237	005373	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1507	237	005374	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1508	237	005375	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1509	238	005376	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1510	238	005377	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1511	238	005378	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1512	238	005379	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1513	238	005380	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1514	238	005381	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1515	238	005382	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1516	238	005383	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1517	238	005384	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1518	239	005385	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1519	239	005386	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1520	239	005387	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1521	239	005388	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1522	239	005389	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1523	239	005390	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1524	239	005391	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1525	239	005392	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1526	239	005393	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1527	239	005394	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1528	240	005395	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1529	240	005396	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1530	240	005397	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1531	240	005398	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1532	240	005399	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1533	240	005400	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1534	240	005401	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1535	240	005402	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1536	240	005403	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1537	240	005404	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1538	241	005405	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1539	241	005406	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1540	241	005407	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1541	241	005408	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1542	241	005409	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1543	241	005410	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1544	241	005411	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1545	241	005412	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1546	241	005413	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1547	241	005414	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1548	242	007927	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1549	242	007928	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1550	242	007929	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1551	242	007930	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1552	242	007931	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1553	242	007932	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1554	242	007933	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1555	242	007934	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1556	242	007935	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1557	242	007936	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1558	242	007937	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1559	242	007938	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1560	242	007939	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1561	243	007940	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1562	243	007941	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1563	243	007942	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1564	244	007943	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1565	244	007944	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1566	244	007945	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1567	244	007946	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1568	244	007947	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1569	244	007948	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1570	244	007949	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1571	244	007950	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1572	244	007951	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1573	244	007952	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1574	244	007953	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1575	244	007954	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1576	244	007955	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1577	245	007956	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1578	245	007957	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1579	245	007958	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1580	245	007959	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1581	245	007960	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1582	245	007961	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1583	245	007962	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1584	246	007963	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1585	246	007964	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1586	246	007965	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1587	246	007966	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1588	246	007967	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1589	247	007968	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1590	247	007969	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1591	248	007970	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1592	248	007971	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1593	248	007972	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1594	248	007973	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1595	248	007974	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1596	248	007975	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1597	248	007976	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1598	249	007977	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1599	249	007978	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1600	249	007979	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1601	249	007980	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1602	249	007981	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1603	249	007982	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1604	249	007983	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1605	250	007984	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1606	250	007985	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1607	250	007986	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1608	250	007987	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1609	250	007988	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1610	250	007989	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1611	250	007990	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1612	250	007991	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1613	251	007992	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1614	251	007993	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1615	251	007994	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1616	251	007995	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1617	251	007996	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1618	251	007997	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1619	251	007998	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1620	251	007999	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1621	251	008000	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1622	251	008001	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1623	251	008002	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1624	251	008003	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1625	251	008004	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1626	252	008005	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1627	252	008006	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1628	252	008007	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1629	252	008008	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1630	253	008012	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1631	253	008013	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1632	253	008014	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1633	253	008015	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1634	254	008016	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1635	254	008017	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1636	254	008018	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1637	254	008019	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1638	255	008020	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1639	255	008021	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1640	255	008022	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1641	255	008023	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1642	255	008024	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1643	255	008025	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1644	255	008026	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1645	255	008027	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1646	255	008028	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1647	255	008029	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1648	255	008030	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1649	255	008031	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1650	255	008032	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1651	255	008033	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1652	255	008034	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1653	255	008035	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1654	255	008036	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1655	255	008037	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1656	255	008038	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1657	255	008039	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1658	255	008040	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1659	255	008041	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1660	255	008130	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1661	255	008131	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1662	256	008042	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1663	256	008043	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1664	256	008044	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1665	256	008045	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1666	257	008046	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1667	257	008047	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1668	257	008048	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1669	257	008049	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1670	257	008050	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1671	257	008051	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1672	257	008052	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1673	257	008053	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1674	257	008054	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1675	257	008055	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1676	257	008056	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1677	257	008057	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1678	257	008058	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1679	257	008059	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1680	257	008060	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1681	257	008061	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1682	257	008062	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1683	257	008063	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1684	257	008064	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1685	257	008065	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1686	257	008066	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1687	257	008067	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1688	258	008068	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1689	258	008069	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1690	258	008070	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1691	258	008071	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1692	258	008072	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1693	258	008073	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1694	258	008074	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1695	258	008075	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1696	258	008076	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1697	259	008077	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1698	259	008078	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1699	259	008079	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1700	259	008080	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1701	259	008081	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1702	259	008082	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1703	259	008083	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1704	259	008084	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1705	259	008085	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1706	259	008086	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1707	260	008087	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1708	260	008088	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1709	260	008089	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1710	260	008090	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1711	260	008091	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1712	260	008092	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1713	260	008093	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1714	260	008094	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1715	260	008095	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1716	260	008096	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1717	260	008097	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1718	260	008098	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1719	261	008099	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1720	261	008100	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1721	261	008101	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1722	261	008102	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1723	261	008103	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1724	261	008104	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1725	262	008009	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1726	262	008010	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1727	262	008011	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1728	262	008105	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1729	262	008106	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1730	262	008107	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1731	262	008108	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1732	263	008109	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1733	263	008110	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1734	263	008111	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1735	263	008112	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1736	264	008113	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1737	264	008114	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1738	264	008115	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1739	264	008116	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1740	264	008117	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1741	264	008118	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1742	264	008119	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1743	264	008120	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1744	264	008121	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1745	264	008122	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1746	264	008123	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1747	265	008124	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1748	265	008125	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1749	265	008126	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1750	265	008127	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1751	265	008128	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1752	265	008129	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1753	266	008132	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1754	266	008133	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1755	266	008134	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1756	266	008135	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1757	266	008136	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1758	266	008137	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1759	266	008138	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1760	267	008139	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1761	267	008140	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1762	267	008141	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1763	267	008142	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1764	267	008143	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1765	267	008144	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1766	267	008145	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1767	267	008146	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1768	267	008147	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1769	267	008148	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1770	268	008149	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1771	268	008150	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1772	269	008151	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1773	269	008152	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1774	269	008153	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1775	269	008154	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1776	270	008155	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1777	270	008156	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1778	270	008157	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1779	270	008158	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1780	271	008159	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1781	271	008160	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1782	271	008161	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1783	272	008162	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1784	272	008163	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1785	273	008164	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1786	273	008165	250	f	f	pending	\N	\N	2026-09-22 16:44:38-05	2026-09-22 16:44:38-05
1787	274	005415	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1788	274	005416	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1789	274	005417	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1790	274	005418	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1791	274	005419	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1792	274	005420	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1793	274	005421	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1794	274	005422	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1795	274	005423	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1796	274	005424	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1797	274	005425	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1798	275	005426	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1799	275	005427	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1800	275	005428	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1801	275	005429	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1802	275	005430	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1803	275	005431	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1804	275	005432	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1805	275	005433	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1806	275	005434	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1807	275	005435	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1808	275	005436	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1809	275	005437	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1810	275	005438	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1811	275	005439	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1812	275	005440	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1813	275	005441	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1814	275	005442	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1815	276	005443	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1816	276	005444	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1817	276	005445	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1818	276	005446	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1819	276	005447	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1820	276	005448	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1821	276	005449	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1822	276	005450	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1823	276	005451	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1824	276	005452	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1825	276	005453	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1826	276	005454	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1827	276	005455	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1828	276	005456	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1829	276	005457	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1830	276	005458	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1831	276	005459	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1832	276	005460	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1833	276	005461	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1834	276	005462	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1835	276	005463	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1836	276	005464	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1837	276	005465	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1838	276	005466	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1839	276	005467	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1840	276	005468	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1841	277	005469	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1842	277	005470	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1843	277	005471	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1844	277	005472	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1845	277	005473	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1846	277	005474	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1847	277	005475	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1848	277	005476	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1849	278	005477	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1850	278	005478	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1851	278	005479	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1852	278	005480	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1853	278	005481	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1854	278	005482	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1855	278	005483	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1856	278	005484	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1857	278	005485	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1858	278	005486	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1859	278	005487	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1860	278	005488	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1861	278	005489	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1862	278	005490	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1863	278	005491	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1864	278	005492	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1865	278	005493	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1866	278	005494	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1867	278	005495	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1868	278	005496	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1869	278	005497	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1870	278	005498	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1871	278	005499	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1872	278	005500	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1873	279	005501	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1874	279	005502	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1875	279	005503	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1876	279	005504	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1877	279	005505	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1878	279	005506	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1879	279	005507	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1880	279	005508	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1881	279	005509	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1882	279	005510	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1883	279	005511	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1884	279	005512	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1885	279	005513	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1886	279	005514	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1887	279	005515	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1888	279	005516	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1889	279	005517	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1890	279	005518	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1891	280	005519	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1892	280	005520	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1893	280	005521	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1894	280	005522	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1895	280	005523	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1896	280	005524	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1897	280	005525	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1898	280	005526	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1899	281	005527	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1900	281	005528	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1901	281	005529	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1902	281	005530	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1903	281	005531	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1904	281	005532	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1905	282	005533	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1906	282	005534	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1907	282	005535	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1908	282	005536	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1909	282	005537	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1910	282	005538	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1911	282	005539	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1912	282	005540	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1913	283	005541	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1914	283	005542	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1915	283	005543	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1916	283	005544	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1917	284	005545	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1918	284	005546	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1919	284	005547	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1920	285	005548	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1921	285	005549	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1922	285	005550	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1923	286	005551	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1924	286	005552	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1925	287	005553	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1926	287	005554	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1927	287	005555	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1928	287	005556	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1929	288	005557	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1930	288	005558	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1931	288	005559	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1932	288	005560	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1933	288	005561	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1934	288	005562	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1935	288	005563	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1936	289	005564	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1937	289	005565	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1938	289	005566	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1939	290	005567	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1940	290	005568	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1941	290	005569	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1942	290	005570	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1943	290	005571	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1944	290	005572	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1945	290	005573	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1946	290	005574	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1947	291	005575	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1948	291	005576	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1949	291	005577	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1950	291	005578	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1951	292	005579	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1952	292	005580	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1953	292	005581	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1954	293	005582	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1955	293	005583	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1956	293	005584	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1957	293	005585	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1958	293	005586	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1959	293	005587	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1960	293	005588	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1961	294	005589	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1962	294	005590	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1963	294	005591	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1964	294	005592	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1965	294	005593	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1966	294	005594	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1967	294	005595	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1968	295	005596	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1969	295	005597	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1970	295	005598	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1971	295	005599	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1972	295	005600	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1973	295	005601	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1974	295	005602	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1975	295	005603	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1976	295	005604	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1977	296	005605	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1978	296	005606	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1979	296	005607	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1980	296	005608	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1981	297	005609	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1982	297	005610	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1983	297	005611	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1984	297	005612	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1985	298	005613	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1986	298	005614	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1987	298	005615	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1988	298	005616	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1989	298	005617	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1990	298	005618	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1991	298	005619	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1992	298	005620	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1993	299	005621	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1994	299	005622	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1995	299	005623	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1996	299	005624	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1997	299	005625	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1998	300	005626	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
1999	300	005627	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2000	300	005628	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2001	300	005629	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2002	300	005630	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2003	301	005631	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2004	301	005632	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2005	301	005633	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2006	301	005634	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2007	301	005635	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2008	301	005636	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2009	301	005637	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2010	301	005638	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2011	301	005639	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2012	301	005640	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2013	301	005641	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2014	301	005642	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2015	301	005643	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2016	301	005644	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2017	301	005645	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2018	301	005646	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2019	301	005647	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2020	301	005648	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2021	301	005649	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2022	301	005650	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2023	301	005651	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2024	301	005652	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2025	301	005653	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2026	301	005654	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2027	301	005655	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2028	301	005656	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2029	301	005657	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2030	302	005658	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2031	302	005659	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2032	302	005660	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2033	302	005661	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2034	302	005662	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2035	302	005663	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2036	302	005664	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2037	302	005665	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2038	302	005666	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2039	303	005667	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2040	303	005668	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2041	303	005669	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2042	303	005670	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2043	303	005671	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2044	303	005672	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2045	304	005673	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2046	304	005674	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2047	304	005675	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2048	305	005676	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2049	305	005677	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2050	305	005678	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2051	305	005679	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2052	306	005680	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2053	306	005681	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2054	306	005682	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2055	306	005683	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2056	306	005684	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2057	306	005685	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2058	306	005686	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2059	306	005687	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2060	306	005688	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2061	307	005689	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2062	307	005690	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2063	307	005691	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2064	307	005692	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2065	307	005693	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2066	307	005694	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2067	307	005695	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2068	307	005696	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2069	307	005697	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2070	307	005698	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2071	307	005699	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2072	307	005700	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2073	307	005701	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2074	307	005702	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2075	307	005703	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2076	308	005704	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2077	308	005705	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2078	308	005706	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2079	308	005707	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2080	308	005708	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2081	308	005709	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2082	308	005710	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2083	308	005711	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2084	308	005712	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2085	308	005713	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2086	308	005714	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2087	308	005715	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2088	308	005716	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2089	308	005717	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2090	308	005718	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2091	308	005719	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2092	308	005720	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2093	308	005721	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2094	308	005722	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2095	308	005723	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2096	308	005724	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2097	308	005725	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2098	308	005726	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2099	308	005727	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2100	308	005728	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2101	308	005729	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2102	308	005730	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2103	308	005731	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2104	308	005732	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2105	308	005733	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2106	308	005734	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2107	308	005735	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2108	308	005736	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2109	309	005737	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2110	309	005738	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2111	309	005739	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2112	309	005740	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2113	309	005741	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2114	309	005742	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2115	309	005743	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2116	309	005744	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2117	309	005745	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2118	309	005746	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2119	309	005747	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2120	309	005748	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2121	309	005749	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2122	309	005750	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2123	309	005751	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2124	309	005752	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2125	310	005753	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2126	310	005754	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2127	310	005755	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2128	310	005756	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2129	310	005757	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2130	310	005758	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2131	310	005759	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2132	311	005760	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2133	311	005761	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2134	311	005762	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2135	311	005763	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2136	311	005764	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2137	311	005765	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2138	311	005766	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2139	311	005767	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2140	311	005768	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2141	312	005769	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2142	312	005770	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2143	312	005771	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2144	312	005772	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2145	312	005773	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2146	312	005774	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2147	313	005775	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2148	313	005776	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2149	313	005777	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2150	313	005778	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2151	313	005779	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2152	313	005780	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2153	313	005781	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2154	313	005782	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2155	314	005783	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2156	314	005784	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2157	314	005785	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2158	314	005786	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2159	314	005787	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2160	314	005788	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2161	314	005789	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2162	314	005790	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2163	314	005791	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2164	314	005792	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2165	314	005793	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2166	314	005794	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2167	314	005795	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2168	314	005796	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2169	314	005797	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2170	314	005798	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2171	315	005799	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2172	315	005800	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2173	315	005801	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2174	315	005802	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2175	315	005803	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2176	315	005804	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2177	315	005805	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2178	315	005806	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2179	315	005807	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2180	315	005808	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2181	315	005809	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2182	315	005810	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2183	315	005811	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2184	315	005812	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2185	315	005813	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2186	315	005814	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2187	315	005815	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2188	315	005816	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2189	315	005817	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2190	315	005818	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2191	315	005819	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2192	316	005820	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2193	316	005821	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2194	316	005822	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2195	316	005823	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2196	316	005824	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2197	316	005825	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2198	316	005826	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2199	316	005827	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2200	316	005828	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2201	316	005829	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2202	316	005830	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2203	316	005831	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2204	316	005832	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2205	316	005833	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2206	316	005834	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2207	317	005835	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2208	317	005836	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2209	317	005837	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2210	317	005838	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2211	317	005839	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2212	317	005840	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2213	317	005841	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2214	317	005842	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2215	318	005843	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2216	318	005844	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2217	318	005845	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2218	318	005846	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2219	318	005847	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2220	318	005848	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2221	318	005849	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2222	318	005850	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2223	318	005851	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2224	318	005852	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2225	318	005853	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2226	318	005854	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2227	318	005855	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2228	318	005856	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2229	318	005857	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2230	319	005858	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2231	319	005859	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2232	319	005860	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2233	319	005861	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2234	319	005862	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2235	319	005863	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2236	320	005864	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2237	320	005865	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2238	320	005866	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2239	320	005867	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2240	320	005868	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2241	321	005869	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2242	321	005870	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2243	321	005871	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2244	321	005872	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2245	321	005873	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2246	321	005874	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2247	321	005875	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2248	321	005876	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2249	321	005877	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2250	321	005878	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2251	321	005879	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2252	321	005880	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2253	322	005881	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2254	322	005882	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2255	322	005883	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2256	322	005884	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2257	322	005885	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2258	322	005886	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2259	322	005887	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2260	322	005888	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2261	322	005889	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2262	322	005890	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2263	322	005891	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2264	322	005892	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2265	322	005893	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2266	323	005894	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2267	323	005895	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2268	323	005896	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2269	323	005897	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2270	323	005898	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2271	323	005899	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2272	323	005900	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2273	323	005901	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2274	323	005902	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2275	323	005903	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2276	323	005904	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2277	323	005905	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2278	323	005906	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2279	323	005907	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2280	323	005908	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2281	323	005909	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2282	324	005910	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2283	324	005911	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2284	324	005912	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2285	324	005913	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2286	324	005914	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2287	324	005915	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2288	324	005916	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2289	325	005917	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2290	325	005918	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2291	325	005919	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2292	325	005920	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2293	325	005921	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2294	325	005922	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2295	325	005923	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2296	325	005924	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2297	325	005925	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2298	325	005926	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2299	325	005927	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2300	326	005928	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2301	326	005929	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2302	326	005930	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2303	326	005931	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2304	326	005932	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2305	326	005933	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2306	326	005934	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2307	326	005935	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2308	326	005936	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2309	326	005937	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2310	326	005938	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2311	326	005939	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2312	326	005940	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2313	327	005941	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2314	327	005942	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2315	327	005943	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2316	327	005944	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2317	327	005945	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2318	327	005946	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2319	327	005947	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2320	328	005948	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2321	328	005949	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2322	328	005950	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2323	328	005951	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2324	328	005952	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2325	328	005953	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2326	328	005954	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2327	328	005955	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2328	328	005956	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2329	329	005957	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2330	329	005958	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2331	329	005959	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2332	329	005960	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2333	329	005961	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2334	329	005962	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2335	329	005963	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2336	330	005964	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2337	330	005965	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2338	330	005966	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2339	330	005967	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2340	330	005968	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2341	330	005969	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2342	330	005970	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2343	330	005971	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2344	330	005972	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2345	331	005973	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2346	331	005974	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2347	331	005975	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2348	331	005976	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2349	331	005977	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2350	331	005978	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2351	331	005979	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2352	331	005980	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2353	331	005981	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2354	331	005982	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2355	331	005983	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2356	331	005984	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2357	331	005985	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2358	331	005986	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2359	331	005987	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2360	331	005988	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2361	332	005989	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2362	332	005990	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2363	332	005991	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2364	332	005992	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2365	332	005993	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2366	332	005994	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2367	332	005995	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2368	332	005996	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2369	332	005997	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2370	333	005998	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2371	333	005999	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2372	333	006000	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2373	333	006001	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2374	333	006002	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2375	333	006003	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2376	333	006004	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2377	334	006005	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2378	334	006006	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2379	334	006007	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2380	334	006008	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2381	334	006009	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2382	334	006010	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2383	334	006011	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2384	334	006012	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2385	335	006013	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2386	335	006014	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2387	335	006015	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2388	335	006016	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2389	335	006017	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2390	335	006018	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2391	335	006019	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2392	335	006020	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2393	336	006021	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2394	336	006022	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2395	336	006023	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2396	336	006024	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2397	336	006025	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2398	336	006026	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2399	336	006027	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2400	336	006028	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2401	336	006029	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2402	336	006030	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2403	336	006031	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2404	336	006032	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2405	337	006033	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2406	337	006034	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2407	337	006035	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2408	337	006036	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2409	337	006037	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2410	337	006038	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2411	337	006039	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2412	337	006040	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2413	337	006041	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2414	337	006042	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2415	337	006043	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2416	337	006044	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2417	337	006045	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2418	338	006046	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2419	338	006047	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2420	338	006048	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2421	338	006049	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2422	338	006050	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2423	338	006051	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2424	339	006052	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2425	339	006053	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2426	339	006054	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2427	339	006055	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2428	339	006056	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2429	339	006057	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2430	339	006058	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2431	339	006059	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2432	339	006060	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2433	339	006061	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2434	339	006062	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2435	339	006063	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2436	339	006064	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2437	339	006065	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2438	339	006066	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2439	339	006067	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2440	340	006068	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2441	340	006069	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2442	340	006070	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2443	340	006071	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2444	340	006072	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2445	340	006073	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2446	340	006074	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2447	340	006075	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2448	340	006076	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2449	340	006077	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2450	340	006078	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2451	341	006079	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2452	341	006080	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2453	341	006081	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2454	341	006082	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2455	341	006083	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2456	341	006084	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2457	341	006085	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2458	341	006086	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2459	341	006087	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2460	341	006088	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2461	341	006089	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2462	341	006090	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2463	341	006091	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2464	342	006092	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2465	342	006093	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2466	342	006094	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2467	342	006095	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2468	342	006096	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2469	342	006097	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2470	342	006098	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2471	343	006099	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2472	343	006100	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2473	343	006101	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2474	343	006102	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2475	343	006103	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2476	343	006104	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2477	343	006105	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2478	343	006106	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2479	343	006107	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2480	343	006108	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2481	343	006109	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2482	343	006110	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2483	343	006111	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2484	344	006112	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2485	344	006113	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2486	344	006114	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2487	344	006115	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2488	344	006116	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2489	344	006117	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2490	344	006118	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2491	344	006119	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2492	344	006120	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2493	344	006121	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2494	345	006122	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2495	345	006123	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2496	345	006124	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2497	345	006125	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2498	345	006126	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2499	345	006127	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2500	345	006128	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2501	346	006129	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2502	346	006130	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2503	346	006131	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2504	346	006132	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2505	346	006133	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2506	347	006134	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2507	347	006135	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2508	347	006136	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2509	347	006137	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2510	347	006138	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2511	347	006139	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2512	347	006140	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2513	347	006141	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2514	348	006142	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2515	348	006143	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2516	348	006144	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2517	348	006145	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2518	348	006146	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2519	348	006147	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2520	348	006148	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2521	348	006149	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2522	349	006150	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2523	349	006151	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2524	349	006152	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2525	349	006153	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2526	349	006154	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2527	349	006155	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2528	349	006156	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2529	349	006157	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2530	349	006158	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2531	349	006159	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2532	349	006160	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2533	350	006161	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2534	350	006162	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2535	350	006163	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2536	350	006164	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2537	350	006165	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2538	350	006166	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2539	350	006167	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2540	350	006168	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2541	350	006169	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2542	350	006170	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2543	350	006171	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2544	350	006172	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2545	351	006173	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2546	351	006174	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2547	351	006175	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2548	351	006176	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2549	351	006177	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2550	351	006178	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2551	352	006179	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2552	352	006180	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2553	352	006181	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2554	352	006182	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2555	352	006183	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2556	352	006184	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2557	352	006185	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2558	352	006186	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2559	352	006187	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2560	352	006188	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2561	352	006189	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2562	352	006190	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2563	352	006191	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2564	352	006192	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2565	352	006193	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2566	352	006194	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2567	353	006195	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2568	353	006196	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2569	353	006197	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2570	353	006198	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2571	353	006199	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2572	353	006200	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2573	353	006201	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2574	354	006202	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2575	354	006203	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2576	354	006204	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2577	354	006205	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2578	354	006206	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2579	354	006207	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2580	354	006208	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2581	354	006209	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2582	354	006210	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2583	354	006211	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2584	354	006212	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2585	355	006213	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2586	355	006214	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2587	355	006215	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2588	355	006216	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2589	355	006217	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2590	355	006218	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2591	355	006219	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2592	355	006220	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2593	355	006221	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2594	355	006222	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2595	355	006223	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2596	355	006224	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2597	355	006225	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2598	355	006226	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2599	355	006227	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2600	355	006228	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2601	356	006229	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2602	356	006230	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2603	357	006231	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2604	357	006232	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2605	357	006233	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2606	357	006234	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2607	357	006235	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2608	357	006236	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2609	358	006237	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2610	358	006238	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2611	358	006239	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2612	358	006240	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2613	359	006241	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2614	359	006242	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2615	359	006243	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2616	359	006244	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2617	360	007785	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2618	360	007786	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2619	360	007787	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2620	360	007788	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2621	360	007789	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2622	360	007790	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2623	360	007791	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2624	360	007792	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2625	360	007793	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2626	360	007794	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2627	361	007795	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2628	361	007796	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2629	361	007797	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2630	361	007798	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2631	361	007799	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2632	361	007800	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2633	361	007801	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2634	361	007802	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2635	361	007803	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2636	361	007804	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2637	361	007805	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2638	362	007806	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2639	362	007807	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2640	362	007808	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2641	362	007809	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2642	362	007810	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2643	362	007811	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2644	362	007812	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2645	362	007813	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2646	362	007814	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2647	362	007815	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2648	362	007816	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2649	362	007817	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2650	362	007818	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2651	362	007819	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2652	362	007820	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2653	363	007821	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2654	363	007822	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2655	363	007823	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2656	363	007824	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2657	363	007825	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2658	363	007826	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2659	363	007827	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2660	363	007828	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2661	364	007829	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2662	364	007830	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2663	364	007831	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2664	364	007832	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2665	364	007833	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2666	364	007834	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2667	364	007835	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2668	364	007836	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2669	364	007837	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2670	364	007838	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2671	364	007839	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2672	364	007840	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2673	364	007841	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2674	364	007842	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2675	364	007843	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2676	364	007844	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2677	364	007845	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2678	364	007846	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2679	364	007847	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2680	364	007848	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2681	364	007849	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2682	364	007850	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2683	365	007851	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2684	365	007852	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2685	365	007853	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2686	365	007854	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2687	365	007855	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2688	365	007856	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2689	365	007857	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2690	365	007858	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2691	365	007859	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2692	365	007860	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2693	365	007861	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2694	365	007862	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2695	365	007863	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2696	365	007864	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2697	365	007865	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2698	365	007866	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2699	365	007867	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2700	365	007868	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2701	365	007869	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2702	365	007870	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2703	365	007871	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2704	365	007872	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2705	365	007873	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2706	365	007874	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2707	365	007875	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2708	366	007876	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2709	366	007877	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2710	366	007878	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2711	366	007879	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2712	366	007880	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2713	366	007881	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2714	366	007882	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2715	366	007883	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2716	366	007884	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2717	366	007885	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2718	366	007886	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2719	366	007887	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2720	366	007888	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2721	366	007889	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2722	366	007890	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2723	366	007891	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2724	366	007892	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2725	366	007893	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2726	366	007894	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2727	366	007895	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2728	366	007896	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2729	366	007897	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2730	367	007898	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2731	367	007899	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2732	367	007900	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2733	367	007901	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2734	367	007902	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2735	367	007903	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2736	367	007904	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2737	367	007905	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2738	367	007906	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2739	367	007907	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2740	367	007908	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2741	367	007909	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2742	367	007910	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2743	367	007911	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2744	368	007912	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2745	368	007913	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2746	368	007914	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2747	368	007915	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2748	368	007916	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2749	369	007917	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2750	369	007918	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2751	369	007919	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2752	369	007920	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2753	369	007921	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2754	370	007922	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2755	370	007923	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2756	370	007924	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2757	370	007925	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2758	370	007926	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2759	371	900853	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2760	371	900854	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2761	371	900855	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2762	371	900856	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2763	372	006245	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2764	372	006246	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2765	372	006247	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2766	372	006248	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2767	372	006249	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2768	372	006250	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2769	372	006251	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2770	372	006252	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2771	372	006253	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2772	372	006254	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2773	372	006255	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2774	372	006256	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2775	372	006257	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2776	372	006258	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2777	372	006259	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2778	372	006260	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2779	373	006261	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2780	373	006262	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2781	373	006263	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2782	373	006264	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2783	373	006265	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2784	373	006266	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2785	373	006267	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2786	373	006268	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2787	373	006269	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2788	373	006270	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2789	373	006271	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2790	374	006272	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2791	374	006273	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2792	374	006274	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2793	374	006275	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2794	374	006276	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2795	374	006277	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2796	374	006278	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2797	374	006279	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2798	374	006280	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2799	374	006281	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2800	374	006282	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2801	374	006283	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2802	374	006284	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2803	375	006285	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2804	375	006286	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2805	375	006287	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2806	375	006288	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2807	375	006289	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2808	375	006290	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2809	375	006291	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2810	375	006292	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2811	375	006293	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2812	375	006294	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2813	375	006295	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2814	375	006296	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2815	375	006297	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2816	375	006298	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2817	376	006299	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2818	376	006300	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2819	376	006301	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2820	376	006302	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2821	376	006303	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2822	376	006304	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2823	376	006305	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2824	376	006306	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2825	376	006307	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2826	376	006308	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2827	377	006309	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2828	377	006310	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2829	377	006311	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2830	377	006312	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2831	377	006313	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2832	377	006314	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2833	377	006315	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2834	377	006316	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2835	377	006317	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2836	377	006318	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2837	377	006319	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2838	377	006320	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2839	377	006321	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2840	377	006322	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2841	377	006323	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2842	377	006324	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2843	378	006325	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2844	378	006326	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2845	378	006327	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2846	378	006328	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2847	378	006329	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2848	378	006330	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2849	379	006331	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2850	379	006332	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2851	379	006333	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2852	379	006334	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2853	379	006335	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2854	379	006336	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2855	379	006337	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2856	379	006338	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2857	380	007606	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2858	380	007607	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2859	380	007608	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2860	380	007609	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2861	380	007610	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2862	380	007611	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2863	380	007612	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2864	380	007613	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2865	380	007614	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2866	380	007615	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2867	380	007616	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2868	380	007617	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2869	380	007618	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2870	380	007619	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2871	380	007620	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2872	380	007621	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2873	380	007622	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2874	380	007623	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2875	380	007624	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2876	380	007625	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2877	380	007626	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2878	380	007627	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2879	380	007628	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2880	380	007629	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2881	380	007630	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2882	380	007631	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2883	380	007632	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2884	380	007633	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2885	380	007634	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2886	380	007635	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2887	380	007636	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2888	380	007637	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2889	380	007638	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2890	380	007639	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2891	380	007640	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2892	381	007641	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2893	381	007642	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2894	381	007643	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2895	381	007644	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2896	381	007645	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2897	381	007646	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2898	381	007647	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2899	381	007648	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2900	381	007649	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2901	381	007650	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2902	381	007651	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2903	381	007652	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2904	381	007653	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2905	382	007654	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2906	382	007655	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2907	382	007656	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2908	382	007657	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2909	382	007658	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2910	382	007659	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2911	382	007660	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2912	382	007661	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2913	382	007662	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2914	382	007663	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2915	382	007664	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2916	382	007665	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2917	382	007666	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2918	383	007667	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2919	383	007668	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2920	383	007669	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2921	383	007670	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2922	383	007671	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2923	383	007672	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2924	383	007673	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2925	383	007674	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2926	383	007675	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2927	383	007676	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2928	383	007677	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2929	383	007678	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2930	383	007679	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2931	384	007680	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2932	384	007681	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2933	384	007682	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2934	384	007683	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2935	384	007684	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2936	384	007685	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2937	384	007686	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2938	384	007687	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2939	384	007688	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2940	384	007689	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2941	384	007690	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2942	384	007691	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2943	384	007692	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2944	384	007693	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2945	384	007694	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2946	385	007695	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2947	385	007696	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2948	385	007697	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2949	385	007698	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2950	385	007699	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2951	385	007700	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2952	385	007701	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2953	385	007702	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2954	385	007703	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2955	385	007704	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2956	386	007705	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2957	386	007706	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2958	386	007707	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2959	386	007708	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2960	386	007709	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2961	386	007710	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2962	386	007711	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2963	386	007712	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2964	386	007713	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2965	386	007714	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2966	386	007715	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2967	386	007716	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2968	386	007717	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2969	386	007718	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2970	386	007719	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2971	386	007720	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2972	386	007721	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2973	386	007722	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2974	387	007723	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2975	387	007724	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2976	387	007725	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2977	387	007726	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2978	387	007727	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2979	387	007728	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2980	387	007729	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2981	387	007730	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2982	387	007731	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2983	387	007732	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2984	387	007733	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2985	387	007734	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2986	387	007735	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2987	388	007736	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2988	388	007737	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2989	388	007738	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2990	388	007739	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2991	388	007740	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2992	388	007741	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2993	388	007742	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2994	388	007743	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2995	388	007744	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2996	388	007745	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2997	388	007746	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2998	388	007747	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
2999	388	007748	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3000	389	007749	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3001	389	007750	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3002	389	007751	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3003	389	007752	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3004	389	007753	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3005	389	007754	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3006	389	007755	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3007	389	007756	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3008	389	007757	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3009	389	007758	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3010	389	007759	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3011	389	007760	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3012	389	007761	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3013	389	007762	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3014	389	007763	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3015	389	007764	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3016	389	007765	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3017	389	007766	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3018	389	007767	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3019	389	007768	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3020	389	007769	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3021	389	007770	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3022	389	007771	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3023	389	007772	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3024	389	007773	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3025	389	007774	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3026	390	007775	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3027	390	007776	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3028	390	007777	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3029	390	007778	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3030	390	007779	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3031	390	007780	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3032	390	007781	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3033	390	007782	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3034	390	007783	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3035	390	007784	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3036	391	006339	250	t	f	processed	\N	\N	2026-09-22 16:44:39-05	2026-09-23 02:05:24-05
3037	391	006340	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3038	391	006341	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3039	391	006342	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3040	391	006343	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3041	391	006344	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3042	392	006345	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3043	392	006346	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3044	392	006347	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3045	392	006348	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3046	392	006349	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3047	393	006350	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3048	393	006351	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3049	393	006352	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3050	393	006353	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3051	393	006354	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3052	394	006355	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3053	394	006356	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3054	394	006357	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3055	394	006358	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3056	394	006359	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3057	394	006360	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3058	394	006361	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3059	394	006362	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3060	394	006363	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3061	394	006364	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3062	394	006365	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3063	394	006366	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3064	394	006367	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3065	394	006368	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3066	394	006369	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3067	394	006370	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3068	394	006371	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3069	395	006372	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3070	395	006373	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3071	395	006374	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3072	395	006375	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3073	395	006376	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3074	395	006377	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3075	395	006378	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3076	396	006379	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3077	396	006380	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3078	396	006381	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3079	396	006382	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3080	396	006383	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3081	396	006384	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3082	396	006385	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3083	396	006386	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3084	397	006387	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3085	397	006388	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3086	397	006389	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3087	397	006390	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3088	397	006391	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3089	397	006392	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3090	397	006393	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3091	397	006394	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3092	397	006395	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3093	397	006396	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3094	397	006397	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3095	397	006398	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3096	398	006399	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3097	398	006400	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3098	398	006401	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3099	398	006402	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3100	398	006403	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3101	398	006404	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3102	398	006405	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3103	398	006406	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3104	398	006407	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3105	398	006408	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3106	398	006409	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3107	399	006410	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3108	399	006411	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3109	399	006412	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3110	400	006413	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3111	400	006414	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3112	400	006415	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3113	401	006416	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3114	401	006417	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3115	401	006418	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3116	402	006419	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3117	402	006420	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3118	402	006421	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3119	402	006422	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3120	402	006423	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3121	402	006424	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3122	402	006425	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3123	402	006426	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3124	402	006427	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3125	402	006428	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3126	402	006429	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3127	402	006430	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3128	402	006431	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3129	402	006432	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3130	402	006433	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3131	403	006434	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3132	403	006435	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3133	403	006436	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3134	403	006437	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3135	403	006438	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3136	403	006439	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3137	404	006440	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3138	404	006441	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3139	404	006442	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3140	404	006443	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3141	405	006444	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3142	405	006445	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3143	405	006446	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3144	405	006447	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3145	405	006448	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3146	405	006449	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3147	405	006450	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3148	405	006451	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3149	405	006452	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3150	406	006453	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3151	406	006454	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3152	406	006455	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3153	406	006456	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3154	406	006457	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3155	406	006458	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3156	406	006459	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3157	407	006460	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3158	407	006461	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3159	407	006462	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3160	408	006463	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3161	408	006464	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3162	408	006465	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3163	408	006466	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3164	408	006467	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3165	409	006468	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3166	409	006469	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3167	409	006470	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3168	409	006471	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3169	409	006472	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3170	409	006473	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3171	409	006474	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3172	410	006475	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3173	410	006476	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3174	410	006477	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3175	410	006478	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3176	410	006479	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3177	410	006480	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3178	411	006481	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3179	411	006482	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3180	411	006483	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3181	411	006484	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3182	411	006485	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3183	411	006486	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3184	411	006487	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3185	411	006488	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3186	411	006489	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3187	412	006490	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3188	412	006491	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3189	412	006492	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3190	412	006493	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3191	412	006494	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3192	412	006495	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3193	412	006496	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3194	412	006497	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3195	412	006498	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3196	413	006499	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3197	413	006500	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3198	413	006501	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3199	413	006502	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3200	413	006503	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3201	413	006504	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3202	413	006505	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3203	413	006506	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3204	414	006507	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3205	414	006508	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3206	414	006509	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3207	414	006510	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3208	414	006511	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3209	414	006512	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3210	414	006513	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3211	414	006514	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3212	415	006515	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3213	415	006516	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3214	415	006517	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3215	415	006518	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3216	415	006519	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3217	415	006520	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3218	415	006521	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3219	416	006522	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3220	416	006523	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3221	417	006524	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3222	417	006525	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3223	417	006526	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3224	417	006527	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3225	418	006528	250	t	f	processed	\N	\N	2026-09-22 16:44:39-05	2026-09-25 02:19:01-05
3226	418	006529	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3227	418	006530	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3228	418	006531	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3229	418	006532	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3230	418	006533	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3231	418	006534	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3232	418	006535	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3233	418	006536	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3234	418	006537	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3235	419	006538	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3236	419	006539	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3237	419	006540	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3238	419	006541	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3239	419	006542	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3240	419	006543	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3241	419	006544	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3242	419	006545	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3243	419	006546	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3244	420	006547	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3245	420	006548	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3246	420	006549	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3247	420	006550	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3248	420	006551	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3249	420	006552	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3250	421	006553	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3251	421	006554	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3252	421	006555	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3253	421	006556	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3254	421	006557	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3255	421	006558	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3256	421	006559	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3257	421	006560	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3258	421	006561	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3259	421	006562	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3260	421	006563	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3261	421	006564	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3262	421	006565	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3263	421	006566	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3264	421	006567	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3265	421	006568	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3266	421	006569	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3267	421	006570	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3268	421	006571	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3269	421	006572	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3270	421	006573	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3271	421	006574	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3272	421	006575	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3273	421	006576	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3274	422	006577	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3275	422	006578	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3276	422	006579	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3277	422	006580	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3278	422	006581	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3279	422	006582	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3280	422	006583	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3281	422	006584	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3282	422	006585	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3283	422	006586	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3284	422	006587	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3285	422	006588	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3286	422	006589	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3287	423	006590	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3288	423	006591	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3289	423	006592	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3290	423	006593	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3291	423	006594	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3292	423	006595	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3293	423	006596	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3294	423	006597	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3295	423	006598	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3296	423	006599	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3297	423	006600	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3298	423	006601	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3299	423	006602	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3300	423	006603	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3301	424	006604	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3302	424	006605	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3303	424	006606	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3304	424	006607	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3305	424	006608	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3306	424	006609	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3307	424	006610	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3308	424	006611	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3309	425	006612	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3310	425	006613	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3311	425	006614	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3312	425	006615	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3313	425	006616	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3314	425	006617	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3315	425	006618	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3316	425	006619	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3317	425	006620	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3318	425	006621	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3319	425	006622	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3320	425	006623	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3321	425	006624	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3322	425	006625	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3323	425	006626	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3324	425	006627	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3325	425	006628	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3326	425	006629	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3327	425	006630	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3328	425	006631	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3329	425	006632	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3330	425	006633	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3331	426	006634	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3332	426	006635	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3333	426	006636	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3334	426	006637	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3335	426	006638	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3336	426	006639	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3337	426	006640	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3338	426	006641	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3339	426	006642	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3340	426	006643	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3341	426	006644	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3342	426	006645	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3343	426	006646	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3344	426	006647	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3345	426	006648	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3346	426	006649	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3347	426	006650	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3348	426	006651	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3349	427	006652	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3350	427	006653	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3351	427	006654	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3352	427	006655	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3353	427	006656	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3354	427	006657	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3355	427	006658	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3356	427	006659	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3357	427	006660	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3358	427	006661	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3359	427	006662	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3360	427	006663	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3361	427	006664	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3362	427	006665	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3363	427	006666	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3364	427	006667	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3365	427	006668	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3366	427	006669	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3367	427	006670	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3368	427	006671	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3369	427	006672	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3370	428	006673	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3371	428	006674	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3372	428	006675	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3373	428	006676	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3374	428	006677	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3375	428	006678	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3376	429	006679	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3377	429	006680	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3378	429	006681	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3379	429	006682	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3380	429	006683	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3381	429	006684	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3382	429	006685	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3383	429	006686	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3384	429	006687	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3385	429	006688	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3386	429	006689	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3387	429	006690	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3388	429	006691	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3389	429	006692	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3390	429	006693	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3391	429	006694	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3392	429	006695	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3393	429	006696	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3394	429	006697	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3395	429	006698	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3396	429	006699	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3397	429	006700	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3398	430	006701	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3399	430	006702	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3400	430	006703	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3401	430	006704	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3402	430	006705	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3403	430	006706	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3404	430	006707	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3405	430	006708	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3406	430	006709	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3407	430	006710	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3408	431	006711	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3409	431	006712	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3410	431	006713	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3411	431	006714	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3412	431	006715	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3413	431	006716	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3414	432	006717	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3415	432	006718	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3416	432	006719	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3417	432	006720	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3418	432	006721	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3419	432	006722	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3420	432	006723	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3421	432	006724	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3422	432	006725	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3423	432	006726	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3424	432	006727	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3425	433	006728	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3426	433	006729	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3427	433	006730	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3428	433	006731	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3429	433	006732	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3430	433	006733	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3431	433	006734	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3432	433	006735	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3433	434	006736	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3434	434	006737	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3435	434	006738	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3436	434	006739	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3437	434	006740	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3438	434	006741	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3439	434	006742	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3440	435	006743	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3441	435	006744	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3442	435	006745	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3443	435	006746	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3444	435	006747	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3445	435	006748	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3446	435	006749	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3447	435	006750	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3448	436	006751	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3449	436	006752	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3450	436	006753	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3451	436	006754	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3452	436	006755	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3453	436	006756	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3454	436	006757	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3455	436	006758	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3456	436	006759	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3457	436	006760	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3458	436	006761	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3459	436	006762	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3460	436	006763	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3461	436	006764	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3462	437	006765	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3463	437	006766	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3464	437	006767	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3465	437	006768	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3466	437	006769	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3467	437	006770	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3468	437	006771	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3469	437	006772	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3470	437	006773	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3471	437	006774	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3472	437	006775	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3473	437	006776	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3474	437	006777	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3475	437	006778	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3476	437	006779	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3477	438	006780	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3478	438	006781	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3479	438	006782	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3480	438	006783	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3481	438	006784	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3482	438	006785	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3483	438	006786	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3484	438	006787	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3485	438	006788	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3486	439	006789	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3487	439	006790	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3488	439	006791	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3489	439	006792	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3490	439	006793	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3491	439	006794	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3492	439	006795	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3493	439	006796	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3494	439	006797	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3495	439	006798	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3496	439	006799	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3497	439	006800	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3498	440	006801	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3499	440	006802	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3500	440	006803	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3501	440	006804	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3502	440	006805	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3503	440	006806	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3504	440	006807	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3505	440	006808	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3506	440	006809	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3507	441	006810	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3508	441	006811	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3509	441	006812	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3510	441	006813	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3511	441	006814	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3512	441	006815	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3513	442	006816	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3514	442	006817	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3515	442	006818	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3516	442	006819	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3517	442	006820	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3518	442	006821	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3519	442	006822	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3520	442	006823	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3521	442	006824	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3522	442	006825	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3523	443	006826	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3524	443	006827	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3525	443	006828	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3526	443	006829	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3527	443	006830	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3528	443	006831	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3529	444	006832	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3530	444	006833	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3531	444	006834	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3532	444	006835	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3533	444	006836	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3534	444	006837	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3535	444	006838	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3536	444	006839	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3537	445	006840	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3538	445	006841	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3539	445	006842	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3540	445	006843	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3541	445	006844	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3542	445	006845	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3543	445	006846	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3544	445	006847	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3545	445	006848	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3546	445	006849	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3547	446	006850	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3548	446	006851	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3549	446	006852	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3550	446	006853	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3551	446	006854	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3552	446	006855	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3553	446	006856	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3554	446	006857	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3555	446	006858	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3556	446	006859	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3557	446	006860	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3558	446	006861	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3559	446	006862	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3560	446	006863	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3561	446	006864	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3562	446	006865	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3563	446	006866	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3564	446	006867	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3565	447	006868	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3566	447	006869	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3567	447	006870	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3568	447	006871	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3569	447	006872	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3570	447	006873	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3571	447	006874	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3572	447	006875	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3573	447	006876	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3574	447	006877	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3575	447	006878	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3576	447	006879	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3577	448	006880	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3578	448	006881	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3579	448	006882	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3580	448	006883	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3581	448	006884	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3582	448	006885	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3583	448	006886	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3584	448	006887	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3585	448	006888	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3586	448	006889	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3587	448	006890	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3588	448	006891	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3589	448	006892	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3590	448	006893	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3591	448	006894	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3592	448	006895	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3593	448	006896	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3594	449	006897	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3595	449	006898	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3596	449	006899	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3597	449	006900	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3598	449	006901	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3599	449	006902	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3600	449	006903	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3601	449	006904	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3602	449	006905	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3603	449	006906	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3604	449	006907	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3605	450	006908	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3606	450	006909	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3607	450	006910	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3608	450	006911	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3609	450	006912	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3610	450	006913	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3611	450	006914	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3612	450	006915	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3613	451	006916	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-23 02:31:27-05
3614	451	006917	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3615	452	006918	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3616	452	006919	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3617	453	006920	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3618	453	006921	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3619	453	006922	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3620	453	006923	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3621	453	006924	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3622	454	006927	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3623	454	006928	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3624	454	006929	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3625	454	006930	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3626	455	006925	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3627	455	006926	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3628	456	006931	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3629	456	006932	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3630	457	006933	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3631	457	006934	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3632	458	006935	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3633	458	006936	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3634	458	006937	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3635	458	006938	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3636	458	006939	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3637	458	006940	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3638	458	006941	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3639	458	006942	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3640	458	006943	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3641	458	006944	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3642	458	006945	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3643	458	006946	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3644	458	006947	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3645	458	006948	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3646	458	006949	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3647	459	006950	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3648	460	006951	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3649	460	006952	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3650	460	006953	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3651	460	006954	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3652	460	006955	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3653	461	006956	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3654	461	006957	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3655	461	006958	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3656	461	006959	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3657	461	006960	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3658	461	006961	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3659	462	006962	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3660	462	006963	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3661	462	006964	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3662	462	006965	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3663	462	006966	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3664	462	006967	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3665	463	006968	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3666	463	006969	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3667	463	006970	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3668	463	006971	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3669	463	006972	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3670	463	006973	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3671	463	006974	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3672	463	006975	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3673	463	006976	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3674	463	006977	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3675	463	006978	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3676	463	006979	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3677	464	006980	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3678	464	006981	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3679	464	006982	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3680	464	006983	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3681	464	006984	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3682	464	006985	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3683	464	006986	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3684	465	006987	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3685	465	006988	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3686	465	006989	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3687	465	006990	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3688	465	006991	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3689	465	006992	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3690	465	006993	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3691	466	006994	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3692	466	006995	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3693	466	006996	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3694	467	006997	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3695	467	006998	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3696	467	006999	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3697	467	007000	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3698	467	007001	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3699	467	007002	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3700	467	007003	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3701	467	007004	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3702	467	007005	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3703	467	007006	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3704	467	007007	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3705	467	007008	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3706	467	007009	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3707	467	007010	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3708	467	007011	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3709	467	007012	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3710	467	007013	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3711	467	007014	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3712	467	007015	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3713	467	007016	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3714	467	007017	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3715	468	007018	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3716	468	007019	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3717	468	007020	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3718	468	007021	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3719	468	007022	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3720	468	007023	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3721	468	007024	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3722	468	007025	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3723	469	007026	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3724	469	007027	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3725	469	007028	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3726	469	007029	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3727	469	007030	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3728	469	007031	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3729	469	007032	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3730	469	007033	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3731	469	007034	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3732	469	007035	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3733	469	007036	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3734	469	007037	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3735	469	007038	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3736	469	007039	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3737	469	007040	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3738	469	007041	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3739	470	007042	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3740	470	007043	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3741	470	007044	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3742	470	007045	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3743	471	007046	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3744	471	007047	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3745	471	007048	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3746	471	007049	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3747	471	007050	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3748	471	007051	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3749	471	007052	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3750	472	007053	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3751	472	007054	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3752	472	007055	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3753	473	007056	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3754	473	007057	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3755	473	007058	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3756	473	007059	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3757	473	007060	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3758	473	007061	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3759	473	007062	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3760	473	007063	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3761	473	007064	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3762	474	007065	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3763	474	007066	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3764	474	007067	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3765	474	007068	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3766	474	007069	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3767	474	007070	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3768	474	007071	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3769	474	007072	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3770	475	007073	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3771	475	007074	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3772	475	007075	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3773	475	007076	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3774	475	007077	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3775	476	007078	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3776	476	007079	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3777	476	007080	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3778	476	007081	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3779	476	007082	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3780	476	007083	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3781	476	007084	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3782	476	007085	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3783	476	007086	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3784	476	007087	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3785	476	007088	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3786	476	007089	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3787	476	007090	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3788	476	007091	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3789	476	007092	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3790	476	007093	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3791	476	007094	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3792	476	007095	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3793	476	007096	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3794	476	007097	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3795	477	007098	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3796	477	007099	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3797	477	007100	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3798	477	007101	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3799	477	007102	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3800	477	007103	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3801	477	007104	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3802	477	007105	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3803	477	007106	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3804	477	007107	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3805	477	007108	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3806	477	007109	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3807	478	007110	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3808	478	007111	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3809	478	007112	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3810	478	007113	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3811	478	007114	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3812	478	007115	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3813	478	007116	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3814	478	007117	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3815	478	007118	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3816	478	007119	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3817	478	007120	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3818	478	007121	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3819	478	007122	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3820	478	007123	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3821	478	007124	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3822	478	007125	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3823	478	007126	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3824	478	007127	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3825	478	007128	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3826	478	007129	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3827	478	007130	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3828	478	007131	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3829	478	007132	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3830	478	007133	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3831	478	007134	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3832	479	007135	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3833	479	007136	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3834	479	007137	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3835	479	007138	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3836	479	007139	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3837	479	007140	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3838	479	007141	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3839	479	007142	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3840	480	007143	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3841	480	007144	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3842	480	007145	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3843	480	007146	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3844	480	007147	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3845	480	007148	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3846	480	007149	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3847	480	007150	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3848	481	007151	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3849	481	007152	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3850	481	007153	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3851	481	007154	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3852	481	007155	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3853	481	007156	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3854	481	007157	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3855	481	007158	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3856	482	007159	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3857	482	007160	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3858	482	007161	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3859	482	007162	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3860	482	007163	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3861	482	007164	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3862	482	007165	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3863	482	007166	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3864	483	007167	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3865	483	007168	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3866	483	007169	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3867	483	007170	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3868	483	007171	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3869	483	007172	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3870	483	007173	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3871	483	007174	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3872	483	007175	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3873	483	007176	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3874	483	007177	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3875	483	007178	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3876	483	007179	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3877	483	007180	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3878	483	007181	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3879	484	007182	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3880	484	007183	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3881	484	007184	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3882	484	007185	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3883	484	007186	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3884	484	007187	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3885	484	007188	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3886	484	007189	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3887	484	007190	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3888	484	007191	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3889	484	007192	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3890	484	007193	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3891	484	007194	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3892	484	007195	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3893	484	007196	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3894	484	007197	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3895	484	007198	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3896	484	007199	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3897	484	007200	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3898	484	007201	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3899	484	007202	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3900	485	007203	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3901	485	007204	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3902	485	007205	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3903	485	007206	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3904	485	007207	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3905	485	007208	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3906	485	007209	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3907	485	007210	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3908	485	007211	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3909	485	007212	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3910	485	007213	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3911	485	007214	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3912	485	007215	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3913	485	007216	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3914	485	007217	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3915	485	007218	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3916	485	007219	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3917	485	007220	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3918	485	007221	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3919	485	007222	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3920	485	007223	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3921	485	007224	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3922	486	007225	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3923	486	007226	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3924	486	007227	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3925	486	007228	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3926	486	007229	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3927	486	007230	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3928	486	007231	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3929	486	007232	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3930	486	007233	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3931	486	007234	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3932	486	007235	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3933	486	007236	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3934	486	007237	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3935	486	007238	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3936	486	007239	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3937	486	007240	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3938	487	007241	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3939	487	007242	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3940	487	007243	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3941	487	007244	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3942	487	007245	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3943	487	007246	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3944	487	007247	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3945	488	007248	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3946	488	007249	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3947	488	007250	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3948	488	007251	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3949	488	007252	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3950	489	007253	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3951	489	007254	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3952	489	007255	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3953	489	007256	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3954	489	007257	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3955	489	007258	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3956	490	007259	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3957	490	007260	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3958	490	007261	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3959	490	007262	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3960	490	007263	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3961	490	007264	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3962	490	007265	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3963	490	007266	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3964	491	007267	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3965	491	007268	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3966	491	007269	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3967	491	007270	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3968	491	007271	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3969	491	007272	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3970	491	007273	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3971	491	007274	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3972	491	007275	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3973	492	007276	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3974	492	007277	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3975	492	007278	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3976	492	007279	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3977	493	007280	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3978	493	007281	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3979	493	007282	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3980	493	007283	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3981	494	007284	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3982	494	007285	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3983	494	007286	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3984	494	007287	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3985	494	007288	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3986	494	007289	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3987	494	007290	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3988	494	007291	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3989	494	007292	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3990	494	007293	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3991	494	007294	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3992	494	007295	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3993	494	007296	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3994	494	007297	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3995	494	007298	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3996	495	007299	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3997	495	007300	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3998	495	007301	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
3999	495	007302	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4000	495	007303	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4001	495	007304	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4002	496	007305	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4003	496	007306	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4004	496	007307	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4005	496	007308	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4006	496	007309	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4007	496	007310	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4008	496	007311	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4009	496	007312	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4010	496	007313	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4011	497	007314	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4012	497	007315	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4013	497	007316	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4014	497	007317	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4015	497	007318	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4016	497	007319	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4017	497	007320	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4018	497	007321	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4019	497	007322	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4020	497	007323	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4021	498	007324	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4022	498	007325	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4023	498	007326	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4024	498	007327	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4025	498	007328	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4026	498	007329	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4027	498	007330	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4028	498	007331	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4029	498	007332	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4030	498	007333	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4031	498	007334	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4032	498	007335	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4033	498	007336	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4034	498	007337	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4035	499	007338	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4036	499	007339	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4037	499	007340	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4038	499	007341	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4039	499	007342	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4040	499	007343	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4041	499	007344	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4042	499	007345	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4043	499	007346	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4044	499	007347	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4045	499	007348	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4046	499	007349	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4047	499	007350	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4048	499	007351	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4049	500	007352	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4050	500	007353	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4051	500	007354	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4052	500	007355	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4053	500	007356	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4054	501	007357	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4055	501	007358	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4056	501	007359	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4057	501	007360	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4058	501	007361	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4059	501	007362	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4060	501	007363	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4061	501	007364	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4062	502	007365	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4063	502	007366	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4064	502	007367	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4065	502	007368	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4066	502	007369	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4067	502	007370	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4068	502	007371	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4069	503	007372	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4070	503	007373	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4071	503	007374	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4072	503	007375	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4073	503	007376	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4074	503	007377	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4075	503	007378	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4076	503	007379	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4077	503	007380	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4078	503	007381	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4079	504	007382	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4080	504	007383	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4081	504	007384	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4082	504	007385	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4083	505	007386	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4084	505	007387	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4085	505	007388	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4086	506	007389	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4087	506	007390	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4088	506	007391	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4089	506	007392	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4090	507	007393	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4091	507	007394	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4092	507	007395	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4093	507	007396	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4094	507	007397	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4095	507	007398	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4096	507	007399	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4097	507	007400	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4098	507	007401	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4099	507	007402	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4100	507	007403	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4101	507	007404	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4102	507	007405	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4103	507	007406	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4104	507	007407	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4105	507	007408	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4106	507	007409	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4107	507	007410	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4108	507	007411	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4109	507	007412	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4110	507	007413	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4111	507	007414	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4112	508	007415	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4113	508	007416	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4114	508	007417	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4115	508	007418	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4116	508	007419	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4117	508	007420	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4118	508	007421	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4119	508	007422	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4120	508	007423	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4121	508	007424	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4122	508	007425	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4123	508	007426	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4124	508	007427	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4125	508	007428	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4126	508	007429	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4127	508	007430	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4128	508	007431	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4129	508	007432	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4130	508	007433	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4131	508	007434	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4132	508	007435	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4133	508	007436	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4134	508	007437	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4135	508	007438	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4136	509	007439	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4137	509	007440	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4138	509	007441	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4139	509	007442	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4140	509	007443	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4141	509	007444	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4142	509	007445	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4143	509	007446	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4144	509	007447	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4145	510	007448	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4146	510	007449	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4147	510	007450	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4148	511	007451	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4149	511	007452	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4150	511	007453	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4151	511	007454	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4152	511	007455	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4153	511	007456	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4154	511	007457	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4155	511	007458	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4156	512	007459	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4157	512	007460	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4158	512	007461	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4159	512	007462	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4160	512	007463	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4161	512	007464	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4162	513	007465	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4163	513	007466	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4164	513	007467	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4165	513	007468	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4166	513	007469	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4167	514	007470	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4168	514	007471	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4169	514	007472	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4170	514	007473	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4171	515	007474	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4172	515	007475	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4173	515	007476	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4174	515	007477	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4175	515	007478	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4176	515	007479	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4177	515	007480	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4178	515	007481	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4179	515	007482	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4180	515	007483	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4181	515	007484	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4182	515	007485	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4183	515	007486	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4184	515	007487	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4185	516	007488	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4186	516	007489	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4187	516	007490	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4188	516	007491	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4189	516	007492	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4190	516	007493	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4191	516	007494	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4192	517	007495	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4193	517	007496	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4194	518	007497	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4195	518	007498	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4196	518	007499	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4197	519	007500	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4198	519	007501	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4199	519	007502	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4200	519	007503	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4201	519	007504	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4202	520	007505	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4203	520	007506	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4204	521	007507	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4205	521	007508	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4206	521	007509	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4207	522	007510	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4208	522	007511	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4209	522	007512	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4210	522	007513	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4211	523	007514	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4212	523	007515	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4213	523	007516	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4214	523	007517	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4215	523	007518	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4216	523	007519	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4217	523	007520	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4218	523	007521	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4219	523	007522	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4220	523	007523	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4221	523	007524	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4222	523	007525	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4223	523	007526	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4224	523	007527	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4225	523	007528	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4226	523	007529	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4227	523	007530	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4228	523	007531	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4229	523	007532	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4230	523	007533	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4231	523	007534	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4232	523	007535	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4233	523	007536	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4234	523	007537	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4235	523	007538	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4236	523	007539	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4237	523	007540	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4238	524	007541	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4239	524	007542	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4240	524	007543	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4241	524	007544	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4242	524	007545	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4243	524	007546	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4244	524	007547	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4245	524	007548	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4246	524	007549	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4247	524	007550	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4248	524	007551	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4249	524	007552	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4250	524	007553	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4251	524	007554	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4252	525	007555	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4253	525	007556	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4254	525	007557	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4255	525	007558	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4256	525	007559	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4257	525	007560	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4258	525	007561	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4259	525	007562	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4260	525	007563	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4261	525	007564	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4262	526	007565	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4263	526	007566	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4264	526	007567	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4265	526	007568	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4266	526	007569	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4267	527	007570	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4268	527	007571	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4269	527	007572	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4270	527	007573	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4271	527	007574	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4272	527	007575	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4273	527	007576	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4274	527	007577	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4275	527	007578	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4276	527	007579	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4277	527	007580	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4278	527	007581	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4279	527	007582	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4280	527	007583	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4281	528	007584	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4282	528	007585	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4283	528	007586	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4284	528	007587	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4285	528	007588	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4286	528	007589	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4287	529	007590	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4288	529	007591	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4289	529	007592	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4290	529	007593	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4291	529	007594	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4292	529	007595	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4293	529	007596	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4294	529	007597	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4295	529	007598	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4296	529	007599	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4297	529	007600	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4298	529	007601	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4299	529	007602	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4300	529	007603	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4301	529	007604	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4302	529	007605	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4303	530	008166	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4304	530	008167	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4305	530	008168	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4306	530	008169	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4307	530	008170	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4308	530	008171	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4309	530	008172	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4310	530	008173	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4311	530	008174	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4312	530	008175	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4313	530	008176	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4314	531	008177	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4315	531	008178	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4316	531	008179	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4317	531	008180	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4318	531	008181	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4319	531	008182	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4320	531	008183	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4321	531	008184	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4322	531	008185	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4323	531	008186	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4324	531	008187	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4325	531	008188	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4326	531	008189	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4327	531	008190	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4328	531	008191	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4329	531	008192	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4330	531	008193	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4331	531	008194	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4332	531	008195	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4333	531	008196	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4334	531	008197	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4335	531	008198	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4336	531	008199	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4337	531	008200	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4338	531	008201	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4339	531	008202	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4340	531	008203	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4341	531	008204	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4342	531	008205	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4343	532	008206	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4344	532	008207	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4345	532	008208	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4346	532	008209	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4347	532	008210	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4348	532	008211	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4349	532	008212	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4350	532	008213	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4351	532	008214	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4352	532	008215	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4353	532	008216	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4354	532	008217	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4355	532	008218	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4356	532	008219	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4357	532	008220	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4358	532	008221	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4359	532	008222	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4360	532	008223	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4361	532	008224	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4362	532	008225	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4363	532	008226	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4364	532	008227	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4365	532	008228	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4366	532	008229	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4367	532	008230	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4368	532	008231	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4369	532	008232	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4370	532	008233	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4371	532	008234	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4372	532	008235	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4373	532	008236	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4374	532	008237	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4375	532	008238	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4376	532	008239	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4377	532	008240	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4378	532	008241	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4379	532	008242	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4380	532	008243	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4381	532	008244	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4382	532	008245	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4383	532	008246	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4384	532	008247	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4385	532	008248	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4386	533	008249	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4387	533	008250	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4388	533	008251	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4389	533	008252	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4390	533	008253	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4391	533	008254	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4392	533	008255	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4393	533	008256	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4394	533	008257	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4395	533	008258	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4396	534	008259	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4397	534	008260	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4398	534	008261	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4399	534	008262	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4400	534	008263	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4401	535	008264	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4402	535	008265	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4403	535	008266	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4404	535	008267	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4405	535	008268	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4406	535	008269	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4407	535	008270	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4408	535	008271	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4409	535	008272	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4410	535	008273	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4411	535	008274	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4412	535	008275	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4413	535	008276	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4414	535	008277	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4415	535	008278	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4416	535	008279	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4417	536	008280	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4418	536	008281	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4419	536	008282	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4420	536	008283	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4421	536	008284	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4422	536	008285	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4423	537	008286	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4424	537	008287	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4425	537	008288	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4426	537	008289	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4427	537	008290	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4428	537	008291	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4429	537	008292	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4430	538	008293	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4431	538	008294	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4432	538	008295	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4433	538	008296	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4434	538	008297	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4435	538	008298	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4436	538	008299	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4437	539	008300	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4438	539	008301	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4439	539	008302	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4440	539	008303	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4441	539	008304	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4442	539	008305	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4443	539	008306	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4444	539	008307	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4445	539	008308	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4446	539	008309	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4447	539	008310	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4448	539	008311	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4449	539	008312	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4450	539	008313	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4451	539	008314	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4452	539	008315	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4453	539	008316	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4454	539	008317	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4455	539	008318	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4456	539	008319	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4457	539	008320	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4458	539	008321	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4459	539	008322	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4460	539	008323	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4461	540	008324	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4462	540	008325	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4463	540	008326	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4464	540	008327	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4465	540	008328	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4466	540	008329	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4467	540	008330	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4468	540	008331	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4469	540	008332	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4470	540	008333	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4471	541	008334	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4472	541	008335	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4473	541	008336	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4474	541	008337	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4475	541	008338	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4476	542	008339	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4477	542	008340	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4478	542	008341	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4479	542	008342	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4480	542	008343	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4481	542	008344	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4482	543	008345	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4483	543	008346	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4484	543	008347	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4485	543	008348	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4486	543	008349	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4487	543	008350	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4488	543	008351	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4489	543	008352	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4490	543	008353	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4491	543	008354	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4492	544	008355	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4493	544	008356	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4494	544	008357	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4495	544	008358	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4496	544	008359	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4497	544	008360	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4498	544	008361	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4499	544	008362	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4500	544	008363	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4501	544	008364	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4502	544	008365	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4503	545	008366	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4504	545	008367	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4505	545	008368	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4506	545	008369	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4507	545	008370	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4508	545	008371	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4509	545	008372	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4510	546	008373	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4511	546	008374	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4512	546	008375	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4513	546	008376	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4514	546	008377	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4515	546	008378	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4516	546	008379	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4517	546	008380	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4518	546	008381	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4519	546	008382	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4520	546	008383	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4521	546	008384	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4522	546	008385	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4523	547	008672	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4524	547	008673	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4525	547	008674	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4526	547	008675	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4527	547	008676	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4528	547	008677	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4529	547	008678	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4530	547	008679	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4531	547	008680	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4532	548	008681	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4533	548	008682	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4534	548	008683	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4535	548	008684	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4536	548	008685	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4537	548	008686	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4538	548	008687	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4539	548	008688	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4540	548	008689	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4541	548	008690	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4542	548	008691	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4543	549	008692	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4544	549	008693	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4545	549	008694	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4546	549	008695	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4547	549	008696	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4548	550	008697	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4549	550	008698	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4550	550	008699	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4551	550	008700	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4552	550	008701	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4553	550	008702	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4554	550	008703	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4555	550	008704	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4556	551	008705	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4557	551	008706	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4558	551	008707	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4559	551	008708	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4560	551	008709	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4561	551	008710	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4562	551	008711	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4563	551	008712	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4564	551	008713	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4565	551	008714	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4566	551	008715	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4567	551	008716	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4568	552	008717	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4569	552	008718	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4570	552	008719	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4571	552	008720	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4572	552	008721	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4573	553	008722	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4574	553	008723	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4575	553	008724	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4576	553	008725	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4577	554	008726	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4578	554	008727	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4579	554	008728	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4580	554	008729	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4581	554	008730	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4582	555	900823	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4583	556	008731	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4584	556	008732	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4585	556	008733	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4586	556	008734	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4587	556	008735	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4588	556	008736	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4589	556	008737	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4590	556	008738	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4591	556	008739	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4592	556	008740	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4593	557	008741	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4594	557	008742	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4595	557	008743	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4596	557	008744	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4597	558	900824	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4598	558	900825	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4599	558	900826	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4600	558	900827	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4601	558	900828	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4602	558	900829	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4603	558	900830	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4604	559	008745	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4605	559	008746	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4606	559	008747	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4607	559	008748	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4608	559	008749	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4609	559	008750	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4610	559	008751	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4611	559	008752	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4612	559	008753	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4613	559	008754	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4614	559	008755	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4615	559	008756	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4616	559	008757	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4617	559	008758	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4618	560	008759	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4619	560	008760	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4620	560	008761	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4621	561	008762	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4622	561	008763	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4623	561	008764	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4624	562	008777	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4625	562	008778	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4626	562	008779	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4627	563	008765	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4628	563	008766	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4629	563	008767	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4630	563	008768	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4631	563	008769	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4632	563	008770	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4633	563	008771	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4634	563	008772	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4635	563	008773	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4636	563	008774	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4637	563	008775	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4638	563	008776	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4639	564	008780	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4640	564	008781	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4641	564	008782	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4642	564	008783	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4643	564	008784	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4644	565	008785	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4645	565	008786	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4646	565	008787	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4647	565	008788	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4648	566	008789	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4649	566	008790	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4650	566	008791	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4651	566	008792	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4652	567	008793	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4653	567	008794	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4654	567	008795	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4655	567	008796	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4656	568	900831	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4657	569	008797	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4658	569	008798	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4659	569	008799	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4660	569	008800	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4661	569	008801	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4662	569	008802	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4663	569	008803	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4664	569	008804	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4665	569	008805	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4666	569	008806	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4667	569	008807	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4668	569	008808	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4669	569	008809	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4670	569	008810	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4671	569	008811	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4672	569	008812	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4673	569	008813	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4674	569	008814	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4675	569	008815	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4676	569	008816	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4677	227	008817	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4678	227	008818	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4679	227	008819	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4680	227	008820	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4681	227	008821	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4682	227	008822	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4683	227	008823	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4684	570	008826	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4685	571	008827	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4686	571	008828	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4687	571	008829	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4688	572	008830	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4689	572	008831	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4690	572	008832	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4691	572	008833	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4692	572	008834	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4693	572	008835	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4694	572	008836	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4695	573	008837	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4696	573	008838	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4697	573	008839	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4698	574	008840	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4699	574	008841	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4700	574	008842	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4701	575	008843	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4702	575	008844	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4703	575	008845	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4704	575	008846	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4705	575	008847	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4706	575	008848	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4707	575	008849	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4708	575	008850	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4709	576	008851	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4710	576	008852	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4711	576	008853	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4712	576	008854	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4713	576	008855	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4714	577	008856	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4715	577	008857	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4716	577	008858	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4717	577	008859	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4718	577	008860	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4719	578	008861	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4720	578	008862	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4721	578	008863	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4722	578	008864	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4723	578	008865	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4724	578	008866	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4725	578	008867	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4726	579	008868	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4727	579	008869	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4728	579	008870	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4729	579	008871	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4730	579	008872	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4731	579	008873	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4732	579	008874	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4733	580	008875	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4734	580	008876	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4735	580	008877	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4736	580	008878	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4737	580	008879	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4738	580	008880	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4739	580	008881	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4740	580	008882	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4741	581	008883	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4742	581	008884	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4743	582	900832	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4744	583	008885	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4745	583	008886	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4746	583	008887	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4747	583	008888	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4748	584	008889	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4749	584	008890	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4750	584	008891	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4751	584	008892	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4752	584	008893	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4753	585	900833	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4754	586	008894	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4755	586	008895	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4756	587	008896	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4757	587	008897	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4758	587	008898	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4759	587	008899	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4760	587	008900	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4761	587	008901	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4762	587	008902	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4763	587	008903	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4764	587	008904	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4765	587	008905	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4766	587	008906	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4767	588	008907	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4768	588	008908	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4769	588	008909	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4770	588	008910	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4771	588	008911	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4772	588	008912	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4773	588	008913	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4774	588	008914	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4775	588	008915	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4776	588	008916	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4777	588	008917	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4778	588	008918	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4779	589	008919	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4780	589	008920	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4781	590	008921	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4782	590	008922	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4783	590	008923	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4784	591	008924	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4785	591	008925	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4786	591	008926	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4787	592	008927	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4788	593	008928	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4789	593	008929	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4790	593	008930	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4791	593	008931	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4792	593	008932	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4793	593	008933	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4794	594	008934	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4795	594	008935	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4796	594	008936	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4797	594	008937	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4798	594	008938	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4799	595	008939	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4800	595	008940	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4801	595	008941	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4802	595	008942	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4803	596	008943	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4804	596	008944	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4805	596	008945	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4806	597	008946	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4807	597	008947	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4808	597	008948	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4809	598	008949	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4810	598	008950	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4811	598	008951	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4812	598	008952	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4813	598	008953	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4814	598	008954	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4815	599	900845	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4816	599	900846	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4817	600	008955	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4818	600	008956	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4819	600	008957	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4820	600	008958	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4821	600	008959	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4822	600	008960	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4823	600	008961	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4824	600	008962	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4825	600	008963	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4826	601	008964	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4827	601	008965	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4828	601	008966	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4829	601	008967	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4830	601	008968	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4831	602	008969	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4832	602	008970	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4833	602	008971	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4834	602	008972	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4835	602	008973	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4836	602	008974	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4837	603	008975	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4838	603	008976	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4839	603	008977	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4840	603	008978	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4841	603	008979	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4842	604	008980	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4843	604	008981	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4844	604	008982	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4845	604	008983	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4846	605	008984	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4847	605	008985	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4848	606	900848	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4849	607	900849	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4850	608	900847	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4851	609	008986	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4852	609	008987	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4853	609	008988	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4854	609	008989	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4855	610	008990	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4856	610	008991	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4857	610	008992	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4858	610	008993	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4859	611	900850	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4860	612	900852	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4861	613	900851	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4862	614	008994	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4863	614	008995	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4864	614	008996	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4865	615	008997	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4866	615	008998	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4867	615	008999	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4868	616	009000	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4869	616	009001	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4870	616	009002	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4871	616	009003	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4872	617	009004	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4873	617	009005	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4874	617	009006	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4875	618	009007	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4876	618	009008	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4877	618	009009	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4878	618	009010	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4879	618	009011	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4880	618	009012	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4881	618	009013	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4882	618	009014	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4883	618	009015	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4884	618	009016	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4885	618	009017	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4886	618	009018	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4887	619	009019	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4888	619	009020	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4889	619	009021	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4890	620	009022	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4891	620	009023	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4892	620	009024	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4893	621	009025	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4894	621	009026	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4895	622	009047	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4896	623	009027	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4897	623	009028	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4898	623	009029	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4899	623	009030	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4900	623	009031	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4901	623	009032	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4902	623	009033	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4903	623	009034	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4904	624	009035	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4905	624	009036	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4906	624	009037	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4907	624	009038	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4908	624	009039	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4909	624	009040	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4910	624	009041	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4911	624	009042	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4912	624	009043	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4913	624	009044	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4914	624	009045	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4915	624	009046	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4916	625	009048	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4917	625	009049	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4918	625	009050	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4919	625	009051	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4920	626	008388	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4921	626	008389	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4922	626	008390	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4923	626	008391	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4924	626	008392	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4925	626	008393	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4926	626	008394	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4927	627	008386	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4928	627	008387	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4929	627	008395	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4930	627	008396	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4931	627	008397	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4932	627	008398	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4933	627	008399	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4934	627	008400	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4935	627	008401	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4936	628	008402	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4937	628	008403	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4938	628	008404	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4939	628	008405	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4940	629	900834	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4941	629	900835	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4942	630	008406	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4943	630	008407	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4944	630	008408	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4945	630	008409	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4946	630	008410	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4947	630	008411	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4948	631	008422	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4949	631	008423	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4950	631	008424	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4951	631	008425	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4952	631	008426	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4953	631	008427	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4954	632	900836	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4955	632	900837	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4956	632	900838	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4957	633	008412	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4958	633	008413	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4959	633	008414	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4960	633	008415	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4961	633	008416	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4962	633	008417	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4963	633	008418	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4964	633	008419	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4965	633	008420	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4966	633	008421	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4967	634	008428	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4968	634	008429	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4969	634	008430	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4970	634	008431	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4971	635	008432	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4972	635	008433	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4973	635	008434	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4974	636	008435	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4975	636	008436	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4976	636	008437	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4977	636	008438	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4978	636	008439	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4979	636	008440	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4980	637	008441	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4981	637	008442	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4982	637	008443	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4983	638	008444	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4984	638	008445	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4985	638	008446	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4986	638	008447	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4987	639	900839	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4988	640	008448	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4989	640	008449	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4990	640	008450	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4991	640	008451	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4992	640	008452	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4993	641	008453	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4994	641	008454	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4995	641	008455	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4996	642	008456	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4997	642	008457	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4998	642	008458	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
4999	643	008459	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5000	643	008460	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5001	643	008461	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5002	643	008462	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5003	644	008463	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5004	644	008464	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5005	644	008465	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5006	645	008466	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5007	645	008467	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5008	645	008468	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5009	645	008469	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5010	646	900840	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5011	646	900841	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5012	647	900842	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5013	648	008470	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5014	648	008471	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5015	648	008472	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5016	649	008473	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5017	649	008474	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5018	649	008475	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5019	650	900843	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5020	650	900844	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5021	651	008476	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5022	651	008477	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5023	651	008478	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5024	651	008479	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5025	651	008480	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5026	651	008481	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5027	652	008482	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5028	652	008483	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5029	652	008484	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5030	652	008485	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5031	652	008486	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5032	652	008487	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5033	652	008488	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5034	652	008489	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5035	652	008490	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5036	652	008491	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5037	652	008492	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5038	652	008493	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5039	652	008494	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5040	652	008495	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5041	652	008496	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5042	652	008497	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5043	652	008498	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5044	652	008499	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5045	652	008500	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5046	652	008501	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5047	652	008502	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5048	652	008503	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5049	652	008504	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5050	653	008505	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5051	653	008506	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5052	653	008507	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5053	653	008508	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5054	653	008509	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5055	653	008510	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5056	653	008511	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5057	653	008512	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5058	653	008513	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5059	653	008514	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5060	653	008515	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5061	653	008516	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5062	653	008517	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5063	653	008518	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5064	653	008519	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5065	653	008520	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5066	653	008521	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5067	653	008522	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5068	653	008523	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5069	653	008524	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5070	653	008525	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5071	653	008526	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5072	653	008527	250	f	f	pending	\N	\N	2026-09-22 16:44:39-05	2026-09-22 16:44:39-05
5073	654	008528	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5074	654	008529	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5075	654	008530	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5076	654	008531	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5077	654	008532	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5078	654	008533	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5079	654	008534	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5080	654	008535	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5081	655	008536	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5082	655	008537	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5083	655	008538	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5084	655	008539	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5085	655	008540	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5086	655	008541	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5087	655	008542	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5088	655	008543	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5089	655	008544	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5090	655	008545	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5091	655	008546	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5092	655	008547	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5093	655	008548	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5094	655	008549	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5095	655	008550	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5096	656	008551	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5097	656	008552	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5098	656	008553	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5099	656	008554	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5100	656	008555	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5101	656	008556	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5102	656	008557	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5103	657	008558	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5104	657	008559	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5105	657	008560	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5106	657	008561	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5107	657	008562	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5108	657	008563	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5109	657	008564	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5110	657	008565	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5111	657	008566	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5112	657	008567	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5113	657	008568	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5114	657	008569	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5115	658	008570	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5116	658	008571	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5117	658	008572	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5118	658	008573	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5119	658	008574	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5120	658	008575	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5121	659	008576	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5122	659	008577	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5123	659	008578	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5124	659	008579	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5125	659	008580	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5126	659	008581	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5127	659	008582	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5128	659	008583	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5129	659	008584	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5130	659	008585	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5131	659	008586	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5132	659	008587	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5133	659	008588	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5134	659	008589	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5135	659	008590	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5136	659	008591	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5137	659	008592	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5138	659	008593	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5139	659	008594	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5140	659	008595	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5141	659	008596	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5142	659	008597	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5143	659	008598	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5144	659	008599	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5145	660	008600	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5146	660	008601	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5147	660	008602	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5148	660	008603	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5149	660	008604	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5150	660	008605	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5151	660	008606	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5152	660	008607	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5153	660	008608	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5154	660	008609	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5155	660	008610	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5156	660	008611	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5157	660	008612	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5158	660	008613	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5159	660	008614	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5160	660	008615	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5161	661	008616	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5162	661	008617	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5163	661	008618	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5164	661	008619	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5165	661	008620	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5166	661	008621	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5167	661	008622	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5168	661	008623	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5169	662	008624	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5170	662	008625	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5171	662	008626	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5172	662	008627	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5173	662	008628	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5174	662	008629	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5175	662	008630	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5176	662	008631	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5177	662	008632	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5178	663	008633	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5179	663	008634	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5180	663	008635	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5181	663	008636	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5182	663	008637	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5183	663	008638	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5184	663	008639	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5185	663	008640	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5186	663	008641	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5187	663	008642	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5188	663	008643	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5189	663	008644	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5190	663	008645	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5191	663	008646	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5192	663	008647	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5193	663	008648	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5194	663	008649	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5195	663	008650	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5196	663	008651	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5197	663	008652	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5198	663	008653	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5199	663	008654	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5200	664	008655	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5201	664	008656	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5202	664	008657	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5203	664	008658	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5204	664	008659	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5205	664	008660	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5206	664	008661	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5207	664	008662	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5208	664	008663	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5209	664	008664	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5210	664	008665	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5211	664	008666	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5212	664	008667	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5213	664	008668	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5214	664	008669	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5215	664	008670	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5216	664	008671	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5217	665	009052	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5218	665	009053	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5219	665	009054	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5220	665	009055	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5221	665	009056	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5222	665	009057	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5223	665	009058	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5224	666	009059	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5225	666	009060	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5226	666	009061	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5227	667	009062	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5228	667	009063	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5229	668	900858	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5230	669	900857	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5231	670	009064	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5232	670	009065	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5233	670	009066	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5234	670	009067	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5235	670	009068	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5236	670	009069	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5237	670	009070	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5238	670	009071	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5239	671	009072	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5240	671	009073	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5241	671	009074	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5242	672	009075	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5243	672	009076	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5244	672	009077	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5245	673	900862	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5246	674	009094	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5247	674	009095	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5248	674	009096	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5249	674	009097	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5250	674	009098	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5251	675	009099	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5252	675	009100	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5253	675	009101	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5254	676	009078	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5255	676	009079	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5256	676	009080	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5257	677	900859	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5258	677	900860	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5259	677	900861	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5260	678	009081	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5261	678	009082	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5262	678	009083	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5263	678	009084	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5264	678	009085	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5265	678	009086	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5266	678	009087	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5267	678	009088	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5268	679	009089	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5269	679	009090	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5270	679	009091	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5271	679	009092	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5272	679	009093	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5273	680	009102	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5274	680	009103	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5275	680	009104	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5276	680	009105	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5277	680	009106	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5278	680	009107	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5279	681	009108	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5280	681	009109	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5281	681	009110	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5282	681	009111	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5283	681	009112	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5284	681	009113	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5285	681	009114	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5286	681	009115	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5287	681	009116	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5288	681	009117	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5289	681	009118	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5290	681	009119	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5291	681	009120	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5292	681	009121	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5293	682	009122	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5294	682	009123	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5295	682	009124	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5296	682	009125	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5297	682	009126	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5298	682	009127	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5299	682	009128	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5300	682	009129	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5301	682	009130	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5302	682	009131	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5303	683	009132	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5304	683	009133	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5305	683	009134	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5306	683	009135	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5307	683	009136	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5308	684	009137	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5309	684	009138	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5310	684	009139	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5311	684	009140	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5312	684	009141	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5313	684	009142	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5314	684	009143	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5315	684	009144	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5316	684	009145	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5317	685	009146	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5318	685	009147	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5319	685	009148	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5320	686	009149	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5321	686	009150	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5322	686	009151	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5323	686	009152	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5324	686	009153	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5325	686	009154	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5326	686	009155	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5327	686	009156	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5328	686	009157	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5329	686	009158	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5330	686	009159	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5331	686	009160	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5332	686	009161	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5333	686	009162	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5334	686	009163	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5335	687	009164	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5336	687	009165	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5337	687	009166	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5338	687	009167	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5339	687	009168	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5340	687	009169	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5341	687	009170	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5342	687	009171	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5343	687	009172	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5344	687	009173	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5345	687	009174	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5346	687	009175	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5347	687	009176	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5348	688	009177	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5349	688	009178	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5350	688	009179	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5351	688	009180	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5352	688	009181	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5353	688	009182	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5354	688	009183	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5355	688	009184	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5356	688	009185	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5357	688	009186	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5358	688	009187	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5359	689	009188	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5360	689	009189	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5361	689	009190	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5362	689	009191	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5363	689	009192	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5364	690	009193	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5365	690	009194	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5366	690	009195	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5367	691	009196	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5368	691	009197	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5369	691	009198	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5370	691	009199	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5371	692	009200	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5372	692	009201	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5373	692	009202	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5374	692	009203	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5375	692	009204	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5376	692	009205	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5377	692	009206	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5378	692	009207	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5379	693	009208	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5380	693	009209	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5381	693	009210	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5382	693	009211	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5383	694	009212	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5384	694	009213	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5385	694	009214	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5386	694	009215	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5387	694	009216	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5388	694	009217	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5389	694	009218	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5390	694	009219	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5391	695	009220	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5392	695	009221	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5393	695	009222	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5394	695	009223	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5395	695	009224	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5396	695	009225	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5397	696	009226	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5398	696	009227	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5399	696	009228	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5400	696	009229	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5401	696	009230	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5402	696	009231	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5403	696	009232	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5404	696	009233	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5405	697	009234	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5406	697	009235	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5407	697	009236	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5408	697	009237	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5409	697	009238	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5410	697	009239	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5411	697	009240	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5412	697	009241	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5413	697	009242	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5414	697	009243	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5415	697	009244	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5416	697	009245	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5417	697	009246	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5418	697	009247	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5419	697	009248	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5420	697	009249	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5421	698	009250	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5422	698	009251	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5423	698	009252	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5424	698	009253	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5425	698	009254	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5426	698	009255	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5427	699	009256	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5428	699	009257	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5429	699	009258	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5430	699	009259	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5431	699	009260	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5432	699	009261	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5433	699	009262	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5434	699	009263	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5435	699	009264	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5436	699	009265	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5437	699	009266	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5438	699	009267	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5439	700	009268	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5440	700	009269	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5441	700	009270	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5442	700	009271	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5443	700	009272	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5444	700	009273	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5445	700	009274	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5446	700	009275	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5447	700	009276	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5448	700	009277	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5449	700	009278	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5450	701	009279	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5451	701	009280	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5452	701	009281	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5453	701	009282	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5454	701	009283	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5455	702	009284	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5456	702	009285	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5457	703	009286	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5458	703	009287	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5459	703	009288	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5460	703	009289	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5461	703	009290	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5462	703	009291	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5463	704	009292	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5464	704	009293	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5465	705	900863	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5466	706	009294	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5467	706	009295	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5468	706	009296	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5469	706	009297	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5470	706	009298	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5471	706	009299	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5472	707	900865	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5473	708	900864	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5474	709	900866	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5475	710	009300	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5476	710	009301	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5477	710	009302	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5478	711	900867	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5479	711	900868	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5480	712	009303	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5481	712	009304	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5482	712	009305	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5483	712	009306	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5484	712	009307	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5485	712	009308	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5486	712	009309	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5487	713	009310	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5488	713	009311	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5489	714	009312	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5490	714	009313	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5491	715	009314	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5492	715	009315	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5493	716	009316	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5494	716	009317	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5495	716	009318	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5496	717	009319	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5497	717	009320	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
5498	717	009321	250	f	f	pending	\N	\N	2026-09-22 16:44:40-05	2026-09-22 16:44:40-05
1308	228	005175	250	t	f	processed	1	/storage/actas/09b760c387c34f098d0264b60b10ffe6.avif	2026-09-22 16:44:38-05	2026-09-26 10:34:46.824847-05
1309	228	005176	250	t	f	processed	\N	/storage/actas/292a5348c421436890bb6854ea532574.avif	2026-09-22 16:44:38-05	2026-09-26 10:34:56.002106-05
1311	228	005178	250	t	f	processed	1	/storage/actas/22625206811f40459393ca9c47804431.avif	2026-09-22 16:44:38-05	2026-09-26 10:46:26.609855-05
1313	228	005180	250	t	t	requires_review	1	\N	2026-09-22 16:44:38-05	2026-09-26 11:36:27.233591-05
\.


--
-- Data for Name: ubigeo; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.ubigeo (ubigeo, ubigeo_reniec, departamento, provincia, distrito, nivel, capital, latitud, longitud, altitud, densidad_poblacional, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: usuario_alcance; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.usuario_alcance (usuario_id, ubigeo, created_at, local_id) FROM stdin;
2	040100	2026-09-15 18:39:30-05	\N
3	040500	2026-09-15 18:39:30-05	\N
4	040112	2026-09-15 18:39:31-05	\N
5	040126	2026-09-15 18:39:31-05	\N
6	040112	2026-09-15 18:39:31-05	\N
7	040700	2026-09-17 03:50:35-05	\N
8	040701	2026-09-17 03:50:37-05	\N
10	040702	2026-09-17 03:51:23-05	\N
9	040700	2026-09-17 03:53:57-05	\N
11	040100	2026-09-17 04:02:58-05	\N
\.


--
-- Data for Name: usuarios; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.usuarios (id, email, dni, nombres, apellidos, telefono, password_hash, rol, activo, intentos_fallidos, bloqueado_hasta, ultimo_acceso, debe_cambiar_clave, created_at, updated_at) FROM stdin;
2	coord.arequipa@computoarequipa.gob.pe	40000002	Iván	Paredes Chávez	959000002	$2b$12$RK1idGwWW.RIbwsBJi/dquHBzdv8zB1P49ma/szi1L4qAcKj3f4kO	COORD_PROVINCIAL	t	0	\N	2026-09-17 04:21:27.386056-05	t	2026-09-15 18:39:30-05	2026-09-17 04:21:27-05
3	coord.caylloma@computoarequipa.gob.pe	40000003	Milagros	Huanca Sullo	959000003	$2b$12$kP1Z214dqeGz4Q3p0a1y9OuutXGRLUinBdAQ0j1.teg4eI7BfrOJ6	COORD_PROVINCIAL	t	0	\N	2026-09-15 19:37:03.934507-05	t	2026-09-15 18:39:30-05	2026-09-15 19:37:04-05
4	resp.paucarpata@computoarequipa.gob.pe	40000004	Jorge	Mamani Quispe	959000004	$2b$12$Ji8HTS1pgl8da5DIC0t0B.CBo.XuHcY68EKrpRhgNMW/3.NuN4lR.	RESPONSABLE_DISTRITAL	t	0	\N	2026-09-17 04:55:04.377178-05	t	2026-09-15 18:39:31-05	2026-09-17 04:55:04-05
5	resp.yanahuara@computoarequipa.gob.pe	40000005	Lucía	Bustinza Flores	959000005	$2b$12$nsMfx84N7Cjyln9A4EJt1eusF/VI9tx68UnPCMnjt7ppGZqPUyzPW	RESPONSABLE_DISTRITAL	t	0	\N	2026-09-17 22:29:36.703005-05	t	2026-09-15 18:39:31-05	2026-09-17 22:29:37-05
6	personero.paucarpata@computoarequipa.gob.pe	40000006	Abel	Cáceres Puma	959000006	$2b$12$yBRuOwF14iYxq.VnHkWTXObdjn.2t7yzLmz2k4M4SAPN7SOU72P9W	PERSONERO	t	0	\N	2026-09-17 22:27:47.338694-05	t	2026-09-15 18:39:31-05	2026-09-17 22:27:47-05
7	coord.islay@computoarequipa.gob.pe	40000011	Coord	Islay Test	\N	$2b$12$HlLL0G1l.ARdO6jchaRe/esnvZrBhTjeZUHR7dYzlSNv9tkdUzj6K	COORD_PROVINCIAL	t	0	\N	2026-09-17 04:53:25.892538-05	t	2026-09-17 03:50:35-05	2026-09-17 04:53:26-05
8	resp.mollendo@computoarequipa.gob.pe	40000012	Resp	Mollendo Test	\N	$2b$12$lyCoAk374SEXAr8rkTAdfOEM6CIYVCbxNuT3Jr9XDu2paW/4UhAUC	RESPONSABLE_DISTRITAL	t	0	\N	\N	t	2026-09-17 03:50:37-05	2026-09-17 03:50:37-05
9	personero.mollendo@computoarequipa.gob.pe	40000013	Pers	Mollendo Test	\N	$2b$12$Zhn2RY/7cCRGmPyotqeAyuIOY2SEVYGmC936p6Mr48ttodF.M7SgW	PERSONERO	t	0	\N	2026-09-17 05:38:16.740744-05	t	2026-09-17 03:50:39-05	2026-09-17 05:38:17-05
10	pers.islay2@computoarequipa.gob.pe	40000014	Pers2	Islay	\N	$2b$12$BqyddcOnRhxpIFUwupE4Wuz3KvUMSIZGH8uCCfYMSA9ayNrdM7c/q	PERSONERO	t	0	\N	\N	t	2026-09-17 03:51:23-05	2026-09-17 03:51:23-05
11	jhoedmon1@gmail.com	43993541	jhob	monroy	974437150	$2b$12$Z4Iiz4hTgTncSgoCtM63.uHpNaDKSKUpKEczea4G3ydAsS23ZjANG	PERSONERO	t	0	\N	\N	t	2026-09-17 04:02:58-05	2026-09-17 04:02:58-05
12	digitador.global@computoarequipa.gob.pe	40000009	Elena	Quispe Vargas	959000009	$2b$12$jaW0iHOgKR/DycuBxKWdFe0wpC5ncsKjFIHwXXAr3jiUR4rC8d5E.	DIGITADOR_GLOBAL	t	0	\N	2026-09-18 04:56:29.020978-05	t	2026-09-18 02:22:26-05	2026-09-18 04:56:29-05
13	jhoedmon@gmail.com	43993542	john	monroy	974437150	$2b$12$qaip4VUZK6PoptsadBJcU.UNBckOIXumZsDPOxeYUrILki8cNldFG	DIGITADOR_GLOBAL	t	0	\N	2026-09-19 13:45:42.006902-05	t	2026-09-18 02:34:57-05	2026-09-19 13:45:42-05
14	admin@gmail.com	43993543	pepe	pepe	974437150	$2b$12$VBR/UF/6ogrEaYyNZ4j9k.5TOGmrDkwO8tPRSWs46NggzMcu9w2p.	DIGITADOR_GLOBAL	t	0	\N	2026-09-25 01:45:23.424981-05	t	2026-09-24 23:27:52-05	2026-09-25 01:45:23-05
1	admin@computoarequipa.gob.pe	40000001	Rosa	Delgado Vela	959000001	$2b$12$nGNWiH.AdcChJSdhYs9OOOQviRJYX6ZA.qQJFNxAO2iL0Tk/P7nhW	SUPER_ADMIN	t	0	\N	2026-09-26 11:53:01.063545-05	t	2026-09-15 18:39:30-05	2026-09-26 11:53:01.045478-05
\.


--
-- Data for Name: venues; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.venues (id, name, sector, address, latitude, longitude, ubigeo, total_tables, created_at) FROM stdin;
455	IEI QUEQUEÑA	QUEQUEÑA	PLAZA PRINCIPAL SN	-16.557222	-71.451389	040115	2	2026-09-22 16:44:39-05
260	IE 40657	ALTO SELVA ALEGRE	VILLA INDEPENDIENTE SN	-16.38	-71.521111	040102	12	2026-09-22 16:44:38-05
233	IE 40025 SANTA DOROTEA	AREQUIPA	AV VIDAURRAZAGA SN	-16.393333	-71.528889	040101	8	2026-09-22 16:44:38-05
227	IE FAUSTINO B FRANCO	FRENTE AL PARQUE	AV SAMUEL PASTOR 1301	-16.613611	-72.699167	040208	8	2026-09-18 04:35:16-05
228	IE JUANA CERVANTES DE BOLOGNESI	AREQUIPA	MALECON VALLECITO SN	-16.393333	-71.528889	040101	14	2026-09-22 16:44:38-05
229	IE 41008 MANUEL MUÑOZ NAJAR	AREQUIPA	PSJ FERNANDEZ DAVILA 107	-16.393333	-71.528889	040101	10	2026-09-22 16:44:38-05
230	IE MICAELA BASTIDAS	AREQUIPA	PROL CALLE AYACUCHO SN	-16.393333	-71.528889	040101	14	2026-09-22 16:44:38-05
231	UNIVERSIDAD CATOLICA DE SANTA MARIA	AREQUIPA	URB SAN JOSE SN	-16.393333	-71.528889	040101	34	2026-09-22 16:44:38-05
232	UNIVERSIDAD NACIONAL DE SAN AGUSTIN AREA DE SOCIALES	AREQUIPA	AV VENEZUELA SN	-16.393333	-71.528889	040101	35	2026-09-22 16:44:38-05
476	IE 40172	SOCABAYA	CALLE PANAMA 101	-16.4675	-71.528611	040122	20	2026-09-22 16:44:39-05
551	IE 41041 CRISTO REY	CAMANA	JR SAN MARTIN SN	-16.624722	-72.711389	040201	12	2026-09-22 16:44:39-05
600	IE LIBERTADOR CASTILLA	APLAO	AV 3 DE ABRIL SN	-16.076111	-72.492222	040401	9	2026-09-22 16:44:39-05
601	INSTITUTO DE EDUCACION SUPERIOR TECNOLOGICO CASTILLA	APLAO	AV LAS PEÑAS SN	-16.076111	-72.492222	040401	5	2026-09-22 16:44:39-05
602	IE 40440 CORAZON DE FATIMA	APLAO	CALLE JORGE CHAVEZ SN	-16.076111	-72.492222	040401	6	2026-09-22 16:44:39-05
603	IE 40307 ANGELA RENDON DE SANCHEZ	APLAO	CALLE JUAN PABLO VIZCARDO Y GUZMAN 100	-16.076111	-72.492222	040401	5	2026-09-22 16:44:39-05
604	IE 40314 NUESTRA SEÑORA DE LA ASUNCION	ANDAGUA	CALLE JELJATA SN	-15.498889	-72.356111	040402	4	2026-09-22 16:44:39-05
605	IE 40316 JULIO ERNESTO LAZO DIAZ	AYO	CALLE VIRGEN DEL ROSARIO SN	-15.682778	-72.271944	040403	2	2026-09-22 16:44:39-05
606	IE 40607 CHECOTAÑA	CHACHAS	ANEXO CHECOTAÑA	-15.501389	-72.270556	040404	1	2026-09-22 16:44:39-05
607	IE 40573	CHACHAS	ANEXO HUARACOPALCA	-15.501389	-72.270556	040404	1	2026-09-22 16:44:39-05
608	IE 40349 GRAN NOBEL MARIO VARGAS LLOSA	CHACHAS	CALLE LEONCIO PRADO SN	-15.501389	-72.270556	040404	1	2026-09-22 16:44:39-05
609	IE 40317	CHACHAS	CALLE CALVARIO SN	-15.501389	-72.270556	040404	4	2026-09-22 16:44:39-05
610	IE 40352 BENJAMIN GOMEZ YANCAPALLO	CHILCAYMARCA	PLAZA PRINCIPAL SN	-15.286111	-72.376667	040405	4	2026-09-22 16:44:39-05
611	IE 40318	CHOCO	CALLE PRINCIPAL SN	-15.576667	-72.128889	040406	1	2026-09-22 16:44:39-05
612	LOCAL COMUNAL MIÑA	CHOCO	PLAZA PRINCIPAL SN	-15.576667	-72.128889	040406	1	2026-09-22 16:44:39-05
613	IE 40354	CHOCO	CALLE SN	-15.576667	-72.128889	040406	1	2026-09-22 16:44:39-05
614	IE 40319	CHOCO	CALLE PROLONGACION PROGRESO SN	-15.576667	-72.128889	040406	3	2026-09-22 16:44:39-05
615	IE 40320 NUESTRA SEÑORA DEL ROSARIO PRIMARIA	HUANCARQUI	CALLE 30 DE AGOSTO SN	-16.096111	-72.472222	040407	3	2026-09-22 16:44:39-05
616	IE 40320 NUESTRA SEÑORA DEL ROSARIO SECUNDARIA	HUANCARQUI	AV AREQUIPA SN	-16.096111	-72.472222	040407	4	2026-09-22 16:44:39-05
617	IE 40322 NUESTRA SEÑORA DE LA ASUNTA	MACHAGUAY	CALLE SANTIAGO HUACO SN	-15.650278	-72.506111	040408	3	2026-09-22 16:44:39-05
660	IE 40625 CORAZON DE JESUS	MAJES	AAHH B 1	-16.353333	-72.247222	040520	16	2026-09-22 16:44:40-05
706	IE 40517 CAPITAN EVARISTO AMESQUITA	HUAYNACOTAS	PLAZA DE ACHO SN	-15.174722	-72.849722	040804	6	2026-09-22 16:44:40-05
707	IE 40524 HUARHUA	PAMPAMARCA	CALLE PROGRESO SN	-15.1825	-72.905278	040805	1	2026-09-22 16:44:40-05
708	IE 40522 JUAN LUIS SOTO MOTTA	PAMPAMARCA	CALLE 28 DE JULIO SN	-15.1825	-72.905278	040805	1	2026-09-22 16:44:40-05
709	IEI 40547 TECCA	PAMPAMARCA	CALLE SN	-15.1825	-72.905278	040805	1	2026-09-22 16:44:40-05
710	IE 40523 JUAN LUIS SOTO MOTTA	PAMPAMARCA	CALLE 28 DE JULIO SN	-15.1825	-72.905278	040805	3	2026-09-22 16:44:40-05
711	IE 40549 SANTISIMA VIRGEN DE LA ASUNTA	PUYCA	PLAZA PRINCIPAL SN	-15.059167	-72.691667	040806	2	2026-09-22 16:44:40-05
712	IE 40525 SAN SANTIAGO	PUYCA	CALLE 13 DE OCTUBRE SN	-15.059167	-72.691667	040806	7	2026-09-22 16:44:40-05
713	IE 40558	QUECHUALLA	PLAZA DE ARMAS SN	-15.273889	-73.022222	040807	2	2026-09-22 16:44:40-05
714	IE 40526 SAN MARTIN DE THOURS	SAYLA	CALLE 28 DE JULIO SN	-15.32	-73.221944	040808	2	2026-09-22 16:44:40-05
715	IE 40529 VICTOR ANDRES BELAUNDE	TAURIA	CALLE PROGRESO SN	-15.354167	-73.2325	040809	2	2026-09-22 16:44:40-05
716	IE 40531 HONOFRE BENAVIDES	TOMEPAMPA	PLAZA DE ARMAS 121	-15.173056	-72.830278	040810	3	2026-09-22 16:44:40-05
717	IE 40534 JUAN MANUEL GUILLEN BENAVIDES	TORO	CALLE LAS MERCEDES SN	-15.264444	-72.928333	040811	3	2026-09-22 16:44:40-05
250	IE NUESTRA SEÑORA DE GUADALUPE	ALTO SELVA ALEGRE	CALLE MEXICO 101	-16.38	-71.521111	040102	8	2026-09-22 16:44:38-05
581	IE 40289	ATIQUIPA	PLAZA PRINCIPAL SN	-15.796111	-74.363611	040304	2	2026-09-22 16:44:39-05
251	IEPM COLEGIO MILITAR FRANCISCO BOLOGNESI	ALTO SELVA ALEGRE	AV VICTOR RAUL HAYA DE LA TORRE SN	-16.38	-71.521111	040102	13	2026-09-22 16:44:38-05
252	IE 40686 MI DIVINO NIÑO JESUS	ALTO SELVA ALEGRE	CRUCE CHILINA URB JUAN VELASCO ALVARADO ZONA A MZ F LT 17	-16.38	-71.521111	040102	4	2026-09-22 16:44:38-05
253	IEP HEIMER SCHOOL	ALTO SELVA ALEGRE	AAHH VILLA ECOLOGICA MZ G LT 1	-16.38	-71.521111	040102	4	2026-09-22 16:44:38-05
254	IEP MARIA DE SALES BRIGNOLE	ALTO SELVA ALEGRE	AV 15 DE AGOSTO SN	-16.38	-71.521111	040102	4	2026-09-22 16:44:38-05
255	IE 40028 GUILLERMO MERCADO BARROSO	ALTO SELVA ALEGRE	CALLE HUARAZ SN	-16.38	-71.521111	040102	24	2026-09-22 16:44:38-05
256	IE 40024 MANUEL GONZALES PRADA SECUNDARIA	ALTO SELVA ALEGRE	AAHH JAVIER HERAUD MZ T LT 1 PAMPAS DE POLANCO	-16.38	-71.521111	040102	4	2026-09-22 16:44:38-05
257	IE SAN MARTIN DE PORRES CIRCA	ALTO SELVA ALEGRE	AV ATLANTIDA 401	-16.38	-71.521111	040102	22	2026-09-22 16:44:38-05
258	IE PINTO TALAVERA	ALTO SELVA ALEGRE	AAHH VILLA CONFRATERNIDAD MZ M LT 1 ZONA B	-16.38	-71.521111	040102	9	2026-09-22 16:44:38-05
259	IEP PRIMARIA SAN DANIEL COMBONI	ALTO SELVA ALEGRE	VILLA CONFRATERNIDAD MZ V LT 3 ZONA B	-16.38	-71.521111	040102	10	2026-09-22 16:44:38-05
261	IE SAN JOSE OBRERO CIRCA	ALTO SELVA ALEGRE	CALLE 12 DE OCTUBRE SN	-16.38	-71.521111	040102	6	2026-09-22 16:44:38-05
262	IE 40261 TOMAS GUZMAN GOMEZ	ALTO SELVA ALEGRE	CALLE PROGRESO SN	-16.38	-71.521111	040102	7	2026-09-22 16:44:38-05
263	CEBE AUVERGNE PERU FRANCIA	ALTO SELVA ALEGRE	AV ROOSEVELT 408	-16.38	-71.521111	040102	4	2026-09-22 16:44:38-05
264	IE 40222 DIEGO THOMSON	ALTO SELVA ALEGRE	CALLE CESAR VALLEJO SN	-16.38	-71.521111	040102	11	2026-09-22 16:44:38-05
265	IE EL MIRADOR AQP	ALTO SELVA ALEGRE	ASOC EL GRAN CHAPARRAL MZ C LT 5	-16.38	-71.521111	040102	6	2026-09-22 16:44:38-05
266	IEP ADOLFO KOLPING	ALTO SELVA ALEGRE	CALLE GARCIA CALDERON 601	-16.38	-71.521111	040102	7	2026-09-22 16:44:38-05
267	IEP ANDENES DE CHILINA	ALTO SELVA ALEGRE	AV FRANCISCO MOSTAJO SN	-16.38	-71.521111	040102	10	2026-09-22 16:44:38-05
268	IEP CESAR VALLEJO	ALTO SELVA ALEGRE	URB AUGUSTO SALAZAR BONDY MZ H LT 2	-16.38	-71.521111	040102	2	2026-09-22 16:44:38-05
269	IEP FEDERICO VILLARREAL	ALTO SELVA ALEGRE	CALLE LOS ANGELES SN INDEPENDENCIA ZN A MZ 53 LT 12	-16.38	-71.521111	040102	4	2026-09-22 16:44:38-05
270	IEP MAGISTERIAL	ALTO SELVA ALEGRE	SECTOR LEALTAD DEMOCRATICA MZ E LT 3 ZONA INDEPENDENCIA	-16.38	-71.521111	040102	4	2026-09-22 16:44:38-05
618	IE ALBERTO FLORES GALINDO	ORCOPAMPA	CALLE SANTA ROSA SN	-15.2625	-72.341944	040409	12	2026-09-22 16:44:39-05
619	IE 40140 PAMPACOLCA	PAMPACOLCA	CALLE JUAN PABLO VIZCARDO Y GUZMAN 205	-15.713333	-72.573889	040410	3	2026-09-22 16:44:39-05
620	IE GLORIOSO JUAN PABLO VISCARDO Y GUZMAN	PAMPACOLCA	AV INDEPENDENCIA 1211	-15.713333	-72.573889	040410	3	2026-09-22 16:44:39-05
621	IE CESAR A DURAN LAZARTE	TIPAN	CALLE TORREBLANCA SN	-15.723056	-72.501944	040411	2	2026-09-22 16:44:39-05
622	IE 40330	UÑON	CALLE PROGRESO SN	-15.728611	-72.432222	040412	1	2026-09-22 16:44:39-05
623	IE MIXTO CORIRE	URACA	AV JOSE CARLOS MARIATEGUI SN	-16.223889	-72.469722	040413	8	2026-09-22 16:44:39-05
624	IE NUESTRA SEÑORA DEL CARMEN	URACA	CALLE JUAN PABLO VIZCARDO Y GUZMAN 446	-16.223889	-72.469722	040413	12	2026-09-22 16:44:39-05
625	IE 40336 SAGRADO CORAZON DE JESUS	VIRACO	CALLE LOS ARRAYANES 100	-15.658333	-72.525	040414	4	2026-09-22 16:44:39-05
626	IE 40374 ELIAS CACERES LOZADA	CHIVAY	CALLE BOLOGNESI SN	-15.640278	-71.603611	040501	7	2026-09-22 16:44:39-05
627	IE 40375 MARIA AUXILIADORA	CHIVAY	CALLE MARIANO MELGAR SN	-15.640278	-71.603611	040501	9	2026-09-22 16:44:39-05
628	IE 40376 ACHOMA	ACHOMA	CALLE SUCRE SN	-15.66	-71.703611	040502	4	2026-09-22 16:44:39-05
629	IE 40379 PINCHOLLO	CABANACONDE	CALLE SANCHEZ CERRO SN	-15.62	-71.981944	040503	2	2026-09-22 16:44:39-05
630	IE 40377 JORGE AURELIO ABRIL FLORES	CABANACONDE	CALLE AREQUIPA SN	-15.62	-71.981944	040503	6	2026-09-22 16:44:39-05
631	IE LUIS PONCE GARCIA	CALLALLI	CALLE MANCO CAPAC SN	-15.506389	-71.444722	040504	6	2026-09-22 16:44:39-05
632	IE 40030 SAN FRANCISCO DE ASIS	CAYLLOMA	AV CAYLLOMA CAYARANI SN	-15.188889	-71.773333	040505	3	2026-09-22 16:44:39-05
633	IE 40381 SANTA ROSA DE LIMA	CAYLLOMA	CALLE MODESTO MALAGA SN	-15.188889	-71.773333	040505	10	2026-09-22 16:44:39-05
634	IE 40382 VIRGEN DE CHAPI SECUNDARIA	COPORAQUE	CALLE TACNA Y ARICA SN	-15.627222	-71.646111	040506	4	2026-09-22 16:44:39-05
635	IE 40383 JUAN PABLO II	HUAMBO	PLAZA DE ARMAS SN	-15.729444	-72.109722	040507	3	2026-09-22 16:44:39-05
636	IE 40384 SONCCOY QUILLA	HUANCA	CALLE PAMPA BERNEDO SN	-16.033611	-71.878056	040508	6	2026-09-22 16:44:39-05
637	IE 40386 TUPAC AMARU	ICHUPAMPA	CALLE BOLOGNESI SN	-15.65	-71.686667	040509	3	2026-09-22 16:44:39-05
639	IE 40389 MIGUEL LINARES MALAGA	LLUTA	CALLE MIGUEL LINARES MALAGA SN	-16.015556	-72.013889	040511	1	2026-09-22 16:44:39-05
640	IE 40388 CORAZON SAGRADO DE JESUS DE LLUTA	LLUTA	CALLE CALVARIO SN	-16.015556	-72.013889	040511	5	2026-09-22 16:44:39-05
641	IE 40390 MAYTA CAPAC	MACA	CALLE SAN ISIDRO SN	-15.641389	-71.768333	040512	3	2026-09-22 16:44:39-05
642	IE 40391 MADRIGAL	MADRIGAL	AV SAN MARTIN SN	-15.608333	-71.8075	040513	3	2026-09-22 16:44:39-05
643	IE 40392 JOSE ANTONIO ENCINAS FRANCO	SAN ANTONIO DE CHUCA	CALLE MARISCAL CASTILLA S/N	-15.838889	-71.090556	040514	4	2026-09-22 16:44:39-05
644	IE TECNICO AGROPECUARIO SIBAYO	SIBAYO	PJE FUNDICION SN	-15.486111	-71.456944	040515	3	2026-09-22 16:44:39-05
645	IE 40418 SECUNDARIA	TAPAY	CALLE JERUSALEN SN	-15.5775	-71.939722	040516	4	2026-09-22 16:44:39-05
646	IE 40395	TISCO	CALLE LA PAZ SN	-15.346944	-71.446389	040517	2	2026-09-22 16:44:39-05
647	IE 40321	TISCO	CALLE TARUCAMARCA SN	-15.346944	-71.446389	040517	1	2026-09-22 16:44:39-05
648	IE 40421 JOSE OLAYA BALANDRA	TISCO	PJE UNION SN	-15.346944	-71.446389	040517	3	2026-09-22 16:44:39-05
649	IE 40396	TUTI	CALLE JERUSALEN SN	-15.533056	-71.553056	040518	3	2026-09-22 16:44:39-05
650	IE 40399 GENERAL JUAN VELASCO ALVARADO	YANQUE	CALLE JERUSALEN 508	-15.648333	-71.660833	040519	2	2026-09-22 16:44:39-05
651	IE 40397 SAN ANTONIO DE PADUA	YANQUE	AV SAN ANTONIO 300	-15.648333	-71.660833	040519	6	2026-09-22 16:44:39-05
652	IE 40594 JUAN VELASCO ALVARADO	MAJES	SECTOR EL PIONERO MZ I LOTE 1	-16.353333	-72.247222	040520	23	2026-09-22 16:44:39-05
653	IE ALMIRANTE MIGUEL GRAU	MAJES	AV AREQUIPA SN	-16.353333	-72.247222	040520	23	2026-09-22 16:44:39-05
654	IEP JUSTO JUEZ	MAJES	URB LAS MALVINAS MZ U LT 1	-16.353333	-72.247222	040520	8	2026-09-22 16:44:39-05
655	IE 40661 ISABEL KRIEGER BEATO	MAJES	CENTRO DE SERVICIO ASENTAMIENTO E3	-16.353333	-72.247222	040520	15	2026-09-22 16:44:40-05
656	IE 40698 SAN JUAN BAUTISTA DE MAJES SECUNDARIA	MAJES	LT 491 MZ B1 LOTE 12 PEDREGAL SUR I ETAPA MAJES	-16.353333	-72.247222	040520	7	2026-09-22 16:44:40-05
677	IE 40439 SAN JUAN BAUTISTA DE LA SALLE	YANAQUIHUA	CALLE LOS ESTUDIANTES SN	-15.775556	-72.876389	040608	3	2026-09-22 16:44:40-05
678	IE JORGE BASADRE	YANAQUIHUA	AV BRASIL SN	-15.775556	-72.876389	040608	8	2026-09-22 16:44:40-05
679	IE 40438	YANAQUIHUA	CALLE 28 DE JULIO SN	-15.775556	-72.876389	040608	5	2026-09-22 16:44:40-05
680	IE SAN VICENTE DE PAUL	MOLLENDO	CALLE COMERCIO 1014	-17.029167	-72.016389	040701	6	2026-09-22 16:44:40-05
681	IE 40474 JOSE CARLOS MARIATEGUI	MOLLENDO	JR. ANTONIO MELCHOR CRUCE CON JR. PEDRO GARZON	-17.029167	-72.016389	040701	14	2026-09-22 16:44:40-05
234	UNIVERSIDAD NACIONAL DE SAN AGUSTIN AREA DE BIOMEDICAS	AREQUIPA	AV DANIEL ALCIDES CARRION SN	-16.393333	-71.528889	040101	15	2026-09-22 16:44:38-05
235	UNIVERSIDAD NACIONAL DE SAN AGUSTIN AREA DE INGENIERIAS	AREQUIPA	AV INDEPENDENCIA SN	-16.393333	-71.528889	040101	33	2026-09-22 16:44:38-05
236	IE INDEPENDENCIA AMERICANA	AREQUIPA	AV INDEPENDENCIA 1457 URB IV CENTENARIO	-16.393333	-71.528889	040101	25	2026-09-22 16:44:38-05
237	IE 40001 LUIS H BOURONCLE	AREQUIPA	CALLE PERAL 710	-16.393333	-71.528889	040101	14	2026-09-22 16:44:38-05
238	IE 40002 AL AIRE LIBRE	AREQUIPA	CALLE ECHEVARRIA 201	-16.393333	-71.528889	040101	9	2026-09-22 16:44:38-05
239	IE 40143 SAN PEDRO	AREQUIPA	URB PABLO VI II ETAPA P 21	-16.393333	-71.528889	040101	10	2026-09-22 16:44:38-05
240	IE 40020 ESCUELA ECOLOGICA URBANA	AREQUIPA	PJE SELVA ALEGRE SN	-16.393333	-71.528889	040101	10	2026-09-22 16:44:38-05
241	IEP BRYCE SAC	AREQUIPA	CALLE MANUEL MUÑOZ NAJAR 220	-16.393333	-71.528889	040101	10	2026-09-22 16:44:38-05
242	IE 40003 SANTISIMA VIRGEN DEL CARMEN	ALTO SELVA ALEGRE	CALLE 13 DE ABRIL 513	-16.38	-71.521111	040102	13	2026-09-22 16:44:38-05
243	IE 40024 MANUEL GONZALES PRADA	ALTO SELVA ALEGRE	AV OBRERA 100	-16.38	-71.521111	040102	3	2026-09-22 16:44:38-05
244	IE 40034 MARIO VARGAS LLOSA	ALTO SELVA ALEGRE	CALLE OSCAR NEVES SN	-16.38	-71.521111	040102	13	2026-09-22 16:44:38-05
245	IE 41035 NICANOR RIVERA CACERES	ALTO SELVA ALEGRE	AV LOS INCAS SN	-16.38	-71.521111	040102	7	2026-09-22 16:44:38-05
246	IE SANTA ROSA DE LIMA CIRCA NIVEL SECUNDARIO	ALTO SELVA ALEGRE	CALLE PACIFICO Y AMAZONAS SN	-16.38	-71.521111	040102	5	2026-09-22 16:44:38-05
247	IE SANTA ROSA DE LIMA Y LAS AMERICAS CIRCA NIVEL PRIMARIA	ALTO SELVA ALEGRE	CALLE VILCANOTA 208	-16.38	-71.521111	040102	2	2026-09-22 16:44:38-05
490	IE LA CAMPIÑA	SOCABAYA	AV LA CAMPIÑA SN	-16.4675	-71.528611	040122	8	2026-09-22 16:44:39-05
271	IEP KEPLER	ALTO SELVA ALEGRE	AAHH VILLA ECOLOGICA MZ P LOTE 1	-16.38	-71.521111	040102	3	2026-09-22 16:44:38-05
272	IEI INDEPENDENCIA B 1	ALTO SELVA ALEGRE	JR JORGE CHAVEZ SN	-16.38	-71.521111	040102	2	2026-09-22 16:44:38-05
273	IEI VILLA ASUNCION	ALTO SELVA ALEGRE	JR HOYOS RUBIO MZ O LT 16	-16.38	-71.521111	040102	2	2026-09-22 16:44:38-05
274	IE 40046 JOSE LORENZO CORNEJO ACOSTA	CAYMA	CALLE SUCRE SN	-16.3625	-71.544167	040103	11	2026-09-22 16:44:38-05
275	IE 40049 CORONEL FRANCISCO BOLOGNESI CERVANTES	CAYMA	AV CHACHANI SN	-16.3625	-71.544167	040103	17	2026-09-22 16:44:39-05
276	IE LEON XIII CIRCA SECUNDARIA	CAYMA	AV CHACHANI SN	-16.3625	-71.544167	040103	26	2026-09-22 16:44:39-05
277	IE MAYTA CAPAC	CAYMA	AV BOLOGNESI SN	-16.3625	-71.544167	040103	8	2026-09-22 16:44:39-05
278	IESPP AREQUIPA	CAYMA	AV RAMON CASTILLA 700	-16.3625	-71.544167	040103	24	2026-09-22 16:44:39-05
279	IE HONORIO DELGADO ESPINOZA	CAYMA	CALLE LOS ARCES 202	-16.3625	-71.544167	040103	18	2026-09-22 16:44:39-05
280	IE 40040 JOSE TRINIDAD MORAN	CAYMA	AV TUPAC AMARU SN	-16.3625	-71.544167	040103	8	2026-09-22 16:44:39-05
281	IE 40669 DEAN VALDIVIA SECUNDARIA	CAYMA	COMPLEJO HABITACIONAL DEAN VALDIVIA SECTOR 8 MZ T LT 1	-16.3625	-71.544167	040103	6	2026-09-22 16:44:39-05
282	IE 40669 DEAN VALDIVIA PRIMARIA	CAYMA	COMPLEJO HABITACIONAL DEAN VALDIVIA SECTOR 6 MZ S LT 1	-16.3625	-71.544167	040103	8	2026-09-22 16:44:39-05
283	IE 40606 SEUL	CAYMA	CALLE COMERCIO SUR MZ A LT 3 SECTOR II	-16.3625	-71.544167	040103	4	2026-09-22 16:44:39-05
284	CEBA MAYTA CAPAC	CAYMA	AV BOLOGNESI SN	-16.3625	-71.544167	040103	3	2026-09-22 16:44:39-05
285	IE 40687 FELIX RIVAS GONZALES	CAYMA	AV CHARCANI SN	-16.3625	-71.544167	040103	3	2026-09-22 16:44:39-05
286	IE COMPLEJO HABITACIONAL DEAN VALDIVIA SECTOR 12	CAYMA	COMPLEJO HABITACIONAL DEAN VALDIVIA SECTOR 12	-16.3625	-71.544167	040103	2	2026-09-22 16:44:39-05
287	IE JOHN G LAKE	CAYMA	URB DEAN VALDIVIA SECTOR 4 MZ U LT 7	-16.3625	-71.544167	040103	4	2026-09-22 16:44:39-05
288	IEP CRISTIAN BARNARD	CAYMA	AV BOLOGNESI 708	-16.3625	-71.544167	040103	7	2026-09-22 16:44:39-05
289	IE KENNETH E HAGIN	CAYMA	COMPLEJO HABITACIONAL DEAN VALDIVIA SECTOR 9 MZ L LT 9	-16.3625	-71.544167	040103	3	2026-09-22 16:44:39-05
290	IEP DIVINO CRISTO OBRERO	CAYMA	AV AREQUIPA 601	-16.3625	-71.544167	040103	8	2026-09-22 16:44:39-05
291	IEP TERESITA DE JESUS	CAYMA	AAHH DEAN VALDIVIA SECTOR 3 MZ J LT 30 31 32	-16.3625	-71.544167	040103	4	2026-09-22 16:44:39-05
292	IEPC THOMAS MC	CAYMA	AV JOSE CARLOS MARIATEGUI	-16.3625	-71.544167	040103	3	2026-09-22 16:44:39-05
293	IE 41024 MANUEL GALLEGOS SANZ	CAYMA	CALLE ZELA SN	-16.3625	-71.544167	040103	7	2026-09-22 16:44:39-05
294	IE EL PIONERO G 2	CAYMA	MZ G SECTOR 2	-16.3625	-71.544167	040103	7	2026-09-22 16:44:39-05
295	IEP NIÑO MAGISTRAL PRIMARIA	CAYMA	AV AREQUIPA 509	-16.3625	-71.544167	040103	9	2026-09-22 16:44:39-05
296	IE 40654 VIRGEN DE CHAPI	CAYMA	PJE SANTA ROSA SN MZ G PRIMA CENTRO POBLADO VIRGEN DE CHAPI	-16.3625	-71.544167	040103	4	2026-09-22 16:44:39-05
297	IEP NIÑO MAGISTRAL SECUNDARIA	CAYMA	CALLE REFORMA NACIONAL SN MZ O LT 27	-16.3625	-71.544167	040103	4	2026-09-22 16:44:39-05
298	IE 40052 EL PERUANO DEL MILENIO ALMIRANTE MIGUEL GRAU	CAYMA	AV JOSE CARLOS MARIATEGUI 351	-16.3625	-71.544167	040103	8	2026-09-22 16:44:39-05
299	IE 40081 MIGUEL CESAR AUGUSTO MAZEYRA ACOSTA	CAYMA	AV TRINIDAD MORAN SN	-16.3625	-71.544167	040103	5	2026-09-22 16:44:39-05
300	IE 40618 MONSEÑOR JOSE DE PIRO D AMICO INGUANEZ PRIMARIA	CAYMA	AV PROGRESO 400	-16.3625	-71.544167	040103	5	2026-09-22 16:44:39-05
301	IESTP HONORIO DELGADO ESPINOZA	CAYMA	CALLE LOS ARCES 202	-16.3625	-71.544167	040103	27	2026-09-22 16:44:39-05
302	IEP JASLIN	CAYMA	MZ F LT 15 ZONA A EMBAJADA DE JAPON	-16.3625	-71.544167	040103	9	2026-09-22 16:44:39-05
303	IEP JOULE CAYMA	CAYMA	JR BOLOGNESI 573 ACEQUIA ALTA	-16.3625	-71.544167	040103	6	2026-09-22 16:44:39-05
304	IEP SAN FERNANDO SECUNDARIA	CAYMA	AV SUCRE 1061	-16.3625	-71.544167	040103	3	2026-09-22 16:44:39-05
305	IEP SAN JUAN MASIAS	CAYMA	CALLE ESTRELLA 1 ALTO CAYMA	-16.3625	-71.544167	040103	4	2026-09-22 16:44:39-05
306	IEP BALMER CAYMA	CAYMA	AV GENERAL VARELA 670	-16.3625	-71.544167	040103	9	2026-09-22 16:44:39-05
307	IE 40044 SAN MARTIN DE PORRES	CERRO COLORADO	ASOC CIUDAD MUNICIPAL MZ Q LT 1	-16.376389	-71.560833	040104	15	2026-09-22 16:44:39-05
308	IE 40054 JUAN DOMINGO ZAMACOLA Y JAUREGUI	CERRO COLORADO	CALLE JORGE CHAVEZ 401	-16.376389	-71.560833	040104	33	2026-09-22 16:44:39-05
309	IE 40670 EL EDEN FE Y ALEGRIA 51	CERRO COLORADO	ASOC DE VIVIENDA LA TIERRA PROMETIDA MZ I J	-16.376389	-71.560833	040104	16	2026-09-22 16:44:39-05
310	IE 41025 200 MILLAS PERUANAS	CERRO COLORADO	CALLE 27 DE NOVIEMBRE 307	-16.376389	-71.560833	040104	7	2026-09-22 16:44:39-05
311	IE 41026 MARIA MURILLO DE BERNAL	CERRO COLORADO	CALLE MARIANO MELGAR 401	-16.376389	-71.560833	040104	9	2026-09-22 16:44:39-05
313	IE 40058 IGNACIO ALVAREZ THOMAS	CERRO COLORADO	CALLE JOSE OLAYA SN	-16.376389	-71.560833	040104	8	2026-09-22 16:44:39-05
314	IE 40103 LIBERTADORES DE AMERICA	CERRO COLORADO	CALLE IQUITOS SN	-16.376389	-71.560833	040104	16	2026-09-22 16:44:39-05
315	IE SANTO TOMAS DE AQUINO	CERRO COLORADO	CALLE SAN MARTIN 214	-16.376389	-71.560833	040104	21	2026-09-22 16:44:39-05
316	IE 40055 ROMEO LUNA VICTORIA	CERRO COLORADO	CALLE YAPURA 306	-16.376389	-71.560833	040104	15	2026-09-22 16:44:39-05
317	IE 40689 ALFREDO RODRIGUEZ BALLON	CERRO COLORADO	UPIS MERCADO MAYORISTA MZ M LT 1	-16.376389	-71.560833	040104	8	2026-09-22 16:44:39-05
318	IEP ALEXANDER FRIEDMAN	CERRO COLORADO	ASOC CIUDAD MUNICIPAL MZ M LT 2-3 ZONA 1	-16.376389	-71.560833	040104	15	2026-09-22 16:44:39-05
319	IE 40671 VILLA SAN JUAN	CERRO COLORADO	AV PRINCIPAL SN MZ B LT 1	-16.376389	-71.560833	040104	6	2026-09-22 16:44:39-05
320	IE CRISTO MORADO	CERRO COLORADO	ASOC CIUDAD MUNICIPAL ZONA VII MZ T LT 1	-16.376389	-71.560833	040104	5	2026-09-22 16:44:39-05
321	IE JOSE LUIS BUSTAMANTE Y RIVERO	CERRO COLORADO	ASOC JOSE LUIS BUSTAMANTE Y RIVERO SECTOR V	-16.376389	-71.560833	040104	12	2026-09-22 16:44:39-05
322	IEP JOHN FORBES	CERRO COLORADO	ASOC VILLA CHACHANI MZ A LT 10	-16.376389	-71.560833	040104	13	2026-09-22 16:44:39-05
323	IE SAN PIO X CIRCA	CERRO COLORADO	UPIS MERCADO MAYORISTA ZONA B MZ LL LT 1	-16.376389	-71.560833	040104	16	2026-09-22 16:44:39-05
324	IEP LEONARDO DA VINCI	CERRO COLORADO	ASOC JOSE LUIS BUSTAMANTE Y RIVERO SECTOR VII MZ 1G LT 4	-16.376389	-71.560833	040104	7	2026-09-22 16:44:39-05
325	IEP BRUNING HANS HEIMBRICH	CERRO COLORADO	AV AVIACION KM 7.5	-16.376389	-71.560833	040104	11	2026-09-22 16:44:39-05
326	IEP LAS PLUMAS DEL AMAUTA	CERRO COLORADO	ASOC JOSE LUIS BUSTAMANTE Y RIVERO SECTOR IX MZ 12E LT 7 8	-16.376389	-71.560833	040104	13	2026-09-22 16:44:39-05
327	IEP SAN FRANCISCO DE SALES	CERRO COLORADO	ASOC PRIMAVERA Y LOS ANGELES DE ZAMACOLA MZ A LT 35	-16.376389	-71.560833	040104	7	2026-09-22 16:44:39-05
328	IEP SEÑOR DE LA CAÑA	CERRO COLORADO	ASOC JOSE LUIS BUSTAMANTE Y RIVERO SECTOR V MZ 12B LT 1	-16.376389	-71.560833	040104	9	2026-09-22 16:44:39-05
329	IEP STEPHEN WILLIAM HAWKING	CERRO COLORADO	AV 54 MZ I LOTE 9 10 ZONA	-16.376389	-71.560833	040104	7	2026-09-22 16:44:39-05
330	IEP GRUPO BALMER SAC	CERRO COLORADO	CALLE FILOMENA 103	-16.376389	-71.560833	040104	9	2026-09-22 16:44:39-05
331	IEP HOLY SCHOOLS	CERRO COLORADO	ASOC APIPA MZ H LOTE 40 SECTOR II	-16.376389	-71.560833	040104	16	2026-09-22 16:44:39-05
332	IEP SAN FRANCISCO DE SALES AREQUIPA NORTE	CERRO COLORADO	ASOC HERNAN BEDOYA FORGA ETAPA II MZ D LT1 27 AL 30	-16.376389	-71.560833	040104	9	2026-09-22 16:44:39-05
333	IEP TALENTS SCHOOL	CERRO COLORADO	ASOC JOSE MARIA ARGUEDAS MZ C LT 6-7	-16.376389	-71.560833	040104	7	2026-09-22 16:44:39-05
334	IEP LA SAGRADA FAMILIA DE APIPA	CERRO COLORADO	APIPA MZ B LT 5 Y 1 SECTOR X	-16.376389	-71.560833	040104	8	2026-09-22 16:44:39-05
335	IEP RONALD FISHER	CERRO COLORADO	ASOC PERUARBO SECTOR BOLIVIA III INDUSTRIA MZ C LT 16	-16.376389	-71.560833	040104	8	2026-09-22 16:44:39-05
336	IEP EL EMPERADOR	CERRO COLORADO	ASOC CARLOS BACA FLOR MZ M LT 5 6 7	-16.376389	-71.560833	040104	12	2026-09-22 16:44:39-05
337	IE CRISTO REY CIRCA	CERRO COLORADO	JR 1 EL NAZARENO SN	-16.376389	-71.560833	040104	13	2026-09-22 16:44:39-05
338	IEI ZAMACOLA	CERRO COLORADO	CALLE PUTUMAYO SN	-16.376389	-71.560833	040104	6	2026-09-22 16:44:39-05
339	IE SAN JUAN APOSTOL	CERRO COLORADO	ASOC VILLA CERRILLOS MZ A LT 1 ZONA C	-16.376389	-71.560833	040104	16	2026-09-22 16:44:39-05
340	IE CASA DE CARIDAD ARTES Y OFICIOS	CERRO COLORADO	ASOC FRANCISCO GARCÍA CALDERÓN ZN 1 MZ W LT 1	-16.376389	-71.560833	040104	11	2026-09-22 16:44:39-05
341	IEPC THOMAS MC III	CERRO COLORADO	ASOC HEROES DE LA BREÑA MZ D LT 7 8	-16.376389	-71.560833	040104	13	2026-09-22 16:44:39-05
342	IE 40677 SAN MIGUEL FEBRES CORDERO	CERRO COLORADO	ZONA 1 VILLA LAS CANTERAS	-16.376389	-71.560833	040104	7	2026-09-22 16:44:39-05
343	IE 40035 VICTOR ANDRES BELAUNDE	CERRO COLORADO	AV PRINCIPAL SN	-16.376389	-71.560833	040104	13	2026-09-22 16:44:39-05
344	IE 40106 JUAN SANTOS ATAHUALPA	CERRO COLORADO	AV JOSE SANTOS ATAHUALPA SN	-16.376389	-71.560833	040104	10	2026-09-22 16:44:39-05
345	IEP SAN MATEO ANGLICAN SCHOOL SEDE ZAMACOLA	CERRO COLORADO	CALLE PURUS 600	-16.376389	-71.560833	040104	7	2026-09-22 16:44:39-05
346	IEP ILUMINADORA VIRGEN DEL CARMEN	CERRO COLORADO	MZ J1 LT 22 Y 23 SECTOR XV APIPA	-16.376389	-71.560833	040104	5	2026-09-22 16:44:39-05
347	IEP INTERNACIONAL JOHANNES KEPLER	CERRO COLORADO	AAHH PEDRO P DIAZ MZ 49 LT 3 Y 4	-16.376389	-71.560833	040104	8	2026-09-22 16:44:39-05
348	IEP JESUS MAESTRO	CERRO COLORADO	ASOC BENIGNO BALLON FARFAN MZ I LT 2 Y 3	-16.376389	-71.560833	040104	8	2026-09-22 16:44:39-05
349	IEP JESUS MAESTRO I	CERRO COLORADO	ASOC VILLA SANTA MARIA MZ E LT 5 Y 6	-16.376389	-71.560833	040104	11	2026-09-22 16:44:39-05
350	IEP SABIO ALFRED BINET	CERRO COLORADO	UPIS MERCADO MAYORISTA ZONA A MZ E LT 11 12 13	-16.376389	-71.560833	040104	12	2026-09-22 16:44:39-05
351	IEP SAN MATEO ANGLICAN SCHOOL SEDE ALTO LIBERTAD	CERRO COLORADO	ESQUINA AV PERU CON CALLE BOLOGNESI	-16.376389	-71.560833	040104	6	2026-09-22 16:44:39-05
352	IE SAN JOSE DE COTTOLENGO CIRCA	CERRO COLORADO	ASOC ANDRES AVELINO CACERES MZ A LT 1	-16.376389	-71.560833	040104	16	2026-09-22 16:44:39-05
353	IE 40123 SAN JUAN BAUTISTA	CHARACATO	CALLE SANTA ROSA SN	-16.468611	-71.484444	040105	7	2026-09-22 16:44:39-05
354	IE ANGEL FRANCISCO ALI GUILLEN	CHARACATO	AV COLEGIO NACIONAL	-16.468611	-71.484444	040105	11	2026-09-22 16:44:39-05
355	IEP ITALO PERUANO ALESSANDRO VOLTA	CHARACATO	ASOVICH ZONA B MZ A LT2	-16.468611	-71.484444	040105	16	2026-09-22 16:44:39-05
356	IEI SAN FRANCISCO	CHARACATO	CALLE AREQUIPA SN	-16.468611	-71.484444	040105	2	2026-09-22 16:44:39-05
357	IE 40127 SEÑOR DEL ESPIRITU SANTO	CHIGUATA	CALLE 27 DE OCTUBRE SN	-16.403611	-71.391667	040106	6	2026-09-22 16:44:39-05
358	IE 40637 FERNANDO BELAUNDE TERRY	CHIGUATA	CALLE LA PLAZA SN	-16.403611	-71.391667	040106	4	2026-09-22 16:44:39-05
359	IE 40675 GRAL VELASCO ALVARADO	CHIGUATA	AV BRASIL SN	-16.403611	-71.391667	040106	4	2026-09-22 16:44:39-05
360	IE 40033 SAN AGUSTIN DE HUNTER	JACOBO HUNTER	UPIS PAISAJISTA F1	-16.441389	-71.558611	040107	10	2026-09-22 16:44:39-05
524	IE EL ALTIPLANO	YURA	AV JUAN VELASCO ALVARADO SN	-16.246944	-71.706389	040128	14	2026-09-22 16:44:39-05
361	IE 40043 NUESTRA SEÑORA DE LA MEDALLA MILAGROSA	JACOBO HUNTER	AV ITALIA CUADRA 3 SN	-16.441389	-71.558611	040107	11	2026-09-22 16:44:39-05
362	IE 40200 REPUBLICA FEDERAL ALEMANA	JACOBO HUNTER	AV ITALIA 700	-16.441389	-71.558611	040107	15	2026-09-22 16:44:39-05
363	IE 40206 MILAGROS	JACOBO HUNTER	CALLE SAN SALVADOR 401	-16.441389	-71.558611	040107	8	2026-09-22 16:44:39-05
364	IE 40207 MARIANO MELGAR VALDIVIESO	JACOBO HUNTER	CALLE SANCHEZ CERRO 100	-16.441389	-71.558611	040107	22	2026-09-22 16:44:39-05
365	IE JUAN PABLO VIZCARDO Y GUZMAN	JACOBO HUNTER	AV VIÑA DEL MAR 1300	-16.441389	-71.558611	040107	25	2026-09-22 16:44:39-05
366	IE SAN ANTONIO MARIA CLARET CIRCA	JACOBO HUNTER	CALLE COSTA RICA SN	-16.441389	-71.558611	040107	22	2026-09-22 16:44:39-05
367	IE ADVENTISTA EDUARDO FRANCISCO FORGA	JACOBO HUNTER	CALLE JERUSALEN 202	-16.441389	-71.558611	040107	14	2026-09-22 16:44:39-05
368	IEP GRAN MAESTRO JUAN ENRIQUE PESTALOZZI SECUNDARIA	JACOBO HUNTER	AV SAN MIGUEL DE PIURA MZ B LT 3	-16.441389	-71.558611	040107	5	2026-09-22 16:44:39-05
369	IEP GRAN MAESTRO JUAN ENRIQUE PESTALOZZI PRIMARIA	JACOBO HUNTER	CALLE TENIENTE NESTOR BATANEROS 215	-16.441389	-71.558611	040107	5	2026-09-22 16:44:39-05
370	IEP MARIANISTA - PRIMARIA	JACOBO HUNTER	PJE PROGRESO 101	-16.441389	-71.558611	040107	5	2026-09-22 16:44:39-05
371	IE 40065 GLORIOSO HEROES DEL CENEPA	LA JOYA	CENTRO DE SERVICIOS M H LT 7	-16.423056	-71.818333	040108	4	2026-09-22 16:44:39-05
372	IE 40326 JUAN VELASCO ALVARADO	LA JOYA	CENTRO DE SERVICIOS DEL ASENTAMIENTO 6	-16.423056	-71.818333	040108	16	2026-09-22 16:44:39-05
373	IE JESUS	LA JOYA	AV PAZ SOLDAN SN	-16.423056	-71.818333	040108	11	2026-09-22 16:44:39-05
374	IE 40062 SEÑORA DE FATIMA	LA JOYA	AV PAZ SOLDAN 107	-16.423056	-71.818333	040108	13	2026-09-22 16:44:39-05
375	IE EL CRUCE	LA JOYA	JR JOSE CARLOS MARIATEGUI SN	-16.423056	-71.818333	040108	14	2026-09-22 16:44:39-05
376	IE 40137 NUESTRA SEÑORA DE LA GLORIA	LA JOYA	URB LA FLORIDA SN	-16.423056	-71.818333	040108	10	2026-09-22 16:44:39-05
377	IE CARLOS W SUTTON	LA JOYA	JR DOS DE MAYO SN	-16.423056	-71.818333	040108	16	2026-09-22 16:44:39-05
378	IE 40068	LA JOYA	AV PRINCIPAL SN EL RAMAL	-16.423056	-71.818333	040108	6	2026-09-22 16:44:39-05
379	IEP SAN FERNANDO	LA JOYA	AV 2 DE MAYO 205	-16.423056	-71.818333	040108	8	2026-09-22 16:44:39-05
380	IE GUE MARIANO MELGAR VALDIVIESO	MARIANO MELGAR	AV JESUS 513	-16.407222	-71.505556	040109	35	2026-09-22 16:44:39-05
381	IE ANDREA VALDIVIESO DE MELGAR	MARIANO MELGAR	CALLE JUNIN 500	-16.407222	-71.505556	040109	13	2026-09-22 16:44:39-05
382	IE 40129 MANUEL VERAMENDI E HIDALGO	MARIANO MELGAR	CALLE NICARAGUA SN	-16.407222	-71.505556	040109	13	2026-09-22 16:44:39-05
383	IE PIO XII	MARIANO MELGAR	AV BRASIL 325	-16.407222	-71.505556	040109	13	2026-09-22 16:44:39-05
384	IE 41031 MADRE DEL DIVINO AMOR	MARIANO MELGAR	CALLE JUAN MANUEL POLAR 407	-16.407222	-71.505556	040109	15	2026-09-22 16:44:39-05
385	IE SAN FRANCISCO JAVIER CIRCA	MARIANO MELGAR	CALLE MUNICH E1	-16.407222	-71.505556	040109	10	2026-09-22 16:44:39-05
386	IE CORAZON DE JESUS CIRCA	MARIANO MELGAR	CALLE COMANDANTE CANGA 600	-16.407222	-71.505556	040109	18	2026-09-22 16:44:39-05
387	IE 40134	MARIANO MELGAR	CALLE PARQUE BOLIVAR 103	-16.407222	-71.505556	040109	13	2026-09-22 16:44:39-05
388	IE 40139 ANDRES AVELINO CACERES DORREGARAY	MARIANO MELGAR	CALLE BELEN SN	-16.407222	-71.505556	040109	13	2026-09-22 16:44:39-05
389	IE POLITECNICO RAFAEL SANTIAGO LOAYZA GUEVARA	MARIANO MELGAR	AV JESUS 515	-16.407222	-71.505556	040109	26	2026-09-22 16:44:39-05
390	IEP PREMIO NOBEL MARIO VARGAS LLOSA	MARIANO MELGAR	CALLE CHANCAY 702	-16.407222	-71.505556	040109	10	2026-09-22 16:44:39-05
391	IE 40148 GERARDO IQUIRA PIZARRO	MIRAFLORES	AV GOYENECHE 2900	-16.394722	-71.5225	040110	6	2026-09-22 16:44:39-05
392	IE 40151 CAP FAP JOSÉ ABELARDO QUIÑONES	MIRAFLORES	CALLE GONZALES PRADA 100	-16.394722	-71.5225	040110	5	2026-09-22 16:44:39-05
393	IE 40157 JORGE LUIS BORGES	MIRAFLORES	CALLE GONZALES PRADA SN	-16.394722	-71.5225	040110	5	2026-09-22 16:44:39-05
394	IE 40159 EJÉRCITO AREQUIPA	MIRAFLORES	CALLE PROGRESO 1220	-16.394722	-71.5225	040110	17	2026-09-22 16:44:39-05
395	IE 41016 REPUBLICA ARGENTINA	MIRAFLORES	CALLE ARICA 259	-16.394722	-71.5225	040110	7	2026-09-22 16:44:39-05
396	IE 41037 JOSÉ GALVEZ	MIRAFLORES	PJE SAN MARTIN SN	-16.394722	-71.5225	040110	8	2026-09-22 16:44:39-05
397	IE FRANCISCO JAVIER DE LUNA PIZARRO	MIRAFLORES	AV SAN MARTIN 2303	-16.394722	-71.5225	040110	12	2026-09-22 16:44:39-05
398	IE 40158 EL GRAN AMAUTA	MIRAFLORES	AV SAN MARTIN 4403	-16.394722	-71.5225	040110	11	2026-09-22 16:44:39-05
399	IE 40133 CIRIACO VERA PEREA	MIRAFLORES	CALLE RAMON CASTILLA 721	-16.394722	-71.5225	040110	3	2026-09-22 16:44:39-05
400	IEI DIVINO NIÑO JESUS	MIRAFLORES	CALLE PASCO MZ 58 LT 2	-16.394722	-71.5225	040110	3	2026-09-22 16:44:39-05
401	IEI MISTI	MIRAFLORES	CALLE MARIA NIEVES BUSTAMANTE 116	-16.394722	-71.5225	040110	3	2026-09-22 16:44:39-05
402	IEP LA CANTUTA DE AREQUIPA	MIRAFLORES	CALLE SAN ANTONIO 109	-16.394722	-71.5225	040110	15	2026-09-22 16:44:39-05
403	IEP CRISTO OBRERO	MIRAFLORES	CALLE TACNA Y ARICA 301	-16.394722	-71.5225	040110	6	2026-09-22 16:44:39-05
404	IE PADRE ELOY ARRIBAS LAZARO	MIRAFLORES	CALLE JOSE CARLOS MARIATEGUI MZ R LT 18	-16.394722	-71.5225	040110	4	2026-09-22 16:44:39-05
405	IE 40144 AUGUSTO SALAZAR BONDY	MIRAFLORES	AV PROHOGAR 1002	-16.394722	-71.5225	040110	9	2026-09-22 16:44:39-05
406	IEP SALOMON	MIRAFLORES	AV GOYENECHE 715	-16.394722	-71.5225	040110	7	2026-09-22 16:44:39-05
407	CETPRO GUAMAN POMA	MIRAFLORES	AV BOLOGNESI 800	-16.394722	-71.5225	040110	3	2026-09-22 16:44:39-05
408	IEP KAROL JOSEF	MIRAFLORES	CALLE LIMA 301	-16.394722	-71.5225	040110	5	2026-09-22 16:44:39-05
409	IEP CORPUS CHRISTI	MIRAFLORES	CALLE SANCHEZ TRUJILLO 240	-16.394722	-71.5225	040110	7	2026-09-22 16:44:39-05
410	IEP FRANCIS COLLINS SCHOOL - PRIMARIA	MIRAFLORES	CALLE SANCHEZ TRUJILLO 114 - 116	-16.394722	-71.5225	040110	6	2026-09-22 16:44:39-05
411	IEP LORD KARMEL	MIRAFLORES	AV TARAPACA 1309	-16.394722	-71.5225	040110	9	2026-09-22 16:44:39-05
412	IEP ENRICO FERMI	MIRAFLORES	CALLE HIPOLITO UNANUE 129	-16.394722	-71.5225	040110	9	2026-09-22 16:44:39-05
413	IEP FRANCIS COLLINS SCHOOL	MIRAFLORES	CALLE JORGE CHAVEZ 621	-16.394722	-71.5225	040110	8	2026-09-22 16:44:39-05
414	IEP SANTISIMO NIÑO DE MARIA	MIRAFLORES	CALLE 22 DE AGOSTO 405	-16.394722	-71.5225	040110	8	2026-09-22 16:44:39-05
415	IE 40160 OBDULIO BARRIGA VIZCARRA	MOLLEBAYA	CALLE UNION SN	-16.487222	-71.466944	040111	7	2026-09-22 16:44:39-05
416	IE 40263 PABLO VELARDE MANRIQUE	MOLLEBAYA	MACHAHUAYA SN SAN ISIDRO	-16.487222	-71.466944	040111	2	2026-09-22 16:44:39-05
417	ASOCIACION DE VIVIENDA SAN ISIDRO	MOLLEBAYA	AV MOLLEBAYA SN ANEXO MACHAHUAYA	-16.487222	-71.466944	040111	4	2026-09-22 16:44:39-05
418	IE 40300 MIGUEL GRAU	PAUCARPATA	AV VENEZUELA SN	-16.432778	-71.504722	040112	10	2026-09-22 16:44:39-05
419	IE 40010 JULIO C TELLO	PAUCARPATA	CALLE MELGAR SN	-16.432778	-71.504722	040112	9	2026-09-22 16:44:39-05
420	IE 40161 MONSEÑOR JOSE LUIS DEL CARPIO RIVERA	PAUCARPATA	CALLE COLON 105	-16.432778	-71.504722	040112	6	2026-09-22 16:44:39-05
421	IE 40163 BENIGNO BALLON FARFAN	PAUCARPATA	AV BRASIL 300 URB 15 DE ENERO	-16.432778	-71.504722	040112	24	2026-09-22 16:44:39-05
422	IE 40164 JOSÉ CARLOS MARIATEGUI	PAUCARPATA	CALLE AREQUIPA 100	-16.432778	-71.504722	040112	13	2026-09-22 16:44:39-05
423	IE 40178 VICTOR RAUL HAYA DE LA TORRE	PAUCARPATA	CALLE ELIAS AGUIRRE 100 PJ MIGUEL GRAU	-16.432778	-71.504722	040112	14	2026-09-22 16:44:39-05
424	IE JUAN XXIII CIRCA	PAUCARPATA	CALLE JOSE CARLOS MARIATEGUI SN	-16.432778	-71.504722	040112	8	2026-09-22 16:44:39-05
425	IE NEPTALI VALDERRAMA AMPUERO	PAUCARPATA	AV PIZARRO 132	-16.432778	-71.504722	040112	22	2026-09-22 16:44:39-05
426	IE SAN PEDRO Y SAN PABLO CIRCA	PAUCARPATA	AV LA MAR SN URB JORGE CHAVEZ	-16.432778	-71.504722	040112	18	2026-09-22 16:44:39-05
427	IE SOR ANA CIRCA	PAUCARPATA	CALLE 24 DE JUNIO SN CIUDAD BLANCA	-16.432778	-71.504722	040112	21	2026-09-22 16:44:39-05
428	IE 40630 VIRGEN DEL CARMEN	PAUCARPATA	AAHH VIRGEN DEL CARMEN MZ K LT 1	-16.432778	-71.504722	040112	6	2026-09-22 16:44:39-05
429	IE PADRE PEREZ DE GUEREÑU	PAUCARPATA	AV CHE GUEVARA 700	-16.432778	-71.504722	040112	22	2026-09-22 16:44:39-05
430	IEP GRAN PADRE AMADO	PAUCARPATA	CALLE NICARAGUA SN PARCELA 3	-16.432778	-71.504722	040112	10	2026-09-22 16:44:39-05
431	IEP SAN SEBASTIAN	PAUCARPATA	COOPERATIVA VILLA PORONGOCHE C 17	-16.432778	-71.504722	040112	6	2026-09-22 16:44:39-05
432	IE 40009 SAN MARTIN DE PORRES	PAUCARPATA	AV SAN MARTIN 206	-16.432778	-71.504722	040112	11	2026-09-22 16:44:39-05
433	IE PAULO VI CIRCA	PAUCARPATA	CALLE ABRAHAM SN ISRAEL	-16.432778	-71.504722	040112	8	2026-09-22 16:44:39-05
434	IEP ROBERT F KENNEDY	PAUCARPATA	URB EL CAYRO MZ E LT 5	-16.432778	-71.504722	040112	7	2026-09-22 16:44:39-05
435	IE PARROQUIAL SANTA ROSA DE LIMA	PAUCARPATA	COOP VILLA PORONGOCHE SN	-16.432778	-71.504722	040112	8	2026-09-22 16:44:39-05
436	IE PARROQUIAL SANTA ROSA DE LIMA PRIMARIA - SECUNDARIA	PAUCARPATA	CALLE CESAR VALLEJO 104 URB CALIFORNIA	-16.432778	-71.504722	040112	14	2026-09-22 16:44:39-05
437	IE NUESTRA SEÑORA DE LOURDES CIRCA	PAUCARPATA	CALLE AZANGARO SN	-16.432778	-71.504722	040112	15	2026-09-22 16:44:39-05
438	IE VIRGEN DE CHAPI CIRCA	PAUCARPATA	CALLE URANO SN URB NUEVO PERU MZ J LT 12	-16.432778	-71.504722	040112	9	2026-09-22 16:44:39-05
439	IE 40174 PAOLA FRASSINETTI FE Y ALEGRIA 45	PAUCARPATA	CALLE LA MAR SN	-16.432778	-71.504722	040112	12	2026-09-22 16:44:39-05
440	IE 40177 DIVINO CORAZON DE JESUS	PAUCARPATA	CALLE ABRAHAM VALDELOMAR SN	-16.432778	-71.504722	040112	9	2026-09-22 16:44:39-05
441	IE 40182 PROGRESISTA	PAUCARPATA	AV ARGENTINA SN CUADRA 9	-16.432778	-71.504722	040112	6	2026-09-22 16:44:39-05
442	IE 40185 SAN JUAN BAUTISTA DE JESUS	PAUCARPATA	CALLE MICAELA BASTIDAS 500 URB MANCO CAPAC	-16.432778	-71.504722	040112	10	2026-09-22 16:44:39-05
443	IE 40696 SANTA MARIA	PAUCARPATA	PJE SANTA MARIA I COMITE 4 MZ O LT2	-16.432778	-71.504722	040112	6	2026-09-22 16:44:39-05
444	IE JOSE TEOBALDO PAREDES VALDEZ	PAUCARPATA	CALLE BENIGNO BALLON FARFAN SN	-16.432778	-71.504722	040112	8	2026-09-22 16:44:39-05
445	IE 40183 INDOAMERICA	PAUCARPATA	AV LOS ALPES SN	-16.432778	-71.504722	040112	10	2026-09-22 16:44:39-05
446	IE 40211 HEROES DEL PACIFICO	PAUCARPATA	CALLE MESIAS SN COMITÉ 11 ISRAEL	-16.432778	-71.504722	040112	18	2026-09-22 16:44:39-05
447	IE 40315 JOSE MARIA ARGUEDAS	PAUCARPATA	AV TUPAC AMARU SN	-16.432778	-71.504722	040112	12	2026-09-22 16:44:39-05
448	IE POR CONVENIO SANTA MARIA DE LA PAZ	PAUCARPATA	PJE NUEVA ALBORADA MZ T LT 1	-16.432778	-71.504722	040112	17	2026-09-22 16:44:39-05
449	IEP JOULE DIVINO NIÑO	PAUCARPATA	COOPERATIVA VILLA PORONGOCHE J7	-16.432778	-71.504722	040112	11	2026-09-22 16:44:39-05
450	IEP ALMIRANTE GRAU	PAUCARPATA	AV MIGUEL GRAU 727	-16.432778	-71.504722	040112	8	2026-09-22 16:44:39-05
451	IE 40188	POCSI	CALLE PRINCIPAL SN	-16.517778	-71.389722	040113	2	2026-09-22 16:44:39-05
452	IE 40189	POCSI	MZ R LT 4 CCPP PIACA	-16.517778	-71.389722	040113	2	2026-09-22 16:44:39-05
453	IE 40190 SANTISIMA VIRGEN DE CHAPI	POLOBAYA	PLAZA PRINCIPAL SN	-16.565833	-71.368333	040114	5	2026-09-22 16:44:39-05
454	IE 40192	QUEQUEÑA	PLAZA PRINCIPAL SN	-16.557222	-71.451389	040115	4	2026-09-22 16:44:39-05
456	PRONOEI JESUCITO REDENTOR	QUEQUEÑA	ASOC PEREGRINOS DE CHAPI SN	-16.557222	-71.451389	040115	2	2026-09-22 16:44:39-05
457	LOCAL SOCIAL DE ASOC TRADICION Y FUTURO DE QUEQUEÑA	QUEQUEÑA	CALLE LAS MORAS SN MZ L LT 1 2 Y 3 SECTOR 1	-16.557222	-71.451389	040115	2	2026-09-22 16:44:39-05
458	IE 40193 FLORENTINO PORTUGAL	SABANDIA	CALLE PRINCIPAL 328	-16.456944	-71.494722	040116	15	2026-09-22 16:44:39-05
459	IE 40195	SABANDIA	AV 15 DE AGOSTO SN	-16.456944	-71.494722	040116	1	2026-09-22 16:44:39-05
460	IE 40060 DOMINIC WILLIAMS	SACHACA	AAHH VILLA EL TRIUNFO ZONA A SN	-16.424444	-71.566389	040117	5	2026-09-22 16:44:39-05
461	IEP AMOR DE DIOS	SACHACA	CALLE MARCARANI 149	-16.424444	-71.566389	040117	6	2026-09-22 16:44:39-05
462	IEP DIVINA INFANCIA DE JESUS	SACHACA	PSJ DOS DE MAYO 102 HUARANGUILLO	-16.424444	-71.566389	040117	6	2026-09-22 16:44:39-05
638	IE 40387 LARI	LARI	AV UCAYALI SN	-15.618333	-71.7725	040510	4	2026-09-22 16:44:39-05
463	IE EL MILAGRO DE FATIMA	SACHACA	CALLE JOSE OLAYA SN ALTO DE AMADOS	-16.424444	-71.566389	040117	12	2026-09-22 16:44:39-05
464	IE 40078 SAGRADO CORAZON DE JESUS DE SACHACA	SACHACA	AV ALFONSO UGARTE SN TIO CHICO	-16.424444	-71.566389	040117	7	2026-09-22 16:44:39-05
465	IE 40075 HORACIO MORALES DELGADO SECUNDARIA	SACHACA	CALLE LAS ROSAS 200	-16.424444	-71.566389	040117	7	2026-09-22 16:44:39-05
466	IE 40075 HORACIO MORALES DELGADO PRIMARIA	SACHACA	CALLE LAS ROSAS SN PAMPA DE CAMARONES	-16.424444	-71.566389	040117	3	2026-09-22 16:44:39-05
467	IEP INNOVA SCHOOL	SACHACA	AV FRANCISCO VALENCIA SN	-16.424444	-71.566389	040117	21	2026-09-22 16:44:39-05
468	IE 40079 VICTOR NUÑEZ VALENCIA	SACHACA	AV SALAVERRY SN CON AV WANDERS	-16.424444	-71.566389	040117	8	2026-09-22 16:44:39-05
469	IEP LA FAYETTE	SACHACA	AV LA FLORIDA 113 HUARANGUILLO	-16.424444	-71.566389	040117	16	2026-09-22 16:44:39-05
470	IE 40072	SAN JUAN DE SIGUAS	CARRETERA PANAMERICANA SUR KM 918 TAMBILLO	-16.346111	-72.128333	040118	4	2026-09-22 16:44:39-05
471	IE 40196 SAN JUAN BAUTISTA	SAN JUAN DE TARUCANI	AV BOLOGNESI SN	-16.183611	-71.061944	040119	7	2026-09-22 16:44:39-05
472	IE 40108	SANTA ISABEL DE SIGUAS	CALLE PRINCIPAL SN	-16.320833	-72.098889	040120	3	2026-09-22 16:44:39-05
473	IE 40073 VICTOR MANUEL PEROCHENA LUQUE	SANTA RITA DE SIGUAS	CALLE PEROCHENA SN	-16.493611	-72.094722	040121	9	2026-09-22 16:44:39-05
474	IE SANTA RITA DE SIGUAS	SANTA RITA DE SIGUAS	CALLE CIRO ALEGRIA SN	-16.493611	-72.094722	040121	8	2026-09-22 16:44:39-05
475	IE NUEVA JUVENTUD	SANTA RITA DE SIGUAS	AAHH NUEVA JUVENTUD MZ A LT 1	-16.493611	-72.094722	040121	5	2026-09-22 16:44:39-05
477	IE 40199	SOCABAYA	CALLE SANCHEZ TRUJILLO 301	-16.4675	-71.528611	040122	12	2026-09-22 16:44:39-05
478	IE SAN MARTIN DE SOCABAYA	SOCABAYA	CALLE FERREÑAFE 101	-16.4675	-71.528611	040122	25	2026-09-22 16:44:39-05
480	IE 40676 LA MANSION DE SOCABAYA	SOCABAYA	MANSION SOCABAYA MZ M LT 1	-16.4675	-71.528611	040122	8	2026-09-22 16:44:39-05
481	IE 40639	SOCABAYA	AV AREQUIPA SN SECTOR 1 MZ J	-16.4675	-71.528611	040122	8	2026-09-22 16:44:39-05
482	IE EL GRAN MAESTRO	SOCABAYA	AUM HORACIO ZEBALLOS GAMEZ SECTOR B ZONA 17 MZ 37 LT 1	-16.4675	-71.528611	040122	8	2026-09-22 16:44:39-05
483	IE DIVINA PROVIDENCIA CIRCA	SOCABAYA	ZONA 21 SECTOR G MZ 13 LOTE 1	-16.4675	-71.528611	040122	15	2026-09-22 16:44:39-05
484	IEP SANTISIMO SALVADOR	SOCABAYA	AV SALAVERRY SN	-16.4675	-71.528611	040122	21	2026-09-22 16:44:39-05
485	IE 40205 MANUEL BENITO LINARES ARENAS	SOCABAYA	CALLE CHICLAYO SN	-16.4675	-71.528611	040122	22	2026-09-22 16:44:39-05
486	IE SAN LUIS GONZAGA CIRCA	SOCABAYA	AV JOSE CARLOS MARIATEGUI SN	-16.4675	-71.528611	040122	16	2026-09-22 16:44:39-05
487	IEP DIVINO NIÑO DE BELEN	SOCABAYA	AMPLIACION SOCABAYA MZ M LT 3	-16.4675	-71.528611	040122	7	2026-09-22 16:44:39-05
488	IEP DIVINO JESUS DE SOCABAYA	SOCABAYA	CALLE AREQUIPA MZ 15 LOTE 8 SECTOR F	-16.4675	-71.528611	040122	5	2026-09-22 16:44:39-05
489	IEP SANTA MARIA DE FATIMA	SOCABAYA	AV SAN FERNANDO 101	-16.4675	-71.528611	040122	6	2026-09-22 16:44:39-05
491	IE FRANCISCO MOSTAJO	TIABAYA	CALLE LOS PERALES SN	-16.449444	-71.591667	040123	9	2026-09-22 16:44:39-05
492	IE 40086	TIABAYA	PROL AV MIGUEL GRAU SN PATASAGUA BAJA	-16.449444	-71.591667	040123	4	2026-09-22 16:44:39-05
493	IEP JUAN PABLO MAGNO	TIABAYA	AV PANAMERICA ANTIGUA SN	-16.449444	-71.591667	040123	4	2026-09-22 16:44:39-05
494	IE FUTURA SCHOOL	TIABAYA	CALLE JUNIN SN	-16.449444	-71.591667	040123	15	2026-09-22 16:44:39-05
495	IE CARLOS JOSE ECHAVARRY OSACAR SECUNDARIA	TIABAYA	AV JUAN MANUEL POLAR SN PJ SAN JOSE	-16.449444	-71.591667	040123	6	2026-09-22 16:44:39-05
496	IE 40082 MARIANO J VALDIVIA	TIABAYA	CALLE LOS PERALES 121	-16.449444	-71.591667	040123	9	2026-09-22 16:44:39-05
497	IE CARLOS JOSE ECHAVARRY OSACAR PRIMARIA	TIABAYA	CALLE LOS LAURELES MZ H LOTE 1 PAMPAS NUEVAS	-16.449444	-71.591667	040123	10	2026-09-22 16:44:39-05
498	IE 40092 JOSE DOMINGO ZUZUNAGA OBANDO	UCHUMAYO	CALLE CHAPI SN URB CERRO VERDE	-16.425278	-71.6725	040124	14	2026-09-22 16:44:39-05
499	IE 40091 ALMA MATER DE CONGATA	UCHUMAYO	AV CONGATA SN	-16.425278	-71.6725	040124	14	2026-09-22 16:44:39-05
500	IEI CONGATA	UCHUMAYO	CONJUNTO HABITACIONAL ALVAREZ THOMAS G 9 SECTOR II	-16.425278	-71.6725	040124	5	2026-09-22 16:44:39-05
501	IEP SANTIAGO RAMON Y CAJAL	UCHUMAYO	EL MALECON C 5 URB EL CARMEN DE CONGATA	-16.425278	-71.6725	040124	8	2026-09-22 16:44:39-05
502	IEP DIOS ES AMOR	UCHUMAYO	URB CERRO VERDE N 7	-16.425278	-71.6725	040124	7	2026-09-22 16:44:39-05
503	IE 40088 REYNO DE BELGICA	UCHUMAYO	CALLE SAN MARTIN 101	-16.425278	-71.6725	040124	10	2026-09-22 16:44:39-05
504	IE VICTOR RAUL HAYA DE LA TORRE	VITOR	CALLE SN	-16.465833	-71.935833	040125	4	2026-09-22 16:44:39-05
505	IE 40285	VITOR	JR 9 ASENTAMIENTO HUMANO PUEBLO VIEJO	-16.465833	-71.935833	040125	3	2026-09-22 16:44:39-05
506	IEP JESUS BENAVIDES MOSCOSO	VITOR	CALLE JUAN VELAZCO ALVARADO 29	-16.465833	-71.935833	040125	4	2026-09-22 16:44:39-05
507	IE 40165 SAN JUAN BAUTISTA DE LA SALLE	YANAHUARA	PSJ SAN JUAN SN CON CALLE JOSE MARIA ARGUEDAS UMACOLLO	-16.381944	-71.536389	040126	22	2026-09-22 16:44:39-05
508	IE 40048 ANTONIO JOSE DE SUCRE	YANAHUARA	AV LEON VELARDE 409	-16.381944	-71.536389	040126	24	2026-09-22 16:44:39-05
509	IE SANTA ROSA DE VITERBO	YANAHUARA	AV ZAMACOLA 106	-16.381944	-71.536389	040126	9	2026-09-22 16:44:39-05
510	IE 40099	YANAHUARA	PJE FATIMA MZ B LOTE 8	-16.381944	-71.536389	040126	3	2026-09-22 16:44:39-05
511	IE 40039 SANTA MARIA	YANAHUARA	COOP DE VIVIENDA VICTOR ANDRES BELAUNDE MZ LL LOTE 27 UMACOLLO	-16.381944	-71.536389	040126	8	2026-09-22 16:44:39-05
512	IEP NUESTRA SEÑORA DE LA MERCED	YANAHUARA	CALLE ARICA CON PSJ CORTADERAS	-16.381944	-71.536389	040126	6	2026-09-22 16:44:39-05
513	COLEGIO ESCLAVAS DEL SAGRADO CORAZON DE JESUS	YANAHUARA	CALLE ANTERO PERALTA SN UMACOLLO	-16.381944	-71.536389	040126	5	2026-09-22 16:44:39-05
514	CEBE NUESTRA SEÑORA DEL PILAR	YANAHUARA	AV ZAMÁCOLA 120	-16.381944	-71.536389	040126	4	2026-09-22 16:44:39-05
515	IEP AMERICO GARIBALDI	YANAHUARA	URB EL REMANSO A 4	-16.381944	-71.536389	040126	14	2026-09-22 16:44:39-05
516	IEI REGINA MUNDI	YANAHUARA	CALLE LAS ORQUIDEAS MZ B URB MAGISTERIAL III ETAPA UMACOLLO	-16.381944	-71.536389	040126	7	2026-09-22 16:44:39-05
517	IEI EL CERRO	YARABAMBA	ANEXO EL CERRO SN	-16.546667	-71.475556	040127	2	2026-09-22 16:44:39-05
518	IEI SAN ANTONIO	YARABAMBA	PLAZA SAN ANTONIO SN	-16.546667	-71.475556	040127	3	2026-09-22 16:44:39-05
519	IE 40209 HEROES DE YARABAMBA	YARABAMBA	PJE LINO URQUIETA SN	-16.546667	-71.475556	040127	5	2026-09-22 16:44:39-05
520	IE 40225 SAN ANTONIO	YARABAMBA	CALLE PLAZA SAN ANTONIO SN	-16.546667	-71.475556	040127	2	2026-09-22 16:44:39-05
521	IE MONSEÑOR LEONIDAS BERNEDO MALAGA	YARABAMBA	CALLE PROGRESO SN	-16.546667	-71.475556	040127	3	2026-09-22 16:44:39-05
522	IE 40102 NUESTRA SEÑORA DEL CARMEN PATRONA DE YURA	YURA	PSJ EL PORVENIR MZ L LT 1	-16.246944	-71.706389	040128	4	2026-09-22 16:44:39-05
523	IE 40202 CHARLOTTE	YURA	CARRETERA CIUDAD DE DIOS KM 13 Y MEDIO	-16.246944	-71.706389	040128	27	2026-09-22 16:44:39-05
525	IE SEÑOR DE LOS MILAGROS CIRCA	YURA	CIUDAD DE DIOS KM 13 Y MEDIO CARRETERA YURA	-16.246944	-71.706389	040128	10	2026-09-22 16:44:39-05
526	IE SANTO TORIBIO DE MOGROVEJO CIRCA	YURA	CARRETERA A YURA KM 13	-16.246944	-71.706389	040128	5	2026-09-22 16:44:39-05
527	IEPC THOMAS MC	YURA	ASOC CIUDAD DE DIOS ZONA 1 COMITE 5 MZ U LT7	-16.246944	-71.706389	040128	14	2026-09-22 16:44:39-05
528	IE SAN BERNARDO CIRCA	YURA	CIUDAD DE DIOS KM 16	-16.246944	-71.706389	040128	6	2026-09-22 16:44:39-05
529	IE JORGE SANJINEZ LENZ	YURA	CIUDAD DE DIOS KM 16	-16.246944	-71.706389	040128	16	2026-09-22 16:44:39-05
530	IE 41038 JOSE OLAYA BALANDRA	JOSE LUIS BUSTAMANTE Y RIVERO	CALLE MARISCAL CASTILLA SN	-16.426667	-71.523889	040129	11	2026-09-22 16:44:39-05
531	IE INMACULADA CONCEPCION	JOSE LUIS BUSTAMANTE Y RIVERO	URB PEDRO DIEZ CANSECO MZ I LT 11	-16.426667	-71.523889	040129	29	2026-09-22 16:44:39-05
532	IE 40038 JORGE BASADRE GROHMANN	JOSE LUIS BUSTAMANTE Y RIVERO	CALLE SANGARARA 100	-16.426667	-71.523889	040129	43	2026-09-22 16:44:39-05
533	IE 40121 EVERARDO ZAPATA SANTILLANA	JOSE LUIS BUSTAMANTE Y RIVERO	URB CASAPIA SN	-16.426667	-71.523889	040129	10	2026-09-22 16:44:39-05
534	IE 41006 JORGE POLAR	JOSE LUIS BUSTAMANTE Y RIVERO	URB LA MELGARIANA F6	-16.426667	-71.523889	040129	5	2026-09-22 16:44:39-05
535	IE 40122 MANUEL SCORZA TORRES	JOSE LUIS BUSTAMANTE Y RIVERO	CALLE AYARZA SN	-16.426667	-71.523889	040129	16	2026-09-22 16:44:39-05
536	CONSERVATORIO REGIONAL DE MUSICA LUIS DUNCKER LAVALLE	JOSE LUIS BUSTAMANTE Y RIVERO	COOP LAMBRAMANI CALLE 4 SN	-16.426667	-71.523889	040129	6	2026-09-22 16:44:39-05
537	IEP WOLFGANG AMADEUS MOZART	JOSE LUIS BUSTAMANTE Y RIVERO	URB JUAN PABLO VIZCARDO Y GUZMAN I ETAPA G 12	-16.426667	-71.523889	040129	7	2026-09-22 16:44:39-05
538	IEP MUNDO ECOLOGICO	JOSE LUIS BUSTAMANTE Y RIVERO	COOP DANIEL ALCIDES CARRION CALLE 1 NRO 103	-16.426667	-71.523889	040129	7	2026-09-22 16:44:39-05
539	IE 40175 GRAN LIBERTADOR SIMON BOLIVAR	JOSE LUIS BUSTAMANTE Y RIVERO	CALLE ULRICH NEISSER SN	-16.426667	-71.523889	040129	24	2026-09-22 16:44:39-05
540	IE PNP 7 DE AGOSTO	JOSE LUIS BUSTAMANTE Y RIVERO	URB SANTA CATALINA H2	-16.426667	-71.523889	040129	10	2026-09-22 16:44:39-05
541	CEBE HELEN KELLER	JOSE LUIS BUSTAMANTE Y RIVERO	URB JUAN PABLO VIZCARDO Y GUZMAN II ETAPA M7	-16.426667	-71.523889	040129	5	2026-09-22 16:44:39-05
542	IE 40631 JUAN PABLO II	JOSE LUIS BUSTAMANTE Y RIVERO	AV LAS ESMERALDAS 300	-16.426667	-71.523889	040129	6	2026-09-22 16:44:39-05
543	IEERA ALFRED BINET	JOSE LUIS BUSTAMANTE Y RIVERO	CALLE COLON SN	-16.426667	-71.523889	040129	10	2026-09-22 16:44:39-05
544	IEP ARCANGEL SAN MIGUEL	JOSE LUIS BUSTAMANTE Y RIVERO	AV CARACAS A99	-16.426667	-71.523889	040129	11	2026-09-22 16:44:39-05
545	IEP NIÑO DE LA PAZ	JOSE LUIS BUSTAMANTE Y RIVERO	URB CASAPIA C16	-16.426667	-71.523889	040129	7	2026-09-22 16:44:39-05
546	IESTP PEDRO P DIAZ	JOSE LUIS BUSTAMANTE Y RIVERO	AV PIZARRO 130	-16.426667	-71.523889	040129	13	2026-09-22 16:44:39-05
547	IE 41040 JOSE CARLOS MARIATEGUI	CAMANA	PJE TASSARA SN	-16.624722	-72.711389	040201	9	2026-09-22 16:44:39-05
548	IE 41041 CRISTO REY PRIMARIA	CAMANA	JR SAMUEL PASTOR SN	-16.624722	-72.711389	040201	11	2026-09-22 16:44:39-05
549	IE 40226 SANTA ROSA DE LIMA	CAMANA	CALLE LAS DALIAS MZ F LT 8	-16.624722	-72.711389	040201	5	2026-09-22 16:44:39-05
550	IE 40227 EDUARDO PORTUGAL	CAMANA	AV PRIMAVERA 279	-16.624722	-72.711389	040201	8	2026-09-22 16:44:39-05
552	IE 40233 JOSE MARIA QUIMPER Y CABALLERO	JOSE MARIA QUIMPER	AV LIVERPOOL 200	-16.601944	-72.727222	040202	5	2026-09-22 16:44:39-05
553	IE 40232 VIRGEN DEL ROSARIO	JOSE MARIA QUIMPER	PANAMERICAN SUR SN	-16.601944	-72.727222	040202	4	2026-09-22 16:44:39-05
554	IE JULIO ERNESTO PORTUGAL ESCOBEDO	JOSE MARIA QUIMPER	AV LAS VEGAS SN	-16.601944	-72.727222	040202	5	2026-09-22 16:44:39-05
555	IE 40667 CRISTO MORADO	MARIANO NICOLAS VALCARCEL	CALLE SN SECTOR NUEVA ESPERANZA LT 53	-16.031389	-73.174444	040203	1	2026-09-22 16:44:39-05
556	IE 40194 RICARDO PALMA	MARIANO NICOLAS VALCARCEL	CALLE PRINCIPAL SN SECOCHA BAJA	-16.031389	-73.174444	040203	10	2026-09-22 16:44:39-05
557	IEP GRAN SABIO ALBERT EINSTEIN	MARIANO NICOLAS VALCARCEL	CALLE 8 SN MZ B LT 4	-16.031389	-73.174444	040203	4	2026-09-22 16:44:39-05
558	IE 40236 CESAR VALLEJO	MARISCAL CACERES	AV PANAMERICANA SN MZ F LT 6 ZONA B	-16.619722	-72.736111	040204	7	2026-09-22 16:44:39-05
559	IE 40235 VIRGEN DE LA ASUNTA	MARISCAL CACERES	PLAZA DE ARMAS 100	-16.619722	-72.736111	040204	14	2026-09-22 16:44:39-05
560	IE 40251 VIRGEN DE GUADALUPE	NICOLAS DE PIEROLA	AV NICOLAS DE PIEROLA 617	-16.573056	-72.715833	040205	3	2026-09-22 16:44:39-05
561	IE 40237 ALBERTO LOAYZA SALAS	NICOLAS DE PIEROLA	CALLE LAS GARDENIAS SN	-16.573056	-72.715833	040205	3	2026-09-22 16:44:39-05
562	IEI GOTITAS DE AMOR	NICOLAS DE PIEROLA	CALLE SALAVERRY SN	-16.573056	-72.715833	040205	3	2026-09-22 16:44:39-05
563	IE 40239 NICOLAS DE PIEROLA	NICOLAS DE PIEROLA	AV NICOLAS DE PIEROLA 1804	-16.573056	-72.715833	040205	12	2026-09-22 16:44:39-05
564	IE JOSE MARIA MORANTE	OCOÑA	AV JOSE MARIA MORANTE 101	-16.431667	-73.105	040206	5	2026-09-22 16:44:39-05
565	IEP SANTISIMA INFANTA MARIA	OCOÑA	CALLE SANTA ROSA MZ Q LT 12 A	-16.431667	-73.105	040206	4	2026-09-22 16:44:39-05
566	IE 40240 LUZ ANGELICA CARNERO DONGO	OCOÑA	CALLE SAN MARTIN 107	-16.431667	-73.105	040206	4	2026-09-22 16:44:39-05
567	IE 40244 VIRGEN DE LA CANDELARIA DE QUILCA	QUILCA	CALLE MIRAMAR SN	-16.716944	-72.425556	040207	4	2026-09-22 16:44:39-05
568	IE 40238 NUESTRA SEÑORA DEL CARMEN	SAMUEL PASTOR	CALLE 16 DE JULIO 121 EL CARMEN	-16.613611	-72.699167	040208	1	2026-09-22 16:44:39-05
569	IE NUESTRA SEÑORA DE LA CANDELARIA	SAMUEL PASTOR	AV SAMUEL PASTOR 1203	-16.613611	-72.699167	040208	20	2026-09-22 16:44:39-05
570	IE 40516 JUAN PABLO VIZCARDO Y GUZMAN	SAMUEL PASTOR	AV LA MARINA SN	-16.613611	-72.699167	040208	2	2026-09-22 16:44:39-05
571	IE 40203 TUPAC AMARU	SAMUEL PASTOR	CALLE PRINCIPAL SN MZ G LT 8	-16.613611	-72.699167	040208	3	2026-09-22 16:44:39-05
572	IE VILLA DON JORGE	SAMUEL PASTOR	CALLE SN AAHH VILLA DON JORGE	-16.613611	-72.699167	040208	7	2026-09-22 16:44:39-05
573	IE 40281 CPED ALTO HUARANGAL	SAMUEL PASTOR	MZ L LT 15 AAHH ALTO HUARANGAL	-16.613611	-72.699167	040208	3	2026-09-22 16:44:39-05
574	IE 40245 JOSE PASTOR CAMPOS	SAMUEL PASTOR	CALLE LAS GARDENIAS 102	-16.613611	-72.699167	040208	3	2026-09-22 16:44:39-05
575	IE INDEPENDENCIA DEL PERU	CARAVELI	CALLE AYACUCHO 800	-15.7725	-73.365833	040301	8	2026-09-22 16:44:39-05
576	IE 41042 PEDRO JOSE TORDOYA MONTOYA	CARAVELI	AV 2 DE MAYO 802	-15.7725	-73.365833	040301	5	2026-09-22 16:44:39-05
577	IE NICOLAS DE PIEROLA	ACARI	CALLE MARISCAL ORBEGOSO SN	-15.435556	-74.616389	040302	5	2026-09-22 16:44:39-05
578	IETP SAN MARTIN DE PORRES	ACARI	AV SEBASTIAN BARRANCA SN	-15.435556	-74.616389	040302	7	2026-09-22 16:44:39-05
579	IE MIGUEL GRAU	ATICO	CALLE PORVENIR SN LA FLORIDA	-16.208333	-73.623611	040303	7	2026-09-22 16:44:39-05
580	IE 40267 SAGRADO CORAZON DE JESUS	ATICO	CALLE GARCILAZO DE LA VEGA SN	-16.208333	-73.623611	040303	8	2026-09-22 16:44:39-05
582	IE 40306	BELLA UNION	CARRETERA PANAMERICANA SUR KM 559	-15.450556	-74.658333	040305	1	2026-09-22 16:44:39-05
583	IE 40268 PEDRO ALFERRANO HERNANDEZ	BELLA UNION	AV FRANCISCO FLORES BERRUEZO SN	-15.450556	-74.658333	040305	4	2026-09-22 16:44:39-05
584	IE 40269 ISMAEL CONTRERAS YAÑEZ	BELLA UNION	AV ANGEL ESCALANTE SN	-15.450556	-74.658333	040305	5	2026-09-22 16:44:39-05
585	IE 40292 MARIA AUXILIADORA	CAHUACHO	CALLE PRINCIPAL SN	-15.502778	-73.479722	040306	1	2026-09-22 16:44:39-05
586	IE VIRGEN DE COPACABANA	CAHUACHO	AV JULIO ERNESTO PORTUGAL SN	-15.502778	-73.479722	040306	2	2026-09-22 16:44:39-05
587	IE HORTENCIA PARDO MANCEBO	CHALA	AV FRANKLIN PEASE OLIVERA SN CHALA NORTE	-15.865556	-74.2475	040307	11	2026-09-22 16:44:39-05
588	IE 40272 JOSE OLAYA BALANDRA	CHALA	CALLE BOLIVAR 700 CHALA SUR	-15.865556	-74.2475	040307	12	2026-09-22 16:44:39-05
589	IE NUESTRA SEÑORA MARIA DEL PILAR	CHAPARRA	AV HORTENCIA NEYRA SN	-15.805278	-73.966944	040308	2	2026-09-22 16:44:39-05
590	IE SIMON BOLIVAR	CHAPARRA	AV PRINCIPAL SN	-15.805278	-73.966944	040308	3	2026-09-22 16:44:39-05
591	IE 40274 SEÑOR DE LOS MILAGROS	CHAPARRA	PJE CARLOS MELLER SN	-15.805278	-73.966944	040308	3	2026-09-22 16:44:39-05
592	IE 40297 JUAN BAUTISTA DE TOCOTA	HUANUHUANU	AV JULIAN DONGO CHACON SN	-15.658889	-74.091389	040309	1	2026-09-22 16:44:39-05
593	IE CARLOS NORIEGA JIMENEZ	HUANUHUANU	CALLE PRINCIPAL SN	-15.658889	-74.091389	040309	6	2026-09-22 16:44:39-05
594	IE 40277	JAQUI	AV AREQUIPA SN	-15.479167	-74.443611	040310	5	2026-09-22 16:44:39-05
595	IE 40299 JOSE ALFREDO MOLINA	LOMAS	CALLE VICTORIA SN	-15.569722	-74.851389	040311	4	2026-09-22 16:44:39-05
596	IE SAN ANTONIO DE LA PIEDRA	QUICACHA	CALLE MAGISTERIAL SN	-15.625	-73.798333	040312	3	2026-09-22 16:44:39-05
597	IE 40279 NUESTRA SEÑORA DEL PERPETUO SOCORRO	QUICACHA	CALLE MAGISTERIAL SN	-15.625	-73.798333	040312	3	2026-09-22 16:44:39-05
598	IE 40280 NUESTRA SEÑORA DE FATIMA	YAUCA	CALLE AREQUIPA SN	-15.661944	-74.527222	040313	6	2026-09-22 16:44:39-05
599	IE 40342 LA CENTRAL	APLAO	CALLE SN ANEXO LA CENTRAL	-16.076111	-72.492222	040401	2	2026-09-22 16:44:39-05
479	IE 40221 CORAZON DE JESUS	SOCABAYA	CALLE BLONDET SN	-16.4675	-71.528611	040122	8	2026-09-22 16:44:39-05
248	IEP ADDISON	ALTO SELVA ALEGRE	JR MIGUEL GRAU SN	-16.38	-71.521111	040102	7	2026-09-22 16:44:38-05
249	IEP SAN JUAN APOSTOL	ALTO SELVA ALEGRE	PJE CRISANTEMOS 104	-16.38	-71.521111	040102	7	2026-09-22 16:44:38-05
682	IESTP JORGE BASADRE	MOLLENDO	AV PANAMERICANA SUR SN	-17.029167	-72.016389	040701	10	2026-09-22 16:44:40-05
683	IEP CIENCIAS ITALO PERUANO ENRICO FERMI	MOLLENDO	URB LAS AMBARINAS F 2	-17.029167	-72.016389	040701	5	2026-09-22 16:44:40-05
684	IE 40472 CARLOS M FEBRES	MOLLENDO	CALLE TEOFILO NUÑEZ  201	-17.029167	-72.016389	040701	9	2026-09-22 16:44:40-05
685	IE 41050 DIVINO MAESTRO	MOLLENDO	CALLE ALFONSO UGARTE SN	-17.029167	-72.016389	040701	3	2026-09-22 16:44:40-05
686	IE DEAN VALDIVIA	MOLLENDO	AV MARISCAL CASTILLA 1001	-17.029167	-72.016389	040701	15	2026-09-22 16:44:40-05
687	CPM SAN FRANCISCO DE ASIS	MOLLENDO	JR JORGE ZAPATER D1 CESAR VALLEJO	-17.029167	-72.016389	040701	13	2026-09-22 16:44:40-05
688	IE MARIANO EDUARDO DE RIVERO Y USTARIZ	COCACHACRA	AV PROGRESO 1200	-17.091111	-71.773889	040702	11	2026-09-22 16:44:40-05
689	IE 41513 SAGRADO CORAZON DE JESUS	COCACHACRA	CALLE PERU SN	-17.091111	-71.773889	040702	5	2026-09-22 16:44:40-05
690	IESTP VALLE DE TAMBO	COCACHACRA	CARRETERA AVIS VERACRUZ CHICA MZ X2 LT 4	-17.091111	-71.773889	040702	3	2026-09-22 16:44:40-05
691	IEI NIÑO JESUS DE PRAGA	COCACHACRA	AV PROGRESO SN	-17.091111	-71.773889	040702	4	2026-09-22 16:44:40-05
692	IE 40482 SAN MARTIN DE PORRES	COCACHACRA	AV PROGRESO SN	-17.091111	-71.773889	040702	8	2026-09-22 16:44:40-05
693	IE 41048 CRISTO REY	COCACHACRA	CALLE TACNA 612	-17.091111	-71.773889	040702	4	2026-09-22 16:44:40-05
694	IE 40484 VIRGEN DE FATIMA	DEAN VALDIVIA	CALLE FATIMA SN	-17.145	-71.826667	040703	8	2026-09-22 16:44:40-05
695	IE 40485 RUBEN LINARES LINARES	DEAN VALDIVIA	JR INTERNACIONAL SN	-17.145	-71.826667	040703	6	2026-09-22 16:44:40-05
696	IE FRANCISCO LOPEZ DE ROMAÑA	DEAN VALDIVIA	AV PRLG GUARDIOLA SN	-17.145	-71.826667	040703	8	2026-09-22 16:44:40-05
697	IE 40479 MIGUEL GRAU	ISLAY	CALLE MIGUEL GRAU SN	-17.000833	-72.0975	040704	16	2026-09-22 16:44:40-05
698	IE 40494 JOSE ABELARDO QUIÑONES GONZALES	MEJIA	AV TAMBO SN	-17.101111	-71.9075	040705	6	2026-09-22 16:44:40-05
699	IE VICTOR MANUEL TORRES CACERES	PUNTA DE BOMBON	CALLE VICTOR LIRA SN	-17.156111	-71.784722	040706	12	2026-09-22 16:44:40-05
700	IE 40488 ERNESTO DE OLAZABAL LLOSA	PUNTA DE BOMBON	CALLE PIZARRO SN	-17.156111	-71.784722	040706	11	2026-09-22 16:44:40-05
701	IE MARISCAL ORBEGOSO	COTAHUASI	AV SANTA ANA 222	-15.212778	-72.889444	040801	5	2026-09-22 16:44:40-05
702	IE 40167 MARIA AUXILIADORA	COTAHUASI	CALLE PUENTE GRAU 203	-15.212778	-72.889444	040801	2	2026-09-22 16:44:40-05
703	IE 40510 CORONEL CASIMIRO PERALTA	ALCA	AV MARISCAL CASTILLA 105	-15.134167	-72.765	040802	6	2026-09-22 16:44:40-05
704	IE 40515 SAN SEBASTIAN	CHARCANA	CALLE STADIUM RADA SN	-15.240556	-73.070556	040803	2	2026-09-22 16:44:40-05
705	IE 40542 HUARCAYA	HUAYNACOTAS	CCPP HUARCAYA SN	-15.174722	-72.849722	040804	1	2026-09-22 16:44:40-05
312	IE GRAN PACHACUTEC	CERRO COLORADO	AV MANCO CAPAC SN	-16.376389	-71.560833	040104	6	2026-09-22 16:44:39-05
657	IE CORONEL FRANCISCO BOLOGNESI PRIMARIA	MAJES	MODULO B SECTOR 2 MZ E3 LT 1	-16.353333	-72.247222	040520	12	2026-09-22 16:44:40-05
658	IE 40656 SAN FRANCISCO DE ASIS SECUNDARIA	MAJES	AAHH MZ E LT 2	-16.353333	-72.247222	040520	6	2026-09-22 16:44:40-05
659	IE 40230 SAN ANTONIO DEL PEDREGAL	MAJES	CALLE 70 SN	-16.353333	-72.247222	040520	24	2026-09-22 16:44:40-05
661	IEP MENDEL PEDREGAL	MAJES	AV 3 DE OCTUBRE PARCELA 338 ZONA A	-16.353333	-72.247222	040520	8	2026-09-22 16:44:40-05
662	IE 40201 TECNICO AGROPECUARIO LA COLINA PRIMARIA	MAJES	X-01-B-LA COLINA	-16.353333	-72.247222	040520	9	2026-09-22 16:44:40-05
663	IE 40284 PEDRO PAULET MOSTAJO PRIMARIA	MAJES	AV PRINCIPAL SN SAN JUAN EL ALTO	-16.353333	-72.247222	040520	22	2026-09-22 16:44:40-05
664	IE 41061 JOSE ANTONIO ENCINAS	MAJES	AAHH B3	-16.353333	-72.247222	040520	17	2026-09-22 16:44:40-05
665	IE 41045 CORAZÓN DE JESUS	CHUQUIBAMBA	AV ALAMEDA LOS TRES ERRANTES SN	-15.839444	-72.651667	040601	7	2026-09-22 16:44:40-05
666	IE 40428 VIRGEN DE FATIMA	CHUQUIBAMBA	CALLE SAN MARTIN 204	-15.839444	-72.651667	040601	3	2026-09-22 16:44:40-05
667	IE 40430 JOSE SIMION TEJEDA	ANDARAY	CALLE FRANCISCO BOLOGNESI 200	-15.797222	-72.860833	040602	2	2026-09-22 16:44:40-05
668	IE 40568 ARCATA	CAYARANI	PJE SN MZ G LT 9	-14.671944	-72.021944	040603	1	2026-09-22 16:44:40-05
669	IE 40459 SAN ROQUE	CAYARANI	PJE 16 Y 17 SN	-14.671944	-72.021944	040603	1	2026-09-22 16:44:40-05
670	IE 40458 SAN JUAN BAUTISTA	CAYARANI	CALLE TRIUNFO SN	-14.671944	-72.021944	040603	8	2026-09-22 16:44:40-05
671	IE 40432 VICTOR RAUL HAYA DE LA TORRE	CHICHAS	PLAZA PRINCIPAL SN	-15.547778	-72.918611	040604	3	2026-09-22 16:44:40-05
672	IE 40434 FRAY MARTIN DE PORRES	IRAY	AV PRINCIPAL SN	-15.853611	-72.63	040605	3	2026-09-22 16:44:40-05
673	IE 40447 LA INMACULADA CONCEPCION	RIO GRANDE	PLAZA PRINCIPAL SN	-15.94	-73.131111	040606	1	2026-09-22 16:44:40-05
674	IE 40446 MIGUEL GRAU	RIO GRANDE	PLAZA PRINCIPAL SN	-15.94	-73.131111	040606	5	2026-09-22 16:44:40-05
675	IE 41511 LIBERTADORES DE AMERICA	RIO GRANDE	AV LOS ANGELES SN	-15.94	-73.131111	040606	3	2026-09-22 16:44:40-05
676	IE 40436 SALAMANCA	SALAMANCA	PJE SANTA IGLESIA SN	-15.504444	-72.834444	040607	3	2026-09-22 16:44:40-05
\.


--
-- Name: accesos_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.accesos_log_id_seq', 216, true);


--
-- Name: acta_adjuntos_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.acta_adjuntos_id_seq', 1, false);


--
-- Name: acta_auditoria_global_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.acta_auditoria_global_id_seq', 1, false);


--
-- Name: acta_columnas_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.acta_columnas_id_seq', 1, false);


--
-- Name: acta_eventos_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.acta_eventos_id_seq', 1, false);


--
-- Name: acta_metadata_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.acta_metadata_id_seq', 10, true);


--
-- Name: acta_observaciones_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.acta_observaciones_id_seq', 1, false);


--
-- Name: actas_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.actas_id_seq', 1, false);


--
-- Name: asignacion_personeros_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.asignacion_personeros_id_seq', 42, true);


--
-- Name: candidatos_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.candidatos_id_seq', 1, false);


--
-- Name: categorias_incidencia_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.categorias_incidencia_id_seq', 32, true);


--
-- Name: checkins_personero_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.checkins_personero_id_seq', 1, false);


--
-- Name: consejero_candidates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.consejero_candidates_id_seq', 75, true);


--
-- Name: detalle_votos_acta_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.detalle_votos_acta_id_seq', 1, false);


--
-- Name: district_candidates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.district_candidates_id_seq', 539, true);


--
-- Name: incidencia_adjuntos_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.incidencia_adjuntos_id_seq', 1, false);


--
-- Name: incidencia_seguimiento_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.incidencia_seguimiento_id_seq', 1, false);


--
-- Name: incidencias_campo_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.incidencias_campo_id_seq', 1, false);


--
-- Name: locales_votacion_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.locales_votacion_id_seq', 1, false);


--
-- Name: mesas_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.mesas_id_seq', 1, false);


--
-- Name: organizaciones_politicas_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.organizaciones_politicas_id_seq', 1, false);


--
-- Name: provincial_candidates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.provincial_candidates_id_seq', 86, true);


--
-- Name: records_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.records_id_seq', 140, true);


--
-- Name: regional_candidates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.regional_candidates_id_seq', 16, true);


--
-- Name: seq_incid_codigo; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.seq_incid_codigo', 1, false);


--
-- Name: sesiones_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.sesiones_id_seq', 200, true);


--
-- Name: tables_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.tables_id_seq', 9405, true);


--
-- Name: usuarios_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.usuarios_id_seq', 17, true);


--
-- Name: venues_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.venues_id_seq', 1380, true);


--
-- Name: accesos_log accesos_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accesos_log
    ADD CONSTRAINT accesos_log_pkey PRIMARY KEY (id);


--
-- Name: acta_adjuntos acta_adjuntos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_adjuntos
    ADD CONSTRAINT acta_adjuntos_pkey PRIMARY KEY (id);


--
-- Name: acta_auditoria_global acta_auditoria_global_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_auditoria_global
    ADD CONSTRAINT acta_auditoria_global_pkey PRIMARY KEY (id);


--
-- Name: acta_columnas acta_columnas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_columnas
    ADD CONSTRAINT acta_columnas_pkey PRIMARY KEY (id);


--
-- Name: acta_columnas acta_columnas_unica; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_columnas
    ADD CONSTRAINT acta_columnas_unica UNIQUE (acta_id, columna);


--
-- Name: acta_eventos acta_eventos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_eventos
    ADD CONSTRAINT acta_eventos_pkey PRIMARY KEY (id);


--
-- Name: acta_metadata acta_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_metadata
    ADD CONSTRAINT acta_metadata_pkey PRIMARY KEY (id);


--
-- Name: acta_observaciones acta_observaciones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_observaciones
    ADD CONSTRAINT acta_observaciones_pkey PRIMARY KEY (id);


--
-- Name: actas actas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actas
    ADD CONSTRAINT actas_pkey PRIMARY KEY (id);


--
-- Name: actas actas_unica_por_mesa_eleccion; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actas
    ADD CONSTRAINT actas_unica_por_mesa_eleccion UNIQUE (mesa_id, tipo_eleccion);


--
-- Name: CONSTRAINT actas_unica_por_mesa_eleccion ON actas; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON CONSTRAINT actas_unica_por_mesa_eleccion ON public.actas IS 'Evita digitación duplicada de la misma mesa para el mismo tipo de elección.';


--
-- Name: asignacion_personeros asignacion_personeros_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asignacion_personeros
    ADD CONSTRAINT asignacion_personeros_pkey PRIMARY KEY (id);


--
-- Name: candidatos candidatos_lista_unica; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidatos
    ADD CONSTRAINT candidatos_lista_unica UNIQUE (organizacion_id, ubigeo, cargo, numero_lista);


--
-- Name: candidatos candidatos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidatos
    ADD CONSTRAINT candidatos_pkey PRIMARY KEY (id);


--
-- Name: categorias_incidencia categorias_incidencia_codigo_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorias_incidencia
    ADD CONSTRAINT categorias_incidencia_codigo_key UNIQUE (codigo);


--
-- Name: categorias_incidencia categorias_incidencia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorias_incidencia
    ADD CONSTRAINT categorias_incidencia_pkey PRIMARY KEY (id);


--
-- Name: checkins_personero checkins_personero_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.checkins_personero
    ADD CONSTRAINT checkins_personero_pkey PRIMARY KEY (id);


--
-- Name: consejero_candidates consejero_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consejero_candidates
    ADD CONSTRAINT consejero_candidates_pkey PRIMARY KEY (id);


--
-- Name: detalle_votos_acta detalle_unico_por_columna; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.detalle_votos_acta
    ADD CONSTRAINT detalle_unico_por_columna UNIQUE (columna_id, organizacion_id);


--
-- Name: detalle_votos_acta detalle_votos_acta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.detalle_votos_acta
    ADD CONSTRAINT detalle_votos_acta_pkey PRIMARY KEY (id);


--
-- Name: district_candidates district_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.district_candidates
    ADD CONSTRAINT district_candidates_pkey PRIMARY KEY (id);


--
-- Name: incidencia_adjuntos incidencia_adjuntos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencia_adjuntos
    ADD CONSTRAINT incidencia_adjuntos_pkey PRIMARY KEY (id);


--
-- Name: incidencia_seguimiento incidencia_seguimiento_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencia_seguimiento
    ADD CONSTRAINT incidencia_seguimiento_pkey PRIMARY KEY (id);


--
-- Name: incidencias_campo incidencias_campo_codigo_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencias_campo
    ADD CONSTRAINT incidencias_campo_codigo_key UNIQUE (codigo);


--
-- Name: incidencias_campo incidencias_campo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencias_campo
    ADD CONSTRAINT incidencias_campo_pkey PRIMARY KEY (id);


--
-- Name: locales_votacion locales_codigo_por_ubigeo; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locales_votacion
    ADD CONSTRAINT locales_codigo_por_ubigeo UNIQUE (ubigeo, codigo_local);


--
-- Name: locales_votacion locales_votacion_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locales_votacion
    ADD CONSTRAINT locales_votacion_pkey PRIMARY KEY (id);


--
-- Name: mesas mesas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesas
    ADD CONSTRAINT mesas_pkey PRIMARY KEY (id);


--
-- Name: mesas mesas_unica_por_local; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesas
    ADD CONSTRAINT mesas_unica_por_local UNIQUE (local_id, numero_mesa);


--
-- Name: organizaciones_politicas organizaciones_politicas_nombre_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizaciones_politicas
    ADD CONSTRAINT organizaciones_politicas_nombre_key UNIQUE (nombre);


--
-- Name: organizaciones_politicas organizaciones_politicas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizaciones_politicas
    ADD CONSTRAINT organizaciones_politicas_pkey PRIMARY KEY (id);


--
-- Name: provincial_candidates provincial_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provincial_candidates
    ADD CONSTRAINT provincial_candidates_pkey PRIMARY KEY (id);


--
-- Name: records records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_pkey PRIMARY KEY (id);


--
-- Name: regional_candidates regional_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regional_candidates
    ADD CONSTRAINT regional_candidates_pkey PRIMARY KEY (id);


--
-- Name: sesiones sesiones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sesiones
    ADD CONSTRAINT sesiones_pkey PRIMARY KEY (id);


--
-- Name: tables tables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tables
    ADD CONSTRAINT tables_pkey PRIMARY KEY (id);


--
-- Name: ubigeo ubigeo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ubigeo
    ADD CONSTRAINT ubigeo_pkey PRIMARY KEY (ubigeo);


--
-- Name: asignacion_personeros uq_personero_mesa_rol; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asignacion_personeros
    ADD CONSTRAINT uq_personero_mesa_rol UNIQUE (usuario_id, mesa_id, tipo);


--
-- Name: usuario_alcance usuario_alcance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuario_alcance
    ADD CONSTRAINT usuario_alcance_pkey PRIMARY KEY (usuario_id, ubigeo);


--
-- Name: usuarios usuarios_dni_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_dni_key UNIQUE (dni);


--
-- Name: usuarios usuarios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_pkey PRIMARY KEY (id);


--
-- Name: venues venues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venues
    ADD CONSTRAINT venues_pkey PRIMARY KEY (id);


--
-- Name: idx_accesos_email_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_accesos_email_fecha ON public.accesos_log USING btree (email, created_at DESC);


--
-- Name: idx_actas_digitada; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_actas_digitada ON public.actas USING btree (digitada_por) WHERE (digitada_por IS NOT NULL);


--
-- Name: idx_actas_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_actas_estado ON public.actas USING btree (estado);


--
-- Name: idx_actas_foto_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_actas_foto_hash ON public.actas USING btree (foto_hash_sha256) WHERE (foto_hash_sha256 IS NOT NULL);


--
-- Name: idx_actas_mesa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_actas_mesa ON public.actas USING btree (mesa_id);


--
-- Name: idx_actas_observadas; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_actas_observadas ON public.actas USING btree (updated_at DESC) WHERE (estado = 'OBSERVADA'::public.estado_acta);


--
-- Name: idx_actas_tipo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_actas_tipo ON public.actas USING btree (tipo_eleccion, estado);


--
-- Name: idx_adj_incid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_adj_incid ON public.incidencia_adjuntos USING btree (incidencia_id);


--
-- Name: idx_adjuntos_acta; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_adjuntos_acta ON public.acta_adjuntos USING btree (acta_id);


--
-- Name: idx_alcance_ubigeo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_alcance_ubigeo ON public.usuario_alcance USING btree (ubigeo);


--
-- Name: idx_ap_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ap_estado ON public.asignacion_personeros USING btree (estado);


--
-- Name: idx_ap_mesa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ap_mesa ON public.asignacion_personeros USING btree (mesa_id);


--
-- Name: idx_ap_usuario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ap_usuario ON public.asignacion_personeros USING btree (usuario_id);


--
-- Name: idx_auditoria_global_acta; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auditoria_global_acta ON public.acta_auditoria_global USING btree (acta_id, created_at DESC);


--
-- Name: idx_auditoria_global_mesa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auditoria_global_mesa ON public.acta_auditoria_global USING btree (numero_mesa, created_at DESC);


--
-- Name: idx_auditoria_global_usuario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auditoria_global_usuario ON public.acta_auditoria_global USING btree (usuario_id, created_at DESC);


--
-- Name: idx_candidatos_ambito; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_candidatos_ambito ON public.candidatos USING btree (tipo_eleccion, ubigeo, cargo, numero_lista);


--
-- Name: idx_candidatos_busqueda; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_candidatos_busqueda ON public.candidatos USING btree (lower((nombre_completo)::text) text_pattern_ops);


--
-- Name: idx_candidatos_dni; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_candidatos_dni ON public.candidatos USING btree (dni) WHERE (dni IS NOT NULL);


--
-- Name: idx_candidatos_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_candidatos_org ON public.candidatos USING btree (organizacion_id);


--
-- Name: idx_checkin_asig; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_checkin_asig ON public.checkins_personero USING btree (asignacion_id, created_at DESC);


--
-- Name: idx_columnas_acta; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_columnas_acta ON public.acta_columnas USING btree (acta_id);


--
-- Name: idx_detalle_candidato; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_detalle_candidato ON public.detalle_votos_acta USING btree (candidato_id) WHERE (candidato_id IS NOT NULL);


--
-- Name: idx_detalle_columna; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_detalle_columna ON public.detalle_votos_acta USING btree (columna_id);


--
-- Name: idx_detalle_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_detalle_org ON public.detalle_votos_acta USING btree (organizacion_id);


--
-- Name: idx_eventos_acta; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_eventos_acta ON public.acta_eventos USING btree (acta_id, created_at DESC);


--
-- Name: idx_eventos_json; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_eventos_json ON public.acta_eventos USING gin (detalle);


--
-- Name: idx_incid_abiertas; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_incid_abiertas ON public.incidencias_campo USING btree (estado, prioridad, created_at) WHERE (estado = ANY (ARRAY['REPORTADA'::public.estado_incidencia, 'EN_ATENCION'::public.estado_incidencia, 'ESCALADA'::public.estado_incidencia]));


--
-- Name: idx_incid_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_incid_estado ON public.incidencias_campo USING btree (estado);


--
-- Name: idx_incid_local; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_incid_local ON public.incidencias_campo USING btree (local_id);


--
-- Name: idx_incid_prior; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_incid_prior ON public.incidencias_campo USING btree (prioridad);


--
-- Name: idx_incid_ubigeo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_incid_ubigeo ON public.incidencias_campo USING btree (ubigeo);


--
-- Name: idx_locales_ubigeo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_locales_ubigeo ON public.locales_votacion USING btree (ubigeo);


--
-- Name: idx_mesas_local; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mesas_local ON public.mesas USING btree (local_id);


--
-- Name: idx_observaciones_abiertas; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_observaciones_abiertas ON public.acta_observaciones USING btree (severidad, created_at) WHERE (NOT resuelta);


--
-- Name: idx_observaciones_acta; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_observaciones_acta ON public.acta_observaciones USING btree (acta_id, resuelta);


--
-- Name: idx_org_jne; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_org_jne ON public.organizaciones_politicas USING btree (id_jne);


--
-- Name: idx_seguimiento_incid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_seguimiento_incid ON public.incidencia_seguimiento USING btree (incidencia_id, created_at DESC);


--
-- Name: idx_sesiones_usuario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sesiones_usuario ON public.sesiones USING btree (usuario_id);


--
-- Name: idx_ubigeo_distritos; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ubigeo_distritos ON public.ubigeo USING btree (provincia) WHERE (distrito IS NOT NULL);


--
-- Name: idx_ubigeo_provincia; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ubigeo_provincia ON public.ubigeo USING btree (provincia) WHERE (distrito IS NULL);


--
-- Name: idx_ubigeo_reniec; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ubigeo_reniec ON public.ubigeo USING btree (ubigeo_reniec);


--
-- Name: ix_accesos_log_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_accesos_log_email ON public.accesos_log USING btree (email);


--
-- Name: ix_accesos_log_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_accesos_log_id ON public.accesos_log USING btree (id);


--
-- Name: ix_acta_auditoria_global_accion; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_acta_auditoria_global_accion ON public.acta_auditoria_global USING btree (accion);


--
-- Name: ix_acta_auditoria_global_acta_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_acta_auditoria_global_acta_id ON public.acta_auditoria_global USING btree (acta_id);


--
-- Name: ix_acta_auditoria_global_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_acta_auditoria_global_created_at ON public.acta_auditoria_global USING btree (created_at);


--
-- Name: ix_acta_auditoria_global_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_acta_auditoria_global_id ON public.acta_auditoria_global USING btree (id);


--
-- Name: ix_acta_auditoria_global_numero_mesa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_acta_auditoria_global_numero_mesa ON public.acta_auditoria_global USING btree (numero_mesa);


--
-- Name: ix_acta_auditoria_global_usuario_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_acta_auditoria_global_usuario_id ON public.acta_auditoria_global USING btree (usuario_id);


--
-- Name: ix_acta_metadata_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_acta_metadata_id ON public.acta_metadata USING btree (id);


--
-- Name: ix_asignacion_personeros_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_asignacion_personeros_estado ON public.asignacion_personeros USING btree (estado);


--
-- Name: ix_asignacion_personeros_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_asignacion_personeros_id ON public.asignacion_personeros USING btree (id);


--
-- Name: ix_asignacion_personeros_mesa_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_asignacion_personeros_mesa_id ON public.asignacion_personeros USING btree (mesa_id);


--
-- Name: ix_asignacion_personeros_usuario_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_asignacion_personeros_usuario_id ON public.asignacion_personeros USING btree (usuario_id);


--
-- Name: ix_checkins_personero_asignacion_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_checkins_personero_asignacion_id ON public.checkins_personero USING btree (asignacion_id);


--
-- Name: ix_checkins_personero_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_checkins_personero_id ON public.checkins_personero USING btree (id);


--
-- Name: ix_consejero_candidates_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_consejero_candidates_id ON public.consejero_candidates USING btree (id);


--
-- Name: ix_consejero_candidates_ubigeo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_consejero_candidates_ubigeo ON public.consejero_candidates USING btree (ubigeo);


--
-- Name: ix_district_candidates_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_district_candidates_id ON public.district_candidates USING btree (id);


--
-- Name: ix_district_candidates_ubigeo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_district_candidates_ubigeo ON public.district_candidates USING btree (ubigeo);


--
-- Name: ix_provincial_candidates_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_provincial_candidates_id ON public.provincial_candidates USING btree (id);


--
-- Name: ix_provincial_candidates_ubigeo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_provincial_candidates_ubigeo ON public.provincial_candidates USING btree (ubigeo);


--
-- Name: ix_records_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_records_id ON public.records USING btree (id);


--
-- Name: ix_regional_candidates_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_regional_candidates_id ON public.regional_candidates USING btree (id);


--
-- Name: ix_regional_candidates_ubigeo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_regional_candidates_ubigeo ON public.regional_candidates USING btree (ubigeo);


--
-- Name: ix_sesiones_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_sesiones_id ON public.sesiones USING btree (id);


--
-- Name: ix_sesiones_token_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ix_sesiones_token_hash ON public.sesiones USING btree (token_hash);


--
-- Name: ix_sesiones_usuario_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_sesiones_usuario_id ON public.sesiones USING btree (usuario_id);


--
-- Name: ix_tables_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_tables_id ON public.tables USING btree (id);


--
-- Name: ix_tables_numero_mesa; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ix_tables_numero_mesa ON public.tables USING btree (numero_mesa);


--
-- Name: ix_usuarios_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ix_usuarios_email ON public.usuarios USING btree (email);


--
-- Name: ix_usuarios_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_usuarios_id ON public.usuarios USING btree (id);


--
-- Name: ix_venues_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_venues_id ON public.venues USING btree (id);


--
-- Name: ix_venues_ubigeo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_venues_ubigeo ON public.venues USING btree (ubigeo);


--
-- Name: actas trg_actas_auditar; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_actas_auditar AFTER INSERT OR UPDATE OF estado ON public.actas FOR EACH ROW EXECUTE FUNCTION public.fn_auditar_acta();


--
-- Name: actas trg_actas_crear_columnas; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_actas_crear_columnas AFTER INSERT ON public.actas FOR EACH ROW EXECUTE FUNCTION public.fn_crear_columnas_acta();


--
-- Name: actas trg_actas_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_actas_updated BEFORE UPDATE ON public.actas FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: actas trg_actas_validar_contabilizacion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_actas_validar_contabilizacion BEFORE INSERT OR UPDATE OF estado ON public.actas FOR EACH ROW EXECUTE FUNCTION public.fn_validar_contabilizacion();


--
-- Name: acta_adjuntos trg_adjuntos_foto_unica; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_adjuntos_foto_unica BEFORE INSERT ON public.acta_adjuntos FOR EACH ROW WHEN ((new.hash_sha256 IS NOT NULL)) EXECUTE FUNCTION public.fn_evitar_foto_duplicada();


--
-- Name: asignacion_personeros trg_asignacion_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_asignacion_updated BEFORE UPDATE ON public.asignacion_personeros FOR EACH ROW EXECUTE FUNCTION public.fn_campo_updated_at();


--
-- Name: candidatos trg_candidatos_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_candidatos_updated BEFORE UPDATE ON public.candidatos FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: checkins_personero trg_checkin_presente; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_checkin_presente AFTER INSERT ON public.checkins_personero FOR EACH ROW EXECUTE FUNCTION public.fn_checkin_presente();


--
-- Name: acta_columnas trg_columnas_consolidar; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_columnas_consolidar AFTER INSERT OR DELETE OR UPDATE ON public.acta_columnas FOR EACH ROW EXECUTE FUNCTION public.fn_tras_cambio_columna();


--
-- Name: acta_columnas trg_columnas_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_columnas_updated BEFORE UPDATE ON public.acta_columnas FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: detalle_votos_acta trg_detalle_recalcular; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_detalle_recalcular AFTER INSERT OR DELETE OR UPDATE ON public.detalle_votos_acta FOR EACH ROW EXECUTE FUNCTION public.fn_recalcular_columna();


--
-- Name: detalle_votos_acta trg_detalle_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_detalle_updated BEFORE UPDATE ON public.detalle_votos_acta FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: incidencias_campo trg_incid_bitacora; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_incid_bitacora AFTER INSERT OR UPDATE OF estado ON public.incidencias_campo FOR EACH ROW EXECUTE FUNCTION public.fn_incid_bitacora();


--
-- Name: incidencias_campo trg_incid_cierre; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_incid_cierre BEFORE UPDATE OF estado ON public.incidencias_campo FOR EACH ROW EXECUTE FUNCTION public.fn_incid_cierre();


--
-- Name: incidencias_campo trg_incid_codigo; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_incid_codigo BEFORE INSERT ON public.incidencias_campo FOR EACH ROW EXECUTE FUNCTION public.fn_incid_codigo();


--
-- Name: incidencias_campo trg_incid_coherencia; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_incid_coherencia BEFORE INSERT OR UPDATE OF mesa_id, ubigeo ON public.incidencias_campo FOR EACH ROW EXECUTE FUNCTION public.fn_incid_coherencia();


--
-- Name: incidencias_campo trg_incid_prioridad; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_incid_prioridad BEFORE INSERT ON public.incidencias_campo FOR EACH ROW EXECUTE FUNCTION public.fn_incid_prioridad_default();


--
-- Name: incidencias_campo trg_incid_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_incid_updated BEFORE UPDATE ON public.incidencias_campo FOR EACH ROW EXECUTE FUNCTION public.fn_campo_updated_at();


--
-- Name: locales_votacion trg_locales_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_locales_updated BEFORE UPDATE ON public.locales_votacion FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: mesas trg_mesas_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_mesas_updated BEFORE UPDATE ON public.mesas FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: acta_observaciones trg_observaciones_no_sobre_contabilizada; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_observaciones_no_sobre_contabilizada BEFORE INSERT OR UPDATE ON public.acta_observaciones FOR EACH ROW EXECUTE FUNCTION public.fn_observacion_sobre_contabilizada();


--
-- Name: organizaciones_politicas trg_org_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_org_updated BEFORE UPDATE ON public.organizaciones_politicas FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: ubigeo trg_ubigeo_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ubigeo_updated BEFORE UPDATE ON public.ubigeo FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: usuarios trg_usuarios_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_usuarios_updated BEFORE UPDATE ON public.usuarios FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: acta_adjuntos acta_adjuntos_acta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_adjuntos
    ADD CONSTRAINT acta_adjuntos_acta_id_fkey FOREIGN KEY (acta_id) REFERENCES public.actas(id) ON DELETE CASCADE;


--
-- Name: acta_adjuntos acta_adjuntos_subido_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_adjuntos
    ADD CONSTRAINT acta_adjuntos_subido_por_fkey FOREIGN KEY (subido_por) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: acta_auditoria_global acta_auditoria_global_acta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_auditoria_global
    ADD CONSTRAINT acta_auditoria_global_acta_id_fkey FOREIGN KEY (acta_id) REFERENCES public.tables(id) ON DELETE CASCADE;


--
-- Name: acta_auditoria_global acta_auditoria_global_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_auditoria_global
    ADD CONSTRAINT acta_auditoria_global_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: acta_columnas acta_columnas_acta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_columnas
    ADD CONSTRAINT acta_columnas_acta_id_fkey FOREIGN KEY (acta_id) REFERENCES public.actas(id) ON DELETE CASCADE;


--
-- Name: acta_eventos acta_eventos_acta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_eventos
    ADD CONSTRAINT acta_eventos_acta_id_fkey FOREIGN KEY (acta_id) REFERENCES public.actas(id) ON DELETE CASCADE;


--
-- Name: acta_eventos acta_eventos_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_eventos
    ADD CONSTRAINT acta_eventos_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: acta_metadata acta_metadata_table_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_metadata
    ADD CONSTRAINT acta_metadata_table_id_fkey FOREIGN KEY (table_id) REFERENCES public.tables(id);


--
-- Name: acta_observaciones acta_observaciones_acta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_observaciones
    ADD CONSTRAINT acta_observaciones_acta_id_fkey FOREIGN KEY (acta_id) REFERENCES public.actas(id) ON DELETE CASCADE;


--
-- Name: acta_observaciones acta_observaciones_columna_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_observaciones
    ADD CONSTRAINT acta_observaciones_columna_id_fkey FOREIGN KEY (columna_id) REFERENCES public.acta_columnas(id) ON DELETE CASCADE;


--
-- Name: acta_observaciones acta_observaciones_resuelta_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.acta_observaciones
    ADD CONSTRAINT acta_observaciones_resuelta_por_fkey FOREIGN KEY (resuelta_por) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: actas actas_digitada_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actas
    ADD CONSTRAINT actas_digitada_por_fkey FOREIGN KEY (digitada_por) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: actas actas_foto_subida_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actas
    ADD CONSTRAINT actas_foto_subida_por_fkey FOREIGN KEY (foto_subida_por) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: actas actas_mesa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actas
    ADD CONSTRAINT actas_mesa_id_fkey FOREIGN KEY (mesa_id) REFERENCES public.mesas(id) ON DELETE RESTRICT;


--
-- Name: actas actas_validada_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actas
    ADD CONSTRAINT actas_validada_por_fkey FOREIGN KEY (validada_por) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: asignacion_personeros asignacion_personeros_asignado_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asignacion_personeros
    ADD CONSTRAINT asignacion_personeros_asignado_por_fkey FOREIGN KEY (asignado_por) REFERENCES public.usuarios(id);


--
-- Name: asignacion_personeros asignacion_personeros_mesa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asignacion_personeros
    ADD CONSTRAINT asignacion_personeros_mesa_id_fkey FOREIGN KEY (mesa_id) REFERENCES public.tables(id);


--
-- Name: asignacion_personeros asignacion_personeros_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asignacion_personeros
    ADD CONSTRAINT asignacion_personeros_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id);


--
-- Name: candidatos candidatos_organizacion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidatos
    ADD CONSTRAINT candidatos_organizacion_id_fkey FOREIGN KEY (organizacion_id) REFERENCES public.organizaciones_politicas(id) ON DELETE CASCADE;


--
-- Name: candidatos candidatos_ubigeo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidatos
    ADD CONSTRAINT candidatos_ubigeo_fkey FOREIGN KEY (ubigeo) REFERENCES public.ubigeo(ubigeo) ON UPDATE CASCADE;


--
-- Name: checkins_personero checkins_personero_asignacion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.checkins_personero
    ADD CONSTRAINT checkins_personero_asignacion_id_fkey FOREIGN KEY (asignacion_id) REFERENCES public.asignacion_personeros(id);


--
-- Name: detalle_votos_acta detalle_votos_acta_candidato_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.detalle_votos_acta
    ADD CONSTRAINT detalle_votos_acta_candidato_id_fkey FOREIGN KEY (candidato_id) REFERENCES public.candidatos(id) ON DELETE SET NULL;


--
-- Name: detalle_votos_acta detalle_votos_acta_columna_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.detalle_votos_acta
    ADD CONSTRAINT detalle_votos_acta_columna_id_fkey FOREIGN KEY (columna_id) REFERENCES public.acta_columnas(id) ON DELETE CASCADE;


--
-- Name: detalle_votos_acta detalle_votos_acta_organizacion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.detalle_votos_acta
    ADD CONSTRAINT detalle_votos_acta_organizacion_id_fkey FOREIGN KEY (organizacion_id) REFERENCES public.organizaciones_politicas(id) ON DELETE RESTRICT;


--
-- Name: incidencia_adjuntos incidencia_adjuntos_incidencia_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencia_adjuntos
    ADD CONSTRAINT incidencia_adjuntos_incidencia_id_fkey FOREIGN KEY (incidencia_id) REFERENCES public.incidencias_campo(id) ON DELETE CASCADE;


--
-- Name: incidencia_adjuntos incidencia_adjuntos_subido_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencia_adjuntos
    ADD CONSTRAINT incidencia_adjuntos_subido_por_fkey FOREIGN KEY (subido_por) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: incidencia_seguimiento incidencia_seguimiento_incidencia_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencia_seguimiento
    ADD CONSTRAINT incidencia_seguimiento_incidencia_id_fkey FOREIGN KEY (incidencia_id) REFERENCES public.incidencias_campo(id) ON DELETE CASCADE;


--
-- Name: incidencia_seguimiento incidencia_seguimiento_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencia_seguimiento
    ADD CONSTRAINT incidencia_seguimiento_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: incidencias_campo incidencias_campo_asignada_a_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencias_campo
    ADD CONSTRAINT incidencias_campo_asignada_a_fkey FOREIGN KEY (asignada_a) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: incidencias_campo incidencias_campo_categoria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencias_campo
    ADD CONSTRAINT incidencias_campo_categoria_id_fkey FOREIGN KEY (categoria_id) REFERENCES public.categorias_incidencia(id);


--
-- Name: incidencias_campo incidencias_campo_local_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencias_campo
    ADD CONSTRAINT incidencias_campo_local_id_fkey FOREIGN KEY (local_id) REFERENCES public.locales_votacion(id) ON DELETE SET NULL;


--
-- Name: incidencias_campo incidencias_campo_mesa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencias_campo
    ADD CONSTRAINT incidencias_campo_mesa_id_fkey FOREIGN KEY (mesa_id) REFERENCES public.mesas(id) ON DELETE SET NULL;


--
-- Name: incidencias_campo incidencias_campo_reportado_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencias_campo
    ADD CONSTRAINT incidencias_campo_reportado_por_fkey FOREIGN KEY (reportado_por) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: incidencias_campo incidencias_campo_ubigeo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidencias_campo
    ADD CONSTRAINT incidencias_campo_ubigeo_fkey FOREIGN KEY (ubigeo) REFERENCES public.ubigeo(ubigeo) ON UPDATE CASCADE;


--
-- Name: locales_votacion locales_votacion_coordinador_local_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locales_votacion
    ADD CONSTRAINT locales_votacion_coordinador_local_id_fkey FOREIGN KEY (coordinador_local_id) REFERENCES public.usuarios(id) ON DELETE SET NULL;


--
-- Name: locales_votacion locales_votacion_ubigeo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locales_votacion
    ADD CONSTRAINT locales_votacion_ubigeo_fkey FOREIGN KEY (ubigeo) REFERENCES public.ubigeo(ubigeo) ON UPDATE CASCADE;


--
-- Name: mesas mesas_local_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesas
    ADD CONSTRAINT mesas_local_id_fkey FOREIGN KEY (local_id) REFERENCES public.locales_votacion(id) ON DELETE CASCADE;


--
-- Name: records records_table_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_table_id_fkey FOREIGN KEY (table_id) REFERENCES public.tables(id);


--
-- Name: sesiones sesiones_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sesiones
    ADD CONSTRAINT sesiones_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id) ON DELETE CASCADE;


--
-- Name: tables tables_venue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tables
    ADD CONSTRAINT tables_venue_id_fkey FOREIGN KEY (venue_id) REFERENCES public.venues(id);


--
-- Name: usuario_alcance usuario_alcance_local_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuario_alcance
    ADD CONSTRAINT usuario_alcance_local_id_fkey FOREIGN KEY (local_id) REFERENCES public.locales_votacion(id) ON DELETE CASCADE;


--
-- Name: usuario_alcance usuario_alcance_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuario_alcance
    ADD CONSTRAINT usuario_alcance_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id) ON DELETE CASCADE;


--
-- Name: acta_auditoria_global; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.acta_auditoria_global ENABLE ROW LEVEL SECURITY;

--
-- Name: actas; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.actas ENABLE ROW LEVEL SECURITY;

--
-- Name: asignacion_personeros; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.asignacion_personeros ENABLE ROW LEVEL SECURITY;

--
-- Name: incidencias_campo; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.incidencias_campo ENABLE ROW LEVEL SECURITY;

--
-- Name: actas p_actas_alcance; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_actas_alcance ON public.actas USING ((EXISTS ( SELECT 1
   FROM ((public.mesas me
     JOIN public.locales_votacion lo ON ((lo.id = me.local_id)))
     JOIN public.usuario_alcance ua ON ((ua.usuario_id = (NULLIF(current_setting('app.usuario_id'::text, true), ''::text))::bigint)))
  WHERE ((me.id = actas.mesa_id) AND ((lo.ubigeo = (ua.ubigeo)::bpchar) OR ((length((ua.ubigeo)::text) = 6) AND ("substring"((lo.ubigeo)::text, 1, 4) = "substring"((ua.ubigeo)::text, 1, 4)) AND (EXISTS ( SELECT 1
           FROM public.ubigeo up
          WHERE ((up.ubigeo = (ua.ubigeo)::bpchar) AND (up.nivel = 'PROVINCIA'::public.nivel_ubigeo))))))))));


--
-- Name: actas p_actas_super_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_actas_super_admin ON public.actas USING ((current_setting('app.rol_actual'::text, true) = 'SUPER_ADMIN'::text));


--
-- Name: asignacion_personeros pol_asig_alcance; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pol_asig_alcance ON public.asignacion_personeros USING (((current_setting('app.rol_actual'::text, true) = ANY (ARRAY['SUPER_ADMIN'::text, 'DIGITADOR_GLOBAL'::text])) OR (usuario_id = (NULLIF(current_setting('app.usuario_id'::text, true), ''::text))::bigint) OR (EXISTS ( SELECT 1
   FROM ((public.mesas m
     JOIN public.locales_votacion l ON ((l.id = m.local_id)))
     JOIN public.usuario_alcance ua ON ((ua.usuario_id = (NULLIF(current_setting('app.usuario_id'::text, true), ''::text))::bigint)))
  WHERE ((m.id = asignacion_personeros.mesa_id) AND ((l.id = ua.local_id) OR (l.ubigeo = (ua.ubigeo)::bpchar)))))));


--
-- Name: acta_auditoria_global pol_auditoria_global_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pol_auditoria_global_insert ON public.acta_auditoria_global FOR INSERT WITH CHECK ((current_setting('app.rol_actual'::text, true) = ANY (ARRAY['SUPER_ADMIN'::text, 'DIGITADOR_GLOBAL'::text])));


--
-- Name: acta_auditoria_global pol_auditoria_global_lectura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pol_auditoria_global_lectura ON public.acta_auditoria_global FOR SELECT USING (((current_setting('app.rol_actual'::text, true) = ANY (ARRAY['SUPER_ADMIN'::text, 'DIGITADOR_GLOBAL'::text])) OR (usuario_id = (NULLIF(current_setting('app.usuario_id'::text, true), ''::text))::bigint)));


--
-- Name: incidencias_campo pol_incid_alcance; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pol_incid_alcance ON public.incidencias_campo USING (((current_setting('app.rol_actual'::text, true) = 'SUPER_ADMIN'::text) OR (reportado_por = (NULLIF(current_setting('app.usuario_id'::text, true), ''::text))::bigint) OR (EXISTS ( SELECT 1
   FROM public.usuario_alcance ua
  WHERE ((ua.usuario_id = (NULLIF(current_setting('app.usuario_id'::text, true), ''::text))::bigint) AND ((incidencias_campo.local_id = ua.local_id) OR (incidencias_campo.ubigeo = (ua.ubigeo)::bpchar) OR ((EXISTS ( SELECT 1
           FROM public.ubigeo up
          WHERE ((up.ubigeo = (ua.ubigeo)::bpchar) AND (up.nivel = 'PROVINCIA'::public.nivel_ubigeo)))) AND ("substring"((incidencias_campo.ubigeo)::text, 1, 4) = "substring"((ua.ubigeo)::text, 1, 4)))))))));


--
-- PostgreSQL database dump complete
--

