import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ColumnaActa, OrgColumna, PlantillaActa } from "./ActaIngresoForm";
import { sesionGuardada } from "../api";

/* ==================================================================== *
 *  FormularioActaElectoral — Captura de votos, Provincia de Arequipa
 *
 *  Orden oficial: 1º REGIONAL → 1º-bis CONSEJERO (Consejo Regional, por
 *  provincia) → 2º PROVINCIAL → 3º DISTRITAL.
 *  Dualidad obligatoria por casilla: candidato + agrupación + símbolo.
 *  Selector de distrito (29) + mesas del padrón, inputs táctiles grandes,
 *  % relativo en vivo, total emitido automático, banner rojo ACTA OBSERVADA
 *  y bloqueo de envío si total > electores hábiles (R2).
 *  Registra con POST /api/v1/actas/registrar.
 * ==================================================================== */

const ORDEN_OFICIAL = ["REGIONAL", "CONSEJERO", "PROVINCIAL", "DISTRITAL"];

interface Distrito {
  ubigeo: string;
  provincia: string;
  provincia_nombre: string;
  distrito: string;
  mesas: number;
}

interface MesaPadron {
  numero_mesa: string;
  local: string;
  electores_habiles: number | null;
  estado: string;
}

interface Digitado {
  votos: Record<number, number | null>;
  blancos: number | null;
  nulos: number | null;
  impugnados: number | null;
  overrideTotal: number | null; // total del papel si difiere del automático
}

interface CheckItem {
  clave: string;
  etiqueta: string;
  ok: boolean;
  detalle: string;
}

interface Checklist {
  numero_mesa: string;
  local: string;
  ubigeo: string;
  electores_habiles: number | null;
  presencia_validada: boolean;
  oferta_por_nivel: Record<string, number>;
  actas_existentes: string[];
  puede_registrar: boolean;
  items: CheckItem[];
}

interface Props {
  onGuardada: () => void;
  onCancelar: () => void;
  /** Mesa preseleccionada (panel del personero): se carga sola al montar. */
  mesaInicial?: string;
}

function authHeaders(): Record<string, string> {
  const s = sesionGuardada();
  return s ? { Authorization: `Bearer ${s.token}` } : {};
}

function digitadoVacio(col: ColumnaActa): Digitado {
  return {
    votos: Object.fromEntries(col.organizaciones.map((o) => [o.numero, o.votos])),
    blancos: col.votos_blancos,
    nulos: col.votos_nulos,
    impugnados: col.votos_impugnados,
    overrideTotal: null,
  };
}

export default function FormularioActaElectoral({ onGuardada, onCancelar, mesaInicial }: Props) {
  const [distritos, setDistritos] = useState<Distrito[]>([]);
  const [ubigeoSel, setUbigeoSel] = useState("");
  const [mesas, setMesas] = useState<MesaPadron[]>([]);
  const [mesa, setMesa] = useState(mesaInicial ?? "");
  const [habilesInput, setHabilesInput] = useState<number | null>(null);

  const [plantilla, setPlantilla] = useState<PlantillaActa | null>(null);
  const [tab, setTab] = useState<string>("REGIONAL");
  const [digitado, setDigitado] = useState<Record<string, Digitado>>({});
  const [registradas, setRegistradas] = useState<string[]>([]);

  const [cargando, setCargando] = useState(false);
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [avisos, setAvisos] = useState<string[]>([]);
  const [checklist, setChecklist] = useState<Checklist | null>(null);
  const [localizando, setLocalizando] = useState(false);

  /* Evidencia fotográfica del acta (se sube aparte y se asocia al registrar). */
  const [fotoUrl, setFotoUrl] = useState<string | null>(null);
  const [subiendoFoto, setSubiendoFoto] = useState(false);
  const fotoRef = useRef<HTMLInputElement>(null);

  /* Catálogo de distritos */
  useEffect(() => {
    fetch("/api/v1/ubigeo/distritos", { headers: authHeaders() })
      .then((r) => (r.ok ? r.json() : []))
      .then((d) => setDistritos(d as Distrito[]))
      .catch(() => setDistritos([]));
  }, []);

  /* Mesas del distrito elegido */
  useEffect(() => {
    if (!ubigeoSel) {
      setMesas([]);
      return;
    }
    fetch(`/api/v1/mesas?ubigeo=${ubigeoSel}`, { headers: authHeaders() })
      .then((r) => (r.ok ? r.json() : []))
      .then((m) => setMesas(m as MesaPadron[]))
      .catch(() => setMesas([]));
  }, [ubigeoSel]);

  const cargarMesa = useCallback(async (numero: string) => {
    if (!/^\d{6}$/.test(numero)) {
      setError("El N° de mesa debe tener 6 dígitos.");
      return;
    }
    setCargando(true);
    setError(null);
    setAvisos([]);
    try {
      const res = await fetch(`/api/actas/plantilla?numero_mesa=${numero}`, {
        headers: authHeaders(),
      });
      if (res.status === 404) {
        setError(`Mesa ${numero} no está en el padrón.`);
        setPlantilla(null);
        return;
      }
      if (res.status === 403) {
        setError("Mesa fuera de tu alcance territorial.");
        setPlantilla(null);
        return;
      }
      if (!res.ok) throw new Error(`Error ${res.status}`);
      const data = (await res.json()) as PlantillaActa;
      // Orden oficial R → P → D aunque el backend cambie el orden.
      data.elecciones.sort(
        (a, b) => ORDEN_OFICIAL.indexOf(a.tipo_eleccion) - ORDEN_OFICIAL.indexOf(b.tipo_eleccion)
      );
      setPlantilla(data);
      setHabilesInput(data.electores_habiles);
      const ini: Record<string, Digitado> = {};
      for (const e of data.elecciones) {
        const principal = e.columnas.find((c) => c.es_principal) ?? e.columnas[0];
        if (principal) ini[e.tipo_eleccion] = digitadoVacio(principal);
      }
      setDigitado(ini);
      setTab(data.elecciones[0]?.tipo_eleccion ?? "REGIONAL");
      setRegistradas([]);
      if (data.acta_existente && !data.acta_existente.editable) {
        setError(`La mesa ya tiene acta ${data.acta_existente.estado}: solo lectura.`);
      }
      // Check de validación pre-vuelo (padrón, presencia, oferta, duplicados).
      try {
        const chk = await fetch(`/api/v1/actas/checklist?numero_mesa=${numero}`, {
          headers: authHeaders(),
        });
        if (chk.ok) setChecklist((await chk.json()) as Checklist);
        else setChecklist(null);
      } catch {
        setChecklist(null);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setPlantilla(null);
      setChecklist(null);
    } finally {
      setCargando(false);
    }
  }, []);

  /* Autocarga cuando viene mesa preseleccionada (panel del personero). */
  useEffect(() => {
    if (mesaInicial && /^\d{6}$/.test(mesaInicial)) {
      void cargarMesa(mesaInicial);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const hacerCheckin = useCallback(() => {
    if (!plantilla || !navigator.geolocation) {
      setError("Tu dispositivo no soporta geolocalización.");
      return;
    }
    setLocalizando(true);
    setError(null);
    navigator.geolocation.getCurrentPosition(
      async (pos) => {
        try {
          const res = await fetch("/api/v1/campo/checkin", {
            method: "POST",
            headers: { "Content-Type": "application/json", ...authHeaders() },
            body: JSON.stringify({
              numero_mesa: plantilla.numero_mesa,
              latitud: pos.coords.latitude,
              longitud: pos.coords.longitude,
              precision_m: pos.coords.accuracy ?? null,
              dispositivo: navigator.userAgent.slice(0, 120),
            }),
          });
          const body = await res.json();
          if (!res.ok) {
            setError(typeof body?.detail === "string" ? body.detail : `Error ${res.status}`);
          } else if (body.dentro_de_radio) {
            setAvisos([`✓ ${body.mensaje} Ya puedes registrar actas de este local.`]);
            const chk = await fetch(
              `/api/v1/actas/checklist?numero_mesa=${plantilla.numero_mesa}`,
              { headers: authHeaders() }
            );
            if (chk.ok) setChecklist((await chk.json()) as Checklist);
          } else {
            setError(`✗ ${body.mensaje}`);
          }
        } catch (e) {
          setError(e instanceof Error ? e.message : String(e));
        } finally {
          setLocalizando(false);
        }
      },
      (geoErr) => {
        setError(`No se pudo obtener tu ubicación: ${geoErr.message}`);
        setLocalizando(false);
      },
      { enableHighAccuracy: true, timeout: 15000 }
    );
  }, [plantilla]);

  const eleccion = useMemo(
    () => plantilla?.elecciones.find((e) => e.tipo_eleccion === tab) ?? null,
    [plantilla, tab]
  );
  const columna = eleccion?.columnas.find((c) => c.es_principal) ?? eleccion?.columnas[0] ?? null;
  const dig = tab ? digitado[tab] : undefined;
  const habiles = habilesInput ?? plantilla?.electores_habiles ?? 0;

  const calculo = useMemo(() => {
    if (!columna || !dig) {
      return { porOrg: {} as Record<number, number>, validos: 0, total: 0, pct: {} as Record<number, number> };
    }
    const porOrg: Record<number, number> = {};
    for (const o of columna.organizaciones) porOrg[o.numero] = dig.votos[o.numero] ?? 0;
    const validos = Object.values(porOrg).reduce((s, v) => s + v, 0);
    const total = validos + (dig.blancos ?? 0) + (dig.nulos ?? 0) + (dig.impugnados ?? 0);
    const pct: Record<number, number> = {};
    for (const [k, v] of Object.entries(porOrg)) {
      pct[Number(k)] = validos > 0 ? Math.round((1000 * v) / validos) / 10 : 0;
    }
    return { porOrg, validos, total, pct };
  }, [columna, dig]);

  const totalReferencia = dig?.overrideTotal ?? calculo.total;
  const excedePadron = habiles > 0 && totalReferencia > habiles;
  const incompleto =
    !dig ||
    columna?.organizaciones.some((o) => dig.votos[o.numero] === null) ||
    dig.blancos === null ||
    dig.nulos === null ||
    dig.impugnados === null;

  const setVoto = (numero: number, valor: number | null) => {
    if (!tab) return;
    setDigitado((p) => ({ ...p, [tab]: { ...p[tab], votos: { ...p[tab].votos, [numero]: valor } } }));
  };
  const setCampo = (campo: "blancos" | "nulos" | "impugnados" | "overrideTotal", valor: number | null) => {
    if (!tab) return;
    setDigitado((p) => ({ ...p, [tab]: { ...p[tab], [campo]: valor } }));
  };

  const subirFoto = async (file: File) => {
    setSubiendoFoto(true);
    setError(null);
    try {
      const fd = new FormData();
      fd.append("file", file);
      const res = await fetch("/api/v1/actas/foto", {
        method: "POST",
        headers: authHeaders(),
        body: fd,
      });
      if (!res.ok) {
        const txt = await res.text();
        let detail = `Error ${res.status} al subir la foto`;
        try { detail = JSON.parse(txt)?.detail ?? detail; } catch { /* cuerpo no JSON */ }
        setError(typeof detail === "string" ? detail : detail);
        return;
      }
      const body = await res.json();
      setFotoUrl(body.url);
      setAvisos((prev) => [
        ...prev.filter((a) => !a.startsWith("📷")),
        "📷 Foto del acta cargada. Se asociará al registrar la primera elección.",
      ]);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubiendoFoto(false);
      if (fotoRef.current) fotoRef.current.value = "";
    }
  };

  const registrar = async () => {
    if (!plantilla || !eleccion || !dig || incompleto || excedePadron) return;
    setEnviando(true);
    setError(null);
    setAvisos([]);
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
          total_emitidos: totalReferencia,
          impugnada: false,
          image_url: fotoUrl,
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
        const hs = (body.hallazgos ?? []).map((h: { regla: string; mensaje: string }) => `[${h.regla}] ${h.mensaje}`);
        setAvisos([`Acta ${body.estado}: queda para revisión.`, ...hs]);
      }
      if (nuevos.length >= (plantilla?.elecciones.length ?? 1)) onGuardada();
      else {
        // Avanza a la siguiente pestaña pendiente (orden oficial).
        const pend = ORDEN_OFICIAL.find(
          (t) => !nuevos.includes(t) && plantilla?.elecciones.some((e) => e.tipo_eleccion === t)
        );
        if (pend) setTab(pend);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setEnviando(false);
    }
  };

  const tarjetaCandidato = (o: OrgColumna) => {
    const v = dig?.votos[o.numero] ?? null;
    return (
      <div key={o.numero} className="flex items-center gap-3 rounded-xl border border-slate-200 bg-white p-3 shadow-xs">
        {o.logo_url ? (
          <img src={o.logo_url} alt={o.nombre} className="h-11 w-11 shrink-0 rounded-lg object-contain bg-slate-50" />
        ) : (
          <span
            className="flex h-11 w-11 shrink-0 items-center justify-center rounded-lg text-lg font-black text-white"
            style={{ backgroundColor: o.color ?? "#E02020" }}
          >
            {o.numero}
          </span>
        )}
        <div className="min-w-0 flex-1">
          {/* Dualidad obligatoria: candidato + agrupación */}
          <p className="truncate text-[15px] font-black text-slate-900">{o.candidato}</p>
          <p className="truncate text-xs font-semibold text-slate-500">{o.nombre}</p>
          {calculo.validos > 0 && (
            <div className="mt-1 h-1.5 overflow-hidden rounded-full bg-slate-100">
              <div
                className="h-full rounded-full"
                style={{ width: `${calculo.pct[o.numero] ?? 0}%`, backgroundColor: o.color ?? "#E02020" }}
              />
            </div>
          )}
        </div>
        <div className="shrink-0 text-right">
          {calculo.validos > 0 && (
            <p className="font-mono text-[11px] font-bold text-slate-500">{calculo.pct[o.numero] ?? 0}%</p>
          )}
          <input
            type="number"
            min={0}
            inputMode="numeric"
            value={v ?? ""}
            onChange={(e) => setVoto(o.numero, e.target.value === "" ? null : Math.max(0, Number(e.target.value)))}
            placeholder="0"
            aria-label={`Votos ${o.nombre}`}
            className="mt-0.5 h-12 w-24 rounded-xl border-2 border-slate-300 text-center font-mono text-xl font-black text-[#E02020] focus:border-[#E02020] focus:outline-none"
          />
        </div>
      </div>
    );
  };

  return (
    <div className="mx-auto max-w-3xl space-y-5">
      {/* Encabezado oficial */}
      <div className="rounded-2xl bg-[#E02020] p-5 text-center text-white shadow">
        <p className="text-[11px] font-bold uppercase tracking-[0.25em] text-white/70">
          República del Perú · ONPE · Provincia de Arequipa
        </p>
        <h2 className="mt-1 text-xl font-black uppercase tracking-wider">Acta de Escrutinio</h2>
      </div>

      {/* Identificación: distrito + mesa + hábiles */}
      <section className="rounded-2xl border border-slate-200 bg-white p-5">
        <div className="grid gap-3 md:grid-cols-3">
          <label className="text-xs font-bold text-slate-600">
            Distrito (109 · 8 provincias)
            <select value={ubigeoSel} onChange={(e) => { setUbigeoSel(e.target.value); setMesa(""); }}
              className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2.5 text-sm font-semibold">
              <option value="">— elegir distrito —</option>
              {(() => {
                const grupos = new Map<string, { nombre: string; items: Distrito[] }>();
                for (const d of distritos) {
                  const g = grupos.get(d.provincia) ?? { nombre: d.provincia_nombre, items: [] };
                  g.items.push(d);
                  grupos.set(d.provincia, g);
                }
                return [...grupos.entries()].map(([prov, g]) => (
                  <optgroup key={prov} label={g.nombre}>
                    {g.items.map((d) => (
                      <option key={d.ubigeo} value={d.ubigeo}>
                        {d.distrito} ({d.mesas} mesas)
                      </option>
                    ))}
                  </optgroup>
                ));
              })()}
            </select>
          </label>
          <label className="text-xs font-bold text-slate-600">
            N° Mesa (6 dígitos)
            <input value={mesa} inputMode="numeric" maxLength={6}
              onChange={(e) => setMesa(e.target.value.replace(/\D/g, ""))}
              placeholder="023001"
              className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2.5 font-mono text-lg tracking-[0.2em]" />
          </label>
          <label className="text-xs font-bold text-slate-600">
            Electores hábiles
            <input type="number" min={1} value={habilesInput ?? ""}
              onChange={(e) => setHabilesInput(e.target.value === "" ? null : Number(e.target.value))}
              placeholder="del padrón"
              className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2.5 font-mono text-lg font-black text-[#E02020]" />
          </label>
        </div>

        {mesas.length > 0 && (
          <div className="mt-3 flex max-h-36 flex-wrap gap-1.5 overflow-y-auto rounded-lg bg-slate-50 p-2">
            {mesas.map((m) => (
              <button key={m.numero_mesa}
                onClick={() => { setMesa(m.numero_mesa); void cargarMesa(m.numero_mesa); }}
                title={`${m.local} · ${m.electores_habiles ?? "?"} hábiles`}
                className={`rounded px-2 py-1 font-mono text-xs font-bold ${
                  mesa === m.numero_mesa ? "bg-[#E02020] text-white" : "bg-white text-slate-600 hover:bg-slate-200"}`}>
                {m.numero_mesa}
              </button>
            ))}
          </div>
        )}

        <div className="mt-3 flex flex-wrap items-center gap-3">
          <button onClick={() => void cargarMesa(mesa)} disabled={cargando || !/^\d{6}$/.test(mesa)}
            className="rounded-lg bg-[#E02020] px-5 py-2.5 text-sm font-bold text-white disabled:opacity-50">
            {cargando ? "Buscando…" : "Cargar acta"}
          </button>

          {/* Evidencia fotográfica del acta: se sube aquí y se asocia al registrar */}
          <button onClick={() => fotoRef.current?.click()} disabled={subiendoFoto}
            className="rounded-lg border-2 border-[#E02020] px-4 py-2 text-sm font-bold text-[#E02020] disabled:opacity-50">
            {subiendoFoto ? "⏳ Subiendo…" : fotoUrl ? "📷 Cambiar foto" : "📷 Cargar foto del acta"}
          </button>
          <input ref={fotoRef} type="file" accept="image/*" capture="environment" className="hidden"
            onChange={(e) => { const f = e.target.files?.[0]; if (f) void subirFoto(f); }} />

          {plantilla && (
            <p className="text-xs text-slate-500">
              <strong>{plantilla.local.nombre}</strong> · padrón: {plantilla.electores_habiles ?? "—"}
            </p>
          )}
        </div>
        {fotoUrl && (
          <div className="mt-3 flex items-start gap-3 rounded-lg border border-slate-200 bg-white p-2">
            <img src={fotoUrl} alt="Foto del acta cargada"
              className="h-28 w-auto max-w-[45%] cursor-zoom-in rounded border object-contain"
              onClick={() => window.open(fotoUrl, "_blank")} />
            <div className="text-xs text-slate-500">
              <p className="font-bold text-slate-700">Foto lista ✓</p>
              <p>Se asociará a esta mesa al registrar la primera elección.</p>
              <button onClick={() => setFotoUrl(null)}
                className="mt-1 text-[11px] font-bold text-red-600 hover:underline">
                Quitar foto
              </button>
            </div>
          </div>
        )}
        {error && <p className="mt-2 rounded bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">{error}</p>}
        {avisos.map((a, i) => (
          <p key={i} className="mt-2 rounded bg-amber-50 px-3 py-2 text-sm font-semibold text-amber-800">{a}</p>
        ))}
      </section>

      {checklist && (
        <section className={`rounded-2xl border-2 p-4 ${
          checklist.puede_registrar ? "border-emerald-500 bg-emerald-50" : "border-amber-500 bg-amber-50"
        }`}>
          <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
            <h3 className="text-xs font-black uppercase tracking-wider text-slate-700">
              Check de validación · Mesa {checklist.numero_mesa}
            </h3>
            {!checklist.presencia_validada && (
              <button onClick={hacerCheckin} disabled={localizando}
                className="rounded-lg bg-[#E02020] px-4 py-2 text-xs font-black uppercase tracking-wider text-white disabled:opacity-50">
                {localizando ? "Localizando…" : "📍 Registrar check-in"}
              </button>
            )}
          </div>
          <ul className="space-y-1.5">
            {checklist.items.map((it) => (
              <li key={it.clave} className="flex items-start gap-2 text-xs">
                <span className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-[11px] font-black text-white ${
                  it.ok ? "bg-emerald-600" : "bg-red-600"}`}>
                  {it.ok ? "✓" : "✗"}
                </span>
                <span>
                  <strong>{it.etiqueta}.</strong>{" "}
                  <span className="text-slate-600">{it.detalle}</span>
                </span>
              </li>
            ))}
          </ul>
          {!checklist.puede_registrar && (
            <p className="mt-2 text-xs font-bold text-amber-800">
              Completa los checks pendientes para habilitar el registro
              (el servidor también lo exige).
            </p>
          )}
        </section>
      )}

      {plantilla && eleccion && columna && dig && (
        <>
          {/* Tabs en orden oficial */}
          <div className="grid grid-cols-4 gap-2">
            {ORDEN_OFICIAL.filter((t) => plantilla.elecciones.some((e) => e.tipo_eleccion === t)).map((t, i) => (
              <button key={t} onClick={() => setTab(t)}
                className={`rounded-xl px-2 py-3 text-center transition ${
                  tab === t ? "bg-[#E02020] text-white shadow" : "border bg-white text-slate-500"}`}>
                <span className="block text-[10px] font-bold opacity-70">{i + 1}º ELECCIÓN</span>
                <span className="block text-xs font-black uppercase tracking-wider">
                  {t}{registradas.includes(t) ? " ✓" : ""}
                </span>
              </button>
            ))}
          </div>

          <p className="text-xs text-slate-500">{eleccion.cargos}</p>

          {/* Tarjetas por candidato (dualidad + % en vivo) */}
          <div className="space-y-2.5">
            {columna.organizaciones.map(tarjetaCandidato)}
          </div>

          {/* Pie de acta obligatorio */}
          <section className="grid grid-cols-3 gap-2.5">
            {([
              ["blancos", "Votos en Blanco"],
              ["nulos", "Votos Nulos"],
              ["impugnados", "Impugnación de Identidad"],
            ] as const).map(([campo, etiqueta]) => (
              <div key={campo} className="rounded-xl border border-slate-200 bg-white p-3 text-center">
                <p className="mb-1.5 text-[11px] font-black uppercase tracking-wide text-slate-600">{etiqueta}</p>
                <input type="number" min={0} inputMode="numeric"
                  value={dig[campo] ?? ""}
                  onChange={(e) => setCampo(campo, e.target.value === "" ? null : Math.max(0, Number(e.target.value)))}
                  placeholder="0"
                  className="h-12 w-full rounded-xl border-2 border-slate-300 text-center font-mono text-xl font-black focus:border-[#E02020] focus:outline-none" />
              </div>
            ))}
          </section>

          {/* Total automático + override del papel */}
          <section className="rounded-2xl border-2 border-slate-200 bg-white p-4">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <p className="text-[11px] font-black uppercase tracking-wider text-slate-500">
                  Total de votos emitidos (automático)
                </p>
                <p className="font-mono text-3xl font-black text-[#E02020]">{calculo.total}</p>
                <p className="text-[11px] text-slate-400">
                  válidos {calculo.validos} + blancos {dig.blancos ?? "—"} + nulos {dig.nulos ?? "—"} + impugnados {dig.impugnados ?? "—"}
                </p>
              </div>
              <label className="text-xs font-bold text-slate-600">
                Total del papel (si difiere)
                <input type="number" min={0} value={dig.overrideTotal ?? ""}
                  onChange={(e) => setCampo("overrideTotal", e.target.value === "" ? null : Number(e.target.value))}
                  placeholder="= automático"
                  className="mt-1 block w-32 rounded border border-slate-300 px-2 py-1.5 text-right font-mono" />
              </label>
            </div>
          </section>

          {/* Banner ACTA OBSERVADA */}
          {excedePadron && (
            <div className="rounded-2xl border-2 border-red-600 bg-red-600 p-4 text-white shadow">
              <p className="text-lg font-black uppercase tracking-wider">⛔ Acta observada</p>
              <p className="mt-1 text-sm font-semibold">
                Total emitido ({totalReferencia}) supera electores hábiles ({habiles}).
                Revisa la digitación: el envío está deshabilitado.
              </p>
            </div>
          )}

          <div className="sticky bottom-0 -mx-1 flex items-center justify-between gap-3 rounded-2xl border border-slate-200 bg-white/95 p-3 shadow-lg backdrop-blur">
            <p className="text-xs text-slate-500">
              Σ {totalReferencia} · {habiles} hábiles
              <span className="block font-bold">
                {registradas.length}/{plantilla.elecciones.length} niveles
                {checklist && !checklist.puede_registrar ? " · check pendiente" : ""}
              </span>
            </p>
            <div className="flex gap-3">
              <button onClick={onCancelar}
                className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-bold text-slate-600">
                Cancelar
              </button>
              <button onClick={() => void registrar()}
                disabled={enviando || incompleto || excedePadron || (checklist ? !checklist.puede_registrar : false)}
                title={
                  excedePadron ? "ACTA OBSERVADA: total supera el padrón"
                  : incompleto ? "Completa todos los campos (organizaciones + pie de acta)"
                  : checklist && !checklist.puede_registrar ? "Check de validación pendiente (presencia/padrón/oferta)" : undefined
                }
                className="rounded-lg bg-[#E02020] px-6 py-2.5 text-sm font-black uppercase tracking-wider text-white disabled:opacity-40">
                {enviando ? "Registrando…" : `Registrar ${tab}`}
              </button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
