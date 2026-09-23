import { useState } from "react";
import { api, sesionGuardada } from "../api";
import type { ElectorFicha } from "../types";
import ActaCargaModal from "./ActaCargaModal";

/* ==================================================================== *
 *  Consulta ONPE — réplica de la ficha oficial "Conoce tu local de
 *  votación" conectada a la base del sistema (Arequipa).
 *
 *  Búsqueda por DNI (8 dígitos) o N° de mesa (6, autodetectado):
 *  GET /api/v1/elector/buscar. Fila superior: estado de miembro (rojo
 *  #e31837 / verde), identidad y jerarquía REGIÓN/PROVINCIA/DISTRITO.
 *  Fila inferior: bloque Capacítate, local en azul #38bdf8 con el botón
 *  "Cargar / Editar Acta de Mesa" (Digitador Global) y cajas de N° mesa
 *  y N° de orden.
 * ==================================================================== */

const ROLES_CARGA = ["SUPER_ADMIN", "DIGITADOR_GLOBAL", "RESPONSABLE_DISTRITAL",
  "COORD_PROVINCIAL"];

export default function ConsultaONPE() {
  const [texto, setTexto] = useState("");
  const [modo, setModo] = useState<"auto" | "dni" | "mesa">("auto");
  const [ficha, setFicha] = useState<ElectorFicha | null>(null);
  const [cargando, setCargando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [modalAbierto, setModalAbierto] = useState(false);

  const miRol = sesionGuardada()?.usuario.rol ?? "";
  const puedeCargar = ROLES_CARGA.includes(miRol);

  const buscar = async (valor?: string) => {
    const limpio = (valor ?? texto).replace(/\D/g, "");
    const esDni = modo === "dni" || (modo === "auto" && limpio.length === 8);
    const esMesa = modo === "mesa" || (modo === "auto" && limpio.length === 6);
    if (!esDni && !esMesa) {
      setError("Ingrese un DNI (8 dígitos) o un N° de mesa (6 dígitos).");
      return;
    }
    setCargando(true);
    setError(null);
    try {
      const res = await api.electorBuscar(
        esDni ? { dni: limpio } : { mesa: limpio });
      setFicha(res);
    } catch (e) {
      setFicha(null);
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCargando(false);
    }
  };

  return (
    <div className="space-y-5">
      {/* Cabecera oficial */}
      <div className="overflow-hidden rounded-2xl bg-[#002B66] text-white shadow-md">
        <div className="flex flex-wrap items-center justify-between gap-3 px-6 py-4">
          <div>
            <p className="text-[11px] font-black uppercase tracking-[0.2em] text-sky-300">
              ONPE · Arequipa 2026
            </p>
            <h3 className="text-xl font-black">Conoce tu local de votación</h3>
          </div>
          <span className="rounded-lg bg-white px-3 py-1.5 text-sm font-black text-[#002B66]">
            ONPE
          </span>
        </div>
        {/* Barra de búsqueda */}
        <div className="bg-[#003a8c] px-6 py-4">
          <div className="flex flex-col gap-2 sm:flex-row">
            <div className="flex overflow-hidden rounded-xl bg-white text-xs font-black">
              {(["auto", "dni", "mesa"] as const).map((m) => (
                <button
                  key={m}
                  onClick={() => setModo(m)}
                  className={`px-4 py-3 uppercase tracking-wider ${
                    modo === m ? "bg-[#e31837] text-white" : "text-slate-500"
                  }`}
                >
                  {m === "auto" ? "Auto" : m === "dni" ? "DNI" : "Mesa"}
                </button>
              ))}
            </div>
            <input
              value={texto}
              onChange={(e) => setTexto(e.target.value.replace(/\D/g, "").slice(0, 8))}
              onKeyDown={(e) => { if (e.key === "Enter") void buscar(); }}
              placeholder="DNI o N° de mesa…"
              inputMode="numeric"
              className="min-w-0 flex-1 rounded-xl border-0 px-5 py-3 font-mono text-lg font-black tracking-widest text-slate-900 placeholder:font-sans placeholder:text-sm placeholder:font-normal"
            />
            <button
              onClick={() => void buscar()}
              disabled={cargando}
              className="rounded-xl bg-[#e31837] px-8 py-3 text-sm font-black uppercase tracking-widest text-white hover:bg-[#c11230] disabled:opacity-60"
            >
              {cargando ? "Buscando…" : "🔍 Buscar"}
            </button>
          </div>
        </div>
      </div>

      {error && (
        <p className="rounded-xl bg-red-50 px-4 py-3 text-sm font-semibold text-red-700">{error}</p>
      )}

      {!ficha && !error && (
        <p className="rounded-2xl border border-dashed border-slate-300 bg-white py-10 text-center text-sm text-slate-500">
          Ingrese un DNI para ver el estado de miembro de mesa, o un N° de mesa
          para la ficha del local y operar el acta.
        </p>
      )}

      {ficha && (
        <>
          {/* Fila superior */}
          <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
            {/* Estado de miembro */}
            <div className={`flex items-center gap-4 rounded-2xl p-5 text-white shadow-md ${
              ficha.esMiembroMesa ? "bg-[#16a34a]" : "bg-[#e31837]"}`}>
              <span className="flex h-14 w-14 shrink-0 items-center justify-center rounded-full bg-white/20 text-2xl font-black">
                {ficha.esMiembroMesa ? "✓" : "✕"}
              </span>
              <div>
                <p className="text-lg font-black leading-tight">
                  {ficha.esMiembroMesa ? "ERES MIEMBRO DE MESA" : "NO ERES MIEMBRO DE MESA"}
                </p>
                <p className="mt-1 text-xs font-semibold text-white/85">
                  {ficha.asignacion
                    ? `${ficha.asignacion.tipo} · Mesa ${ficha.asignacion.mesa} · ${ficha.asignacion.estado}`
                    : "Sin asignación registrada"}
                </p>
              </div>
            </div>
            {/* Identidad */}
            <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-md">
              <p className="text-[11px] font-black uppercase tracking-wider text-slate-400">DNI</p>
              <p className="font-mono text-2xl font-black tabular-nums text-[#002B66]">
                {ficha.dni ?? "—"}
              </p>
              <p className="mt-2 text-[11px] font-black uppercase tracking-wider text-slate-400">
                Nombres y apellidos
              </p>
              <p className="text-base font-black text-slate-900">
                {[ficha.nombres, ficha.apellidos].filter(Boolean).join(" ") || "—"}
              </p>
            </div>
            {/* Ubicación jerárquica */}
            <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-md">
              <p className="text-[11px] font-black uppercase tracking-wider text-slate-400">
                Región / Provincia / Distrito
              </p>
              <p className="mt-1 text-base font-black leading-snug text-[#002B66]">
                {ficha.region || "—"} / {ficha.provincia || "—"} / {ficha.distrito || "—"}
              </p>
              <p className="mt-2 inline-block rounded-lg bg-slate-100 px-2.5 py-1 font-mono text-xs font-bold text-slate-600">
                Ubigeo {ficha.ubigeo || "—"}
              </p>
            </div>
          </div>

          {/* Fila inferior */}
          {ficha.numeroMesa && (
            <div className="grid grid-cols-1 gap-4 lg:grid-cols-4">
              {/* Capacítate */}
              <div className="flex flex-col justify-between gap-3 rounded-2xl bg-gradient-to-br from-[#002B66] to-[#0056B3] p-5 text-white shadow-md">
                <div>
                  <p className="text-3xl">🎓</p>
                  <p className="mt-2 text-base font-black">Capacítate</p>
                  <p className="mt-1 text-xs text-white/80">
                    Material oficial para miembros de mesa y personeros.
                  </p>
                </div>
                <a href="https://www.onpe.gob.pe" target="_blank" rel="noopener noreferrer"
                  className="rounded-xl bg-white/15 px-4 py-2.5 text-center text-xs font-black uppercase tracking-wider hover:bg-white/25">
                  Ir a ONPE →
                </a>
              </div>
              {/* Local de votación */}
              <div className="flex flex-col rounded-2xl bg-[#38bdf8] p-5 text-white shadow-md lg:col-span-2">
                <p className="text-[11px] font-black uppercase tracking-[0.2em] text-white/85">
                  Local de votación
                </p>
                <p className="mt-1 text-2xl font-black leading-tight">{ficha.local.nombre}</p>
                <p className="mt-2 text-sm font-bold">📍 {ficha.local.direccion || "Dirección no registrada"}</p>
                <p className="text-xs text-white/85">
                  Ref.: {ficha.local.referencia || "—"}
                  {ficha.electoresHabiles != null && ` · ${ficha.electoresHabiles} electores hábiles`}
                </p>
                <div className="mt-3 flex flex-wrap items-center gap-2">
                  <span className={`rounded-full px-3 py-1 text-[11px] font-black ${
                    ficha.estadoActa === "REGISTRADA" ? "bg-emerald-600 text-white"
                    : ficha.estadoActa === "OBSERVADA" ? "bg-amber-500 text-white"
                    : "bg-white/25 text-white"}`}>
                    Acta {ficha.estadoActa}
                  </span>
                </div>
                {puedeCargar && (
                  <button
                    onClick={() => setModalAbierto(true)}
                    className="mt-4 rounded-xl bg-white px-4 py-3 text-sm font-black uppercase tracking-wider text-[#002B66] shadow hover:bg-slate-100"
                  >
                    📝 Cargar / Editar acta de mesa
                  </button>
                )}
              </div>
              {/* Detalles numéricos */}
              <div className="grid grid-cols-2 gap-4 lg:grid-cols-1">
                <div className="rounded-2xl border-2 border-[#002B66] bg-white p-4 text-center shadow-md">
                  <p className="text-[11px] font-black uppercase tracking-wider text-slate-500">N° de mesa</p>
                  <p className="font-mono text-4xl font-black tabular-nums text-[#002B66]">
                    {ficha.numeroMesa}
                  </p>
                </div>
                <div className="rounded-2xl border-2 border-[#38bdf8] bg-white p-4 text-center shadow-md">
                  <p className="text-[11px] font-black uppercase tracking-wider text-slate-500">N° de orden</p>
                  <p className="font-mono text-4xl font-black tabular-nums text-[#0284c7]">
                    {String(ficha.numeroOrden).padStart(2, "0")}
                  </p>
                </div>
              </div>
            </div>
          )}

          {ficha.nota && (
            <p className="rounded-xl bg-amber-50 px-4 py-3 text-xs font-semibold text-amber-800">
              ℹ {ficha.nota}
            </p>
          )}
        </>
      )}

      {modalAbierto && ficha && ficha.numeroMesa && (
        <ActaCargaModal
          mesa={ficha.numeroMesa}
          onClose={() => setModalAbierto(false)}
          onSaved={() => { setModalAbierto(false); void buscar(ficha.numeroMesa); }}
        />
      )}
    </div>
  );
}
