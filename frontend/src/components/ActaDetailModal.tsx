import { useEffect, useState } from "react";
import { api } from "../api";
import type { ActaRecord, RankingEntry } from "../types";
import { Alerta, Boton } from "./ui";
import { useCuadreColumnas } from "../lib/validacionCuadre";
import { AlertaCuadre, BadgeCuadre } from "./CuadreUI";

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

/* Entrada del historial de auditoría (GET /actas/{id}/auditoria). */
interface AuditoriaItem {
  id: number;
  accion: string;
  usuario: string;
  rol: string;
  ip: string | null;
  motivo: string | null;
  fecha: string | null;
  antes: Record<string, unknown>;
  despues: Record<string, unknown>;
}
type Auditoria = { acta_id: number; numero_mesa: string; total: number; items: AuditoriaItem[] };

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

/* Etiquetas legibles de las claves de la huella de auditoría. */
const ETIQUETA_AUDIT: Record<string, string> = {
  status: "Estado", processed: "Contabilizada", requires_review: "Observada",
  votos_blancos: "Blancos", votos_nulos: "Nulos", votos_impugnados: "Impugnados",
  total_electores: "Electores hábiles", total_votantes: "Votantes (cabecera)",
  numero_mesa: "N° de mesa", image_url: "Foto del acta", ocr_confidence: "Confianza OCR",
};
const NIVEL_AUDIT: Record<string, string> = {
  district: "Distrital", provincial: "Provincial",
  consejero: "Consejeros", regional: "Regional",
};

/* Diferencias legibles entre la huella "antes" y "después" de una edición:
   cabecera (status, votantes, pie…) y votos por candidato y nivel. */
function diferenciasAuditoria(
  antes: Record<string, unknown>,
  despues: Record<string, unknown>,
): string[] {
  const out: string[] = [];
  const esNum = (v: unknown) => typeof v === "number" || typeof v === "boolean";
  for (const [k, d] of Object.entries(despues)) {
    if (k === "votos" || k === "payload" || k === "numero_mesa") continue;
    const a = antes[k];
    if (a === d || (esNum(a) && esNum(d) && Number(a) === Number(d))) continue;
    const et = ETIQUETA_AUDIT[k] ?? k;
    const fmt = (v: unknown) =>
      typeof v === "boolean" ? (v ? "sí" : "no")
      : k === "status" ? String(v ?? "—")
      : esNum(v) ? num(Number(v)) : String(v ?? "—");
    out.push(`${et}: ${fmt(a)} → ${fmt(d)}`);
  }
  const votosA = (antes.votos ?? {}) as Record<string, Record<string, number>>;
  const votosD = (despues.votos ?? {}) as Record<string, Record<string, number>>;
  for (const nivel of new Set([...Object.keys(votosA), ...Object.keys(votosD)])) {
    const fa = votosA[nivel] ?? {};
    const fd = votosD[nivel] ?? {};
    for (const cid of new Set([...Object.keys(fa), ...Object.keys(fd)])) {
      const a = fa[cid] ?? 0;
      const d = fd[cid] ?? 0;
      if (Number(a) !== Number(d)) {
        out.push(`${NIVEL_AUDIT[nivel] ?? nivel} · casilla ${cid}: ${num(a)} → ${num(d)}`);
      }
    }
  }
  return out;
}

export default function ActaDetailModal({
  acta: actaBase, numeroMesa, onClose, onEditar, onCargar,
}: Props) {
  const acta = actaBase as ActaConAuditoria | null;
  const mesa = acta?.numero_mesa ?? numeroMesa ?? "";
  const [checklist, setChecklist] = useState<Checklist | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [fotoGrande, setFotoGrande] = useState(false);
  /* Historial de auditoría: se carga sólo para actas registradas. */
  const [auditoria, setAuditoria] = useState<Auditoria | null>(null);
  const [auditError, setAuditError] = useState<string | null>(null);
  /* Ítem del historial expandido (para ver el diff antes/después). */
  const [auditAbierta, setAuditAbierta] = useState<number | null>(null);

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

  useEffect(() => {
    setAuditoria(null);
    setAuditError(null);
    if (!acta?.id) return;
    let vigente = true;    api.auditoriaActa(acta.id)
      .then((a) => { if (vigente) setAuditoria(a); })
      .catch((e) => {
        // El historial es complementario: su fallo no rompe la ficha.
        if (vigente) setAuditError(String(e instanceof Error ? e.message : e));
      });
    return () => { vigente = false; };
  }, [acta?.id]);

  /* ==================== MOTOR DE CUADRE (R1 por columna) ====================
     Vive ANTES del early return: los hooks no pueden llamarse
     condicionalmente. Con acta null las columnas llegan vacías y el motor
     sólo devuelve resultados INACTIVA (sin efecto en la ficha). */
  const aAny = (acta ?? {}) as unknown as Record<string, number | null | undefined>;
  /* Pie POR COLUMNA resuelto en sus tres componentes (blancos, nulos,
     impugnados), con el mismo respaldo del resumen tabular: si el nivel no
     trae pie propio digitado, una columna con votos usa el consolidado
     histórico; sin votos, el pie es cero (columna inactiva). */
  const pieDeNivel = (nivel: string, validos: number): { b: number; n: number; i: number } => {
    const b = aAny[`blancos_${nivel}`];
    const nu = aAny[`nulos_${nivel}`];
    const im = aAny[`impugnados_${nivel}`];
    const piePropio = (b ?? 0) + (nu ?? 0) + (im ?? 0);
    if ((b != null || nu != null || im != null) && piePropio > 0) {
      return { b: b ?? 0, n: nu ?? 0, i: im ?? 0 };
    }
    return validos > 0
      ? { b: acta?.votos_blancos ?? 0, n: acta?.votos_nulos ?? 0, i: acta?.votos_impugnados ?? 0 }
      : { b: 0, n: 0, i: 0 };
  };
  const votantesCabecera = aAny.total_votantes ?? null;
  /* Resultados por nivel: badge (⚠️ 150 ≠ 250 / ✓ cuadra 250), alerta con
     desglose dinámico (Diferencia = Total_Votaron − Total_Leídas) y
     diagnóstico de origen (lista de partidos vs pie B/N/I). */
  const cuadres = useCuadreColumnas(
    NIVELES.map((n) => {
      const filas =
        (acta as unknown as Record<string, RankingEntry[]> | null)?.[`votos_${n.clave}`] ?? [];
      const validos = suma(filas);
      const p = pieDeNivel(n.clave, validos);
      return {
        clave: n.clave, nombre: n.tituloCorto,
        validos, blancos: p.b, nulos: p.n, impugnados: p.i,
      };
    }),
    votantesCabecera,
  );

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
  const columnas = NIVELES.map((n) => {
    const r = cuadres[n.clave];
    return {
      clave: n.clave, titulo: n.tituloCorto,
      total: r.totalLeidas,
      activa: r.estado !== "INACTIVA",
    };
  });
  const emitidos = Math.max(0, ...columnas.filter((c) => c.activa).map((c) => c.total));
  const hayVotos = emitidos > 0;
  const participacion = electores && electores > 0 ? (100 * emitidos) / electores : 0;

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
                /* Resultado del motor de cuadre de esta columna: estado,
                   badge, alerta con desglose y origen de la brecha. */
                const r = cuadres[n.clave];
                const validosNivel = r.validos;
                const activa = r.estado !== "INACTIVA";
                const maxVotos = Math.max(1, ...votos[n.clave].map((c) => c.votes));
                return (
                  <div key={n.clave}
                    className={`rounded-xl border-2 bg-white ${
                      !activa ? "border-slate-200 opacity-60" : r.bordeClase}`}>
                    <div className={`flex items-center justify-between gap-2 rounded-t-lg px-3 py-1.5 ${
                      activa ? r.cabeceraClase : "bg-slate-50"}`}>
                      <span className="text-[11px] font-black uppercase tracking-wider text-slate-600">
                        {n.tituloCorto}
                      </span>
                      <BadgeCuadre r={r} />
                    </div>
                    {!activa ? (
                      <p className="px-3 py-4 text-center text-xs text-slate-400">Sin votos en este nivel.</p>
                    ) : (
                      <>
                        {/* Alerta de cuadre: "Faltan registrar N votos en esta
                            categoría para cuadrar con el padrón (250)" con el
                            desglose exacto y el origen resaltado (lista de
                            partidos vs blancos/nulos/impugnados). */}
                        <div className="px-3">
                          <AlertaCuadre r={r} />
                        </div>
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
                        {/* Desglose técnico por columna (B/N/I en gris neutro).
                            Usa los mismos valores saneados del motor para que
                            las partes SIEMPRE sumen la casilla "Leídas". */}
                        <div className="grid grid-cols-5 gap-px border-t border-slate-100 bg-slate-100 text-center">
                          {([
                            ["Válidos", r.validos, "bg-white text-slate-800"],
                            ["Blancos", r.blancos, "bg-slate-50 text-slate-500"],
                            ["Nulos", r.nulos, "bg-slate-50 text-slate-500"],
                            ["Impugn.", r.impugnados, "bg-slate-50 text-slate-500"],
                            ["Leídas", r.totalLeidas, "bg-slate-800 text-white"],
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

          {/* ============ D. HISTORIAL DE EDICIONES (auditoría) ============ */}
          {tieneActa && (
            <section className="rounded-xl border border-slate-200 p-3">
              <div className="flex items-center justify-between">
                <h3 className="text-[11px] font-black uppercase tracking-wider text-slate-500">
                  🕘 Historial de ediciones
                </h3>
                {auditoria && auditoria.total > 0 && (
                  <span className="rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-black text-slate-500">
                    {auditoria.total} {auditoria.total === 1 ? "edición" : "ediciones"}
                  </span>
                )}
              </div>
              {auditError && (
                <p className="mt-1 text-[11px] text-slate-400">Historial no disponible: {auditError}</p>
              )}
              {auditoria && auditoria.items.length === 0 && (
                <p className="mt-1 text-[11px] text-slate-400">
                  Sin ediciones registradas: el acta se guardó una sola vez y no ha sido rectificada.
                </p>
              )}
              {auditoria && auditoria.items.length > 0 && (
                <ul className="mt-2 space-y-1.5">
                  {auditoria.items.map((it) => {
                    const abierta = auditAbierta === it.id;
                    const difs = diferenciasAuditoria(it.antes, it.despues);
                    return (
                      <li key={it.id} className="rounded-lg border border-slate-100 bg-slate-50/60">
                        <button
                          type="button"
                          onClick={() => setAuditAbierta(abierta ? null : it.id)}
                          aria-expanded={abierta}
                          className="flex w-full flex-wrap items-center gap-x-3 gap-y-0.5 px-2.5 py-1.5 text-left"
                        >
                          <span className={`rounded-full px-2 py-0.5 text-[10px] font-black ${
                            it.accion === "CREAR" ? "bg-emerald-100 text-emerald-700"
                            : "bg-indigo-100 text-indigo-700"}`}>
                            {it.accion === "CREAR" ? "Registro" : "Edición"}
                          </span>
                          <span className="min-w-0 flex-1 truncate text-[11px] font-bold text-slate-700">
                            {it.usuario}
                            <span className="ml-1 font-normal text-slate-400">({it.rol})</span>
                          </span>
                          {it.fecha && (
                            <span className="font-mono text-[10px] text-slate-400">
                              {new Date(it.fecha).toLocaleString("es-PE", { dateStyle: "short", timeStyle: "short" })}
                            </span>
                          )}
                          <span className="text-[10px] text-slate-400">{abierta ? "▲" : "▼"}</span>
                        </button>
                        <div className="border-t border-slate-100 px-2.5 py-1.5">
                          {it.motivo && (
                            <p className="text-[11px] text-slate-600">
                              <span className="font-black uppercase tracking-wide text-slate-400">Motivo: </span>
                              {it.motivo}
                            </p>
                          )}
                          {!it.motivo && it.accion === "MODIFICAR" && (
                            <p className="text-[11px] italic text-slate-400">Sin motivo registrado (edición anterior a la trazabilidad).</p>
                          )}
                          {abierta && (
                            <div className="mt-1.5">
                              {difs.length === 0 ? (
                                <p className="text-[11px] text-slate-400">Sin cambios de valores respecto a la edición anterior.</p>
                              ) : (
                                <ul className="space-y-0.5 font-mono text-[11px]">
                                  {difs.map((d, idx) => (
                                    <li key={idx} className="text-slate-700">
                                      <span className="text-slate-400">·</span> {d}
                                    </li>
                                  ))}
                                </ul>
                              )}
                              {it.ip && (
                                <p className="mt-1 font-mono text-[10px] text-slate-300">ip {it.ip}</p>
                              )}
                            </div>
                          )}
                        </div>
                      </li>
                    );
                  })}
                </ul>
              )}
            </section>
          )}

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
