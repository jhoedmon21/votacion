import { useCallback, useMemo, useState } from "react";
import type { ActaRecord, ActaStatusFila, ResumenStatus, ResumenStatusParams, ActaEstado } from "../../types";
import { api } from "../../api";
import { Boton, Input } from "../ui";
import ActaDetailModal from "../ActaDetailModal";
import SideBySideDigitization from "./actas/SideBySideDigitization";
import ActaValidationView from "./actas/ActaValidationView";
import ActaHistoryPanel from "./actas/ActaHistoryPanel";

const ESTADOS: Array<{ value: ActaEstado; etiqueta: string }> = [
  { value: "todas", etiqueta: "Todas" },
  { value: "registradas", etiqueta: "Registradas / Procesadas" },
  { value: "pendientes", etiqueta: "Pendientes / Sin cargar" },
  { value: "observadas", etiqueta: "Con observación / Para rectificar" },
];

const BADGE: Record<string, string> = {
  REGISTRADA: "bg-emerald-100 text-emerald-800",
  PENDIENTE: "bg-slate-200 text-slate-700",
  OBSERVADA: "bg-amber-100 text-amber-800",
  EN_DIGITACION: "bg-red-100 text-red-800",
  DIGITADA: "bg-indigo-100 text-indigo-800",
  EN_REVISION: "bg-yellow-100 text-yellow-800",
  VALIDADA: "bg-emerald-100 text-emerald-800",
  CERRADA: "bg-slate-100 text-slate-700",
};

function fechaCorta(iso: string | null): string {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleString("es-PE", {
      day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit",
    });
  } catch {
    return "—";
  }
}

interface ActaTableProps {
  onEdit?: (acta: ActaRecord) => void;
  onValidate?: (acta: ActaRecord) => void;
  onHistory?: (acta: ActaRecord) => void;
  onView?: (acta: ActaRecord) => void;
}

export default function ActaTable({
  onEdit,
  onValidate,
  onHistory,
  onView,
}: ActaTableProps) {
  const [provincias, setProvincias] = useState<Array<{ provincia: string; nombre: string; mesas: number }>>([]);
  const [distritos, setDistritos] = useState<Array<{ ubigeo: string; distrito: string; mesas: number }>>([]);
  const [locales, setLocales] = useState<Array<{ id: number; nombre: string; mesas: number }>>([]);

  const [provincia, setProvincia] = useState("");
  const [distrito, setDistrito] = useState("");
  const [localId, setLocalId] = useState("");
  const [estado, setEstado] = useState<ActaEstado>("todas");
  const [mesa, setMesa] = useState("");
  const [mesaDeb, setMesaDeb] = useState("");
  const [pagina, setPagina] = useState(1);
  const [pageSize, setPageSize] = useState(15);

  const [data, setData] = useState<ResumenStatus | null>(null);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [verActa, setVerActa] = useState<ActaRecord | null>(null);
  const [editarActa, setEditarActa] = useState<ActaRecord | null>(null);
  const [validarActa, setValidarActa] = useState<ActaRecord | null>(null);
  const [historialActa, setHistorialActa] = useState<ActaRecord | null>(null);

  useEffect(() => {
    api.provincias().then(setProvincias).catch(() => setProvincias([]));
  }, []);

  useEffect(() => {
    setDistrito("");
    if (!provincia) { setDistritos([]); return; }
    api.distritos(provincia).then(setDistritos).catch(() => setDistritos([]));
  }, [provincia]);

  useEffect(() => {
    setLocalId("");
    if (!distrito) { setLocales([]); return; }
    api.localesUbigeo(distrito).then(setLocales).catch(() => setLocales([]));
  }, [distrito]);

  useEffect(() => {
    const t = setTimeout(() => {
      setMesaDeb(mesa.trim());
      setPagina(1);
    }, 400);
    return () => clearTimeout(t);
  }, [mesa]);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      const res = await api.resumenStatus({
        departamento: "AREQUIPA",
        provincia: provincia || undefined,
        distrito: distrito || undefined,
        local_id: localId ? Number(localId) : null,
        estado,
        mesa: /^\d{6}$/.test(mesaDeb) ? mesaDeb : undefined,
        pagina,
        page_size: pageSize,
      });
      setData(res);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCargando(false);
    }
  }, [provincia, distrito, localId, estado, mesaDeb, pagina, pageSize]);

  useEffect(() => { void cargar(); }, [cargar]);
  useEffect(() => {
    const t = setInterval(() => { if (!verActa && !editarActa && !validarActa && !historialActa) void cargar(); }, 30000);
    return () => clearInterval(t);
  }, [cargar, verActa, editarActa, validarActa, historialActa]);

  const selProvincia = (v: string) => { setProvincia(v); setPagina(1); };
  const selDistrito = (v: string) => { setDistrito(v); setPagina(1); };
  const selLocal = (v: string) => { setLocalId(v); setPagina(1); };
  const selEstado = (v: ActaEstado) => { setEstado(v); setPagina(1); };

  const totales = data?.totales;
  const paginas = useMemo(() => {
    const tp = data?.total_paginas ?? 1;
    const pg = data?.pagina ?? 1;
    const ini = Math.max(1, Math.min(pg - 2, tp - 4));
    return Array.from({ length: Math.min(5, tp) }, (_, i) => ini + i);
  }, [data]);

  const abrirVer = async (actaId: number | null) => {
    if (actaId == null) return;
    try { setVerActa(await api.getActa(actaId)); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };

  const abrirEditar = async (actaId: number | null) => {
    if (actaId == null) return;
    try { setEditarActa(await api.getActa(actaId)); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };

  const abrirValidar = async (actaId: number | null) => {
    if (actaId == null) return;
    try { setValidarActa(await api.getActa(actaId)); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };

  const abrirHistorial = async (actaId: number | null) => {
    if (actaId == null) return;
    try { setHistorialActa(await api.getActa(actaId)); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };

  const abrirFoto = async (actaId: number | null) => {
    if (actaId == null) return;
    try {
      const a = await api.getActa(actaId);
      if (a.image_url) window.open(a.image_url, "_blank", "noopener");
      else setError("El acta no tiene foto registrada.");
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-black uppercase tracking-wider text-[#E02020]">Gestión de actas por territorio</h3>
        <button onClick={() => void cargar()} className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs font-bold text-slate-600 hover:bg-slate-50">↻ Actualizar</button>
      </div>

      <div className="flex flex-col gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-4 lg:flex-row lg:items-end">
        <label className="flex min-w-0 flex-1 flex-col gap-1 text-[11px] font-black uppercase tracking-wider text-slate-500">
          Departamento
          <select value="AREQUIPA" onChange={() => undefined} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-xs font-bold normal-case tracking-normal text-slate-700"><option value="AREQUIPA">AREQUIPA</option></select>
        </label>
        <label className="flex min-w-0 flex-1 flex-col gap-1 text-[11px] font-black uppercase tracking-wider text-slate-500">
          Provincia
          <select value={provincia} onChange={(e) => selProvincia(e.target.value)} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-xs font-bold normal-case tracking-normal text-slate-700">
            <option value="">Todas (8 provincias)</option>
            {provincias.map((p) => <option key={p.provincia} value={p.provincia}>{p.nombre} ({p.mesas} mesas)</option>)}
          </select>
        </label>
        <label className="flex min-w-0 flex-1 flex-col gap-1 text-[11px] font-black uppercase tracking-wider text-slate-500">
          Distrito
          <select value={distrito} onChange={(e) => selDistrito(e.target.value)} disabled={!provincia} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-xs font-bold normal-case tracking-normal text-slate-700 disabled:bg-slate-100">
            <option value="">{provincia ? "Todos" : "Elija provincia…"}</option>
            {distritos.map((d) => <option key={d.ubigeo} value={d.ubigeo}>{d.distrito} ({d.mesas})</option>)}
          </select>
        </label>
        <label className="flex min-w-0 flex-1 flex-col gap-1 text-[11px] font-black uppercase tracking-wider text-slate-500">
          Local
          <select value={localId} onChange={(e) => selLocal(e.target.value)} disabled={!distrito} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-xs font-bold normal-case tracking-normal text-slate-700 disabled:bg-slate-100">
            <option value="">{distrito ? "Todos" : "Elija distrito…"}</option>
            {locales.map((l) => <option key={l.id} value={String(l.id)}>{l.nombre} ({l.mesas})</option>)}
          </select>
        </label>
        <label className="flex min-w-0 flex-1 flex-col gap-1 text-[11px] font-black uppercase tracking-wider text-slate-500">
          Estado
          <select value={estado} onChange={(e) => selEstado(e.target.value as ActaEstado)} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-xs font-bold normal-case tracking-normal text-slate-700">
            {ESTADOS.map((e) => <option key={e.value} value={e.value}>{e.etiqueta}</option>)}
          </select>
        </label>
        <label className="flex min-w-0 flex-1 flex-col gap-1 text-[11px] font-black uppercase tracking-wider text-slate-500">
          Mesa exacta
          <Input
            value={mesa}
            onChange={(e) => setMesa(e.target.value.replace(/\D/g, "").slice(0, 6))}
            placeholder="023001"
            inputMode="numeric"
            className="rounded-lg border border-slate-300 bg-white px-3 py-2 font-mono text-xs font-bold text-slate-700"
          />
        </label>
      </div>

      {error && <p className="rounded bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">{error}</p>}

      {totales && (
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-xs">
            <p className="text-[11px] font-black uppercase tracking-wider text-slate-500">Total mesas</p>
            <p className="mt-1 font-mono text-2xl font-black tabular-nums text-[#E02020]">{totales.total.toLocaleString()}</p>
            <p className="mt-0.5 font-mono text-[11px] tabular-nums text-slate-400">avance {totales.avance_pct}%</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-xs">
            <p className="text-[11px] font-black uppercase tracking-wider text-slate-500">Registradas</p>
            <p className="mt-1 font-mono text-2xl font-black tabular-nums text-emerald-700">{totales.registradas.toLocaleString()}</p>
            <p className="mt-0.5 font-mono text-[11px] tabular-nums text-slate-400">{((100 * totales.registradas) / totales.total).toFixed(1)}% del total</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-xs">
            <p className="text-[11px] font-black uppercase tracking-wider text-slate-500">Pendientes</p>
            <p className="mt-1 font-mono text-2xl font-black tabular-nums text-slate-600">{totales.pendientes.toLocaleString()}</p>
            <p className="mt-0.5 font-mono text-[11px] tabular-nums text-slate-400">{((100 * totales.pendientes) / totales.total).toFixed(1)}% por cargar</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-xs">
            <p className="text-[11px] font-black uppercase tracking-wider text-slate-500">Observadas</p>
            <p className="mt-1 font-mono text-2xl font-black tabular-nums text-amber-600">{totales.observadas.toLocaleString()}</p>
            <p className="mt-0.5 font-mono text-[11px] tabular-nums text-slate-400">para rectificar</p>
          </div>
        </div>
      )}

      {totales && totales.total > 0 && (
        <div className="flex h-3 w-full overflow-hidden rounded-full bg-slate-100">
          <div className="h-full bg-emerald-500 transition-all" style={{ width: `${(100 * totales.registradas) / totales.total}%` }} />
          <div className="h-full bg-amber-500 transition-all" style={{ width: `${(100 * totales.observadas) / totales.total}%` }} />
        </div>
      )}

      {cargando && !data ? (
        <p className="py-8 text-center text-sm text-slate-500">Cargando actas…</p>
      ) : !data || data.total_filas === 0 ? (
        <p className="rounded-2xl border border-dashed border-slate-300 bg-white py-8 text-center text-sm text-slate-500">
          Sin actas para este filtro. Ajuste la cascada o limpie la búsqueda de mesa.
        </p>
      ) : (
        <>
          <div className="overflow-x-auto rounded-2xl border border-slate-200 bg-white">
            <table className="w-full text-sm">
              <thead>
                <tr className="bg-slate-50 text-left text-[11px] uppercase tracking-wider text-slate-500">
                  <th className="px-4 py-3">Mesa</th>
                  <th className="px-4 py-3">Distrito</th>
                  <th className="px-4 py-3">Local de votación</th>
                  <th className="px-4 py-3">Estado</th>
                  <th className="px-4 py-3">Digitador</th>
                  <th className="px-4 py-3">Actualización</th>
                  <th className="px-4 py-3 text-right">Acciones</th>
                </tr>
              </thead>
              <tbody>
                {data.filas.map((f) => (
                  <tr key={f.numero_mesa} className="border-t border-slate-100 hover:bg-slate-50">
                    <td className="px-4 py-2.5 font-mono font-black tabular-nums text-[#E02020]">{f.numero_mesa}</td>
                    <td className="px-4 py-2.5 text-xs font-bold text-slate-700">
                      {f.distrito}
                      <span className="block font-mono text-[10px] font-normal text-slate-400">{f.ubigeo}</span>
                    </td>
                    <td className="px-4 py-2.5 text-xs text-slate-600">{f.local}</td>
                    <td className="px-4 py-2.5">
                      <span className={`rounded-full px-2.5 py-1 text-[11px] font-black ${BADGE[f.estado] || "bg-gray-100 text-gray-800"}`}>
                        {f.estado === "REGISTRADA" ? "Registrada" : f.estado === "OBSERVADA" ? "Observada" : "Pendiente"}
                      </span>
                    </td>
                    <td className="px-4 py-2.5 text-xs text-slate-600">{f.digitador ?? "—"}</td>
                    <td className="px-4 py-2.5 font-mono text-[11px] tabular-nums text-slate-500">{fechaCorta(f.actualizada_en)}</td>
                    <td className="px-4 py-2.5">
                      <div className="flex justify-end gap-1.5">
                        {f.estado === "PENDIENTE" ? (
                          <button
                            onClick={() => onEdit?.({ id: f.acta_id!, numero_mesa: f.numero_mesa } as ActaRecord)}
                            className="rounded-lg bg-[#E02020] px-2.5 py-1.5 text-[11px] font-black text-white hover:bg-[#003a8c]"
                          >
                            ⬆ Cargar
                          </button>
                        ) : (
                          <>
                            <button onClick={() => abrirVer(f.acta_id)} className="rounded-lg bg-slate-100 px-2.5 py-1.5 text-[11px] font-bold text-slate-700 hover:bg-slate-200">Ver</button>
                            <button onClick={() => abrirEditar(f.acta_id)} className="rounded-lg bg-red-100 px-2.5 py-1.5 text-[11px] font-bold text-red-800 hover:bg-red-200">Editar</button>
                            <button onClick={() => abrirValidar(f.acta_id)} className="rounded-lg bg-amber-100 px-2.5 py-1.5 text-[11px] font-bold text-amber-800 hover:bg-amber-200">Validar</button>
                            <button onClick={() => abrirHistorial(f.acta_id)} className="rounded-lg bg-violet-100 px-2.5 py-1.5 text-[11px] font-bold text-violet-800 hover:bg-violet-200">Historial</button>
                            {f.tiene_foto && <button onClick={() => abrirFoto(f.acta_id)} className="rounded-lg bg-violet-100 px-2.5 py-1.5 text-[11px] font-bold text-violet-800 hover:bg-violet-200">Foto</button>}
                          </>
                        )}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="flex flex-wrap items-center justify-between gap-3 text-xs font-bold text-slate-600">
            <span>{data.total_filas} acta{data.total_filas === 1 ? "" : "s"} · página {data.pagina} de {data.total_paginas}</span>
            <div className="flex items-center gap-1.5">
              <button disabled={data.pagina <= 1} onClick={() => setPagina((p) => p - 1)} className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 disabled:opacity-40">← Anterior</button>
              {paginas.map((p) => (
                <button key={p} onClick={() => setPagina(p)} className={`rounded-lg px-3 py-1.5 ${p === data.pagina ? "bg-[#E02020] text-white" : "border border-slate-300 bg-white"}`}>{p}</button>
              ))}
              <button disabled={data.pagina >= data.total_paginas} onClick={() => setPagina((p) => p + 1)} className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 disabled:opacity-40">Siguiente →</button>
              <select value={pageSize} onChange={(e) => { setPageSize(Number(e.target.value)); setPagina(1); }} className="ml-2 rounded-lg border border-slate-300 bg-white px-2 py-1.5">
                {[10, 15, 25, 50].map((n) => <option key={n} value={n}>{n} / pág.</option>)}
              </select>
            </div>
          </div>
        </>
      )}

      {verActa && <ActaDetailModal acta={verActa} onClose={() => setVerActa(null)} />}
      {editarActa && <SideBySideDigitization acta={editarActa} onClose={() => setEditarActa(null)} onSave={() => { setEditarActa(null); void cargar(); }} mode="edit" />}
      {validarActa && <ActaValidationView acta={validarActa} onClose={() => setValidarActa(null)} onValidated={() => { setValidarActa(null); void cargar(); }} />}
      {historialActa && <ActaHistoryPanel acta={historialActa} onClose={() => setHistorialActa(null)} />}
    </div>
  );
}