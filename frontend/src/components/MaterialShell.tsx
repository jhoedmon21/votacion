import { useState, type ReactNode } from "react";

/* ==================================================================== *
 *  MaterialShell — armazón estilo Material Dashboard (CreativeIT)
 *
 *  Sidebar oscuro con navegación por rol, topbar con título/estado y área
 *  de contenido clara con tarjetas de elevación suave. Drawer en móvil.
 * ==================================================================== */

export interface NavItem {
  id: string;
  etiqueta: string;
  icono: ReactNode;
  activo: boolean;
  onClick: () => void;
}

interface Props {
  nav: NavItem[];
  titulo: string;
  bajada: string;
  usuario: string;
  insignia: string;
  colorInsignia: string;
  onSalir: () => void;
  children: ReactNode;
}

export default function MaterialShell({
  nav, titulo, bajada, usuario, insignia, colorInsignia, onSalir, children,
}: Props) {
  const [abierto, setAbierto] = useState(false);

  return (
    <div className="min-h-screen bg-[#f1f2f7] font-sans text-slate-800 antialiased">
      {/* Overlay móvil */}
      {abierto && (
        <button
          aria-label="Cerrar menú"
          onClick={() => setAbierto(false)}
          className="fixed inset-0 z-30 bg-black/50 lg:hidden"
        />
      )}

      {/* Sidebar oscuro */}
      <aside
        className={`fixed inset-y-0 left-0 z-40 flex w-64 flex-col bg-[#232a35] text-slate-300 shadow-2xl transition-transform duration-300 lg:translate-x-0 ${
          abierto ? "translate-x-0" : "-translate-x-full"
        }`}
      >
        <div className="flex items-center gap-3 px-5 pb-5 pt-6">
          <span className="rounded-lg bg-white px-2.5 py-1 text-lg font-black tracking-tight text-[#002B66] shadow">
            ONPE
          </span>
          <div>
            <p className="text-sm font-black uppercase leading-tight tracking-wider text-white">
              Cómputo
            </p>
            <p className="text-[11px] text-slate-400">Arequipa 2026</p>
          </div>
        </div>

        <nav className="flex-1 space-y-1 overflow-y-auto px-3" aria-label="Principal">
          {nav.map((item) => (
            <button
              key={item.id}
              onClick={() => {
                item.onClick();
                setAbierto(false);
              }}
              aria-current={item.activo ? "page" : undefined}
              className={`flex w-full items-center gap-3 rounded-xl px-4 py-3 text-left text-sm font-bold transition ${
                item.activo
                  ? "bg-white/10 text-white shadow-inner"
                  : "text-slate-400 hover:bg-white/5 hover:text-white"
              }`}
            >
              <span
                className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-lg ${
                  item.activo ? "bg-[#002B66] text-white shadow" : "bg-white/5 text-slate-300"
                }`}
              >
                {item.icono}
              </span>
              {item.etiqueta}
              {item.activo && (
                <span className="ml-auto h-5 w-1 rounded-full bg-emerald-400" />
              )}
            </button>
          ))}
        </nav>

        <div className="border-t border-white/10 p-4">
          <div className="flex items-center gap-3 rounded-xl bg-white/5 p-3">
            <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#002B66] text-sm font-black text-white">
              {(usuario || "?").charAt(0).toUpperCase()}
            </span>
            <div className="min-w-0 flex-1">
              <p className="truncate text-xs font-bold text-white">{usuario}</p>
              <span
                className={`mt-0.5 inline-block rounded-full px-2 py-0.5 text-[10px] font-black uppercase text-white ${colorInsignia}`}
              >
                {insignia}
              </span>
            </div>
            <button
              onClick={onSalir}
              title="Cerrar sesión"
              className="rounded-lg px-2.5 py-2 text-sm text-slate-400 transition hover:bg-red-600 hover:text-white"
            >
              ⏻
            </button>
          </div>
        </div>
      </aside>

      {/* Columna principal */}
      <div className="lg:pl-64">
        {/* Topbar */}
        <header className="sticky top-0 z-20 border-b border-slate-200 bg-white/90 shadow-xs backdrop-blur">
          <div className="mx-auto flex max-w-7xl items-center gap-3 px-4 py-3 sm:px-6">
            <button
              onClick={() => setAbierto(true)}
              aria-label="Abrir menú"
              className="rounded-lg p-2 text-slate-600 hover:bg-slate-100 lg:hidden"
            >
              ☰
            </button>
            <div className="min-w-0">
              <h1 className="truncate text-base font-black text-slate-900 sm:text-lg">
                {titulo}
              </h1>
              <p className="truncate text-[11px] text-slate-500">{bajada}</p>
            </div>
            <span className="ml-auto hidden items-center gap-1.5 rounded-full bg-emerald-50 px-3 py-1 text-[11px] font-black text-emerald-700 sm:flex">
              <span className="h-2 w-2 animate-pulse rounded-full bg-emerald-500" />
              EN VIVO
            </span>
          </div>
        </header>

        {/* Contenido */}
        <main className="mx-auto max-w-7xl px-4 py-6 sm:px-6">{children}</main>
      </div>
    </div>
  );
}
