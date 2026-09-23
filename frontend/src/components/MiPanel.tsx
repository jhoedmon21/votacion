import { useCallback, useEffect, useState } from "react";
import { api, sesionGuardada, type MesaAsignada } from "../api";
import FormularioPersonero from "./FormularioPersonero";
import { Alerta, Boton, Cargando, Vacio } from "./ui";

/* ==================================================================== *
 *  MiPanel — Portada del PERSONERO/DELEGADO_MESA
 *
 *  El personal de campo NO ve el dashboard general ni datos de la región:
 *  sólo sus mesas asignadas, su check-in GPS y el registro de sus actas.
 * ==================================================================== */

export default function MiPanel() {
  const sesion = sesionGuardada();
  const [mesas, setMesas] = useState<MesaAsignada[]>([]);
  const [presencia, setPresencia] = useState(false);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);
  const [localizando, setLocalizando] = useState<string | null>(null);
  const [mesaActiva, setMesaActiva] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      const est = await api.miEstado();
      setMesas(est.asignaciones);
      setPresencia(est.presencia_validada);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCargando(false);
    }
  }, []);

  useEffect(() => {
    void cargar();
  }, [cargar]);

  const hacerCheckin = (numeroMesa: string) => {
    if (!navigator.geolocation) {
      setError("Tu dispositivo no soporta geolocalización.");
      return;
    }
    setLocalizando(numeroMesa);
    setError(null);
    setMensaje(null);
    navigator.geolocation.getCurrentPosition(
      async (pos) => {
        try {
          const r = await api.checkin({
            numero_mesa: numeroMesa,
            latitud: pos.coords.latitude,
            longitud: pos.coords.longitude,
            precision_m: pos.coords.accuracy ?? null,
            dispositivo: navigator.userAgent.slice(0, 120),
          });
          if (r.dentro_de_radio) {
            setMensaje(`✓ ${r.mensaje}`);
            await cargar();
          } else {
            setError(`✗ ${r.mensaje}`);
          }
        } catch (e) {
          setError(e instanceof Error ? e.message : String(e));
        } finally {
          setLocalizando(null);
        }
      },
      (geoErr) => {
        setError(`No se pudo obtener tu ubicación: ${geoErr.message}`);
        setLocalizando(null);
      },
      { enableHighAccuracy: true, timeout: 15000 }
    );
  };

  if (mesaActiva) {
    return (
      <FormularioPersonero
        mesaInicial={mesaActiva}
        onGuardada={() => {
          setMesaActiva(null);
          void cargar();
        }}
        onCancelar={() => setMesaActiva(null)}
      />
    );
  }

  return (
    <div className="mx-auto max-w-3xl space-y-4">
      <div className="rounded-2xl bg-[#E02020] p-5 text-white">
        <p className="text-[11px] font-bold uppercase tracking-[0.25em] text-white/70">
          Panel del personero
        </p>
        <h2 className="mt-1 text-xl font-black">{sesion?.usuario.nombre_completo}</h2>
        <p className="mt-1 text-xs text-white/80">
          {sesion?.usuario.rol} ·{" "}
          {presencia ? "✓ Presencia validada hoy" : "Sin presencia validada hoy"}
        </p>
      </div>

      {mensaje && <Alerta tono="exito">{mensaje}</Alerta>}
      {error && <Alerta tono="error">{error}</Alerta>}
      {cargando ? (
        <Cargando texto="Cargando tus mesas…" />
      ) : mesas.length === 0 ? (
        <Vacio
          titulo="No tienes mesas asignadas"
          bajada="Pide tu asignación al coordinador distrital."
        />
      ) : (
        <div className="space-y-3">
          {mesas.map((m) => (
            <div key={`${m.numero_mesa}-${m.tipo}`} className="rounded-2xl border border-slate-200 bg-white p-4">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div>
                  <p className="font-mono text-lg font-black text-[#E02020]">{m.numero_mesa}</p>
                  <p className="text-xs text-slate-500">
                    {m.local} · {m.tipo}
                  </p>
                </div>
                <span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${
                  m.estado === "PRESENTE" ? "bg-green-100 text-green-800"
                  : "bg-amber-100 text-amber-800"
                }`}>
                  {m.checkin_hoy ? "Check-in hoy ✓" : m.estado}
                </span>
              </div>
              <div className="mt-3 flex flex-wrap gap-2">
                {!m.checkin_hoy && (
                  <Boton
                    onClick={() => hacerCheckin(m.numero_mesa)}
                    deshabilitado={localizando === m.numero_mesa}
                    clase="!min-h-[48px] flex-1 text-xs uppercase tracking-wider"
                  >
                    {localizando === m.numero_mesa ? "Localizando…" : "📍 Llegué al local"}
                  </Boton>
                )}
                <Boton
                  variante="borde"
                  onClick={() => setMesaActiva(m.numero_mesa)}
                  clase="!min-h-[48px] flex-1 text-xs uppercase tracking-wider"
                >
                  📋 Registrar acta
                </Boton>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
