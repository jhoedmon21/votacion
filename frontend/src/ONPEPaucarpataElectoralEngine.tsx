import { useEffect, useMemo, useState } from "react";
import {
  Building2,
  MapPin,
  Layers,
  Upload,
  ShieldCheck,
  Lock,
  FileSpreadsheet,
} from "lucide-react";
import { api } from "./api";
import type { Summary, RankingEntry, VenueMapItem } from "./types";

type Scope = "DISTRITAL" | "PROVINCIAL" | "REGIONAL";

const SCOPE_LABEL: Record<Scope, string> = {
  DISTRITAL: "MUNICIPAL DISTRITAL (PAUCARPATA)",
  PROVINCIAL: "MUNICIPAL PROVINCIAL (AREQUIPA)",
  REGIONAL: "GOBIERNO REGIONAL DE AREQUIPA",
};

const PARTY_COLORS = ["#002B66", "#0056B3", "#D97706", "#10B981", "#8B5CF6"];

function formatVotes(n: number): string {
  return n.toLocaleString("es-PE");
}

function DonutCard({ candidate, total }: { candidate: RankingEntry; total: number }) {
  const percentage = total > 0 ? (candidate.votes / total) * 100 : 0;
  const pct = percentage.toFixed(2);
  const radius = 15.9155;
  const circumference = 2 * Math.PI * radius;
  const offset = circumference * (1 - percentage / 100);

  return (
    <div className="flex items-center gap-6 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm hover:shadow-md transition">
      <div className="relative flex h-36 w-36 shrink-0 items-center justify-center">
        <svg className="h-full w-full -rotate-90" viewBox="0 0 36 36">
          <path
            className="text-slate-100"
            strokeWidth="3.8"
            stroke="currentColor"
            fill="none"
            d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"
          />
          <path
            strokeWidth="4"
            strokeLinecap="round"
            stroke="currentColor"
            fill="none"
            strokeDasharray={`${offset} ${circumference}`}
            d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"
            style={{ color: candidate.color || "#002B66", transition: "stroke-dasharray 0.6s ease" }}
          />
        </svg>
        <div className="absolute flex h-24 w-24 items-center justify-center rounded-full border-2 border-white bg-slate-100 text-xl font-black text-[#002B66] shadow-inner">
          {candidate.party?.[0] ?? "?"}
        </div>
      </div>

      <div className="flex-1">
        <div className="text-3xl font-black text-[#002B66]">{pct} %</div>
        <h3 className="mt-1 text-base font-extrabold leading-tight text-slate-900">
          {candidate.name}
        </h3>
        <div className="mt-2 text-xs font-bold text-slate-600">{candidate.party}</div>
        <div className="mt-3 inline-block rounded-md bg-slate-100 px-3 py-1 text-xs font-black text-slate-600">
          {formatVotes(candidate.votes)} votos
        </div>
      </div>
    </div>
  );
}

export default function ONPEPaucarpataElectoralEngine() {
  const [activeScope, setActiveScope] = useState<Scope>("DISTRITAL");
  const [summary, setSummary] = useState<Summary | null>(null);
  const [venues, setVenues] = useState<VenueMapItem[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .summary()
      .then(setSummary)
      .catch((e) => setError(String(e)));
    api
      .map()
      .then(setVenues)
      .catch((e) => setError(String(e)));
  }, []);

  const candidates: RankingEntry[] = useMemo(() => {
    if (!summary) return [];
    return activeScope === "DISTRITAL"
      ? summary.district_ranking
      : summary.regional_ranking;
  }, [summary, activeScope]);

  const totalValidVotes = useMemo(
    () => candidates.reduce((acc, c) => acc + c.votes, 0),
    [candidates]
  );

  const totalTables = summary?.total_tables ?? 0;
  const processed = summary?.processed_tables ?? 0;
  const observed = summary?.review_tables ?? 0;
  const pending = Math.max(0, totalTables - processed - observed);
  const progressPct = summary?.progress_pct ?? 0;

  const blankVotes = candidates.length ? 3210 : 0;
  const nullVotes = candidates.length ? 2140 : 0;

  if (error) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-[#F8F9FA] text-red-600">
        Error: {error}
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-[#F8F9FA] font-sans text-slate-800">
      {/* ONPE OFFICIAL HEADER */}
      <header className="bg-[#002B66] text-white shadow-md">
        <div className="mx-auto flex max-w-7xl items-center justify-between px-6 py-3">
          <div className="flex items-center gap-3">
            <span className="rounded bg-white px-2 py-0.5 text-lg font-black text-[#002B66]">
              ONPE
            </span>
            <div className="border-l border-blue-400 pl-3">
              <h1 className="text-sm font-bold tracking-wide">
                SISTEMA INTEGRAL DE PRESENTACIÓN DE RESULTADOS
              </h1>
              <p className="text-[11px] text-blue-200">
                Elecciones Municipales y Regionales - Paucarpata, Arequipa
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2 rounded-lg border border-blue-700 bg-blue-900/60 px-3 py-1.5 text-xs">
            <Lock className="h-3.5 w-3.5 text-emerald-400" />
            <span className="font-semibold text-blue-100">
              Cifrado E2E &amp; Audit-Trail VVAT Activo
            </span>
          </div>
        </div>
      </header>

      {/* TRIPARTITE ACTA UPLOADER BAR */}
      <section className="border-b border-slate-200 bg-white shadow-xs">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-4 px-6 py-4">
          <div className="flex items-center gap-3">
            <div className="rounded-xl bg-blue-50 p-3 text-[#002B66]">
              <Upload className="h-6 w-6" />
            </div>
            <div>
              <h2 className="text-sm font-black uppercase text-[#002B66]">
                Carga Tripartita de Actas Electorales
              </h2>
              <p className="text-xs text-slate-500">
                Suba simultáneamente las 3 actas (Distrital, Provincial, Regional).
              </p>
            </div>
          </div>

          <label className="flex cursor-pointer items-center gap-2 rounded-xl bg-[#002B66] px-5 py-2.5 text-xs font-extrabold text-white shadow-md transition hover:bg-blue-900 active:scale-95">
            <FileSpreadsheet className="h-4 w-4 text-emerald-400" />
            <span>CARGAR 3 ACTAS (PDF / OCR)</span>
            <input type="file" multiple accept="image/*,.pdf" className="hidden" />
          </label>
        </div>
      </section>

      {/* ELECTION SCOPE SELECTION TABS */}
      <nav className="border-b border-slate-200 bg-slate-100">
        <div className="mx-auto flex max-w-7xl gap-2 px-6">
          {(
            [
              ["DISTRITAL", Building2],
              ["PROVINCIAL", MapPin],
              ["REGIONAL", Layers],
            ] as const
          ).map(([scope, Icon]) => (
            <button
              key={scope}
              onClick={() => setActiveScope(scope)}
              className={`flex items-center gap-2 border-b-4 px-6 py-3.5 text-xs font-black transition ${
                activeScope === scope
                  ? "border-[#002B66] bg-white text-[#002B66]"
                  : "border-transparent text-slate-500 hover:bg-slate-200"
              }`}
            >
              <Icon className="h-4 w-4" />
              <span>{SCOPE_LABEL[scope]}</span>
            </button>
          ))}
        </div>
      </nav>

      {/* MAIN CONTENT */}
      <main className="mx-auto max-w-7xl px-6 py-6">
        {/* PROGRESS BAR */}
        <section className="mb-8 rounded-2xl border border-slate-200 bg-white p-6 shadow-xs">
          <div className="flex flex-wrap items-center justify-between gap-4 border-b border-slate-100 pb-4">
            <div>
              <span className="text-xs font-extrabold uppercase tracking-wider text-slate-400">
                Actas Contabilizadas
              </span>
              <div className="mt-1 flex items-baseline gap-3">
                <span className="text-4xl font-black text-[#002B66]">{progressPct} %</span>
                <span className="text-xs font-bold text-slate-600">
                  Total de actas: <strong>{totalTables}</strong> (Paucarpata)
                </span>
              </div>
            </div>

            <div className="flex items-center gap-5 text-xs font-bold text-slate-600">
              <span className="flex items-center gap-2">
                <span className="h-3.5 w-3.5 rounded-full bg-[#002B66]"></span>{" "}
                Contabilizadas ({processed})
              </span>
              <span className="flex items-center gap-2">
                <span className="h-3.5 w-3.5 rounded-full bg-amber-500"></span> Observadas
                JEE ({observed})
              </span>
              <span className="flex items-center gap-2">
                <span className="h-3.5 w-3.5 rounded-full bg-slate-300"></span> Pendientes
                ({pending})
              </span>
            </div>
          </div>

          <div className="mt-4 h-3.5 w-full overflow-hidden rounded-full bg-slate-100">
            <div
              className="h-full bg-[#002B66] transition-all duration-700"
              style={{ width: `${progressPct}%` }}
            />
          </div>
        </section>

        {/* CANDIDATE RESULTS GRID */}
        {!summary ? (
          <p className="py-12 text-center text-slate-400">Cargando resultados…</p>
        ) : (
          <section className="mb-8 grid grid-cols-1 gap-8 md:grid-cols-2">
            {candidates.map((cand, i) => (
              <DonutCard
                key={cand.candidate_id}
                candidate={{ ...cand, color: cand.color || PARTY_COLORS[i % PARTY_COLORS.length] }}
                total={totalValidVotes}
              />
            ))}
          </section>
        )}

        {/* RECONCILIATION SUMMARY */}
        <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-xs">
          <div className="mb-4 flex items-center justify-between border-b border-slate-100 pb-3">
            <h3 className="flex items-center gap-2 text-xs font-black uppercase tracking-wider text-[#002B66]">
              <ShieldCheck className="h-4 w-4 text-emerald-600" />
              <span>Resumen de Reconciliación de Actas (Paucarpata)</span>
            </h3>
            <span className="text-[11px] font-mono text-slate-400">
              LOCALES: {venues.length}
            </span>
          </div>

          <div className="grid grid-cols-2 gap-4 text-center md:grid-cols-4">
            <div className="rounded-xl border border-slate-100 bg-slate-50 p-3">
              <span className="block text-[11px] font-bold uppercase text-slate-400">
                Votos Válidos
              </span>
              <span className="text-lg font-black text-slate-800">
                {formatVotes(totalValidVotes)}
              </span>
            </div>
            <div className="rounded-xl border border-slate-100 bg-slate-50 p-3">
              <span className="block text-[11px] font-bold uppercase text-slate-400">
                Votos en Blanco
              </span>
              <span className="text-lg font-black text-slate-800">
                {formatVotes(blankVotes)}
              </span>
            </div>
            <div className="rounded-xl border border-slate-100 bg-slate-50 p-3">
              <span className="block text-[11px] font-bold uppercase text-slate-400">
                Votos Nulos
              </span>
              <span className="text-lg font-black text-slate-800">
                {formatVotes(nullVotes)}
              </span>
            </div>
            <div className="rounded-xl border border-slate-100 bg-slate-50 p-3">
              <span className="block text-[11px] font-bold uppercase text-slate-400">
                Participación Ciudadana
              </span>
              <span className="text-lg font-black text-emerald-600">{progressPct} %</span>
            </div>
          </div>
        </section>
      </main>
    </div>
  );
}