import { useCallback, useEffect, useState } from "react";
import { sesionGuardada } from "./api";

/* ==================================================================== *
 *  Dashboard — Cómputo electoral en tiempo real (réplica ONPE)
 *
 *  Tarjetas de KPIs (actas procesadas, observadas, % avance, % participación)
 *  y resultados por organización política con barras de progreso.
 *  Fuente: GET /api/v1/resultados/resumen?tipo_eleccion=...&top=...
 * ==================================================================== */

interface Partido {
  organizacion: string;
  candidato: string;
  color: string;
  votos: number;
  porcentaje: number;
}

interface DistritoAvance {
  ubigeo: string;
  distrito: string;
  mesas: number;
  actas: number;
  observadas: number;
  avance_pct: number;
}

interface ActaObservada {
  numero_mesa: string;
  local: string;
  ubigeo: string;
  distrito: string;
}

interface Resumen {
  total_mesas: number;
  total_actas: number;
  actas_normales: number;
  actas_observadas: number;
  avance_pct: number;
  participacion_pct: number;
  tipo_eleccion: string;
  electores_habiles: number;
  votos_validos: number;
  votos_blancos: number;
  votos_nulos: number;
  votos_impugnados: number;
  votos_emitidos: number;
  partidos: Partido[];
  distritos: DistritoAvance[];
  observadas: ActaObservada[];
}

const NIVELES = ["DISTRITAL", "PROVINCIAL", "REGIONAL"] as const;

function authHeaders(): Record<string, string> {
  const s = sesionGuardada();
  return s ? { Authorization: `Bearer ${s.token}` } : {};
}

function Kpi({ etiqueta, valor, sub }: { etiqueta: string; valor: string; sub?: string }) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-xs">
      <p className="text-[11px] font-black uppercase tracking-wider text-slate-500">{etiqueta}</p>
      <p className="mt-1 font-mono text-2xl font-black text-[#002B66]">{valor}</p>
      {sub && <p className="mt-0.5 text-[11px] text-slate-400">{sub}</p>}
    </div>
  );
}

export default function Dashboard() {
  const [nivel, setNivel] = useState<string>("DISTRITAL");
  const [resumen, setResumen] = useState<Resumen | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [cargando, setCargando] = useState(true);

  const cargar = useCallback(async (n: string) => {
    setCargando(true);
    setError(null);
    try {
      const res = await fetch(
        `/api/v1/resultados/resumen?tipo_eleccion=${n}&top=10`,
        { headers: authHeaders() }
      );
      if (!res.ok) throw new Error(`Error ${res.status}`);
      setResumen((await res.json()) as Resumen);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setResumen(null);
    } finally {
      setCargando(false);
    }
  }, []);

  useEffect(() => {
    void cargar(nivel);
  }, [cargar, nivel]);

  /* Agregado por agrupación: la misma organización compite en decenas de
     distritos; se suma y se conserva el candidato sólo si es único. */
  const partidos = (() => {
    const mapa = new Map<string, Partido>();
    for (const p of resumen?.partidos ?? []) {
      const actual = mapa.get(p.organizacion);
      if (!actual) {
        mapa.set(p.organizacion, { ...p });
      } else {
        actual.votos += p.votos;
        if (actual.candidato !== p.candidato) actual.candidato = "";
      }
    }
    return [...mapa.values()].sort((a, b) => b.votos - a.votos);
  })();

  const max = Math.max(1, ...partidos.map((p) => p.votos));
  const totalAgregado = partidos.reduce((s, p) => s + p.votos, 0) || 1;

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h3 className="text-sm font-black uppercase tracking-wider text-[#002B66]">
          Cómputo en tiempo real
        </h3>
        <div className="flex gap-2">
          {NIVELES.map((n) => (
            <button
              key={n}
              onClick={() => setNivel(n)}
              className={`rounded-lg px-3 py-1.5 text-xs font-black uppercase tracking-wider ${
                nivel === n ? "bg-[#002B66] text-white" : "border bg-white text-slate-500"
              }`}
            >
              {n}
            </button>
          ))}
        </div>
      </div>

      {error && (
        <p className="rounded bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">{error}</p>
      )}
      {cargando && <p className="py-6 text-center text-sm text-slate-500">Cargando cómputo…</p>}

      {resumen && (
        <>
          {/* KPIs */}
          <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
            <Kpi etiqueta="Mesas" valor={String(resumen.total_mesas)}
              sub="en padrón" />
            <Kpi etiqueta="Contabilizadas" valor={String(resumen.actas_normales)}
              sub={`${resumen.total_actas} registradas`} />
            <Kpi etiqueta="Observadas" valor={String(resumen.actas_observadas)}
              sub="para revisión" />
            <Kpi etiqueta="% Avance" valor={`${resumen.avance_pct}%`}
              sub="actas sobre mesas" />
            <Kpi etiqueta="% Participación" valor={`${resumen.participacion_pct}%`}
              sub={`${resumen.electores_habiles.toLocaleString("es-PE")} hábiles`} />
          </div>

          {/* Estado de actas */}
          <section className="rounded-2xl border border-slate-200 bg-white p-5">
            <h4 className="mb-3 text-xs font-black uppercase tracking-wider text-slate-500">
              Estado de las actas
            </h4>
            <div className="flex h-4 w-full overflow-hidden rounded-full bg-slate-100">
              <div className="h-full bg-emerald-500" style={{
                width: `${resumen.total_mesas ? (100 * resumen.actas_normales) / resumen.total_mesas : 0}%` }} />
              <div className="h-full bg-amber-500" style={{
                width: `${resumen.total_mesas ? (100 * resumen.actas_observadas) / resumen.total_mesas : 0}%` }} />
            </div>
            <div className="mt-2 flex flex-wrap gap-x-5 gap-y-1 text-xs font-bold text-slate-600">
              <span><span className="mr-1 inline-block h-2.5 w-2.5 rounded-full bg-emerald-500" />
                {resumen.actas_normales} contabilizadas</span>
              <span><span className="mr-1 inline-block h-2.5 w-2.5 rounded-full bg-amber-500" />
                {resumen.actas_observadas} observadas</span>
              <span><span className="mr-1 inline-block h-2.5 w-2.5 rounded-full bg-slate-300" />
                {Math.max(0, resumen.total_mesas - resumen.total_actas)} pendientes</span>
            </div>
          </section>

          {/* Desglose de votos */}
          <section className="rounded-2xl border border-slate-200 bg-white p-5">
            <h4 className="mb-3 text-xs font-black uppercase tracking-wider text-slate-500">
              Desglose de votos emitidos ({resumen.votos_emitidos.toLocaleString("es-PE")})
            </h4>
            <div className="grid grid-cols-2 gap-2.5 md:grid-cols-4">
              {([
                ["Válidos", resumen.votos_validos, "#002B66"],
                ["Blancos", resumen.votos_blancos, "#94a3b8"],
                ["Nulos", resumen.votos_nulos, "#d97706"],
                ["Impugnados", resumen.votos_impugnados, "#dc2626"],
              ] as const).map(([et, v, color]) => (
                <div key={et} className="rounded-xl bg-slate-50 p-3 text-center">
                  <p className="text-[10px] font-black uppercase tracking-wider text-slate-500">{et}</p>
                  <p className="font-mono text-xl font-black" style={{ color }}>
                    {v.toLocaleString("es-PE")}
                  </p>
                  <p className="font-mono text-[11px] text-slate-400">
                    {resumen.votos_emitidos > 0
                      ? `${((100 * v) / resumen.votos_emitidos).toFixed(1)}%` : "—"}
                  </p>
                </div>
              ))}
            </div>
          </section>

          <section className="rounded-2xl border border-slate-200 bg-white p-5">
            <h4 className="mb-3 text-xs font-black uppercase tracking-wider text-slate-500">
              Resultados por organización política · {resumen.tipo_eleccion}
            </h4>
            {resumen.partidos.length === 0 && (
              <p className="py-4 text-center text-sm text-slate-400">
                Sin actas contabilizadas en este nivel.
              </p>
            )}
            <div className="space-y-2.5">
              {partidos.map((p) => (
                <div key={p.organizacion}>
                  <div className="mb-1 flex items-baseline justify-between gap-2">
                    <span className="min-w-0">
                      <span className="block truncate text-sm font-bold text-slate-800">
                        {p.organizacion}
                      </span>
                      {p.candidato && (
                        <span className="block truncate text-[11px] font-semibold text-slate-500">
                          {p.candidato}
                        </span>
                      )}
                    </span>
                    <span className="shrink-0 font-mono text-xs text-slate-500">
                      {p.votos.toLocaleString("es-PE")} ·{" "}
                      {((100 * p.votos) / totalAgregado).toFixed(1)}%
                    </span>
                  </div>
                  <div className="h-3 overflow-hidden rounded-full bg-slate-100">
                    <div
                      className="h-full rounded-full transition-all"
                      style={{
                        width: `${(p.votos / max) * 100}%`,
                        backgroundColor: p.color,
                      }}
                    />
                  </div>
                </div>
              ))}
            </div>
          </section>

          {/* Avance por distrito */}
          <section className="rounded-2xl border border-slate-200 bg-white p-5">
            <h4 className="mb-3 text-xs font-black uppercase tracking-wider text-slate-500">
              Avance por distrito ({resumen.distritos.length})
            </h4>
            {resumen.distritos.length === 0 ? (
              <p className="py-4 text-center text-sm text-slate-400">Sin distritos en el alcance.</p>
            ) : (
              <div className="max-h-80 space-y-2 overflow-y-auto pr-1">
                {resumen.distritos.map((d) => (
                  <div key={d.ubigeo} className="flex items-center gap-3">
                    <div className="w-40 shrink-0">
                      <p className="truncate text-xs font-bold text-slate-700">{d.distrito}</p>
                      <p className="font-mono text-[10px] text-slate-400">
                        {d.ubigeo} · {d.actas}/{d.mesas}{d.observadas > 0 ? ` · ${d.observadas} obs` : ""}
                      </p>
                    </div>
                    <div className="h-2.5 flex-1 overflow-hidden rounded-full bg-slate-100">
                      <div
                        className={`h-full rounded-full ${d.avance_pct >= 80 ? "bg-emerald-500" : d.avance_pct >= 40 ? "bg-amber-500" : "bg-red-500"}`}
                        style={{ width: `${Math.min(100, d.avance_pct)}%` }}
                      />
                    </div>
                    <span className="w-12 shrink-0 text-right font-mono text-xs font-bold text-slate-600">
                      {d.avance_pct}%
                    </span>
                  </div>
                ))}
              </div>
            )}
          </section>

          {/* Observadas */}
          <section className="rounded-2xl border border-slate-200 bg-white p-5">
            <h4 className="mb-3 text-xs font-black uppercase tracking-wider text-slate-500">
              Actas observadas ({resumen.observadas.length})
            </h4>
            {resumen.observadas.length === 0 ? (
              <p className="py-4 text-center text-sm font-semibold text-emerald-700">
                ✓ Sin observadas en este corte.
              </p>
            ) : (
              <div className="max-h-64 overflow-y-auto">
                <table className="w-full text-xs">
                  <thead>
                    <tr className="text-left uppercase tracking-wider text-slate-400">
                      <th className="py-1.5 pr-2">Mesa</th>
                      <th className="py-1.5 pr-2">Local</th>
                      <th className="py-1.5 pr-2">Distrito</th>
                    </tr>
                  </thead>
                  <tbody>
                    {resumen.observadas.map((o) => (
                      <tr key={o.numero_mesa} className="border-t border-slate-100">
                        <td className="py-1.5 pr-2 font-mono font-bold text-slate-800">{o.numero_mesa}</td>
                        <td className="py-1.5 pr-2">{o.local}</td>
                        <td className="py-1.5 pr-2 text-slate-500">{o.distrito || o.ubigeo}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
        </>
      )}
    </div>
  );
}
