import { useMemo } from "react";

/* ==================================================================== *
 *  validacionCuadre.ts — Motor de validación de cuadre electoral
 *  (R1 del sistema · norma ONPE por columna)
 *
 *  FÓRMULA DE CONTROL:
 *      Total_Leídas = Válidos + Blancos + Nulos + Impugnados
 *      Total_Leídas === Total_Votaron  (ciudadanos que votaron según
 *      el padrón/cabecera de la mesa)
 *
 *  Si no cuadra, se genera un DESGLOSE DINÁMICO exacto:
 *      Diferencia = Total_Votaron − Total_Leídas
 *        · diferencia > 0 → FALTAN votos por registrar
 *          (ej.: Regional 150 ≠ 250 → faltan 100)
 *        · diferencia < 0 → IMPOSIBLE: se leyeron más votos que
 *          votantes (error de digitación)
 *
 *  DIAGNÓSTICO DE ORIGEN: cuando otras columnas de la misma mesa sí
 *  cuadran (referencia), la brecha de esta columna se compara segmento
 *  a segmento — lista de partidos (votos válidos) vs pie de acta
 *  (blancos/nulos/impugnados) — y el segmento con mayor brecha se
 *  resalta en la interfaz para guiar la vista del digitador.
 *  Es una HEURÍSTICA de orientación, no un veredicto: el papel manda.
 *
 *  Manejo de errores: las entradas vienen de OCR/formularios y pueden
 *  llegar null/undefined/NaN/decimales; entero() sanea todo a entero
 *  >= 0 para que la aritmética de cuadre nunca se rompa.
 * ==================================================================== */

/* Los cuatro casilleros que componen una columna del acta. */
export interface SegmentosColumna {
  /** Suma de la lista de partidos (votos válidos). */
  validos: number;
  /** Votos en blanco del pie de la columna. */
  blancos: number;
  /** Votos nulos del pie de la columna. */
  nulos: number;
  /** Votos impugnados del pie de la columna. */
  impugnados: number;
}

/* Estados posibles del cuadre de una columna:
   · INACTIVA       → sin votos digitados (columna vacía, no se valida)
   · SIN_REFERENCIA → activa pero sin cabecera de votantes (no se valida)
   · CUADRA         → Total_Leídas === Total_Votaron ✓
   · FALTAN         → Total_Leídas < Total_Votaron (faltan registrar)
   · IMPOSIBLE      → Total_Leídas > Total_Votaron (sobra digitación) */
export type EstadoCuadre =
  | "INACTIVA"
  | "SIN_REFERENCIA"
  | "CUADRA"
  | "FALTAN"
  | "IMPOSIBLE";

/* Dónde está probablemente la brecha (para el resaltado visual):
   · VALIDOS     → lista de partidos (votos válidos)
   · PIE         → casilleros de Blancos / Nulos / Impugnados
   · AMBOS       → la brecha se reparte entre ambos segmentos
   · DESCONOCIDO → sin columna de referencia que oriente */
export type OrigenDescuadre = "VALIDOS" | "PIE" | "AMBOS" | "DESCONOCIDO";

/* Columna de referencia para el diagnóstico de origen (valores de
   segmentos de una columna sana de la misma mesa). */
export interface ReferenciaSegmentos {
  validos: number;
  pie: number;
}

export interface ResultadoCuadre {
  clave: string;
  nombre: string;
  /** Segmentos saneados de la columna. */
  validos: number;
  blancos: number;
  nulos: number;
  impugnados: number;
  /** Blancos + Nulos + Impugnados. */
  pie: number;
  /** Válidos + B + N + I (Total_Leídas de la fórmula de control). */
  totalLeidas: number;
  /** Ciudadanos que votaron según el padrón (cabecera del acta). */
  totalVotaron: number | null;
  /** Total_Votaron − Total_Leídas (> 0 faltan, < 0 sobran). */
  diferencia: number;
  /** |diferencia|, para los textos del digitador. */
  diferenciaAbs: number;
  estado: EstadoCuadre;
  origen: OrigenDescuadre;
  /** Texto que explica al digitador dónde revisar según el origen. */
  origenDetalle: string | null;
  /** Alerta principal; null cuando la columna cuadra o no es validable. */
  mensaje: string | null;
  /** Aritmética exacta de la diferencia (desglose dinámico). */
  desglose: string | null;
  /** Texto del badge: "✓ cuadra 250", "⚠️ 150 ≠ 250", "🚫 300 > 250"… */
  badge: string | null;
  /** Clases Tailwind del badge según estado. */
  badgeClase: string;
  /** Clase de fondo de la cabecera de la tarjeta de la sección. */
  cabeceraClase: string;
  /** Clase de borde de la tarjeta de la sección. */
  bordeClase: string;
}

/* Saneo defensivo: cualquier entrada no numérica/negativa → 0. */
const entero = (v: unknown): number =>
  typeof v === "number" && Number.isFinite(v) && v > 0 ? Math.floor(v) : 0;

/* Normaliza la cabecera: null/0/NaN → null (sin referencia). */
const votantesSanos = (v: number | null | undefined): number | null =>
  typeof v === "number" && Number.isFinite(v) && v > 0 ? Math.floor(v) : null;

const num = (v: number) => v.toLocaleString("es-PE");

/* Guías de texto por origen: le dicen al digitador DÓNDE mirar. */
const ORIGEN_DETALLE: Record<OrigenDescuadre, string> = {
  VALIDOS:
    "La brecha proviene sobre todo de la LISTA DE PARTIDOS (votos válidos): " +
    "revisa las casillas de las organizaciones contra el acta física.",
  PIE:
    "La brecha proviene sobre todo de los casilleros de BLANCOS, NULOS o " +
    "IMPUGNADOS: verifícalos contra el pie del acta física.",
  AMBOS:
    "La brecha se reparte entre la lista de partidos y el pie (B/N/I): " +
    "revisa ambos bloques contra el acta física.",
  DESCONOCIDO:
    "No hay otra columna sana de referencia en esta mesa: revisa la lista " +
    "de partidos y los casilleros B/N/I contra el acta física.",
};

/* Estilos por estado (badge, cabecera y borde de la tarjeta). */
const ESTILO: Record<EstadoCuadre, { badge: string; cabecera: string; borde: string }> = {
  INACTIVA: { badge: "bg-slate-100 text-slate-500", cabecera: "bg-slate-50", borde: "border-slate-200" },
  SIN_REFERENCIA: { badge: "bg-slate-100 text-slate-600", cabecera: "bg-slate-50", borde: "border-slate-200" },
  CUADRA: { badge: "bg-emerald-100 text-emerald-700", cabecera: "bg-emerald-50", borde: "border-emerald-200" },
  FALTAN: { badge: "bg-amber-100 text-amber-700", cabecera: "bg-amber-50", borde: "border-amber-400" },
  IMPOSIBLE: { badge: "bg-red-100 text-red-700", cabecera: "bg-red-50", borde: "border-red-400" },
};

/* ---------------------------------------------------------------- *
 *  diagnosticarOrigen — heurística de segmentos
 *
 *  Compara la columna descuadrada contra una referencia sana (una
 *  columna de la MISMA mesa que sí cuadra; si ninguna cuadra, la de
 *  mayor total leído). Mide la brecha de cada segmento:
 *      gapValidos = referencia.validos − col.validos
 *      gapPie     = referencia.pie     − col.pie
 *  El segmento con la brecha dominante (≥ 2× la otra) es el sospechoso.
 * ---------------------------------------------------------------- */
function diagnosticarOrigen(
  col: { validos: number; pie: number },
  ref: ReferenciaSegmentos | null,
): OrigenDescuadre {
  if (!ref) return "DESCONOCIDO";
  const gapValidos = Math.abs(ref.validos - col.validos);
  const gapPie = Math.abs(ref.pie - col.pie);
  if (gapValidos === 0 && gapPie === 0) return "DESCONOCIDO";
  if (gapPie === 0) return "VALIDOS";
  if (gapValidos === 0) return "PIE";
  if (gapValidos >= gapPie * 2) return "VALIDOS";
  if (gapPie > gapValidos * 2) return "PIE";
  return "AMBOS";
}

/* ---------------------------------------------------------------- *
 *  validarCuadre — FUNCIÓN PURA de validación (sin React)
 *
 *  Evalúa  Total_Leídas === Total_Votaron  y devuelve el resultado
 *  completo: estado, diferencia exacta, desglose dinámico, mensaje
 *  para el digitador y diagnóstico de origen.
 *
 *  `referencia` (opcional) habilita el diagnóstico de origen con los
 *  segmentos de una columna sana de la misma mesa.
 * ---------------------------------------------------------------- */
export function validarCuadre(
  clave: string,
  nombre: string,
  col: SegmentosColumna,
  totalVotaron: number | null | undefined,
  referencia: ReferenciaSegmentos | null = null,
): ResultadoCuadre {
  const validos = entero(col.validos);
  const blancos = entero(col.blancos);
  const nulos = entero(col.nulos);
  const impugnados = entero(col.impugnados);
  const pie = blancos + nulos + impugnados;
  const totalLeidas = validos + pie;
  const votaron = votantesSanos(totalVotaron);

  /* Base común del resultado (se completa según estado). */
  const r: ResultadoCuadre = {
    clave, nombre,
    validos, blancos, nulos, impugnados,
    pie, totalLeidas,
    totalVotaron: votaron,
    diferencia: 0,
    diferenciaAbs: 0,
    estado: "INACTIVA",
    origen: "DESCONOCIDO",
    origenDetalle: null,
    mensaje: null,
    desglose: null,
    badge: null,
    badgeClase: ESTILO.INACTIVA.badge,
    cabeceraClase: ESTILO.INACTIVA.cabecera,
    bordeClase: ESTILO.INACTIVA.borde,
  };

  /* Columna sin votos digitados: no se valida, la UI la muestra atenuada. */
  if (totalLeidas === 0) return r;

  /* Sin cabecera de votantes no hay contra qué validar; se muestra el
     total parcial en neutro ("Σ 150") sin alarmar al digitador. */
  if (votaron == null) {
    return {
      ...r,
      estado: "SIN_REFERENCIA",
      badge: `Σ ${num(totalLeidas)}`,
      badgeClase: ESTILO.SIN_REFERENCIA.badge,
      cabeceraClase: ESTILO.SIN_REFERENCIA.cabecera,
      bordeClase: ESTILO.SIN_REFERENCIA.borde,
    };
  }

  const diferencia = votaron - totalLeidas;
  const estilo = diferencia === 0 ? ESTILO.CUADRA : diferencia < 0 ? ESTILO.IMPOSIBLE : ESTILO.FALTAN;
  const estado: EstadoCuadre =
    diferencia === 0 ? "CUADRA" : diferencia < 0 ? "IMPOSIBLE" : "FALTAN";
  const desglose =
    `Válidos (${num(validos)}) + Blancos (${num(blancos)}) + Nulos (${num(nulos)}) ` +
    `+ Impugnados (${num(impugnados)}) = ${num(totalLeidas)} leídas · ` +
    `Diferencia = ${num(votaron)} − ${num(totalLeidas)} = ${diferencia > 0 ? "+" : ""}${num(diferencia)}`;

  /* CUADRA: badge afirmativo "✓ cuadra 250". */
  if (estado === "CUADRA") {
    return {
      ...r,
      estado,
      diferencia,
      desglose,
      badge: `✓ cuadra ${num(votaron)}`,
      badgeClase: ESTILO.CUADRA.badge,
      cabeceraClase: ESTILO.CUADRA.cabecera,
      bordeClase: ESTILO.CUADRA.borde,
    };
  }

  /* Descuadre: mensaje accionable + diagnóstico de origen. */
  const origen = diagnosticarOrigen({ validos, pie }, referencia);
  const mensaje =
    estado === "FALTAN"
      /* Copia exacta pedida para guiar al digitador. */
      ? `Faltan registrar ${num(Math.abs(diferencia))} ${Math.abs(diferencia) === 1 ? "voto" : "votos"} en esta categoría para cuadrar con el padrón (${num(votaron)}).`
      : `Sobran ${num(Math.abs(diferencia))} ${Math.abs(diferencia) === 1 ? "voto" : "votos"} en esta categoría: la suma leída (${num(totalLeidas)}) supera a los votantes del padrón (${num(votaron)}). Verifica la digitación.`;
  const badge =
    estado === "FALTAN"
      ? `⚠️ ${num(totalLeidas)} ≠ ${num(votaron)}`
      : `🚫 ${num(totalLeidas)} > ${num(votaron)}`;

  return {
    ...r,
    estado,
    diferencia,
    diferenciaAbs: Math.abs(diferencia),
    origen,
    origenDetalle: ORIGEN_DETALLE[origen],
    mensaje,
    desglose,
    badge,
    badgeClase: estilo.badge,
    cabeceraClase: estilo.cabecera,
    bordeClase: estilo.borde,
  };
}

/* Entrada de una columna para el hook (segmentos + identificación). */
export interface ColumnaCuadreInput extends SegmentosColumna {
  clave: string;
  nombre: string;
}

/* ---------------------------------------------------------------- *
 *  useCuadreColumnas — AUTO-COMPROBACIÓN EN TIEMPO REAL
 *
 *  Recalcula el cuadre de TODAS las columnas cada vez que el usuario
 *  edita cualquier casillero (votos por partido, blancos, nulos,
 *  impugnados) o la cabecera de votantes. Devuelve un mapa
 *  clave → ResultadoCuadre listo para renderizar badges y alertas.
 *
 *  La columna de REFERENCIA para el diagnóstico de origen se elige
 *  automáticamente: la primera que SÍ cuadra; si ninguna cuadra, la
 *  de mayor total leído (guía suave; nunca la propia columna).
 * ---------------------------------------------------------------- */
export function useCuadreColumnas(
  columnas: ColumnaCuadreInput[],
  totalVotaron: number | null | undefined,
): Record<string, ResultadoCuadre> {
  /* Huella estable de dependencias: con arrays recreados en cada
     render, el useMemo sólo recalcula si un VALOR cambió de verdad. */
  const huella =
    `${votantesSanos(totalVotaron) ?? 0}|` +
    columnas
      .map((c) => `${c.clave}:${entero(c.validos)},${entero(c.blancos)},${entero(c.nulos)},${entero(c.impugnados)}`)
      .join(";");

  return useMemo(() => {
    const votaron = votantesSanos(totalVotaron);
    const base = columnas.map((c) => validarCuadre(c.clave, c.nombre, c, votaron));

    /* Referencia sana: primera columna que cuadra; si no hay, la mayor. */
    const cuadra = base.find((r) => r.estado === "CUADRA");
    const ref =
      cuadra ??
      base.reduce<ResultadoCuadre | null>(
        (acc, r) => (r.totalLeidas > 0 && (!acc || r.totalLeidas > acc.totalLeidas) ? r : acc),
        null,
      );
    const refDatos: ReferenciaSegmentos | null =
      ref ? { validos: ref.validos, pie: ref.pie } : null;

    /* Segunda pasada: re-validar las descuadradas con la referencia
       (la propia referencia nunca se diagnostica contra sí misma). */
    const out: Record<string, ResultadoCuadre> = {};
    for (const r of base) {
      out[r.clave] =
        r.estado === "FALTAN" || r.estado === "IMPOSIBLE"
          ? validarCuadre(
              r.clave, r.nombre,
              { validos: r.validos, blancos: r.blancos, nulos: r.nulos, impugnados: r.impugnados },
              votaron,
              ref && ref.clave !== r.clave ? refDatos : null,
            )
          : r;
    }
    return out;
    // La huella resume todas las entradas del hook (columnas + cabecera).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [huella]);
}
