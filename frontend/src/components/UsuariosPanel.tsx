import { useCallback, useEffect, useMemo, useState } from "react";
import {
  api,
  ROLES_CREABLES,
  sesionGuardada,
  type UsuarioAdmin,
  type UsuarioCrear,
} from "../api";
import { Alerta, Boton, Cargando } from "./ui";

/* ==================================================================== *
 *  UsuariosPanel — Alta y gestión de usuarios por jerarquía
 *
 *  El SUPER_ADMIN crea cualquier rol; los coordinadores crean hacia abajo
 *  dentro de su alcance (el backend lo exige por prefijo de ubigeo).
 *  Acciones por fila: activar/desactivar, restablecer clave, editar alcance.
 * ==================================================================== */

const ROL_COLOR: Record<string, string> = {
  SUPER_ADMIN: "#7c3aed",
  COORD_PROVINCIAL: "#E02020",
  RESPONSABLE_DISTRITAL: "#A01010",
  COORD_LOCAL: "#0e7490",
  DELEGADO_MESA: "#15803d",
  PERSONERO: "#15803d",
};

const formVacio: UsuarioCrear = {
  email: "",
  dni: "",
  nombres: "",
  apellidos: "",
  telefono: "",
  rol: "",
  contrasena: "",
  alcance_ubigeos: [],
};

export default function UsuariosPanel() {
  const sesion = sesionGuardada();
  const miRol = sesion?.usuario.rol ?? "";
  const rolesPermitidos = useMemo(() => ROLES_CREABLES[miRol] ?? [], [miRol]);

  const [usuarios, setUsuarios] = useState<UsuarioAdmin[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);
  const [mostrarForm, setMostrarForm] = useState(false);
  const [form, setForm] = useState<UsuarioCrear>(formVacio);
  const [alcanceTexto, setAlcanceTexto] = useState("");
  const [guardando, setGuardando] = useState(false);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      setUsuarios(await api.usuarios());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCargando(false);
    }
  }, []);

  useEffect(() => {
    void cargar();
  }, [cargar]);

  const set = (campo: keyof UsuarioCrear, valor: string) =>
    setForm((f) => ({ ...f, [campo]: valor }));

  const crear = async () => {
    setError(null);
    setMensaje(null);
    const alcance = alcanceTexto
      .split(/[,\s]+/)
      .map((s) => s.trim())
      .filter((s) => /^\d{6}$/.test(s));
    if (!form.email.includes("@")) return setError("Email inválido.");
    if (!/^\d{8}$/.test(form.dni)) return setError("DNI: 8 dígitos.");
    if (!form.nombres.trim() || !form.apellidos.trim()) return setError("Nombres y apellidos obligatorios.");
    if (!form.rol) return setError("Elige el rol.");
    if (form.contrasena.length < 8) return setError("La contraseña mínima es 8 caracteres.");
    setGuardando(true);
    try {
      const creado = await api.crearUsuario({ ...form, alcance_ubigeos: alcance });
      setUsuarios((u) => [...u, creado].sort((a, b) => a.rol.localeCompare(b.rol)));
      setForm(formVacio);
      setAlcanceTexto("");
      setMostrarForm(false);
      setMensaje(`Usuario ${creado.email} (${creado.rol}) creado.`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setGuardando(false);
    }
  };

  const alternarActivo = async (u: UsuarioAdmin) => {
    setError(null);
    try {
      const act = await api.editarUsuario(u.id, { activo: !u.activo });
      setUsuarios((list) => list.map((x) => (x.id === u.id ? act : x)));
      setMensaje(`${act.email} ${act.activo ? "activado" : "desactivado"}.`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const restablecerClave = async (u: UsuarioAdmin) => {
    const nueva = window.prompt(`Nueva clave para ${u.email} (mínimo 8 caracteres):`);
    if (!nueva) return;
    if (nueva.length < 8) return setError("La contraseña mínima es 8 caracteres.");
    setError(null);
    try {
      const r = await api.resetClave(u.id, nueva);
      setMensaje(r.mensaje);
      void cargar();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const editarAlcance = async (u: UsuarioAdmin) => {
    const texto = window.prompt(
      `Alcance de ${u.email} (ubigeos de 6 dígitos separados por coma):`,
      u.alcance_ubigeos.join(", ")
    );
    if (texto === null) return;
    const alcance = texto
      .split(/[,\s]+/)
      .map((s) => s.trim())
      .filter((s) => /^\d{6}$/.test(s));
    setError(null);
    try {
      const act = await api.editarUsuario(u.id, { alcance_ubigeos: alcance });
      setUsuarios((list) => list.map((x) => (x.id === u.id ? act : x)));
      setMensaje(`Alcance de ${act.email} actualizado.`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  if (cargando) return <Cargando texto="Cargando usuarios…" />;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h3 className="text-sm font-black uppercase tracking-wider text-[#E02020]">
          Usuarios ({usuarios.length}) · tu rol: {miRol}
        </h3>
        {rolesPermitidos.length > 0 && (
          <Boton onClick={() => setMostrarForm((v) => !v)}>
            {mostrarForm ? "✕ Cerrar" : "＋ Nuevo usuario"}
          </Boton>
        )}
      </div>

      {mensaje && <Alerta tono="exito">{mensaje}</Alerta>}
      {error && <Alerta tono="error">{error}</Alerta>}

      {mostrarForm && (
        <section className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-5 md:grid-cols-3">
          <label className="text-xs font-bold text-slate-600">
            Email
            <input value={form.email} onChange={(e) => set("email", e.target.value)}
              placeholder="coord.mollendo@computoarequipa.gob.pe"
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
          </label>
          <label className="text-xs font-bold text-slate-600">
            DNI (8 dígitos)
            <input value={form.dni} onChange={(e) => set("dni", e.target.value.replace(/\D/g, "").slice(0, 8))}
              placeholder="40000009" inputMode="numeric"
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2 font-mono text-sm" />
          </label>
          <label className="text-xs font-bold text-slate-600">
            Teléfono
            <input value={form.telefono} onChange={(e) => set("telefono", e.target.value)}
              placeholder="959000009"
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
          </label>
          <label className="text-xs font-bold text-slate-600">
            Nombres
            <input value={form.nombres} onChange={(e) => set("nombres", e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
          </label>
          <label className="text-xs font-bold text-slate-600">
            Apellidos
            <input value={form.apellidos} onChange={(e) => set("apellidos", e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
          </label>
          <label className="text-xs font-bold text-slate-600">
            Rol
            <select value={form.rol} onChange={(e) => set("rol", e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm">
              <option value="">— elegir —</option>
              {rolesPermitidos.map((r) => (
                <option key={r} value={r}>{r}</option>
              ))}
            </select>
          </label>
          <label className="text-xs font-bold text-slate-600">
            Contraseña inicial (mín. 8)
            <input type="password" value={form.contrasena} onChange={(e) => set("contrasena", e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
          </label>
          <label className="text-xs font-bold text-slate-600 md:col-span-2">
            Alcance (ubigeos de 6 dígitos separados por coma; vacío = sin jurisdicción)
            <input value={alcanceTexto} onChange={(e) => setAlcanceTexto(e.target.value)}
              placeholder="040701 — Mollendo (Islay)"
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2 font-mono text-sm" />
          </label>
          <div className="flex items-end">
            <button onClick={crear} disabled={guardando}
              className="w-full rounded-lg bg-emerald-700 px-4 py-2 text-sm font-bold text-white hover:bg-emerald-800 disabled:opacity-50">
              {guardando ? "Creando…" : "Crear usuario"}
            </button>
          </div>
        </section>
      )}

      <div className="overflow-x-auto rounded-2xl border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-slate-50 text-left text-xs uppercase tracking-wider text-slate-500">
              <th className="px-4 py-3">Usuario</th>
              <th className="px-4 py-3">Rol</th>
              <th className="px-4 py-3">Alcance</th>
              <th className="px-4 py-3">Estado</th>
              <th className="px-4 py-3">Acciones</th>
            </tr>
          </thead>
          <tbody>
            {usuarios.map((u) => (
              <tr key={u.id} className="border-b last:border-0 hover:bg-slate-50">
                <td className="px-4 py-3">
                  <p className="font-bold text-slate-800">{u.nombre_completo}</p>
                  <p className="text-xs text-slate-500">{u.email} · DNI {u.dni}</p>
                </td>
                <td className="px-4 py-3">
                  <span className="rounded-full px-2.5 py-1 text-[11px] font-black text-white"
                    style={{ backgroundColor: ROL_COLOR[u.rol] ?? "#6b7280" }}>
                    {u.rol}
                  </span>
                </td>
                <td className="px-4 py-3 font-mono text-xs text-slate-600">
                  {u.alcance_ubigeos.length ? u.alcance_ubigeos.join(", ") : "—"}
                </td>
                <td className="px-4 py-3">
                  <span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${
                    u.activo ? "bg-green-100 text-green-800" : "bg-gray-200 text-gray-600"
                  }`}>
                    {u.activo ? "Activo" : "Inactivo"}
                  </span>
                </td>
                <td className="px-4 py-3">
                  <div className="flex flex-wrap gap-1.5">
                    <button onClick={() => void alternarActivo(u)}
                      className="rounded bg-slate-100 px-2.5 py-1 text-xs font-bold text-slate-700 hover:bg-slate-200">
                      {u.activo ? "Desactivar" : "Activar"}
                    </button>
                    <button onClick={() => void restablecerClave(u)}
                      className="rounded bg-red-50 px-2.5 py-1 text-xs font-bold text-red-800 hover:bg-red-100">
                      Clave
                    </button>
                    <button onClick={() => void editarAlcance(u)}
                      className="rounded bg-amber-50 px-2.5 py-1 text-xs font-bold text-amber-800 hover:bg-amber-100">
                      Alcance
                    </button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
