import type { InputHTMLAttributes, ReactNode } from "react";

/* ==================================================================== *
 *  Kit UI — piezas compartidas para una UX simple y consistente
 *
 *  Reglas: objetivos táctiles grandes (mín. 44 px), lenguaje claro,
 *  un solo color primario (#E02020), estados vacíos y de carga explícitos.
 * ==================================================================== */

export const COLOR_PRIMARIO = "#E02020";

type Tono = "info" | "exito" | "aviso" | "error";

const TONOS: Record<Tono, { borde: string; fondo: string; texto: string }> = {
  info: { borde: "#bfdbfe", fondo: "#eff6ff", texto: "#1d4ed8" },
  exito: { borde: "#bbf7d0", fondo: "#f0fdf4", texto: "#15803d" },
  aviso: { borde: "#fde68a", fondo: "#fffbeb", texto: "#92400e" },
  error: { borde: "#fecaca", fondo: "#fef2f2", texto: "#b91c1c" },
};

/* ---------------- Botón ---------------- */

interface BotonProps {
  children: ReactNode;
  onClick?: () => void;
  tipo?: "button" | "submit";
  variante?: "primario" | "peligro" | "suave" | "borde" | "exito";
  deshabilitado?: boolean;
  titulo?: string;
  clase?: string;
}

const VARIANTES: Record<string, string> = {
  primario: "bg-[#E02020] text-white hover:bg-[#A01010]",
  exito: "bg-emerald-700 text-white hover:bg-emerald-800",
  peligro: "bg-red-600 text-white hover:bg-red-700",
  suave: "bg-slate-100 text-slate-700 hover:bg-slate-200",
  borde: "border-2 border-[#E02020] text-[#E02020] hover:bg-red-50",
};

export function Boton({
  children, onClick, tipo = "button", variante = "primario",
  deshabilitado, titulo, clase = "",
}: BotonProps) {
  return (
    <button
      type={tipo}
      onClick={onClick}
      disabled={deshabilitado}
      title={titulo}
      className={`inline-flex min-h-[44px] items-center justify-center gap-2 rounded-xl px-5 py-2.5 text-sm font-bold transition active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-40 ${VARIANTES[variante]} ${clase}`}
    >
      {children}
    </button>
  );
}

/* ---------------- Tarjeta ---------------- */

export function Tarjeta({ children, clase = "" }: { children: ReactNode; clase?: string }) {
  return (
    <div className={`rounded-2xl border border-slate-200 bg-white p-4 shadow-xs sm:p-5 ${clase}`}>
      {children}
    </div>
  );
}

/* Variante con nombre en inglés que consumen las vistas de actas
   (SideBySideDigitization, ActaValidationView, ActaTable…). */
const CARD_VARIANTES: Record<string, string> = {
  default: "border border-slate-200 bg-white shadow-xs",
  outline: "border border-slate-200 bg-white",
  error: "border-2 border-red-300 bg-red-50",
};

export function Card({
  children, className = "", variant = "default",
}: { children: ReactNode; className?: string; variant?: "default" | "outline" | "error" }) {
  return (
    <div className={`rounded-2xl p-4 ${CARD_VARIANTES[variant] ?? CARD_VARIANTES.default} ${className}`}>
      {children}
    </div>
  );
}

/* ---------------- Entrada de texto ---------------- */

export function Input({
  className = "", clase = "", ...props
}: InputHTMLAttributes<HTMLInputElement> & { clase?: string }) {
  return <input className={`${CLASE_INPUT} ${clase} ${className}`} {...props} />;
}

export function TituloVista({ titulo, bajada }: { titulo: string; bajada?: string }) {
  return (
    <div className="mb-1">
      <h3 className="text-base font-black text-[#E02020]">{titulo}</h3>
      {bajada && <p className="mt-0.5 text-xs text-slate-500">{bajada}</p>}
    </div>
  );
}

/* ---------------- Alerta / Cargando / Vacío ---------------- */

export function Alerta({ tono, children }: { tono: Tono; children: ReactNode }) {
  const t = TONOS[tono];
  return (
    <p
      className="rounded-xl border px-4 py-2.5 text-sm font-semibold"
      style={{ borderColor: t.borde, backgroundColor: t.fondo, color: t.texto }}
    >
      {children}
    </p>
  );
}

export function Cargando({ texto = "Cargando…" }: { texto?: string }) {
  return (
    <div className="flex items-center justify-center gap-3 py-10 text-sm font-semibold text-slate-500">
      <span className="h-6 w-6 animate-spin rounded-full border-[3px] border-slate-300 border-t-[#E02020]" />
      {texto}
    </div>
  );
}

export function Vacio({ titulo, bajada }: { titulo: string; bajada?: string }) {
  return (
    <div className="rounded-2xl border border-dashed border-slate-300 bg-slate-50 p-8 text-center">
      <p className="text-sm font-bold text-slate-600">{titulo}</p>
      {bajada && <p className="mt-1 text-xs text-slate-400">{bajada}</p>}
    </div>
  );
}

/* ---------------- Insignia y barra ---------------- */

export function Insignia({ color, children }: { color: string; children: ReactNode }) {
  return (
    <span
      className="inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] font-black text-white"
      style={{ backgroundColor: color }}
    >
      {children}
    </span>
  );
}

export function Barra({ pct, color }: { pct: number; color: string }) {
  const v = Math.max(0, Math.min(100, pct));
  return (
    <div className="h-2.5 w-full overflow-hidden rounded-full bg-slate-100">
      <div className="h-full rounded-full transition-all" style={{ width: `${v}%`, backgroundColor: color }} />
    </div>
  );
}

/* ---------------- Campo de formulario ---------------- */

interface CampoProps {
  etiqueta: string;
  children: ReactNode;
  ayuda?: string;
  clase?: string;
}

export function Campo({ etiqueta, children, ayuda, clase = "" }: CampoProps) {
  return (
    <label className={`block text-xs font-bold text-slate-600 ${clase}`}>
      {etiqueta}
      <span className="mt-1 block">{children}</span>
      {ayuda && <span className="mt-1 block text-[11px] font-normal text-slate-400">{ayuda}</span>}
    </label>
  );
}

export const CLASE_INPUT =
  "w-full rounded-xl border-2 border-slate-300 px-3 py-2.5 text-sm focus:border-[#E02020] focus:outline-none disabled:bg-slate-100 disabled:text-slate-500";

/* ---------------- Contacto (llamada + WhatsApp) ---------------- */

/** Normaliza a dígitos; WhatsApp con código país 51 si es celular de 9 dígitos. */
export function waLink(telefono: string | null): string | null {
  const dig = (telefono ?? "").replace(/\D/g, "");
  if (/^9\d{8}$/.test(dig)) return `https://wa.me/51${dig}`;
  return null;
}

export function Contacto({ telefono, compacto }: { telefono: string | null; compacto?: boolean }) {
  if (!telefono) return <span className="text-[11px] text-slate-400">sin teléfono</span>;
  const wa = waLink(telefono);
  const base = compacto
    ? "inline-flex min-h-[36px] items-center gap-1 rounded-lg px-2 py-1 text-[11px] font-bold"
    : "inline-flex min-h-[44px] items-center gap-1.5 rounded-xl px-3 py-2 text-xs font-bold";
  return (
    <span className="inline-flex items-center gap-1.5">
      <a href={`tel:${telefono.replace(/\s/g, "")}`} className={`${base} bg-red-50 text-red-800 hover:bg-red-100`}>
        📞 {telefono}
      </a>
      {wa && (
        <a
          href={wa}
          target="_blank"
          rel="noreferrer"
          title="Abrir WhatsApp"
          className={`${base} bg-emerald-50 text-emerald-800 hover:bg-emerald-100`}
        >
          💬 WA
        </a>
      )}
    </span>
  );
}
