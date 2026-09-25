import { useState } from "react";
import { api, login } from "./api";

/**
 * Portada de sesión: sin credenciales válidas no se ve el dashboard.
 * Si ya hay una sesión viva en localStorage (compartida con la PWA móvil),
 * renderiza los children directamente.
 */
export default function LoginGate({ children }: { children: React.ReactNode }) {
  const [sesion, setSesion] = useState(() => api.sesionGuardada());
  const [email, setEmail] = useState("");
  const [clave, setClave] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [cargando, setCargando] = useState(false);

  if (sesion) {
    return <>{children}</>;
  }

  const enviar = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setCargando(true);
    try {
      const s = await login(email, clave);
      setSesion(s);
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo iniciar sesión");
    } finally {
      setCargando(false);
    }
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-[#232a35] p-4">
      <div className="w-full max-w-md overflow-hidden rounded-2xl bg-white shadow-2xl">
        {/* Franja institucional estilo Material */}
        <div className="bg-[#E02020] px-8 pb-6 pt-7">
          <div className="flex items-center gap-3">
            <span className="rounded-lg bg-white px-2.5 py-1 text-lg font-black tracking-tight text-[#E02020] shadow">
              SISTEMA
            </span>
            <div>
              <p className="text-sm font-black uppercase tracking-wider text-white">
                Cómputo Arequipa 2026
              </p>
              <p className="text-[11px] text-red-200">
                Regionales y Municipales · acceso autorizado
              </p>
            </div>
          </div>
        </div>
        <div className="p-8 pt-6">
          <h1 className="text-xl font-black text-slate-900">Iniciar sesión</h1>
          <p className="mt-1 text-sm text-slate-500">
            Ingresa con tus credenciales institucionales.
          </p>
          <form onSubmit={enviar} className="mt-6 space-y-4">
            <div>
              <label className="mb-1 block text-sm font-semibold text-gray-700" htmlFor="login-email">
                Correo institucional
              </label>
              <input
                id="login-email"
                type="email"
                required
                autoComplete="username"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="usuario@computoarequipa.gob.pe"
                className="min-h-[44px] w-full rounded-xl border-2 border-gray-300 px-3 py-2 text-sm focus:border-[#E02020] focus:outline-none"
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-semibold text-gray-700" htmlFor="login-clave">
                Contraseña
              </label>
              <input
                id="login-clave"
                type="password"
                required
                autoComplete="current-password"
                value={clave}
                onChange={(e) => setClave(e.target.value)}
                placeholder="••••••••"
                className="min-h-[44px] w-full rounded-xl border-2 border-gray-300 px-3 py-2 text-sm focus:border-[#E02020] focus:outline-none"
              />
            </div>
            {error && (
              <p className="rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">
                {error}
              </p>
            )}
            <button
              type="submit"
              disabled={cargando}
              className="min-h-[48px] w-full rounded-xl bg-[#E02020] py-2.5 font-bold text-white shadow-md transition hover:bg-[#A01010] hover:shadow-lg active:scale-[0.99] disabled:opacity-50"
            >
              {cargando ? "Ingresando…" : "Ingresar →"}
            </button>
          </form>
          <p className="mt-6 text-xs text-gray-400">
            Las credenciales las asigna el SUPER_ADMIN. La sesión dura 12 h y se
            cierra automáticamente al expirar.
          </p>
        </div>
      </div>
    </div>
  );
}
