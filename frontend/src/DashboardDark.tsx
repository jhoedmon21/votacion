/* ==========================================================================
 * Dashboard Electoral Oscuro — Arequipa (estilo sala de cómputo FA)
 *
 * Layout pedido:
 *   Header superior  → % procesado global + fuente del sistema + métricas.
 *   Top Cards        → Top 2 de candidatos líderes del ámbito seleccionado.
 *   Panel izq (40%)  → lista ordenada (foto, nombre, partido, %, votos)
 *                      con encabezado del distrito seleccionado.
 *   Panel der (60%)  → mapa vectorial GeoJSON INEI por distrito (UBIGEO),
 *                      coloreado por ganador, hover resalta bordes/opacity
 *                      y clic actualiza toda la vista.
 *
 * Datos reales: /api/analytics/summary + /api/analytics/choropleth
 * (padrón ONPE). Si la API no responde, usa DATOS_EJEMPLO indexados por
 * ubigeo para que la vista siga siendo navegable.
 * ========================================================================== */
import { useEffect, useMemo, useState } from "react";
import { GeoJSON, MapContainer, useMap } from "react-leaflet";
import L from "leaflet";
import type { Feature, GeoJsonObject, Geometry } from "geojson";
import { api } from "./api";
import type { ChoroplethDistrito, RankingEntry, Summary } from "./types";

const ROJO = "#E02020";      /* Fuerza Arequipeña — base */
const BORDE = "#3A1418";     /* slate-700 entre distritos */
const SIN_VOTOS = "#2A1216"; /* slate-800: distrito sin votos */

interface FeatureGeo {
  u: string;   /* ubigeo INEI */
  n: string;   /* nombre distrito */
  pv?: string; /* código provincia */
  pvn?: string;/* nombre provincia */
  geo: Geometry;
}
interface DatosGeo {
  region: FeatureGeo | null;
  provincias: FeatureGeo[];
  distritos: FeatureGeo[];
}

/* ------------------------------------------------------------------ *
 * Estructura de datos de ejemplo JSON indexada por UBIGEO (respaldo).
 * Misma forma que entrega /api/analytics/choropleth (una fila por
 * ubigeo INEI) + candidatos del distrito para la lista.
 * ------------------------------------------------------------------ */
const DATOS_EJEMPLO: Record<string, {
  mesas: number; procesadas: number; observadas: number;
  locales: number; avance: number;
  ganador: { name: string; color: string; votes: number } | null;
  candidatos: RankingEntry[];
}> = {
  "040101": {
    mesas: 241, procesadas: 96, observadas: 2, locales: 14, avance: 39.8,
    ganador: { name: "Luis Justo Mayta Livisi", color: "#3B82F6", votes: 12400 },
    candidatos: [
      { candidate_id: 1, name: "Luis Justo Mayta Livisi", party: "Acción Popular", color: "#3B82F6", votes: 12400 },
      { candidate_id: 2, name: "Rosa Delgado Vela", party: "Fuerza Arequipeña", color: "#E02020", votes: 9800 },
      { candidate_id: 3, name: "Julio César Apaza Choquepata", party: "Ahora Nación - AN", color: "#F59E0B", votes: 6100 },
      { candidate_id: 4, name: "María Elena Cárdenas", party: "Somos Perú", color: "#10B981", votes: 2400 },
    ],
  },
  "040103": {
    mesas: 274, procesadas: 130, observadas: 1, locales: 33, avance: 47.4,
    ganador: { name: "Rosa Delgado Vela", color: "#E02020", votes: 15100 },
    candidatos: [
      { candidate_id: 1, name: "Rosa Delgado Vela", party: "Fuerza Arequipeña", color: "#E02020", votes: 15100 },
      { candidate_id: 2, name: "Luis Justo Mayta Livisi", party: "Acción Popular", color: "#3B82F6", votes: 11200 },
      { candidate_id: 3, name: "Julio César Apaza Choquepata", party: "Ahora Nación - AN", color: "#F59E0B", votes: 4300 },
    ],
  },
  "040112": {
    mesas: 158, procesadas: 61, observadas: 0, locales: 21, avance: 38.6,
    ganador: { name: "Rosa Delgado Vela", color: "#E02020", votes: 8900 },
    candidatos: [
      { candidate_id: 1, name: "Rosa Delgado Vela", party: "Fuerza Arequipeña", color: "#E02020", votes: 8900 },
      { candidate_id: 2, name: "Luis Justo Mayta Livisi", party: "Acción Popular", color: "#3B82F6", votes: 7200 },
      { candidate_id: 3, name: "Pedro Pablo Martínez", party: "Perú Libre", color: "#8B5CF6", votes: 3100 },
      { candidate_id: 4, name: "Julio César Apaza Choquepata", party: "Ahora Nación - AN", color: "#F59E0B", votes: 1800 },
    ],
  },
  "040114": {
    mesas: 187, procesadas: 44, observadas: 3, locales: 18, avance: 23.5,
    ganador: { name: "Luis Justo Mayta Livisi", color: "#3B82F6", votes: 5600 },
    candidatos: [
      { candidate_id: 1, name: "Luis Justo Mayta Livisi", party: "Acción Popular", color: "#3B82F6", votes: 5600 },
      { candidate_id: 2, name: "Rosa Delgado Vela", party: "Fuerza Arequipeña", color: "#E02020", votes: 5100 },
      { candidate_id: 3, name: "María Elena Cárdenas", party: "Somos Perú", color: "#10B981", votes: 2200 },
    ],
  },
  "040121": {
    mesas: 44, procesadas: 12, observadas: 0, locales: 5, avance: 27.3,
    ganador: { name: "Julio César Apaza Choquepata", color: "#F59E0B", votes: 1400 },
    candidatos: [
      { candidate_id: 1, name: "Julio César Apaza Choquepata", party: "Ahora Nación - AN", color: "#F59E0B", votes: 1400 },
      { candidate_id: 2, name: "Rosa Delgado Vela", party: "Fuerza Arequipeña", color: "#E02020", votes: 1100 },
      { candidate_id: 3, name: "Luis Justo Mayta Livisi", party: "Acción Popular", color: "#3B82F6", votes: 900 },
    ],
  },
};

type ScopeEleccion = "district" | "provincial" | "regional";
const NIVELES: Array<{ id: ScopeEleccion; etiqueta: string; desc: string }> = [
  { id: "district", etiqueta: "Distrital", desc: "Alcaldías distritales" },
  { id: "provincial", etiqueta: "Provincial", desc: "Municipal provincial" },
  { id: "regional", etiqueta: "Regional", desc: "Gobierno regional" },
];

/* Encaja el mapa sobre la silueta seleccionada (o la región). */
function Enfoque({ objetivo, llave }: { objetivo: Geometry | null; llave: string }) {
  const map = useMap();
  useEffect(() => {
    if (!objetivo) return;
    const capa = L.geoJSON(
      { type: "Feature", geometry: objetivo, properties: {} } as unknown as GeoJsonObject
    );
    const b = capa.getBounds();
    if (b.isValid()) map.flyToBounds(b, { padding: [24, 24], duration: 0.7 });
  }, [llave, objetivo, map]);
  return null;
}

const fmt = (n: number) => n.toLocaleString("es-PE");

export default function DashboardDark() {
  const [geo, setGeo] = useState<DatosGeo | null>(null);
  const [stats, setStats] = useState<ChoroplethDistrito[] | null>(null);
  const [conEjemplo, setConEjemplo] = useState(false);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [scope, setScope] = useState<ScopeEleccion>("district");
  const [ubigeoSel, setUbigeoSel] = useState("");
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [horaAct] = useState(() =>
    new Date().toLocaleTimeString("es-PE", { hour: "2-digit", minute: "2-digit" })
  );

  /* Capas geográficas + estadísticas por distrito (ganador incluido). */
  useEffect(() => {
    Promise.all([
      fetch("/data/geo/arequipa_geo.json").then((r) => {
        if (!r.ok) throw new Error(`capas geográficas (${r.status})`);
        return r.json() as Promise<DatosGeo>;
      }),
      api.choropleth().catch(() => {
        setConEjemplo(true);
        return Object.entries(DATOS_EJEMPLO).map(([ubigeo, d]) => ({
          ubigeo,
          mesas: d.mesas, procesadas: d.procesadas, observadas: d.observadas,
          locales: d.locales, avance: d.avance, ganador: d.ganador,
        })) as ChoroplethDistrito[];
      }),
    ])
      .then(([g, s]) => {
        setGeo(g);
        setStats(s);
        setCargando(false);
      })
      .catch((e) => {
        setError(String(e?.message ?? e));
        setCargando(false);
      });
  }, []);

  /* Resumen del ámbito: distrito seleccionado o agregado regional. */
  useEffect(() => {
    api.summary(scope, ubigeoSel || undefined)
      .then((d) => setSummary(d))
      .catch(() => setSummary(null));
  }, [scope, ubigeoSel]);

  const statPor = useMemo(
    () => new Map((stats ?? []).map((s) => [s.ubigeo, s])),
    [stats]
  );

  const distritoSel = geo?.distritos.find((d) => d.u === ubigeoSel) ?? null;
  const provinciaSel = distritoSel?.pvn ?? null;
  const nombreAmbito = distritoSel ? distritoSel.n : "Toda la región Arequipa";

  /* Distritos agrupados por provincia para el selector. */
  const distritosPorProvincia = useMemo(() => {
    const mapa = new Map<string, FeatureGeo[]>();
    for (const d of geo?.distritos ?? []) {
      const k = d.pv ?? "—";
      const arr = mapa.get(k);
      if (arr) arr.push(d);
      else mapa.set(k, [d]);
    }
    return [...mapa.entries()].sort((a, b) =>
      (a[1][0]?.pvn ?? "").localeCompare(b[1][0]?.pvn ?? "")
    );
  }, [geo]);

  /* Lista de candidatos: real (summary) o respaldo de ejemplo agregado. */
  const ranking: RankingEntry[] = useMemo(() => {
    if (summary?.ranking?.length) {
      return [...summary.ranking].sort((a, b) => b.votes - a.votes);
    }
    if (ubigeoSel && DATOS_EJEMPLO[ubigeoSel]) {
      return [...DATOS_EJEMPLO[ubigeoSel].candidatos].sort((a, b) => b.votes - a.votes);
    }
    const todos = new Map<string, RankingEntry>();
    let seq = 0;
    for (const fila of Object.values(DATOS_EJEMPLO)) {
      for (const c of fila.candidatos) {
        const previa = todos.get(c.party);
        if (previa) previa.votes += c.votes;
        else todos.set(c.party, { ...c, candidate_id: ++seq });
      }
    }
    return [...todos.values()].sort((a, b) => b.votes - a.votes);
  }, [summary, ubigeoSel]);

  const totalValidos = ranking.reduce((s, c) => s + c.votes, 0);
  const top2 = ranking.slice(0, 2);
  const pctDe = (v: number) => (totalValidos > 0 ? (100 * v) / totalValidos : 0);

  const fila = statPor.get(ubigeoSel) ?? null;
  const pctProcesado = summary?.progress_pct ?? fila?.avance ?? 0;
  const mesasProc = summary?.processed_tables ?? fila?.procesadas ?? 0;
  const mesasTotal = summary?.total_tables ?? fila?.mesas ?? 0;
  const observadas = summary?.review_tables ?? fila?.observadas ?? 0;
  const locales = summary?.total_venues ?? fila?.locales ?? 0;

  const estiloDistrito = (f?: Feature<Geometry, FeatureGeo>): L.PathOptions => {
    const p = (f?.properties ?? {}) as FeatureGeo;
    const s = statPor.get(p.u);
    const sel = p.u === ubigeoSel;
    return {
      fillColor: s?.ganador?.color ?? SIN_VOTOS,
      fillOpacity: sel ? 0.95 : 0.72,
      color: sel ? ROJO : BORDE,
      weight: sel ? 2.5 : 0.7,
    };
  };

  const tooltipDistrito = (p: FeatureGeo): string => {
    const s = statPor.get(p.u);
    if (!s) return `<b>${p.n}</b><br/>Sin locales en el padrón`;
    const gan = s.ganador
      ? `<br/><span style="color:${s.ganador.color};font-weight:700">▲ ${s.ganador.name}: ${fmt(s.ganador.votes)} votos</span>`
      : "<br/><i>Sin votos registrados</i>";
    return (
      `<b>${p.n}</b> <span style="color:#94A3B8">(${p.pvn ?? ""})</span>` +
      `<br/>Mesas: ${s.procesadas}/${s.mesas} · Avance ${s.avance}%` +
      `<br/>Observadas JEE: ${s.observadas} · Locales: ${s.locales}` +
      gan
    );
  };

  if (cargando) {
    return (
      <div className="flex min-h-[60vh] items-center justify-center bg-[#12090B] text-slate-300">
        <div className="text-center">
          <div className="mx-auto h-10 w-10 animate-spin rounded-full border-4 border-[#3A1418] border-t-[#E02020]" />
          <p className="mt-4 text-sm font-semibold">Cargando padrón y capas geográficas…</p>
        </div>
      </div>
    );
  }

  if (error || !geo) {
    return (
      <div className="flex min-h-[60vh] items-center justify-center bg-[#12090B] text-slate-300">
        <div className="max-w-md rounded-2xl border border-red-500/30 bg-[#12090B] p-6 text-center">
          <h2 className="text-lg font-black text-red-400">No se pudo cargar el mapa</h2>
          <p className="mt-2 text-sm text-slate-400">{error}</p>
          <button
            onClick={() => window.location.reload()}
            className="mt-4 rounded-lg bg-[#E02020] px-4 py-2 text-sm font-bold text-white transition hover:bg-[#A01010]"
          >
            Reintentar
          </button>
        </div>
      </div>
    );
  }

  const objetivo = distritoSel?.geo ?? geo.region?.geo ?? null;

  return (
    <div className="min-h-screen bg-[#12090B] text-slate-100">
      {/* ================= HEADER GLOBAL ================= */}
      <header className="sticky top-0 z-30 border-b border-[#3A1418]/50 bg-[#12090B]/90 backdrop-blur">
        <div className="mx-auto flex max-w-[1600px] flex-wrap items-center gap-x-6 gap-y-3 px-4 py-3 lg:px-6">
          {/* Marca */}
          <div className="flex items-center gap-3">
            <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-[#E02020] text-sm font-black text-white shadow-lg shadow-red-900/40">
              FA
            </span>
            <span>
              <span className="block text-sm font-black tracking-wide">
                Cómputo Electoral · Arequipa 2026
              </span>
              <span className="block text-[11px] font-semibold text-slate-400">
                Fuente: <span className="text-slate-200">Sistema de Cómputo</span> · Padrón oficial · Act. {horaAct}
              </span>
            </span>
          </div>

          {/* Métricas de conteo global */}
          <div className="flex flex-1 flex-wrap items-center gap-x-5 gap-y-2">
            <div className="min-w-40">
              <span className="block text-[10px] font-black uppercase tracking-wider text-slate-500">
                Actas procesadas
              </span>
              <span className="flex items-baseline gap-2">
                <span className="font-mono text-xl font-black text-white">{pctProcesado}%</span>
                <span className="font-mono text-[11px] text-slate-400">
                  {fmt(mesasProc)}/{fmt(mesasTotal)}
                </span>
              </span>
              <span className="mt-1 block h-1.5 w-full overflow-hidden rounded-full bg-[#221217]">
                <span
                  className="block h-full rounded-full bg-gradient-to-r from-[#E02020] to-[#A01010] transition-all duration-700"
                  style={{ width: `${Math.min(100, pctProcesado)}%` }}
                />
              </span>
            </div>
            {([
              ["Observadas JEE", fmt(observadas), "text-amber-400"],
              ["Locales", fmt(locales), "text-slate-200"],
              ["Ámbito", nombreAmbito, "text-white"],
            ] as const).map(([k, v, cls]) => (
              <div key={k} className="min-w-20">
                <span className="block text-[10px] font-black uppercase tracking-wider text-slate-500">
                  {k}
                </span>
                <span className={`block truncate text-sm font-black ${cls}`}>{v}</span>
              </div>
            ))}
          </div>

          {ubigeoSel && (
            <button
              onClick={() => setUbigeoSel("")}
              className="rounded-lg border border-[#3A1418] bg-[#221217]/60 px-3 py-1.5 text-[11px] font-black text-slate-300 transition hover:border-[#E02020] hover:text-white"
            >
              ✕ Ver toda la región
            </button>
          )}
        </div>
      </header>

      <main className="mx-auto max-w-[1600px] space-y-5 p-4 lg:p-6">
        {conEjemplo && (
          <div className="rounded-xl border border-amber-500/30 bg-amber-500/10 px-4 py-2 text-xs font-semibold text-amber-300">
            API no disponible: mostrando datos de ejemplo indexados por UBIGEO.
          </div>
        )}

        {/* ================= TOP CARDS (Top 2) ================= */}
        <section className="grid gap-4 md:grid-cols-2" aria-label="Top 2 de candidatos">
          {top2.length === 0 && (
            <p className="col-span-2 rounded-2xl border border-[#3A1418]/50 bg-[#12090B]/60 p-8 text-center text-sm text-slate-400">
              Sin votos contabilizados en este ámbito todavía.
            </p>
          )}
          {top2.map((c, idx) => {
            const pct = pctDe(c.votes);
            return (
              <article
                key={`${c.party}-${c.candidate_id}`}
                className="overflow-hidden rounded-2xl border border-[#3A1418]/50 bg-[#12090B]/60 shadow-xl"
              >
                <div
                  className="flex items-center gap-4 px-5 py-4"
                  style={{
                    background: `linear-gradient(135deg, ${c.color}33 0%, transparent 70%)`,
                    borderTop: `3px solid ${c.color}`,
                  }}
                >
                  {c.photo_url ? (
                    <img
                      src={c.photo_url}
                      alt={c.name}
                      className="h-16 w-16 shrink-0 rounded-full border-2 border-[#3A1418] object-cover"
                    />
                  ) : (
                    <span
                      className="flex h-16 w-16 shrink-0 items-center justify-center rounded-full text-xl font-black text-white"
                      style={{ backgroundColor: c.color }}
                    >
                      {(c.name ?? "?").charAt(0)}
                    </span>
                  )}
                  <div className="min-w-0 flex-1">
                    <span
                      className="inline-flex items-center rounded-full px-2.5 py-0.5 text-[10px] font-black uppercase tracking-widest text-white"
                      style={{ backgroundColor: c.color }}
                    >
                      #{idx + 1} · {nombreAmbito}
                    </span>
                    <h3 className="mt-1 truncate text-lg font-black text-white">{c.name}</h3>
                    <p className="truncate text-xs font-bold uppercase tracking-wide text-slate-400">
                      {c.party}
                    </p>
                  </div>
                  <div className="shrink-0 text-right">
                    <p className="font-mono text-3xl font-black tabular-nums text-white">
                      {pct.toFixed(1)}
                      <span className="text-base">%</span>
                    </p>
                    <p className="font-mono text-xs text-slate-400">{fmt(c.votes)} votos</p>
                  </div>
                </div>
                <div className="px-5 pb-4">
                  <div className="h-2 overflow-hidden rounded-full bg-[#221217]">
                    <div
                      className="h-full rounded-full transition-all duration-700 ease-out"
                      style={{
                        width: `${Math.min(100, pct)}%`,
                        background: `linear-gradient(90deg, ${c.color}, ${c.color}88)`,
                      }}
                    />
                  </div>
                </div>
              </article>
            );
          })}
        </section>

        {/* ================= WORKSPACE 40 / 60 ================= */}
        <section className="grid gap-4 lg:grid-cols-[2fr_3fr]">
          {/* ---------- PANEL IZQUIERDO: lista de candidatos ---------- */}
          <div className="flex flex-col overflow-hidden rounded-2xl border border-[#3A1418]/50 bg-[#12090B]/60">
            <div className="border-b border-[#3A1418]/50 px-4 py-3">
              <h2 className="truncate text-sm font-black uppercase tracking-wider text-white">
                {nombreAmbito}
                {provinciaSel && (
                  <span className="ml-1 text-[11px] font-bold text-slate-400">
                    · {provinciaSel}
                  </span>
                )}
              </h2>
              <p className="text-[11px] font-semibold text-slate-500">
                Elección {NIVELES.find((n) => n.id === scope)?.etiqueta.toLowerCase()} ·{" "}
                {fmt(totalValidos)} votos válidos
              </p>

              {/* Selector de distrito (ubigeo) + nivel de elección */}
              <div className="mt-3 flex flex-col gap-2">
                <select
                  value={ubigeoSel}
                  onChange={(e) => setUbigeoSel(e.target.value)}
                  aria-label="Seleccionar distrito"
                  className="w-full rounded-lg border border-[#3A1418] bg-[#221217] px-3 py-2 text-xs font-bold text-slate-100 outline-none transition focus:border-[#E02020]"
                >
                  <option value="">Toda la región (109 distritos)</option>
                  {distritosPorProvincia.map(([pv, items]) => (
                    <optgroup key={pv} label={items[0]?.pvn ?? pv}>
                      {items.map((d) => (
                        <option key={d.u} value={d.u}>
                          {d.n} ({d.u})
                        </option>
                      ))}
                    </optgroup>
                  ))}
                </select>
                <div
                  className="flex overflow-hidden rounded-lg border border-[#3A1418]"
                  role="group"
                  aria-label="Nivel de elección"
                >
                  {NIVELES.map((n) => (
                    <button
                      key={n.id}
                      type="button"
                      onClick={() => setScope(n.id)}
                      title={n.desc}
                      aria-pressed={scope === n.id}
                      className={`flex-1 px-2 py-1.5 text-[11px] font-black uppercase tracking-wide transition ${
                        scope === n.id
                          ? "bg-[#E02020] text-white"
                          : "bg-[#221217]/60 text-slate-400 hover:text-slate-200"
                      }`}
                    >
                      {n.etiqueta}
                    </button>
                  ))}
                </div>
              </div>
            </div>

            {/* Lista ordenada */}
            <ul className="scroll-dark max-h-[520px] flex-1 overflow-y-auto p-2">
              {ranking.length === 0 && (
                <li className="py-10 text-center text-sm text-slate-500">
                  Sin votos registrados en este ámbito.
                </li>
              )}
              {ranking.map((c, idx) => {
                const pct = pctDe(c.votes);
                return (
                  <li
                    key={`${c.party}-${c.candidate_id}`}
                    className="rounded-xl px-2.5 py-2.5 transition-colors hover:bg-[#221217]/60"
                  >
                    <div className="flex items-center gap-3">
                      <span className="w-6 shrink-0 text-center font-mono text-xs font-black text-slate-500">
                        {String(idx + 1).padStart(2, "0")}
                      </span>
                      {c.photo_url ? (
                        <img
                          src={c.photo_url}
                          alt={c.name}
                          className="h-10 w-10 shrink-0 rounded-full border border-[#3A1418] object-cover"
                        />
                      ) : (
                        <span
                          className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-sm font-black text-white"
                          style={{ backgroundColor: c.color }}
                        >
                          {(c.name ?? "?").charAt(0)}
                        </span>
                      )}
                      <div className="min-w-0 flex-1">
                        <p className="truncate text-sm font-bold text-slate-100">{c.name}</p>
                        <p className="truncate text-[11px] font-semibold uppercase tracking-wide text-slate-500">
                          {c.party}
                        </p>
                      </div>
                      <div className="shrink-0 text-right">
                        <p className="font-mono text-sm font-black tabular-nums text-white">
                          {pct.toFixed(1)}%
                        </p>
                        <p className="font-mono text-[11px] text-slate-400">{fmt(c.votes)}</p>
                      </div>
                    </div>
                    <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-[#221217]">
                      <div
                        className="h-full rounded-full transition-all duration-700 ease-out"
                        style={{
                          width: `${Math.min(100, pct)}%`,
                          backgroundColor: c.color,
                        }}
                      />
                    </div>
                  </li>
                );
              })}
            </ul>
          </div>

          {/* ---------- PANEL DERECHO: mapa vectorial 60% ---------- */}
          <div className="relative overflow-hidden rounded-2xl border border-[#3A1418]/50 bg-[#12090B]/60">
            <MapContainer
              center={[-16.25, -71.7]}
              zoom={8}
              style={{ height: "640px", width: "100%", background: "#12090B" }}
              scrollWheelZoom={false}
              attributionControl={false}
            >
              <Enfoque objetivo={objetivo} llave={`foco:${ubigeoSel || "region"}`} />
              <GeoJSON
                key={`capa-${ubigeoSel}-${stats?.length ?? 0}`}
                data={
                  {
                    type: "FeatureCollection",
                    features: geo.distritos.map((d) => ({
                      type: "Feature",
                      properties: d,
                      geometry: d.geo,
                    })),
                  } as unknown as GeoJsonObject
                }
                style={estiloDistrito}
                onEachFeature={(feature, layer) => {
                  const p = feature.properties as FeatureGeo;
                  layer.bindTooltip(tooltipDistrito(p), { sticky: true, className: "tooltip-dark" });
                  layer.on({
                    click: () => setUbigeoSel(p.u === ubigeoSel ? "" : p.u),
                    mouseover: (e) => {
                      (e.target as L.Path)
                        .setStyle({ weight: 2.5, color: "#F8FAFC", fillOpacity: 0.95 })
                        .bringToFront();
                    },
                    mouseout: (e) => {
                      const sel = p.u === ubigeoSel;
                      (e.target as L.Path).setStyle({
                        weight: sel ? 2.5 : 0.7,
                        color: sel ? ROJO : BORDE,
                        fillOpacity: sel ? 0.95 : 0.72,
                      });
                    },
                  });
                }}
              />
            </MapContainer>

            {/* Leyenda */}
            <div className="absolute bottom-3 left-3 z-[400] max-w-60 rounded-xl border border-[#3A1418]/50 bg-[#12090B]/95 px-3 py-2.5 shadow-xl">
              <p className="mb-1.5 text-[10px] font-black uppercase tracking-wider text-slate-400">
                Ganador distrital
              </p>
              <div className="flex flex-wrap gap-x-3 gap-y-1">
                {[...new Map(
                  (stats ?? [])
                    .filter((s) => s.ganador)
                    .map((s) => [s.ganador!.name, s.ganador!])
                ).values()]
                  .sort((a, b) => b.votes - a.votes)
                  .slice(0, 6)
                  .map((g) => (
                    <span key={g.name} className="flex items-center gap-1.5 text-[10px] font-bold text-slate-300">
                      <span className="h-2.5 w-2.5 rounded-sm" style={{ background: g.color }} />
                      {g.name.split(" ").slice(0, 2).join(" ")}
                    </span>
                  ))}
                {(stats ?? []).every((s) => !s.ganador) && (
                  <span className="text-[10px] text-slate-500">Aún sin votos</span>
                )}
              </div>
              <span className="mt-2 flex items-center gap-1.5 text-[10px] font-semibold text-slate-500">
                <span className="h-2.5 w-2.5 rounded-sm border border-slate-600" style={{ background: SIN_VOTOS }} />
                Sin votos registrados
              </span>
            </div>

            {/* Contador del ámbito */}
            <span className="absolute right-3 top-3 z-[400] rounded-lg border border-[#3A1418]/50 bg-[#12090B]/95 px-3 py-1.5 text-[11px] font-black text-white shadow-lg">
              <span className="text-[#E02020]">{fmt(mesasProc)}</span>
              <span className="text-slate-400">/{fmt(mesasTotal)} actas · 109 distritos</span>
            </span>
          </div>
        </section>
      </main>
    </div>
  );
}
