import { useCallback, useMemo, useState } from "react";
import type { ColumnaActa, PlantillaActa } from "./ActaIngresoForm";
import { sesionGuardada } from "../api";

/* ==================================================================== *
 *  FormularioActa — Réplica de la ficha de escrutinio ONPE
 *
 *  Encabezado oficial (ubigeo, N° mesa, electores hábiles), pestañas por
 *  nivel (REGIONAL / PROVINCIAL / DISTRITAL), tabla de partidos con campo
 *  numérico por organización y filas fijas de votos especiales (blancos,
 *  nulos, impugnación de identidad). Validación reactiva R1/R2 con alerta
 *  roja e inhibición del envío si total_emitidos > electores_hábiles.
 *  Registra con POST /api/v1/actas/registrar (NORMAL / OBSERVADA / IMPUGNADA).
 * ==================================================================== */

interface VotosNivel {
  votos: Record<number, number | null>;
  blancos: number | null;
  nulos: number | null;
  impugnados: number | null;
  totalEmitidos: number | null;
}

interface Props {
  onGuardada: () => void;
  onCancelar: () => void;
}

async function sha256(file: File): Promise<string | null> {
  try {
    const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
    return Array.from(new Uint8Array(digest))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
  } catch {
    return null;
  }
}

function authHeaders(): Record<string, string> {
  const s = sesionGuardada();
  return s ? { Authorization: `Bearer ${s.token}` } : {};
}

export default function FormularioActa({ onGuardada, onCancelar }: Props) {
  const [mesa, setMesa] = useState("");
  const [plantilla, setPlantilla] = useState<PlantillaActa | null>(null);
  const [tab, setTab] = useState<string | null>(null);
  const [votos, setVotos] = useState<Record<string, VotosNivel>>({});

  const [fotoHash, setFotoHash] = useState<string | null>(null);
  const [fotoNombre, setFotoNombre] = useState<string | null>(null);
  const [impugnada, setImpugnada] = useState(false);
  const [motivo, setMotivo] = useState("");

  const [cargando, setCargando] = useState(false);
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [estado, setEstado] = useState<{ estado: string; mensaje: string } | null>(null);

  const vacio = useCallback((col: ColumnaActa): VotosNivel => ({
    votos: Object.fromEntries(col.organizaciones.map((o) => [o.numero, o.votos])),
    blancos: col.votos_blancos,
    nulos: col.votos_nulos,
    impugnados: col.votos_impugnados,
    totalEmitidos: col.total_votantes_papel,
  }), []);

  const cargarMesa = useCallback(async () => {
    const numero = mesa.trim();
    if (!/^\d{6}$/.test(numero)) {
      setError("El N° de mesa debe tener 6 dígitos.");
      return;
    }
    setCargando(true);
    setError(null);
    setEstado(null);
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
      if (!res.ok) throw new Error(`Error ${res.status} al cargar la plantilla`);
      const data = (await res.json()) as PlantillaActa;
      setPlantilla(data);
      const inicial: Record<string, VotosNivel> = {};
      for (const e of data.elecciones) {
        // El registro v1 consolida la columna principal del acta física.
        const principal = e.columnas.find((c) => c.es_principal) ?? e.columnas[0];
        if (principal) inicial[e.tipo_eleccion] = vacio(principal);
      }
      setVotos(inicial);
      setTab(data.elecciones[0]?.tipo_eleccion ?? null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setPlantilla(null);
    } finally {
      setCargando(false);
    }
  }, [mesa, vacio]);

  const eleccionActiva = useMemo(
    () => plantilla?.elecciones.find((e) => e.tipo_eleccion === tab) ?? null,
    [plantilla, tab]
  );
  const digitado = tab ? votos[tab] : undefined;
  const habiles = plantilla?.electores_habiles ?? 0;

  const { sumaOrgs, sumaPartes, diferencia, excedePadron, descuadre } = useMemo(() => {
    if (!eleccionActiva || !digitado) {
      return { sumaOrgs: 0, sumaPartes: 0, diferencia: null as number | null, excedePadron: false, descuadre: false };
    }
    const col = eleccionActiva.columnas[0];
    const sOrgs = col.organizaciones.reduce((s, o) => s + (digitado.votos[o.numero] ?? 0), 0);
    const sPartes = sOrgs + (digitado.blancos ?? 0) + (digitado.nulos ?? 0) + (digitado.impugnados ?? 0);
    const total = digitado.totalEmitidos;
    return {
      sumaOrgs: sOrgs,
      sumaPartes: sPartes,
      diferencia: total === null || total === undefined ? null : total - sPartes,
      excedePadron: total !== null && total !== undefined && habiles > 0 && total > habiles,
      descuadre: total !== null && total !== undefined && total > 0 && sPartes !== total,
    };
  }, [eleccionActiva, digitado, habiles]);

  const setVotoOrg = (numero: number, valor: number | null) => {
    if (!tab) return;
    setVotos((p) => ({ ...p, [tab]: { ...p[tab], votos: { ...p[tab].votos, [numero]: valor } } }));
  };
  const setCampo = (campo: "blancos" | "nulos" | "impugnados" | "totalEmitidos", valor: number | null) => {
    if (!tab) return;
    setVotos((p) => ({ ...p, [tab]: { ...p[tab], [campo]: valor } }));
  };

  const bloqueado = !eleccionActiva || !digitado || enviando || excedePadron || digitado.totalEmitidos === null;

  const registrar = async () => {
    if (!plantilla || !eleccionActiva || !digitado || digitado.totalEmitidos === null) return;
    setEnviando(true);
    setError(null);
    setEstado(null);
    try {
      const res = await fetch("/api/v1/actas/registrar", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({
          numero_mesa: plantilla.numero_mesa,
          tipo_eleccion: eleccionActiva.tipo_eleccion,
          votos: Object.fromEntries(
            Object.entries(digitado.votos).map(([k, v]) => [k, v ?? 0])
          ),
          votos_blancos: digitado.blancos ?? 0,
          votos_nulos: digitado.nulos ?? 0,
          votos_impugnados: digitado.impugnados ?? 0,
          total_emitidos: digitado.totalEmitidos,
          impugnada,
          motivo_impugnacion: motivo.trim() || null,
          foto_hash_sha256: fotoHash,
        }),
      });
      const body = await res.json();
      if (!res.ok) {
        const detalle = typeof body?.detail === "string" ? body.detail : `Error ${res.status}`;
        setError(`No se registró: ${detalle}`);
        return;
      }
      const est: string = body.estado;
      setEstado({
        estado: est,
        mensaje:
          est === "NORMAL"
            ? `Acta ${eleccionActiva.tipo_eleccion} registrada y contabilizada.`
            : est === "IMPUGNADA"
              ? "Acta registrada como IMPUGNADA: queda para resolución."
              : `Acta registrada como OBSERVADA (diferencia ${body.diferencia}): queda para revisión del coordinador.`,
      });
      onGuardada();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setEnviando(false);
    }
  };

  const inputNum = (
    valor: number | null,
    onChange: (v: number | null) => void,
    ancho = "w-20"
  ) => (
    <input
      type="number"
      min={0}
      value={valor ?? ""}
      onChange={(e) => onChange(e.target.value === "" ? null : Math.max(0, Number(e.target.value)))}
      placeholder="—"
      className={`${ancho} rounded border border-slate-300 px-2 py-1.5 text-right font-mono text-sm focus:border-[#E02020] focus:outline-none`}
    />
  );

  return (
    <div className="mx-auto max-w-3xl space-y-5">
      {/* Encabezado oficial */}
      <div className="rounded-2xl bg-[#E02020] p-5 text-center text-white shadow">
        <p className="text-[11px] font-bold uppercase tracking-[0.25em] text-white/70">
          República del Perú · ONPE
        </p>
        <h2 className="mt-1 text-xl font-black uppercase tracking-wider">Acta de Escrutinio</h2>
        <p className="mt-1 text-xs text-white/80">Elecciones Regionales y Municipales · Arequipa 2026</p>
      </div>

      {/* Identificación */}
      <section className="rounded-2xl border border-slate-200 bg-white p-5">
        <div className="grid gap-3 md:grid-cols-4">
          <label className="text-xs font-bold text-slate-600">
            Departamento
            <input value="AREQUIPA" disabled className="mt-1 w-full rounded border bg-slate-50 px-3 py-2 text-sm font-bold" />
          </label>
          <label className="text-xs font-bold text-slate-600">
            Ubigeo distrito
            <input value={plantilla?.ubigeo_distrito ?? "—"} disabled
              className="mt-1 w-full rounded border bg-slate-50 px-3 py-2 font-mono text-sm" />
          </label>
          <label className="text-xs font-bold text-slate-600">
            N° Mesa
            <input value={mesa} inputMode="numeric" maxLength={6}
              onChange={(e) => setMesa(e.target.value.replace(/\D/g, ""))}
              placeholder="023001"
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2 font-mono text-sm tracking-widest" />
          </label>
          <label className="text-xs font-bold text-slate-600">
            Electores hábiles
            <input value={plantilla?.electores_habiles ?? "—"} disabled
              className="mt-1 w-full rounded border bg-slate-50 px-3 py-2 font-mono text-sm font-black text-[#E02020]" />
          </label>
        </div>
        <div className="mt-3 flex items-center gap-3">
          <button onClick={cargarMesa} disabled={cargando || !/^\d{6}$/.test(mesa)}
            className="rounded-lg bg-[#E02020] px-5 py-2 text-sm font-bold text-white disabled:opacity-50">
            {cargando ? "Buscando…" : "Cargar mesa"}
          </button>
          {plantilla && (
            <p className="text-xs text-slate-500">
              <strong>{plantilla.local.nombre}</strong>
              {plantilla.local.direccion ? ` · ${plantilla.local.direccion}` : ""}
            </p>
          )}
        </div>
        {error && <p className="mt-2 rounded bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">{error}</p>}
        {estado && (
          <p className={`mt-2 rounded px-3 py-2 text-sm font-semibold ${
            estado.estado === "NORMAL" ? "bg-green-50 text-green-700"
            : estado.estado === "IMPUGNADA" ? "bg-red-50 text-red-700"
            : "bg-amber-50 text-amber-800"}`}>
            [{estado.estado}] {estado.mensaje}
          </p>
        )}
      </section>

      {plantilla && eleccionActiva && digitado && (
        <>
          {/* Pestañas por nivel */}
          <div className="flex flex-wrap gap-2">
            {plantilla.elecciones.map((e) => (
              <button key={e.tipo_eleccion} onClick={() => setTab(e.tipo_eleccion)}
                className={`rounded-lg px-4 py-2 text-xs font-black uppercase tracking-wider ${
                  tab === e.tipo_eleccion ? "bg-[#E02020] text-white" : "border bg-white text-slate-500"}`}>
                {e.tipo_eleccion}
              </button>
            ))}
          </div>

          {/* Tabla de partidos */}
          <section className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
            <div className="bg-slate-100 px-4 py-2 text-xs font-black uppercase tracking-wider text-slate-600">
              {eleccionActiva.cargos ?? eleccionActiva.tipo_eleccion} · Σ organizaciones: {sumaOrgs}
            </div>
            {eleccionActiva.columnas[0].organizaciones.map((o, i) => (
              <div key={o.numero}
                className={`flex items-center gap-3 px-4 py-2 ${i % 2 ? "bg-white" : "bg-slate-50"}`}>
                <span className="w-6 text-right font-mono text-xs text-slate-400">{o.numero}</span>
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-bold text-slate-800">{o.nombre}</p>
                  <p className="truncate text-xs text-slate-500">{o.candidato}</p>
                </div>
                {inputNum(digitado.votos[o.numero] ?? null, (v) => setVotoOrg(o.numero, v))}
              </div>
            ))}
            {/* Filas fijas */}
            {([
              ["blancos", "Votos en Blanco"],
              ["nulos", "Votos Nulos"],
              ["impugnados", "Votos por Impugnación de Identidad"],
            ] as const).map(([campo, etiqueta]) => (
              <div key={campo} className="flex items-center gap-3 border-t border-slate-100 bg-amber-50/40 px-4 py-2">
                <span className="w-6" />
                <p className="flex-1 text-sm font-bold text-slate-700">{etiqueta}</p>
                {inputNum(digitado[campo] ?? null, (v) => setCampo(campo, v))}
              </div>
            ))}
            {/* Total emitidos */}
            <div className="flex items-center gap-3 border-t-2 border-[#E02020] bg-slate-100 px-4 py-3">
              <span className="w-6" />
              <p className="flex-1 text-sm font-black uppercase text-[#E02020]">Total de votos emitidos</p>
              {inputNum(digitado.totalEmitidos, (v) => setCampo("totalEmitidos", v), "w-24")}
            </div>
          </section>

          {/* Validación reactiva */}
          <section className={`rounded-2xl border-2 p-4 ${
            excedePadron || descuadre ? "border-red-500 bg-red-50" : "border-emerald-500 bg-emerald-50"}`}>
            <div className="flex flex-wrap items-center justify-between gap-2 text-sm font-bold">
              <span>
                Σ válidos+blancos+nulos+impugnados: <span className="font-mono">{sumaPartes}</span>
              </span>
              <span className={diferencia === 0 ? "text-emerald-700" : "text-red-700"}>
                Diferencia: <span className="font-mono text-lg">
                  {diferencia === null ? "—" : diferencia > 0 ? `+${diferencia}` : diferencia}
                </span>
              </span>
            </div>
            {descuadre && (
              <p className="mt-1 text-xs font-bold text-red-700">
                ⚠ R1: la suma no cuadra con el total emitido. Se registrará como OBSERVADA.
              </p>
            )}
            {excedePadron && (
              <p className="mt-1 text-xs font-black text-red-700">
                ⛔ R2: total emitido ({digitado.totalEmitidos}) supera electores hábiles ({habiles}). Envío inhibido.
              </p>
            )}
          </section>

          {/* Evidencia e impugnación */}
          <section className="grid gap-3 md:grid-cols-2">
            <div className="rounded-2xl border border-slate-200 bg-white p-4">
              <span className="text-xs font-bold text-slate-600">Foto del acta (opcional)</span>
              <input type="file" accept="image/*" capture="environment"
                onChange={async (e) => {
                  const f = e.target.files?.[0] ?? null;
                  setFotoNombre(f?.name ?? null);
                  setFotoHash(f ? await sha256(f) : null);
                }}
                className="mt-2 w-full text-xs text-slate-500 file:mr-2 file:rounded file:border-0 file:bg-[#E02020] file:px-3 file:py-1.5 file:text-xs file:font-bold file:text-white" />
              {fotoNombre && <p className="mt-1 truncate text-[11px] text-slate-500">{fotoNombre}</p>}
            </div>
            <div className="rounded-2xl border border-slate-200 bg-white p-4">
              <label className="flex items-center gap-2 text-xs font-bold text-slate-700">
                <input type="checkbox" checked={impugnada} onChange={(e) => setImpugnada(e.target.checked)} />
                Acta impugnada (disconformidad en el papel)
              </label>
              {impugnada && (
                <textarea value={motivo} onChange={(e) => setMotivo(e.target.value)} rows={2}
                  placeholder="Motivo de la impugnación…"
                  className="mt-2 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
              )}
            </div>
          </section>

          <div className="flex justify-end gap-3">
            <button onClick={onCancelar}
              className="rounded-lg border border-slate-300 px-4 py-2 text-sm font-bold text-slate-600">
              Cancelar
            </button>
            <button onClick={registrar} disabled={bloqueado}
              title={excedePadron ? "R2: total emitido supera el padrón" : undefined}
              className="rounded-lg bg-[#E02020] px-6 py-2 text-sm font-bold text-white disabled:opacity-50">
              {enviando ? "Registrando…" : `Registrar ${eleccionActiva.tipo_eleccion}`}
            </button>
          </div>
        </>
      )}
    </div>
  );
}
