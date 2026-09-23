import { useCallback, useEffect, useState } from "react";
import { api, type PersoneroEquipo } from "../api";
import { Alerta, Boton, Campo, Cargando, CLASE_INPUT, Contacto, Vacio } from "./ui";

/* ==================================================================== *
 *  PersonerosPanel — Pestaña de personal de campo (gestores)
 *
 *  Reorganiza a los personeros/delegados fuera del dashboard general:
 *  equipo del alcance con sus mesas, estado, último check-in y presencia,
 *  más formulario de asignación a mesa (TITULAR/SUPLENTE).
 * ==================================================================== */

export default function PersonerosPanel() {
  const [equipo, setEquipo] = useState<PersoneroEquipo[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);

  const [usuarioId, setUsuarioId] = useState("");
  const [mesa, setMesa] = useState("");
  const [tipo, setTipo] = useState("TITULAR");
  const [asignando, setAsignando] = useState(false);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      setEquipo(await api.personeros());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCargando(false);
    }
  }, []);

  useEffect(() => {
    void cargar();
  }, [cargar]);

  const asignar = async () => {
    setError(null);
    setMensaje(null);
    if (!usuarioId) return setError("Elige al personero.");
    if (!/^\d{6}$/.test(mesa.trim())) return setError("Mesa: 6 dígitos.");
    setAsignando(true);
    try {
      const r = await api.asignar({
        usuario_id: Number(usuarioId),
        numero_mesa: mesa.trim(),
        tipo,
      });
      setMensaje(`${r.usuario} asignado a mesa ${r.numero_mesa} (${r.tipo}).`);
      setMesa("");
      await cargar();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setAsignando(false);
    }
  };

  if (cargando) return <Cargando texto="Cargando equipo…" />;

  return (
    <div className="space-y-4">
      <h3 className="text-sm font-black uppercase tracking-wider text-[#002B66]">
        Personeros y delegados ({equipo.length})
      </h3>
      {mensaje && <Alerta tono="exito">{mensaje}</Alerta>}
      {error && <Alerta tono="error">{error}</Alerta>}

      {/* Asignar a mesa */}
      <section className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-2 lg:grid-cols-[1fr_auto_auto_auto]">
        <Campo etiqueta="Personero">
          <select value={usuarioId} onChange={(e) => setUsuarioId(e.target.value)}
            className={CLASE_INPUT}>
            <option value="">— elegir —</option>
            {equipo.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nombre_completo} ({p.dni})
              </option>
            ))}
          </select>
        </Campo>
        <Campo etiqueta="Mesa">
          <input value={mesa} inputMode="numeric" maxLength={6}
            onChange={(e) => setMesa(e.target.value.replace(/\D/g, ""))}
            placeholder="023001"
            className={`${CLASE_INPUT} font-mono`} />
        </Campo>
        <Campo etiqueta="Tipo">
          <select value={tipo} onChange={(e) => setTipo(e.target.value)}
            className={CLASE_INPUT}>
            <option value="TITULAR">TITULAR</option>
            <option value="SUPLENTE">SUPLENTE</option>
          </select>
        </Campo>
        <div className="flex items-end">
          <Boton onClick={() => void asignar()} deshabilitado={asignando} clase="w-full">
            {asignando ? "Asignando…" : "Asignar"}
          </Boton>
        </div>
      </section>

      {/* Equipo */}
      <div className="space-y-3">
        {equipo.length === 0 && (
          <Vacio
            titulo="Sin personeros en tu alcance"
            bajada="Créalos desde la pestaña Usuarios."
          />
        )}
        {equipo.map((p) => (
          <div key={p.id} className="rounded-2xl border border-slate-200 bg-white p-4">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div>
                <p className="font-bold text-slate-800">
                  {p.nombre_completo}{" "}
                  <span className="text-xs font-semibold text-slate-400">DNI {p.dni}</span>
                </p>
                <p className="text-xs text-slate-500">
                  {p.email} · {p.rol}
                </p>
                <div className="mt-1.5">
                  <Contacto telefono={p.telefono} />
                </div>
              </div>
              <div className="flex gap-2">
                {!p.activo && (
                  <span className="rounded-full bg-gray-200 px-2.5 py-1 text-[11px] font-bold text-gray-600">
                    Inactivo
                  </span>
                )}
                <span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${
                  p.presente_hoy ? "bg-green-100 text-green-800" : "bg-amber-100 text-amber-800"
                }`}>
                  {p.presente_hoy ? "Presente hoy" : "Sin presencia"}
                </span>
              </div>
            </div>
            {p.mesas.length === 0 ? (
              <p className="mt-2 text-xs text-slate-400">Sin mesas asignadas.</p>
            ) : (
              <table className="mt-2 w-full text-xs">
                <thead>
                  <tr className="text-left uppercase tracking-wider text-slate-400">
                    <th className="py-1 pr-2">Mesa</th>
                    <th className="py-1 pr-2">Local</th>
                    <th className="py-1 pr-2">Tipo</th>
                    <th className="py-1 pr-2">Estado</th>
                    <th className="py-1 pr-2">Último check-in</th>
                  </tr>
                </thead>
                <tbody>
                  {p.mesas.map((m) => (
                    <tr key={`${m.numero_mesa}-${m.tipo}`} className="border-t border-slate-100">
                      <td className="py-1.5 pr-2 font-mono font-bold">{m.numero_mesa}</td>
                      <td className="py-1.5 pr-2">{m.local}</td>
                      <td className="py-1.5 pr-2">{m.tipo}</td>
                      <td className="py-1.5 pr-2">
                        <span className={`rounded-full px-2 py-0.5 font-bold ${
                          m.estado === "PRESENTE" ? "bg-green-100 text-green-800"
                          : m.estado === "CONFIRMADO" ? "bg-blue-100 text-blue-800"
                          : "bg-slate-100 text-slate-600"
                        }`}>
                          {m.estado}
                        </span>
                      </td>
                      <td className="py-1.5 pr-2 text-slate-500">
                        {m.ultimo_checkin
                          ? `${m.ultimo_checkin.slice(11, 16)} · ${
                              m.dentro_de_radio ? `en local (${m.distancia_m} m)` : "fuera de radio"
                            }`
                          : "—"}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
