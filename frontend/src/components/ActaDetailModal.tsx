import { useEffect, useState } from "react";
import { api } from "../api";
import type { ActaRecord, RankingEntry } from "../types";
import { Alerta, Boton } from "./ui";

/* Incidencias del sistema registradas para esta mesa (log R0-R6). */
interface Incidencia {
  regla: string;
  mensaje: string;
  fecha: string | null;
}

type ActaConAuditoria = ActaRecord & {
  digitador?: string | null;
  actualizada_en?: string | null;
  incidencias?: Incidencia[];
};

/* ==================================================================== *
 *  Ficha de acta / mesa — la vista de "Ver" de la Gestión de Actas.
 *
 *  Sirve para DOS casos, porque el digitador busca el acta antes y después
 *  de cargarla:
 *    * Mesa sin acta  → ficha del padrón (local, distrito, electores,
 *      checklist de la ONPE) y botón para cargarla.
 *    * Acta registrada → además la EVIDENCIA (foto del acta física) y los
 *      votos por nivel (distrital, provincial, regional) con blancos,
 *      nulos e impugnados.
 *
 *  Todo lo territorial sale del padrón real (ubigeo INEI del local), no de
 *  valores escritos a mano.
 * ==================================================================== */

interface Props {
  acta: ActaRecord | null;
  /** Mesa a mostrar cuando todavía no hay acta (fila PENDIENTE). */
  numeroMesa?: string | null;
  onClose: () => void;
  onEditar?: (acta: ActaRecord) => void;
  onCargar?: (mesa: string) => void;
}

type Checklist = Awaited<ReturnType<typeof api.checklist>>;

const NIVELES: Array<{ clave: "distrital" | "provincial" | "consejero" | "regional"; titulo: string; tituloCorto: string }> = [
  { clave: "regional", titulo: "Regional (gobernador y vice)", tituloCorto: "Regional" },
  { clave: "consejero", titulo: "Consejeros Regionales (por provincia)", tituloCorto: "Consejeros" },
  { clave: "provincial", titulo: "Provincial (alcalde provincial)", tituloCorto: "Provincial" },
  { clave: "distrital", titulo: "Distrital (alcalde)", tituloCorto: "Distrital" },
];

const suma = (filas: RankingEntry[] | undefined) =>
  (filas ?? []).reduce((s, c) => s + (c.votes ?? 0), 0);

const num = (v: number | null | undefined) => (v ?? 0).toLocaleString("es-PE");

export default function ActaDetailModal({
  acta: actaBase, numeroMesa, onClose, onEditar, onCargar,
}: Props) {
  const acta = actaBase as ActaConAuditoria | null;
  const mesa = acta?.numero_mesa ?? numeroMesa ?? "";
  const [checklist, setChecklist] = useState<Checklist | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [fotoGrande, setFotoGrande] = useState(false);

  useEffect(() => {
    const cerrar = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      if (fotoGrande) setFotoGrande(false);
      else onClose();
    };
    window.addEventListener("keydown", cerrar);
    return () => window.removeEventListener("keydown", cerrar);
  }, [fotoGrande, onClose]);

  useEffect(() => {
    setChecklist(null);
    setAviso(null);
    if (!mesa) return;
    let vigente = true;
    api
      .checklist(mesa)
      .then((c) => { if (vigente) setChecklist(c); })
      .catch((e) => {
        // Ficha territorial incompleta no debe impedir ver el acta.
        if (vigente) setAviso(String(e instanceof Error ? e.message : e));
      });
    return () => { vigente = false; };
  }, [mesa]);

  if (!acta && !numeroMesa) return null;

  /* OJO: el listado siempre manda `acta_id` (es el id de la MESA, exista acta
     o no), así que el estado no puede deducirse de que haya acta. Se espeja
     `_estado_de_fila` del backend: processed ⇒ registrada, requires_review ⇒
     observada, el resto ⇒ pendiente. */
  const estado: "REGISTRADA" | "OBSERVADA" | "PENDIENTE" = !acta || acta.status === "pending"
    ? "PENDIENTE"
    : acta.requires_review ? "OBSERVADA" : "REGISTRADA";
  const tieneActa = estado !== "PENDIENTE";
  const distrito = acta?.distrito || "";
  const provincia = acta?.provincia || "";
  const ubigeo = acta?.ubigeo || checklist?.ubigeo || "";
  const local = acta?.venue_name || checklist?.local || "";
  const electores = acta?.electores_habiles ?? acta?.total_electores ?? checklist?.electores_habiles ?? null;

  const votos = {
    distrital: acta?.votos_distrital ?? [],
    provincial: acta?.votos_provincial ?? [],
    consejero: acta?.votos_consejero ?? [],
    regional: acta?.votos_regional ?? [],
  };
  /* Norma ONPE por columna: cada nivel tiene su PROPIO pie (blancos/nulos/
     impugnados) y cuadra INDEPENDIENTEMENTE con los votantes de la cabecera.
     Los "emitidos" son los de la COLUMNA MAYOR, nunca la suma de niveles
     (el mismo elector vota en todas las columnas del papel). */
  const aAny = (acta ?? {}) as unknown as Record<string, number | null | undefined>;
  const pieConsolidado = (acta?.votos_blancos ?? 0) + (acta?.votos_nulos ?? 0)
    + (acta?.votos_impugnados ?? 0);
  const otrosDe = (nivel: string, validos: number) => {
    const b = aAny[`blancos_${nivel}`];
    const nu = aAny[`nulos_${nivel}`];
    const im = aAny[`impugnados_${nivel}`];
    if (b != null || nu != null || im != null) {
      const pie = (b ?? 0) + (nu ?? 0) + (im ?? 0);
      if (pie > 0) return pie;
      // Pie por columna en ceros (actas sin pie digitado): la columna con
      // votos usa el consolidado histórico como respaldo.
      return validos > 0 ? pieConsolidado : 0;
    }
    return validos > 0 ? pieConsolidado : 0;
  };
  const columnas = NIVELES.map((n) => {
    const validos = suma(votos[n.clave]);
    return {
      clave: n.clave, titulo: n.tituloCorto,
      total: validos + otrosDe(n.clave, validos),
      activa: validos + otrosDe(n.clave, validos) > 0,
    };
  });
  const emitidos = Math.max(0, ...columnas.filter((c) => c.activa).map((c) => c.total));
  const hayVotos = emitidos > 0;
  const participacion = electores && electores > 0 ? (100 * emitidos) / electores : 0;
  const votantesCabecera = aAny.total_votantes ?? null;

  const ESTILO: Record<string, string> = {
    REGISTRADA: "bg-emerald-100 text-emerald-800",
    PENDIENTE: "bg-slate-200 text-slate-700",
    OBSERVADA: "bg-amber-100 text-amber-800",
  };

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`Acta de la mesa ${mesa}`}
      className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/50 p-3 sm:items-center"
    >
      <div className="w-full max-w-3xl overflow-hidden rounded-2xl bg-white shadow-2xl">
        {/* Cabecera */}
        <div className="flex flex-wrap items-center gap-3 border-b border-slate-100 bg-slate-50 px-5 py-3">
          <div className="min-w-0 flex-1">
            <p className="text-[11px] font-black uppercase tracking-wider text-slate-400">
              Acta de la mesa
            </p>
            <h2 className="font-mono text-xl font-black tabular-nums text-[#E02020]">
              {mesa}
            </h2>
          </div>
          <span className={`rounded-full px-3 py-1 text-[11px] font-black ${ESTILO[estado] ?? ESTILO.PENDIENTE}`}>
            {estado === "REGISTRADA"
              ? "✓ Procesada Normal"
              : estado === "OBSERVADA"
                ? "⚠ Observada por Incoherencia"
                : "En Control de Calidad"}
          </span>
          <button
            onClick={onClose}
            aria-label="Cerrar"
            className="rounded-lg px-2.5 py-1.5 text-slate-500 hover:bg-slate-200"
          >
            ✕
          </button>
        </div>

        <div className="max-h-[80vh] space-y-3 overflow-y-auto p-4">
          {aviso && <Alerta tono="aviso">No se pudo cargar la ficha del padrón: {aviso}</Alerta>}

          {/* ============ A. CABECERA DEL ACTA (un golpe de vista) ============ */}
          <section className="rounded-2xl border border-slate-200 bg-gradient-to-r from-slate-50 to-white p-3">
            <div className="flex flex-wrap items-center gap-x-5 gap-y-2">
              <div className="min-w-0">
                <p className="text-[10px] font-black uppercase tracking-wider text-slate-400">Ubicación</p>
                <p className="truncate text-xs font-bold text-slate-800">
                  AREQUIPA › {provincia || "—"} › {distrito || "—"}
                </p>
                <p className="truncate text-[11px] text-slate-500">{local || "—"}</p>
              </div>
              <div className="min-w-[130px]">
                <p className="text-[10px] font-black uppercase tracking-wider text-slate-400">Mesa</p>
                <p className="font-mono text-lg font-black tabular-nums text-[#E02020]">{mesa}</p>
              </div>
              <div className="min-w-[150px] flex-1">
                <p className="text-[10px] font-black uppercase tracking-wider text-slate-400">Padrón · Participación</p>
                <div className="flex items-baseline gap-2 font-mono text-xs font-bold text-slate-800">
                  <span>{electores ? num(electores) : "—"} hábiles</span>
                  <span className="text-slate-300">·</span>
                  <span>{num(emitidos)} votaron</span>
                  <span className={`text-sm font-black ${participacion >= 100 ? "text-red-600" : "text-emerald-600"}`}>
                    {electores ? `${participacion.toFixed(1)}%` : "—"}
                  </span>
                </div>
                <div className="mt-1 h-1.5 w-full overflow-hidden rounded-full bg-slate-200">
                  <div
                    className={`h-full rounded-full ${participacion >= 100 ? "bg-red-500" : "bg-emerald-500"}`}
                    style={{ width: `${Math.min(100, participacion)}%` }}
                  />
                </div>
                {votantesCabecera != null && hayVotos && votantesCabecera !== emitidos && (
                  <p className="mt-1 text-[11px] font-bold text-red-600">
                    ⚠ Cabecera declara {num(votantesCabecera)} votantes ≠ {num(emitidos)} leídos
                  </p>
                )}
                {votantesCabecera != null && electores != null && votantesCabecera > electores && (
                  <p className="mt-0.5 text-[11px] font-black text-red-600">
                    🚫 R2: votantes superan el padrón
                  </p>
                )}
              </div>
              {tieneActa && acta?.image_url && (
                <button onClick={() => setFotoGrande(true)} title="Ampliar evidencia del acta física"
                  className="shrink-0 rounded-lg border border-slate-200 shadow-sm transition hover:shadow-md">
                  <img src={acta.image_url} alt={`Acta ${mesa}`}
                    className="h-14 w-20 rounded-lg object-cover" />
                </button>
              )}
            </div>
          </section>

          {/* ============ B. RESUMEN COMPARATIVO SIDE-BY-SIDE ============ */}
          {hayVotos && (
            <section className="grid gap-3 lg:grid-cols-2">
              {NIVELES.map((n) => {
                const validosNivel = suma(votos[n.clave]);
                const otros = otrosDe(n.clave, validosNivel);
                const totalLeidas = validosNivel + otros;
                const activa = totalLeidas > 0;
                const descuadre = activa && votantesCabecera != null && votantesCabecera > 0
                  && totalLeidas !== votantesCabecera;
                const imposible = activa && votantesCabecera != null
                  && totalLeidas > votantesCabecera;
                const maxVotos = Math.max(1, ...votos[n.clave].map((c) => c.votes));
                return (
                  <div key={n.clave}
                    className={`rounded-xl border-2 bg-white ${
                      !activa ? "border-slate-200 opacity-60"
                      : descuadre ? (imposible ? "border-red-400" : "border-amber-400")
                      : "border-emerald-200"}`}>
                    <div className={`flex items-center justify-between rounded-t-lg px-3 py-1.5 ${
                      descuadre
                        ? (imposible ? "bg-red-50" : "bg-amber-50")
                        : activa ? "bg-emerald-50" : "bg-slate-50"}`}>
                      <span className="text-[11px] font-black uppercase tracking-wider text-slate-600">
                        {n.tituloCorto}
                      </span>
                      {activa && (
                        <span className={`rounded-full px-2 py-0.5 text-[10px] font-black ${
                          descuadre
                            ? (imposible ? "bg-red-100 text-red-700" : "bg-amber-100 text-amber-700")
                            : "bg-emerald-100 text-emerald-700"}`}>
                          {descuadre
                            ? (imposible
                              ? `🚫 ${num(totalLeidas)} > ${num(votantesCabecera ?? 0)}`
                              : `⚠ ${num(totalLeidas)} ≠ ${num(votantesCabecera ?? 0)}`)
                            : `✓ cuadra ${num(votantesCabecera ?? totalLeidas)}`}
                        </span>
                      )}
                    </div>
                    {!activa ? (
                      <p className="px-3 py-4 text-center text-xs text-slate-400">Sin votos en este nivel.</p>
                    ) : (
                      <>
                        <div className="max-h-44 divide-y divide-slate-50 overflow-y-auto">
                          {votos[n.clave]
                            .slice()
                            .sort((a, b) => b.votes - a.votes)
                            .filter((c) => c.votes > 0)
                            .map((c) => {
                              const pct = validosNivel > 0 ? (100 * c.votes) / validosNivel : 0;
                              return (
                                <div key={`${n.clave}-${c.candidate_id}`} className="flex items-center gap-2 px-3 py-1.5">
                                  <span className="w-5 shrink-0 text-center font-mono text-[10px] font-black text-slate-400"
                                    title={`Casita ${c.candidate_id}`}>
                                    {c.candidate_id}
                                  </span>
                                  <span className="min-w-0 flex-1">
                                    <span className="block truncate text-[11px] font-bold text-slate-800">
                                      {c.party || c.name}
                                    </span>
                                    {/* Micro-gráfico: barra relativa al líder del nivel */}
                                    <span className="mt-0.5 block h-1.5 w-full overflow-hidden rounded-full bg-slate-100">
                                      <span className="block h-full rounded-full"
                                        style={{
                                          width: `${(100 * c.votes) / maxVotos}%`,
                                          backgroundColor: c.color || "#E02020",
                                        }} />
                                    </span>
                                    {c.name && c.name !== c.party && (
                                      <span className="block truncate text-[10px] text-slate-400">{c.name}</span>
                                    )}
                                  </span>
                                  <span className="shrink-0 text-right font-mono text-[11px] font-black tabular-nums text-slate-700">
                                    {num(c.votes)}
                                    <span className="block text-[9px] font-normal text-slate-400">{pct.toFixed(1)}%</span>
                                  </span>
                                </div>
                              );
                            })}
                        </div>
                        {/* Desglose técnico por columna (B/N/I en gris neutro) */}
                        <div className="grid grid-cols-5 gap-px border-t border-slate-100 bg-slate-100 text-center">
                          {([
                            ["Válidos", validosNivel, "bg-white text-slate-800"],
                            ["Blancos", aAny[`blancos_${n.clave}`] ?? acta?.votos_blancos ?? 0,
                              "bg-slate-50 text-slate-500"],
                            ["Nulos", aAny[`nulos_${n.clave}`] ?? acta?.votos_nulos ?? 0,
                              "bg-slate-50 text-slate-500"],
                            ["Impugn.", aAny[`impugnados_${n.clave}`] ?? acta?.votos_impugnados ?? 0,
                              "bg-slate-50 text-slate-500"],
                            ["Leídas", totalLeidas, "bg-slate-800 text-white"],
                          ] as const).map(([et, v, cls]) => (
                            <div key={et} className={`px-1 py-1.5 ${cls}`}>
                              <p className="text-[9px] font-black uppercase tracking-wide opacity-70">{et}</p>
                              <p className="font-mono text-sm font-black tabular-nums">{num(v)}</p>
                            </div>
                          ))}
                        </div>
                      </>
                    )}
                  </div>
                );
              })}
            </section>
          )}
          {!hayVotos && (
            <section className="rounded-xl border border-dashed border-slate-300 bg-slate-50 px-3 py-6 text-center">
              <p className="text-sm font-bold text-slate-600">
                {tieneActa ? "Acta registrada sin votos cargados" : "Esta mesa no tiene acta registrada"}
              </p>
              <p className="mt-1 text-xs text-slate-400">
                {tieneActa
                  ? "Rectifique los votos con el botón Editar."
                  : "Cárguela desde el botón de abajo o desde la fila de la tabla."}
              </p>
            </section>
          )}

          {/* ============ C. AUDITORÍA Y TRAZABILIDAD ============ */}
          <section className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2">
            <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px]">
              <span className="text-slate-400">👤 Digitador:</span>
              <span className="font-bold text-slate-700">{acta?.digitador || "—"}</span>
              <span className="text-slate-400">🕒 Registro:</span>
              <span className="font-mono font-bold text-slate-700">
                {acta?.actualizada_en
                  ? new Date(acta.actualizada_en).toLocaleString("es-PE", { dateStyle: "short", timeStyle: "medium" })
                  : "—"}
              </span>
              <span className="font-mono text-slate-400">ubigeo {ubigeo || "—"}</span>
            </div>
            {(acta?.incidencias?.length ?? 0) > 0 && (
              <div className="mt-1.5 border-t border-slate-200 pt-1.5">
                <p className="text-[10px] font-black uppercase tracking-wider text-amber-600">
                  ⚠ Incidencias del sistema ({acta!.incidencias!.length})
                </p>
                <ul className="mt-0.5 space-y-0.5">
                  {acta!.incidencias!.slice(0, 3).map((i, idx) => (
                    <li key={`${i.regla}-${idx}`} className="truncate text-[11px] text-slate-600">
                      <span className="font-mono font-black text-amber-700">[{i.regla}]</span>{" "}
                      {i.mensaje}
                      {i.fecha && (
                        <span className="ml-1 font-mono text-[10px] text-slate-400">
                          {new Date(i.fecha).toLocaleString("es-PE", { dateStyle: "short", timeStyle: "short" })}
                        </span>
                      )}
                    </li>
                  ))}
                </ul>
              </div>
            )}
          </section>

          {/* Checklist ONPE */}
          {checklist && checklist.items.length > 0 && (
            <section className="rounded-xl border border-slate-200 p-3">
              <h3 className="mb-2 text-[11px] font-black uppercase tracking-wider text-slate-500">
                Validación previa (ONPE)
              </h3>
              <ul className="space-y-1.5">
                {checklist.items.map((it) => (
                  <li key={it.clave} className="flex items-start gap-2 text-xs">
                    <span className={it.ok ? "text-emerald-600" : "text-amber-600"}>
                      {it.ok ? "✔" : "✗"}
                    </span>
                    <span className="min-w-0">
                      <span className="font-bold text-slate-700">{it.etiqueta}: </span>
                      <span className="text-slate-500">{it.detalle}</span>
                    </span>
                  </li>
                ))}
              </ul>
              {checklist.actas_existentes.length > 0 && (
                <p className="mt-2 text-[11px] text-slate-500">
                  Actas ya registradas: {checklist.actas_existentes.join(", ")}
                </p>
              )}
            </section>
          )}
        </div>

        {/* Acciones */}
        <div className="flex flex-wrap justify-end gap-2 border-t border-slate-100 bg-slate-50 px-5 py-3">
          {!tieneActa && onCargar && (
            <Boton variante="primario" onClick={() => { onCargar(mesa); onClose(); }}>
              ⬆ Cargar esta acta
            </Boton>
          )}
          {tieneActa && acta && onEditar && (
            <Boton variante="exito" onClick={() => onEditar(acta)}>
              ✏️ Editar votos
            </Boton>
          )}
          <Boton variante="suave" onClick={onClose}>Cerrar</Boton>
        </div>
      </div>

      {/* Visor de la foto a pantalla completa */}
      {fotoGrande && acta?.image_url && (
        <button
          aria-label="Cerrar imagen"
          onClick={() => setFotoGrande(false)}
          className="fixed inset-0 z-[60] flex items-center justify-center bg-black/90 p-4"
        >
          <img
            src={acta.image_url}
            alt={`Acta de la mesa ${mesa} ampliada`}
            className="max-h-full max-w-full object-contain"
          />
        </button>
      )}
    </div>
  );
}
