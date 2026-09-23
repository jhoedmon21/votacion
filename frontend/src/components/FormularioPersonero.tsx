import { useCallback, useEffect, useState } from "react";
import type { ColumnaActa, PlantillaActa } from "./ActaIngresoForm";
import { api, ROLES_CAMPO, sesionGuardada, type MesaAsignada } from "../api";
import { Alerta, Boton, Cargando, Tarjeta } from "./ui";

/* ==================================================================== *
 *  FormularioPersonero — Registro guiado de actas para campo
 *
 *  Paso 1 Mesa (asignadas o manual) → Paso 2 Nivel (R/P/D) →
 *  Paso 3 Votos por partido + blancos + nulos + impugnados/visados +
 *  total automático → Envío con validación R1/R2 y check de presencia.
 * ==================================================================== */

const ORDEN = ["REGIONAL", "PROVINCIAL", "DISTRITAL"];

interface Digitado {
  votos: Record<number, number | null>;
  blancos: number | null;
  nulos: number | null;
  impugnados: number | null;
}

interface Props {
  onGuardada: () => void;
  onCancelar: () => void;
  mesaInicial?: string;
}

function authHeaders(): Record<string, string> {
  const s = sesionGuardada();
  return s ? { Authorization: `Bearer ${s.token}` } : {};
}

export default function FormularioPersonero({ onGuardada, onCancelar, mesaInicial }: Props) {
  const esCampo = ROLES_CAMPO.includes(sesionGuardada()?.usuario.rol ?? "");
  const [paso, setPaso] = useState(1);
  const [asignadas, setAsignadas] = useState<MesaAsignada[]>([]);
  const [mesa, setMesa] = useState(mesaInicial ?? "");
  const [plantilla, setPlantilla] = useState<PlantillaActa | null>(null);
  const [tab, setTab] = useState("REGIONAL");
  const [digitado, setDigitado] = useState<Record<string, Digitado>>({});
  const [registradas, setRegistradas] = useState<string[]>([]);
  const [puede, setPuede] = useState(true);

  const [cargando, setCargando] = useState(false);
  const [enviando, setEnviando] = useState(false);
  const [localizando, setLocalizando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);

  /* Mesas asignadas (personero) */
  useEffect(() => {
    if (!esCampo) return;
    api
      .miEstado()
      .then((e) => setAsignadas(e.asignaciones))
      .catch(() => setAsignadas([]));
  }, [esCampo]);

  const cargarMesa = useCallback(async (numero: string) => {
    if (!/^\d{6}$/.test(numero)) {
      setError("La mesa debe tener 6 dígitos.");
      return;
    }
    setCargando(true);
    setError(null);
    setAviso(null);
    try {
      const res = await fetch(`/api/actas/plantilla?numero_mesa=${numero}`, {
        headers: authHeaders(),
      });
      if (res.status === 404) throw new Error(`Mesa ${numero} no está en el padrón.`);
      if (res.status === 403) throw new Error("Mesa fuera de tu alcance o sin asignar.");
      if (!res.ok) throw new Error(`Error ${res.status}`);
      const data = (await res.json()) as PlantillaActa;
      data.elecciones.sort(
        (a, b) => ORDEN.indexOf(a.tipo_eleccion) - ORDEN.indexOf(b.tipo_eleccion)
      );
      setPlantilla(data);
      const ini: Record<string, Digitado> = {};
      for (const e of data.elecciones) {
        const col = e.columnas.find((c) => c.es_principal) ?? e.columnas[0];
        if (col) {
          ini[e.tipo_eleccion] = {
            votos: Object.fromEntries(col.organizaciones.map((o) => [o.numero, o.votos])),
            blancos: col.votos_blancos,
            nulos: col.votos_nulos,
            impugnados: col.votos_impugnados,
          };
        }
      }
      setDigitado(ini);
      setTab(data.elecciones[0]?.tipo_eleccion ?? "REGIONAL");
      setRegistradas([]);
      // Check de presencia/padrón (habilita el envío).
      try {
        const chk = await api.checklist(numero);
        setPuede(chk.puede_registrar);
        if (!chk.presencia_validada && esCampo) {
          setAviso("Aún no tienes check-in en este local: regístralo abajo.");
        }
      } catch {
        setPuede(true);
      }
      setPaso(2);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCargando(false);
    }
  }, [esCampo]);

  useEffect(() => {
    if (mesaInicial && /^\d{6}$/.test(mesaInicial)) void cargarMesa(mesaInicial);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const eleccion = plantilla?.elecciones.find((e) => e.tipo_eleccion === tab) ?? null;
  const columna: ColumnaActa | null =
    eleccion?.columnas.find((c) => c.es_principal) ?? eleccion?.columnas[0] ?? null;
  const dig = tab ? digitado[tab] : undefined;
  const habiles = plantilla?.electores_habiles ?? 0;

  const sumaOrgs = columna && dig
    ? columna.organizaciones.reduce((s, o) => s + (dig.votos[o.numero] ?? 0), 0)
    : 0;
  const total = sumaOrgs + (dig?.blancos ?? 0) + (dig?.nulos ?? 0) + (dig?.impugnados ?? 0);
  const excede = habiles > 0 && total > habiles;
  const incompleto =
    !dig ||
    !!columna?.organizaciones.some((o) => dig.votos[o.numero] === null) ||
    dig.blancos === null ||
    dig.nulos === null ||
    dig.impugnados === null;

  const setVoto = (numero: number, v: number | null) => {
    if (!tab) return;
    setDigitado((p) => ({ ...p, [tab]: { ...p[tab], votos: { ...p[tab].votos, [numero]: v } } }));
  };
  const setCampo = (campo: "blancos" | "nulos" | "impugnados", v: number | null) => {
    if (!tab) return;
    setDigitado((p) => ({ ...p, [tab]: { ...p[tab], [campo]: v } }));
  };

  const hacerCheckin = () => {
    if (!plantilla || !navigator.geolocation) {
      setError("Sin geolocalización en este dispositivo.");
      return;
    }
    setLocalizando(true);
    navigator.geolocation.getCurrentPosition(
      async (pos) => {
        try {
          const r = await api.checkin({
            numero_mesa: plantilla.numero_mesa,
            latitud: pos.coords.latitude,
            longitud: pos.coords.longitude,
            precision_m: pos.coords.accuracy ?? null,
          });
          if (r.dentro_de_radio) {
            setAviso(`✓ ${r.mensaje}`);
            const chk = await api.checklist(plantilla.numero_mesa);
            setPuede(chk.puede_registrar);
          } else {
            setError(`✗ ${r.mensaje}`);
          }
        } catch (e) {
          setError(e instanceof Error ? e.message : String(e));
        } finally {
          setLocalizando(false);
        }
      },
      (g) => {
        setError(`Ubicación no disponible: ${g.message}`);
        setLocalizando(false);
      },
      { enableHighAccuracy: true, timeout: 15000 }
    );
  };

  const registrar = async () => {
    if (!plantilla || !eleccion || !dig || incompleto || excede) return;
    setEnviando(true);
    setError(null);
    try {
      const res = await fetch("/api/v1/actas/registrar", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({
          numero_mesa: plantilla.numero_mesa,
          tipo_eleccion: eleccion.tipo_eleccion,
          votos: Object.fromEntries(Object.entries(dig.votos).map(([k, v]) => [k, v ?? 0])),
          votos_blancos: dig.blancos ?? 0,
          votos_nulos: dig.nulos ?? 0,
          votos_impugnados: dig.impugnados ?? 0,
          total_emitidos: total,
          impugnada: false,
        }),
      });
      const body = await res.json();
      if (!res.ok) {
        setError(typeof body?.detail === "string" ? body.detail : `Error ${res.status}`);
        return;
      }
      const nuevos = [...registradas, eleccion.tipo_eleccion];
      setRegistradas(nuevos);
      if (body.estado !== "NORMAL") {
        setAviso(`Acta ${body.estado}: queda para revisión del coordinador.`);
      }
      if (nuevos.length >= (plantilla?.elecciones.length ?? 1)) onGuardada();
      else {
        const pend = ORDEN.find(
          (t) => !nuevos.includes(t) && plantilla?.elecciones.some((e) => e.tipo_eleccion === t)
        );
        if (pend) setTab(pend);
        setPaso(2);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setEnviando(false);
    }
  };

  const num = (v: number | null, on: (x: number | null) => void) => (
    <input
      type="number"
      min={0}
      inputMode="numeric"
      value={v ?? ""}
      onChange={(e) => on(e.target.value === "" ? null : Math.max(0, Number(e.target.value)))}
      placeholder="0"
      className="h-14 w-24 rounded-xl border-2 border-slate-300 text-center font-mono text-2xl font-black text-[#002B66] focus:border-[#002B66] focus:outline-none"
    />
  );

  return (
    <div className="mx-auto max-w-2xl space-y-4">
      {/* Pasos */}
      <div className="flex items-center gap-1">
        {["Mesa", "Nivel", "Votos"].map((et, i) => {
          const n = i + 1;
          const activo = paso === n;
          const listo = paso > n;
          return (
            <div key={et} className="flex flex-1 items-center gap-1">
              <span className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-sm font-black text-white ${
                listo ? "bg-emerald-600" : activo ? "bg-[#002B66]" : "bg-slate-300"}`}>
                {listo ? "✓" : n}
              </span>
              <span className={`text-xs font-bold ${activo ? "text-[#002B66]" : "text-slate-400"}`}>{et}</span>
              {n < 3 && <span className="mx-1 h-0.5 flex-1 rounded bg-slate-200" />}
            </div>
          );
        })}
      </div>

      {error && <Alerta tono="error">{error}</Alerta>}
      {aviso && <Alerta tono={aviso.startsWith("✓") ? "exito" : "aviso"}>{aviso}</Alerta>}

      {/* PASO 1 · Mesa */}
      {paso === 1 && (
        <Tarjeta>
          <p className="mb-3 text-sm font-black text-[#002B66]">1 · Elige tu mesa</p>
          {esCampo && asignadas.length > 0 && (
            <div className="mb-3 grid gap-2">
              {asignadas.map((m) => (
                <button
                  key={`${m.numero_mesa}-${m.tipo}`}
                  onClick={() => {
                    setMesa(m.numero_mesa);
                    void cargarMesa(m.numero_mesa);
                  }}
                  className="flex min-h-[56px] items-center justify-between rounded-xl border-2 border-slate-200 px-4 text-left hover:border-[#002B66]"
                >
                  <span>
                    <span className="block font-mono text-lg font-black text-[#002B66]">{m.numero_mesa}</span>
                    <span className="block text-[11px] text-slate-500">{m.local} · {m.tipo}</span>
                  </span>
                  <span className="text-xl">→</span>
                </button>
              ))}
            </div>
          )}
          <div className="flex gap-2">
            <input
              value={mesa}
              inputMode="numeric"
              maxLength={6}
              onChange={(e) => setMesa(e.target.value.replace(/\D/g, ""))}
              placeholder="N° de mesa (6 dígitos)"
              className="h-14 min-w-0 flex-1 rounded-xl border-2 border-slate-300 px-4 font-mono text-xl tracking-[0.2em] focus:border-[#002B66] focus:outline-none"
            />
            <Boton onClick={() => void cargarMesa(mesa.trim())} deshabilitado={cargando || !/^\d{6}$/.test(mesa)}>
              {cargando ? "…" : "Ir →"}
            </Boton>
          </div>
          {cargando && <Cargando texto="Cargando acta…" />}
          <div className="mt-3 flex justify-end">
            <Boton variante="suave" onClick={onCancelar}>Cancelar</Boton>
          </div>
        </Tarjeta>
      )}

      {/* PASO 2 · Nivel */}
      {paso === 2 && plantilla && (
        <Tarjeta>
          <p className="text-sm font-black text-[#002B66]">
            2 · Nivel · Mesa {plantilla.numero_mesa} ({habiles} hábiles)
          </p>
          <p className="mb-3 text-xs text-slate-500">{plantilla.local.nombre}</p>
          {!puede && (
            <div className="mb-3">
              <Alerta tono="aviso">
                Falta el check de presencia: haz tu check-in GPS en el local para habilitar el registro.
              </Alerta>
              <Boton onClick={hacerCheckin} deshabilitado={localizando} clase="mt-2 w-full">
                {localizando ? "Localizando…" : "📍 Registrar check-in"}
              </Boton>
            </div>
          )}
          <div className="grid grid-cols-3 gap-2">
            {ORDEN.filter((t) => plantilla.elecciones.some((e) => e.tipo_eleccion === t)).map((t) => (
              <button
                key={t}
                onClick={() => { setTab(t); setPaso(3); }}
                className={`min-h-[56px] rounded-xl border-2 px-2 py-2 text-center transition ${
                  registradas.includes(t)
                    ? "border-emerald-500 bg-emerald-50"
                    : "border-slate-200 hover:border-[#002B66]"
                }`}
              >
                <span className="block text-xs font-black uppercase text-[#002B66]">
                  {t}{registradas.includes(t) ? " ✓" : ""}
                </span>
                <span className="block text-[10px] text-slate-400">
                  {plantilla.elecciones.find((e) => e.tipo_eleccion === t)?.columnas[0]?.organizaciones.length ?? 0} partidos
                </span>
              </button>
            ))}
          </div>
          <div className="mt-3 flex justify-between">
            <Boton variante="suave" onClick={() => setPaso(1)}>← Mesa</Boton>
            <Boton variante="suave" onClick={onCancelar}>Cancelar</Boton>
          </div>
        </Tarjeta>
      )}

      {/* PASO 3 · Votos por partido + especiales + total */}
      {paso === 3 && plantilla && eleccion && columna && dig && (
        <div className="space-y-3">
          <Tarjeta>
            <p className="mb-1 text-sm font-black text-[#002B66]">
              3 · Votos · {eleccion.tipo_eleccion} · Mesa {plantilla.numero_mesa}
            </p>
            <p className="mb-3 text-xs text-slate-500">
              Escribe los votos de cada partido tal como están en el papel.
            </p>
            <div className="space-y-2">
              {columna.organizaciones.map((o) => (
                <div key={o.numero} className="flex items-center gap-3">
                  {o.logo_url ? (
                    <img src={o.logo_url} alt={o.nombre} className="h-10 w-10 shrink-0 rounded-lg bg-slate-50 object-contain" />
                  ) : (
                    <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-sm font-black text-white"
                      style={{ backgroundColor: o.color ?? "#002B66" }}>
                      {o.numero}
                    </span>
                  )}
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-bold text-slate-800">{o.nombre}</p>
                    <p className="truncate text-[11px] text-slate-500">{o.candidato}</p>
                  </div>
                  {num(dig.votos[o.numero] ?? null, (v) => setVoto(o.numero, v))}
                </div>
              ))}
            </div>
          </Tarjeta>

          <Tarjeta>
            <p className="mb-2 text-xs font-black uppercase tracking-wider text-slate-500">
              Otros campos del acta
            </p>
            <div className="grid grid-cols-3 gap-2">
              {([
                ["blancos", "Blancos"],
                ["nulos", "Nulos"],
                ["impugnados", "Impugnados / visados"],
              ] as const).map(([campo, etiqueta]) => (
                <label key={campo} className="rounded-xl bg-slate-50 p-2 text-center text-xs font-bold text-slate-600">
                  {etiqueta}
                  <span className="mt-1 block">
                    {num(dig[campo] ?? null, (v) => setCampo(campo, v))}
                  </span>
                </label>
              ))}
            </div>
            <div className={`mt-3 flex items-center justify-between rounded-xl px-4 py-3 ${
              excede ? "bg-red-600 text-white" : "bg-[#002B66] text-white"}`}>
              <span className="text-xs font-black uppercase tracking-wider">
                {excede ? "⛔ Acta observada" : "Total emitido"}
              </span>
              <span className="font-mono text-2xl font-black">{total}</span>
            </div>
            {excede && (
              <p className="mt-2 text-xs font-bold text-red-700">
                El total ({total}) supera los electores hábiles ({habiles}). Corrige los números.
              </p>
            )}
          </Tarjeta>

          <div className="sticky bottom-0 flex gap-2 rounded-2xl border border-slate-200 bg-white/95 p-3 shadow-lg backdrop-blur">
            <Boton variante="suave" onClick={() => setPaso(2)} clase="flex-1">← Nivel</Boton>
            <Boton
              onClick={() => void registrar()}
              deshabilitado={enviando || incompleto || excede || !puede}
              clase="flex-[2]"
              titulo={
                excede ? "Total supera el padrón"
                : !puede ? "Falta check de presencia" : undefined
              }
            >
              {enviando ? "Enviando…" : `Enviar ${tab} →`}
            </Boton>
          </div>
        </div>
      )}
    </div>
  );
}
