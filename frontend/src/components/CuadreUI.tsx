import type { ResultadoCuadre } from "../lib/validacionCuadre";

/* ==================================================================== *
 *  CuadreUI — piezas visuales del motor de cuadre (validacionCuadre.ts)
 *
 *  BadgeCuadre : estado por columna  ⚠️ 150 ≠ 250 / ✓ cuadra 250 / 🚫 >
 *  AlertaCuadre: alerta de sección con desglose dinámico, mensaje
 *                accionable para el digitador y chips que resaltan si
 *                la brecha proviene de la LISTA DE PARTIDOS (válidos)
 *                o de los casilleros de BLANCOS / NULOS / IMPUGNADOS.
 * ==================================================================== */

/* ---------------- Badge de estado de la columna ---------------- */

interface BadgeCuadreProps {
  /** Resultado del cuadre de la columna (useCuadreColumnas/validarCuadre). */
  r: ResultadoCuadre;
  /** Clases extra (posicionamiento, margen…). */
  clase?: string;
}

export function BadgeCuadre({ r, clase = "" }: BadgeCuadreProps) {
  if (!r.badge) return null;
  const titulo =
    r.estado === "SIN_REFERENCIA"
      ? "Sin cabecera de votantes: digítela para validar el cuadre"
      : r.mensaje ?? r.desglose ?? undefined;
  return (
    <span
      title={titulo}
      className={`rounded-full px-2 py-0.5 text-[10px] font-black tabular-nums ${r.badgeClase} ${clase}`}
    >
      {r.badge}
    </span>
  );
}

/* ---------------- Alerta de sección con desglose ---------------- */

/* Los chips muestran el valor de cada segmento y resaltan el
   sospechoso según el diagnóstico de origen del motor. */
const chipSospechoso = "bg-red-100 text-red-700 ring-2 ring-red-400";
const chipNeutro = "bg-slate-100 text-slate-500";

export function AlertaCuadre({ r }: { r: ResultadoCuadre }) {
  /* Sin mensaje no hay nada que alertar (cuadra / inactiva / sin referencia). */
  if (!r.mensaje) return null;

  const imposible = r.estado === "IMPOSIBLE";
  const caja = imposible
    ? "border-red-300 bg-red-50"
    : "border-amber-300 bg-amber-50";
  const tituloColor = imposible ? "text-red-700" : "text-amber-800";

  /* Resaltado de origen: la brecha está sobre todo en la lista de
     partidos (VALIDOS), en el pie B/N/I (PIE), o repartida (AMBOS). */
  const sospechaValidos = r.origen === "VALIDOS" || r.origen === "AMBOS";
  const sospechaPie = r.origen === "PIE" || r.origen === "AMBOS";

  return (
    <div
      role="alert"
      className={`mt-2 rounded-lg border-2 px-3 py-2 ${caja}`}
    >
      {/* Mensaje principal: dice EXACTAMENTE cuánto falta o sobra. */}
      <p className={`text-xs font-black leading-snug ${tituloColor}`}>
        {imposible ? "🚫 " : "⚠️ "}
        {r.mensaje}
      </p>

      {/* Desglose dinámico: aritmética de la fórmula de control. */}
      {r.desglose && (
        <p className="mt-1 font-mono text-[11px] leading-snug text-slate-600">
          {r.desglose}
        </p>
      )}

      {/* Guía de revisión según el origen diagnosticado. */}
      {r.origenDetalle && (
        <p className="mt-0.5 text-[11px] leading-snug text-slate-600">
          {r.origenDetalle}
        </p>
      )}

      {/* Chips de origen: el segmento sospechoso queda resaltado en rojo. */}
      <div className="mt-1.5 flex flex-wrap gap-1.5">
        <span
          className={`rounded-full px-2 py-0.5 text-[10px] font-bold tabular-nums ${
            sospechaValidos ? chipSospechoso : chipNeutro
          }`}
        >
          Lista de partidos (válidos): {r.validos.toLocaleString("es-PE")}
        </span>
        <span
          className={`rounded-full px-2 py-0.5 text-[10px] font-bold tabular-nums ${
            sospechaPie ? chipSospechoso : chipNeutro
          }`}
        >
          Blancos + Nulos + Impugnados: {r.pie.toLocaleString("es-PE")}
        </span>
      </div>
    </div>
  );
}
