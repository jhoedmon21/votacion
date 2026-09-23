import type { ResumenStatus, ActaStatusTotales } from "../../types";

interface ActaSummaryPanelProps {
  totales: ActaStatusTotales | null;
  loading?: boolean;
}

export default function ActaSummaryPanel({ totales, loading = false }: ActaSummaryPanelProps) {
  if (loading || !totales) {
    return (
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-8 animate-pulse">
        {[1,2,3,4,5,6,7,8].map(i => (
          <div key={i} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-xs lg:col-span-1">
            <div className="h-4 bg-slate-200 rounded w-3/4 mb-2"></div>
            <div className="h-8 bg-slate-200 rounded w-1/2"></div>
            <div className="h-3 bg-slate-200 rounded w-full mt-2"></div>
          </div>
        ))}
      </div>
    );
  }

  const pct = (n: number, total: number) => total > 0 ? `${((100 * n) / total).toFixed(1)}%` : "—";

  const cards = [
    { label: "Total Mesas", value: totales.total.toLocaleString(), sub: `avance ${totales.avance_pct}%`, color: "text-[#E02020]", colSpan: 2 },
    { label: "Registradas", value: totales.registradas.toLocaleString(), sub: `${pct(totales.registradas, totales.total)} del total`, color: "text-emerald-700", colSpan: 2 },
    { label: "En Digitación", value: "—", sub: "pendientes de digitación", color: "text-red-700", colSpan: 1 },
    { label: "Digitadas", value: "—", sub: "completas sin validar", color: "text-indigo-700", colSpan: 1 },
    { label: "En Revisión", value: "—", sub: "pendientes de validación", color: "text-yellow-700", colSpan: 1 },
    { label: "Observadas", value: totales.observadas.toLocaleString(), sub: "para rectificar", color: "text-amber-600", colSpan: 1 },
    { label: "Validadas", value: "—", sub: "confirmadas vs imagen", color: "text-emerald-700", colSpan: 1 },
    { label: "Cerradas", value: "—", sub: "bloqueadas definitivamente", color: "text-slate-700", colSpan: 1 },
  ];

  return (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-8">
      {cards.map((card, i) => (
        <div
          key={i}
          className={`rounded-2xl border border-slate-200 bg-white p-4 shadow-xs lg:col-span-${card.colSpan}`}
        >
          <p className="text-[11px] font-black uppercase tracking-wider text-slate-500">{card.label}</p>
          <p className={`mt-1 font-mono text-2xl font-black tabular-nums ${card.color}`}>{card.value}</p>
          <p className="mt-0.5 font-mono text-[11px] tabular-nums text-slate-400">{card.sub}</p>
        </div>
      ))}

      {totales.total > 0 && (
        <div className="lg:col-span-8 mt-2">
          <div className="flex h-3 w-full overflow-hidden rounded-full bg-slate-100">
            <div className="h-full bg-emerald-500 transition-all" style={{ width: `${(100 * totales.registradas) / totales.total}%` }} title="Registradas" />
            <div className="h-full bg-red-500 transition-all" style={{ width: "0%" }} title="En Digitación" />
            <div className="h-full bg-indigo-500 transition-all" style={{ width: "0%" }} title="Digitadas" />
            <div className="h-full bg-yellow-500 transition-all" style={{ width: "0%" }} title="En Revisión" />
            <div className="h-full bg-amber-500 transition-all" style={{ width: `${(100 * totales.observadas) / totales.total}%` }} title="Observadas" />
            <div className="h-full bg-slate-300 transition-all" style={{ width: `${100 - (100 * (totales.registradas + totales.observadas)) / totales.total}%` }} title="Pendientes" />
          </div>
          <div className="flex justify-between text-[10px] text-slate-500 mt-1 font-medium">
            <span>Registradas</span>
            <span>En Digitación</span>
            <span>Digitadas</span>
            <span>En Revisión</span>
            <span>Observadas</span>
            <span>Pendientes</span>
          </div>
        </div>
      )}
    </div>
  );
}