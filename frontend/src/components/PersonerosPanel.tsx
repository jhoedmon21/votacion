import { useCallback, useEffect, useMemo, useState } from "react";
import { api, type PersoneroEquipo } from "../api";
import type { DistritoOpt, LocalOpt } from "../types";
import { Alerta, Boton, Cargando, CLASE_INPUT, Contacto, Vacio } from "./ui";

/* ==================================================================== *
 *  PersonerosPanel — Pestaña de personal de campo (gestores)
 *
 *  Asignación por LOCAL: elige distrito → local → grilla de mesas del
 *  local con multi-selección (TITULAR/SUPLENTE) y asigna en lote.
 *  La grilla muestra quién tiene cada mesa; clic para desasignar.
 * ==================================================================== */

interface MesaLocal {
  id: number;
  numero_mesa: string;
  electores_habiles: number | null;
  estado: string | null;
  asignacion_id: number | null;
  asignado_a: string | null;
  asignado_a_id: number | null;
  tipo: string | null;
  es_del_personero: boolean;
}

export default function PersonerosPanel() {
  const [equipo, setEquipo] = useState<PersoneroEquipo[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);

  /* Cascada territorial para el ámbito de asignación. */
  const [distritos, setDistritos] = useState<DistritoOpt[]>([]);
  const [ubigeoSel, setUbigeoSel] = useState("");
  const [locales, setLocales] = useState<LocalOpt[]>([]);
  const [localSel, setLocalSel] = useState<LocalOpt | null>(null);

  /* Grilla de mesas del local + selección. */
  const [mesas, setMesas] = useState<MesaLocal[]>([]);
  const [seleccion, setSeleccion] = useState<Set<string>>(new Set());
  const [cargandoMesas, setCargandoMesas] = useState(false);

  /* Personero objetivo y tipo de credencial. */
  const [personeroId, setPersoneroId] = useState("");
  const [tipo, setTipo] = useState("TITULAR");
  const [procesando, setProcesando] = useState(false);

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
    api
      .distritos()
      .then(setDistritos)
      .catch(() => setDistritos([]));
  }, [cargar]);

  /* Locales del distrito elegido. */
  useEffect(() => {
    setLocalSel(null);
    setMesas([]);
    setSeleccion(new Set());
    if (!ubigeoSel) {
      setLocales([]);
      return;
    }
    api
      .localesUbigeo(ubigeoSel)
      .then(setLocales)
      .catch(() => setLocales([]));
  }, [ubigeoSel]);

  const cargarMesas = useCallback(async (venueId: number) => {
    setCargandoMesas(true);
    try {
      const uid = personeroId ? Number(personeroId) : undefined;
      setMesas(await api.mesasDeLocal(venueId, uid));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setMesas([]);
    } finally {
      setCargandoMesas(false);
    }
  }, [personeroId]);

  /* Al cambiar el local: carga la grilla. */
  useEffect(() => {
    if (localSel) void cargarMesas(localSel.id);
  }, [localSel, cargarMesas]);

  /* Al cambiar el personero objetivo: re-marca la grilla. */
  useEffect(() => {
    if (localSel) void cargarMesas(localSel.id);
  }, [personeroId, localSel, cargarMesas]);

  const personeroSel = equipo.find((p) => String(p.id) === personeroId) ?? null;

  /* Mesas ya asignadas a CUALQUIER personero de este local. */
  const ocupadas = useMemo(
    () => new Set(mesas.filter((m) => m.asignacion_id).map((m) => m.numero_mesa)),
    [mesas]
  );
  const libres = mesas.filter((m) => !m.asignacion_id).length;

  const toggleMesa = (numero: string, asignadaAOtro: boolean) => {
    if (asignadaAOtro) return;
    setSeleccion((prev) => {
      const nuevo = new Set(prev);
      if (nuevo.has(numero)) nuevo.delete(numero);
      else nuevo.add(numero);
      return nuevo;
    });
  };

  const seleccionarLibres = () => {
    setSeleccion(new Set(mesas.filter((m) => !m.asignacion_id).map((m) => m.numero_mesa)));
  };

  const asignarLote = async () => {
    setError(null);
    setMensaje(null);
    if (!personeroId) return setError("Elige al personero.");
    if (seleccion.size === 0) return setError("Selecciona al menos una mesa de la grilla.");
    setProcesando(true);
    try {
      const r = await api.asignarLote({
        usuario_id: Number(personeroId),
        numero_mesas: [...seleccion],
        tipo,
      });
      const creadas = r.mesas.filter((m) => m.resultado !== "ya_estaba").length;
      setMensaje(
        `${r.usuario}: ${creadas} mesa(s) asignada(s) como ${r.tipo} en ${localSel?.nombre}.`
      );
      setSeleccion(new Set());
      await Promise.all([cargar(), localSel ? cargarMesas(localSel.id) : Promise.resolve()]);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setProcesando(false);
    }
  };

  const desasignar = async (asignacionId: number) => {
    setError(null);
    setMensaje(null);
    setProcesando(true);
    try {
      await api.desasignar(asignacionId);
      setMensaje("Asignación retirada.");
      await Promise.all([cargar(), localSel ? cargarMesas(localSel.id) : Promise.resolve()]);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setProcesando(false);
    }
  };

  if (cargando) return <Cargando texto="Cargando equipo…" />;

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-black uppercase tracking-wider text-[#E02020]">
          Personeros y delegados ({equipo.length})
        </h3>
        <span className="text-[11px] font-bold text-slate-400">
          {equipo.filter((p) => p.presente_hoy).length} presente(s) hoy
        </span>
      </div>
      {mensaje && <Alerta tono="exito">{mensaje}</Alerta>}
      {error && <Alerta tono="error">{error}</Alerta>}

      {/* ===================== ASIGNAR POR LOCAL ===================== */}
      <section className="rounded-2xl border-2 border-[#E02020]/15 bg-white p-5 shadow-xs">
        <h4 className="mb-3 text-xs font-black uppercase tracking-wider text-[#E02020]">
          Asignación por local de votación
        </h4>

        {/* Paso 1: ámbito + personero */}
        <div className="grid gap-3 md:grid-cols-2 lg:grid-cols-4">
          <label className="text-xs font-bold text-slate-600">
            Distrito
            <select value={ubigeoSel} onChange={(e) => setUbigeoSel(e.target.value)}
              className={`mt-1 ${CLASE_INPUT}`}>
              <option value="">— elegir distrito —</option>
              {distritos.map((d) => (
                <option key={d.ubigeo} value={d.ubigeo}>
                  {d.distrito} ({d.mesas} mesas)
                </option>
              ))}
            </select>
          </label>
          <label className="text-xs font-bold text-slate-600">
            Local de votación
            <select
              value={localSel?.id ?? ""}
              onChange={(e) =>
                setLocalSel(locales.find((l) => String(l.id) === e.target.value) ?? null)
              }
              disabled={!ubigeoSel}
              className={`mt-1 ${CLASE_INPUT} disabled:bg-slate-50`}>
              <option value="">{ubigeoSel ? "— elegir local —" : "elige distrito…"}</option>
              {locales.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.nombre} ({l.mesas})
                </option>
              ))}
            </select>
          </label>
          <label className="text-xs font-bold text-slate-600">
            Personero
            <select value={personeroId} onChange={(e) => setPersoneroId(e.target.value)}
              className={`mt-1 ${CLASE_INPUT}`}>
              <option value="">— elegir —</option>
              {equipo.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.nombre_completo} ({p.dni})
                </option>
              ))}
            </select>
          </label>
          <label className="text-xs font-bold text-slate-600">
            Credencial
            <select value={tipo} onChange={(e) => setTipo(e.target.value)}
              className={`mt-1 ${CLASE_INPUT}`}>
              <option value="TITULAR">TITULAR</option>
              <option value="SUPLENTE">SUPLENTE</option>
            </select>
          </label>
        </div>

        {/* Paso 2: grilla de mesas */}
        {localSel && (
          <div className="mt-4">
            <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
              <p className="text-xs font-bold text-slate-600">
                Mesas de <span className="text-[#E02020]">{localSel.nombre}</span>
                <span className="ml-2 font-mono text-[11px] text-slate-400">
                  {libres} libre(s) · {ocupadas.size} asignada(s)
                </span>
              </p>
              <div className="flex gap-2">
                <button onClick={seleccionarLibres}
                  className="rounded-lg border border-slate-300 px-2.5 py-1 text-[11px] font-bold text-slate-600 hover:bg-slate-50">
                  Seleccionar libres
                </button>
                <button onClick={() => setSeleccion(new Set())}
                  className="rounded-lg border border-slate-300 px-2.5 py-1 text-[11px] font-bold text-slate-600 hover:bg-slate-50">
                  Limpiar
                </button>
              </div>
            </div>

            {cargandoMesas ? (
              <Cargando texto="Cargando mesas…" />
            ) : mesas.length === 0 ? (
              <p className="rounded-xl bg-slate-50 p-4 text-center text-xs text-slate-400">
                Este local no tiene mesas en el padrón.
              </p>
            ) : (
              <div className="grid max-h-72 grid-cols-3 gap-1.5 overflow-y-auto rounded-xl bg-slate-50 p-2 sm:grid-cols-6 md:grid-cols-8 lg:grid-cols-10">
                {mesas.map((m) => {
                  const sel = seleccion.has(m.numero_mesa);
                  const deOtro = m.asignacion_id != null && !m.es_del_personero;
                  const suya = m.es_del_personero;
                  return (
                    <button key={m.id}
                      onClick={() => toggleMesa(m.numero_mesa, deOtro)}
                      disabled={deOtro || procesando}
                      title={
                        deOtro
                          ? `Mesa ${m.numero_mesa}: asignada a ${m.asignado_a} (${m.tipo})`
                          : suya
                            ? `Mesa ${m.numero_mesa}: tuya (${m.tipo})`
                            : `Mesa ${m.numero_mesa} libre · ${m.electores_habiles ?? "?"} hábiles`
                      }
                      className={`relative rounded-lg border-2 px-1 py-1.5 text-center transition ${
                        deOtro
                          ? "cursor-not-allowed border-slate-200 bg-slate-200/60"
                          : sel
                            ? "border-[#E02020] bg-[#E02020] text-white shadow"
                            : suya
                              ? "border-[#E02020]/60 bg-[#E02020]/10 hover:bg-[#E02020]/20"
                              : "border-slate-200 bg-white hover:border-[#E02020]/40"
                      }`}>
                      <span className={`block font-mono text-xs font-black ${sel ? "text-white" : "text-slate-800"}`}>
                        {m.numero_mesa}
                      </span>
                      <span className={`block text-[9px] font-bold ${sel ? "text-white/70" : "text-slate-400"}`}>
                        {m.electores_habiles ?? "?"} háb.
                      </span>
                      {suya && (
                        <span className="absolute -right-1 -top-1 flex h-4 w-4 items-center justify-center rounded-full bg-[#E02020] text-[9px] font-black text-white shadow">
                          ✓
                        </span>
                      )}
                      {deOtro && (
                        <span className="absolute -right-1 -top-1 flex h-4 w-4 items-center justify-center rounded-full bg-slate-500 text-[8px] font-black text-white shadow"
                          title={`Asignada a ${m.asignado_a}`}>
                          {m.asignado_a?.slice(0, 1) ?? "?"}
                        </span>
                      )}
                    </button>
                  );
                })}
              </div>
            )}

            {/* Pie: acciones sobre la selección */}
            <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
              <p className="text-xs text-slate-500">
                {personeroSel ? (
                  <>
                    <strong className="text-slate-700">{personeroSel.nombre_completo}</strong>{" "}
                    recibirá <strong>{seleccion.size}</strong> mesa(s) como{" "}
                    <strong className="text-[#E02020]">{tipo}</strong>
                    {ocupadas.size > 0 && (
                      <span className="ml-1 text-slate-400">
                        ({ocupadas.size} ya ocupada(s) en este local)
                      </span>
                    )}
                  </>
                ) : (
                  "Elige al personero para habilitar la asignación."
                )}
              </p>
              <Boton onClick={() => void asignarLote()}
                deshabilitado={procesando || !personeroId || seleccion.size === 0}>
                {procesando ? "Asignando…" : `Asignar ${seleccion.size || ""} mesa(s)`}
              </Boton>
            </div>

            {/* Leyenda */}
            <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[10px] font-bold text-slate-400">
              <span><span className="mr-1 inline-block h-2.5 w-2.5 rounded border-2 border-slate-300 bg-white" /> libre</span>
              <span><span className="mr-1 inline-block h-2.5 w-2.5 rounded border-2 border-[#E02020] bg-white" /> del personero elegido</span>
              <span><span className="mr-1 inline-block h-2.5 w-2.5 rounded border-2 border-slate-200 bg-slate-200/60" /> de otro personero (no editable)</span>
              <span><span className="mr-1 inline-block h-2.5 w-2.5 rounded bg-[#E02020]" /> seleccionada</span>
            </div>
          </div>
        )}
      </section>

      {/* ===================== EQUIPO ===================== */}
      <div className="space-y-3">
        {equipo.length === 0 && (
          <Vacio
            titulo="Sin personeros en tu alcance"
            bajada="Créalos desde la pestaña Usuarios."
          />
        )}
        {equipo.map((p) => {
          const porLocal = new Map<string, typeof p.mesas>();
          for (const m of p.mesas) {
            const lista = porLocal.get(m.local) ?? [];
            lista.push(m);
            porLocal.set(m.local, lista);
          }
          return (
            <div key={p.id} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-xs">
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
                <div className="flex flex-wrap gap-2">
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
                  <span className="rounded-full bg-[#E02020]/10 px-2.5 py-1 font-mono text-[11px] font-black text-[#E02020]">
                    {p.mesas.length} mesa(s)
                  </span>
                  <button
                    onClick={() => {
                      setPersoneroId(String(p.id));
                      const primerLocal = p.mesas[0];
                      if (primerLocal) {
                        const dl = distritos.find((d) => d.ubigeo === primerLocal.ubigeo);
                        if (dl) setUbigeoSel(dl.ubigeo);
                      }
                      document
                        .getElementById("asignacion-local")
                        ?.scrollIntoView({ behavior: "smooth", block: "start" });
                    }}
                    className="rounded-full border border-[#E02020]/30 px-2.5 py-1 text-[11px] font-black text-[#E02020] hover:bg-[#E02020]/5"
                    title="Cargar sus mesas en el panel de asignación">
                    ⚙ Asignar más
                  </button>
                </div>
              </div>

              {p.mesas.length === 0 ? (
                <p className="mt-2 text-xs text-slate-400">Sin mesas asignadas.</p>
              ) : (
                <div className="mt-2 space-y-2">
                  {[...porLocal.entries()].map(([local, lista]) => (
                    <div key={local} className="rounded-xl bg-slate-50 p-2.5">
                      <p className="mb-1.5 text-[11px] font-black uppercase tracking-wide text-slate-500">
                        {local}{" "}
                        <span className="ml-1 font-mono text-slate-400">({lista.length})</span>
                      </p>
                      <div className="flex flex-wrap gap-1.5">
                        {lista.map((m) => (
                          <span key={`${m.numero_mesa}-${m.tipo}`}
                            className={`group relative inline-flex items-center gap-1 rounded-lg border px-2 py-1 text-[11px] font-bold ${
                              m.estado === "PRESENTE"
                                ? "border-green-300 bg-green-50 text-green-800"
                                : "border-slate-200 bg-white text-slate-600"
                            }`}>
                            <span className="font-mono">{m.numero_mesa}</span>
                            <span className="text-[9px] text-slate-400">{m.tipo.slice(0, 4)}</span>
                            {m.asignacion_id != null && (
                              <button
                                onClick={() => void desasignar(m.asignacion_id!)}
                                disabled={procesando}
                                title={`Quitar asignación de ${m.numero_mesa}`}
                                className="ml-0.5 text-[10px] font-black text-red-400 hover:text-red-700">
                                ✕
                              </button>
                            )}
                          </span>
                        ))}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
