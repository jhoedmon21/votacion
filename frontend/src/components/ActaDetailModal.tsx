import { useEffect, useState } from "react";
import { api } from "../api";
import type { ActaRecord, RankingEntry } from "../types";
import { Alerta, Boton } from "./ui";

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

const NIVELES: Array<{ clave: "distrital" | "provincial" | "regional"; titulo: string }> = [
  { clave: "distrital", titulo: "Distrital (alcalde)" },
  { clave: "provincial", titulo: "Provincial (alcalde provincial)" },
  { clave: "regional", titulo: "Regional (gobernador y vice)" },
];

const suma = (filas: RankingEntry[] | undefined) =>
  (filas ?? []).reduce((s, c) => s + (c.votes ?? 0), 0);

const num = (v: number | null | undefined) => (v ?? 0).toLocaleString("es-PE");

export default function ActaDetailModal({
  acta, numeroMesa, onClose, onEditar, onCargar,
}: Props) {
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
    regional: acta?.votos_regional ?? [],
  };
  const votosValidos = suma(votos.distrital);
  const emitidos = votosValidos + (acta?.votos_blancos ?? 0) + (acta?.votos_nulos ?? 0)
    + (acta?.votos_impugnados ?? 0);
  const hayVotos = emitidos > 0;
  const participacion = electores && electores > 0 ? (100 * emitidos) / electores : 0;

  const ESTILO: Record<string, string> = {
    REGISTRADA: "bg-emerald-100 text-emerald-800",
    PENDIENTE: "bg-slate-200 text-slate-700",
    OBSERVADA: "bg-amber-100 text-amber-800",
  };

  const bloqueVotos = (titulo: string, filas: RankingEntry[]) => {
    const total = suma(filas);
    return (
      <div className="rounded-xl border border-slate-200">
        <div className="flex items-center justify-between border-b border-slate-100 bg-slate-50 px-3 py-2">
          <span className="text-[11px] font-black uppercase tracking-wider text-slate-500">
            {titulo}
          </span>
          <span className="font-mono text-[11px] font-bold text-[#002B66]">
            {num(total)} votos
          </span>
        </div>
        {filas.length === 0 ? (
          <p className="px-3 py-3 text-xs text-slate-400">
            Sin votos cargados en este nivel.
          </p>
        ) : (
          <div className="divide-y divide-slate-100">
            {filas
              .slice()
              .sort((a, b) => b.votes - a.votes)
              .map((c) => {
                const pct = total > 0 ? (100 * c.votes) / total : 0;
                return (
                  <div key={`${titulo}-${c.candidate_id}`} className="flex items-center gap-3 px-3 py-2">
                    <span
                      className="w-6 shrink-0 text-center font-mono text-[11px] font-black text-slate-400"
                      title={`Casita ${c.candidate_id}: la fila de esta organización en la columna del acta`}
                    >
                      {c.candidate_id}
                    </span>
                    <span
                      className="h-8 w-8 shrink-0 rounded-lg border border-slate-200 bg-white object-contain p-0.5 text-center text-[10px] font-black leading-[26px] text-white"
                      style={{ backgroundColor: c.color || "#64748b" }}
                      title={c.party}
                    >
                      {(c.party || "?").charAt(0)}
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-xs font-bold text-slate-800">
                        {c.party || c.name}
                      </span>
                      <span className="block truncate text-[11px] text-slate-500">{c.name}</span>
                      <span className="mt-1 block h-1.5 w-full overflow-hidden rounded-full bg-slate-100">
                        <span
                          className="block h-full rounded-full"
                          style={{ width: `${pct}%`, backgroundColor: c.color || "#002B66" }}
                        />
                      </span>
                    </span>
                    <span className="shrink-0 text-right font-mono text-xs font-bold tabular-nums text-slate-700">
                      {num(c.votes)}
                      <span className="block text-[10px] font-normal text-slate-400">
                        {pct.toFixed(1)}%
                      </span>
                    </span>
                  </div>
                );
              })}
          </div>
        )}
      </div>
    );
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
            <h2 className="font-mono text-xl font-black tabular-nums text-[#002B66]">
              {mesa}
            </h2>
          </div>
          <span className={`rounded-full px-3 py-1 text-[11px] font-black ${ESTILO[estado] ?? ESTILO.PENDIENTE}`}>
            {estado === "REGISTRADA" ? "Registrada" : estado === "OBSERVADA" ? "Observada" : "Pendiente"}
          </span>
          <button
            onClick={onClose}
            aria-label="Cerrar"
            className="rounded-lg px-2.5 py-1.5 text-slate-500 hover:bg-slate-200"
          >
            ✕
          </button>
        </div>

        <div className="max-h-[75vh] space-y-4 overflow-y-auto p-5">
          {aviso && <Alerta tono="aviso">No se pudo cargar la ficha del padrón: {aviso}</Alerta>}

          {/* Evidencia fotográfica */}
          <section className="rounded-xl border border-slate-200 p-3">
            <h3 className="mb-2 text-[11px] font-black uppercase tracking-wider text-slate-500">
              Evidencia del acta física
            </h3>
            {tieneActa && acta?.image_url ? (
              <div className="text-center">
                <img
                  src={acta.image_url}
                  alt={`Acta de la mesa ${mesa}`}
                  onClick={() => setFotoGrande(true)}
                  className="mx-auto max-h-72 cursor-zoom-in rounded-lg border border-slate-200 object-contain"
                />
                <div className="mt-2 flex justify-center gap-2">
                  <Boton variante="suave" onClick={() => setFotoGrande(true)}>
                    🔍 Ampliar
                  </Boton>
                  <a
                    href={acta.image_url}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex min-h-[44px] items-center rounded-xl bg-slate-100 px-5 py-2.5 text-sm font-bold text-slate-700 hover:bg-slate-200"
                  >
                    ↗ Abrir original
                  </a>
                </div>
              </div>
            ) : (
              <p className="rounded-lg border border-dashed border-slate-300 bg-slate-50 px-3 py-6 text-center text-xs text-slate-500">
                {tieneActa
                  ? "El acta está registrada pero sin foto adjunta."
                  : "Sin foto: la mesa aún no tiene acta cargada."}
              </p>
            )}
          </section>

          {/* Ubicación y padrón */}
          <section className="grid gap-3 sm:grid-cols-2">
            <div className="rounded-xl border border-slate-200 p-3">
              <h3 className="mb-2 text-[11px] font-black uppercase tracking-wider text-slate-500">
                Ubicación
              </h3>
              <dl className="space-y-1 text-xs">
                <div className="flex gap-2">
                  <dt className="w-24 shrink-0 text-slate-400">Local</dt>
                  <dd className="font-bold text-slate-800">{local || "—"}</dd>
                </div>
                <div className="flex gap-2">
                  <dt className="w-24 shrink-0 text-slate-400">Distrito</dt>
                  <dd className="font-bold text-slate-800">{distrito || "—"}</dd>
                </div>
                <div className="flex gap-2">
                  <dt className="w-24 shrink-0 text-slate-400">Provincia</dt>
                  <dd className="font-bold text-slate-800">{provincia || "—"}</dd>
                </div>
                <div className="flex gap-2">
                  <dt className="w-24 shrink-0 text-slate-400">Ubigeo</dt>
                  <dd className="font-mono font-bold text-slate-800">{ubigeo || "—"}</dd>
                </div>
                {acta?.latitude != null && acta?.longitude != null && (
                  <div className="flex gap-2">
                    <dt className="w-24 shrink-0 text-slate-400">Coordenadas</dt>
                    <dd className="font-mono text-slate-600">
                      {acta.latitude.toFixed(5)}, {acta.longitude.toFixed(5)}
                    </dd>
                  </div>
                )}
              </dl>
            </div>

            <div className="rounded-xl border border-slate-200 p-3">
              <h3 className="mb-2 text-[11px] font-black uppercase tracking-wider text-slate-500">
                Padrón (tope R2)
              </h3>
              <dl className="space-y-1 text-xs">
                <div className="flex gap-2">
                  <dt className="w-28 shrink-0 text-slate-400">Electores hábiles</dt>
                  <dd className="font-mono font-bold text-slate-800">
                    {electores ? num(electores) : "sin padrón"}
                  </dd>
                </div>
                <div className="flex gap-2">
                  <dt className="w-28 shrink-0 text-slate-400">Votos emitidos</dt>
                  <dd className="font-mono font-bold text-slate-800">{num(emitidos)}</dd>
                </div>
                <div className="flex gap-2">
                  <dt className="w-28 shrink-0 text-slate-400">Participación</dt>
                  <dd className="font-mono font-bold text-slate-800">
                    {electores ? `${participacion.toFixed(1)}%` : "—"}
                  </dd>
                </div>
              </dl>
            </div>
          </section>

          {/* Votos */}
          {hayVotos ? (
            <section className="space-y-3">
              <h3 className="flex flex-wrap items-baseline gap-2 text-[11px] font-black uppercase tracking-wider text-slate-500">
                Votos registrados
                <span className="text-[10px] font-bold normal-case tracking-normal text-slate-400">
                  el número es la casita (fila de la columna del acta); se listan de mayor a menor votación
                </span>
              </h3>
              {NIVELES.map((n) => (
                <div key={n.clave}>{bloqueVotos(n.titulo, votos[n.clave])}</div>
              ))}
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                {([
                  ["Blancos", acta?.votos_blancos ?? 0],
                  ["Nulos", acta?.votos_nulos ?? 0],
                  ["Impugnados", acta?.votos_impugnados ?? 0],
                  ["Válidos (distrital)", votosValidos],
                ] as const).map(([et, v]) => (
                  <div key={et} className="rounded-xl bg-slate-50 p-3 text-center">
                    <p className="text-[10px] font-black uppercase tracking-wider text-slate-500">{et}</p>
                    <p className="font-mono text-lg font-black text-slate-800">{num(v)}</p>
                  </div>
                ))}
              </div>
            </section>
          ) : (
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
