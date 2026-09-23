import { useCallback, useEffect, useMemo, useState } from "react";
import { api } from "../api";
import type { ActaEstado, ActaRecord, DistritoOpt, LocalOpt,
  ProvinciaOpt, ResumenStatus } from "../types";
import ActaDetailModal from "./ActaDetailModal";
import ActaEditModal from "./ActaEditModal";

/* ==================================================================== *
 *  Gestión de Actas — búsqueda, filtros en cascada y KPIs en vivo.
 *
 *  Barra: Departamento (fijo AREQUIPA) → Provincia → Distrito → Local
 *  (opcional) → Estado → búsqueda exacta de mesa. Cada cambio actualiza
 *  las tarjetas (totales del ámbito) y la tabla paginada en UNA llamada:
 *  GET /api/v1/actas/resumen-status. El Digitador Global (y SUPER_ADMIN)
 *  consultan cualquier combinación sin restricciones de alcance.
 * ==================================================================== */

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
};

function pct(n: number, total: number): string {
  return total > 0 ? `${((100 * n) / total).toFixed(1)}%` : "—";
}

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

function Kpi({ etiqueta, valor, sub, color }: {
  etiqueta: string; valor: string; sub: string; color: string;
}) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-xs">
      <p className="text-[11px] font-black uppercase tracking-wider text-slate-500">{etiqueta}</p>
      <p className={`mt-1 font-mono text-2xl font-black tabular-nums ${color}`}>{valor}</p>
      <p className="mt-0.5 font-mono text-[11px] tabular-nums text-slate-400">{sub}</p>
    </div>
  );
}

function Select({ etiqueta, value, onChange, disabled, children }: {
  etiqueta: string; value: string; onChange: (v: string) => void;
  disabled?: boolean; children: React.ReactNode;
}) {
  return (
    <label className="flex min-w-0 flex-1 flex-col gap-1 text-[11px] font-black uppercase tracking-wider text-slate-500">
      {etiqueta}
      <select
        value={value}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
        className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-xs font-bold normal-case tracking-normal text-slate-700 disabled:bg-slate-100 disabled:text-slate-400"
      >
        {children}
      </select>
    </label>
  );
}

export default function GestionActas({ onCargarMesa }: {
  /** Mesa pendiente que el Digitador quiere cargar (la abre el panel padre). */
  onCargarMesa?: (mesa: string) => void;
}) {
  const [provincias, setProvincias] = useState<ProvinciaOpt[]>([]);
  const [distritos, setDistritos] = useState<DistritoOpt[]>([]);
  const [locales, setLocales] = useState<LocalOpt[]>([]);

  const [provincia, setProvincia] = useState("");
  const [distrito, setDistrito] = useState("");
  const [localId, setLocalId] = useState("");
  const [estado, setEstado] = useState<ActaEstado>("todas");
  const [mesa, setMesa] = useState("");
  const [mesaDeb, setMesaDeb] = useState("");
  const [busqueda, setBusqueda] = useState("");
  const [busquedaDeb, setBusquedaDeb] = useState("");
  const [pagina, setPagina] = useState(1);
  const [pageSize, setPageSize] = useState(15);

  const [data, setData] = useState<ResumenStatus | null>(null);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  /* La ficha se abre con el acta (si está registrada) o sólo con la mesa
     (fila PENDIENTE): así "Ver" siempre sirve, antes y después de cargar. */
  const [detalle, setDetalle] = useState<{ acta: ActaRecord | null; mesa: string } | null>(null);
  const [editarActa, setEditarActa] = useState<ActaRecord | null>(null);

  /* Catálogo de provincias (una vez). */
  useEffect(() => {
    api.provincias().then(setProvincias).catch(() => setProvincias([]));
  }, []);

  /* Distritos de la provincia (cascada). */
  useEffect(() => {
    setDistrito("");
    if (!provincia) {
      setDistritos([]);
      return;
    }
    api.distritos(provincia).then(setDistritos).catch(() => setDistritos([]));
  }, [provincia]);

  /* Locales del distrito (cascada). */
  useEffect(() => {
    setLocalId("");
    if (!distrito) {
      setLocales([]);
      return;
    }
    api.localesUbigeo(distrito).then(setLocales).catch(() => setLocales([]));
  }, [distrito]);

  /* Debounce de la búsqueda exacta de mesa. */
  useEffect(() => {
    const t = setTimeout(() => {
      setMesaDeb(mesa.trim());
      setPagina(1);
    }, 400);
    return () => clearTimeout(t);
  }, [mesa]);

  /* Debounce de la búsqueda libre (mesa, local o distrito). */
  useEffect(() => {
    const t = setTimeout(() => {
      setBusquedaDeb(busqueda.trim());
      setPagina(1);
    }, 400);
    return () => clearTimeout(t);
  }, [busqueda]);

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
        busqueda: busquedaDeb.length >= 2 ? busquedaDeb : undefined,
        pagina,
        page_size: pageSize,
      });
      setData(res);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCargando(false);
    }
  }, [provincia, distrito, localId, estado, mesaDeb, busquedaDeb, pagina, pageSize]);

  /* Recarga ante cualquier filtro/página + polling en vivo cada 30 s. */
  useEffect(() => {
    void cargar();
  }, [cargar]);
  useEffect(() => {
    const t = setInterval(() => {
      if (!detalle && !editarActa) void cargar();
    }, 30000);
    return () => clearInterval(t);
  }, [cargar, detalle, editarActa]);

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

  const abrirVer = async (actaId: number | null, numeroMesa: string) => {
    if (actaId == null) {
      setDetalle({ acta: null, mesa: numeroMesa });
      return;
    }
    try {
      setDetalle({ acta: await api.getActa(actaId), mesa: numeroMesa });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const abrirEditar = async (actaId: number | null) => {
    if (actaId == null) return;
    try {
      setEditarActa(await api.getActa(actaId));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const abrirFoto = async (actaId: number | null) => {
    if (actaId == null) return;
    try {
      const a = await api.getActa(actaId);
      if (a.image_url) window.open(a.image_url, "_blank", "noopener");
      else setError("El acta no tiene foto registrada.");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-black uppercase tracking-wider text-[#002B66]">
          Gestión de actas por territorio
        </h3>
        <button
          onClick={() => void cargar()}
          className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs font-bold text-slate-600 hover:bg-slate-50"
        >
          ↻ Actualizar
        </button>
      </div>

      {/* Barra de filtros en cascada */}
      <div className="flex flex-col gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-4 lg:flex-row lg:items-end">
        <Select etiqueta="Departamento" value="AREQUIPA" onChange={() => undefined}>
          <option value="AREQUIPA">AREQUIPA</option>
        </Select>
        <Select etiqueta="Provincia" value={provincia} onChange={selProvincia}>
          <option value="">Todas (8 provincias)</option>
          {provincias.map((p) => (
            <option key={p.provincia} value={p.provincia}>
              {p.nombre} ({p.mesas} mesas)
            </option>
          ))}
        </Select>
        <Select etiqueta="Distrito" value={distrito} onChange={selDistrito} disabled={!provincia}>
          <option value="">{provincia ? "Todos" : "Elija provincia…"}</option>
          {distritos.map((d) => (
            <option key={d.ubigeo} value={d.ubigeo}>
              {d.distrito} ({d.mesas})
            </option>
          ))}
        </Select>
        <Select etiqueta="Local" value={localId} onChange={selLocal} disabled={!distrito}>
          <option value="">{distrito ? "Todos" : "Elija distrito…"}</option>
          {locales.map((l) => (
            <option key={l.id} value={String(l.id)}>
              {l.nombre} ({l.mesas})
            </option>
          ))}
        </Select>
        <Select etiqueta="Estado" value={estado} onChange={(v) => selEstado(v as ActaEstado)}>
          {ESTADOS.map((e) => (
            <option key={e.value} value={e.value}>{e.etiqueta}</option>
          ))}
        </Select>
        <label className="flex min-w-0 flex-1 flex-col gap-1 text-[11px] font-black uppercase tracking-wider text-slate-500">
          Buscar
          <input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="mesa, local o distrito…"
            className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-xs font-bold text-slate-700"
          />
        </label>
        <label className="flex min-w-0 flex-1 flex-col gap-1 text-[11px] font-black uppercase tracking-wider text-slate-500">
          Mesa exacta
          <input
            value={mesa}
            onChange={(e) => setMesa(e.target.value.replace(/\D/g, "").slice(0, 6))}
            placeholder="006528"
            inputMode="numeric"
            className="rounded-lg border border-slate-300 bg-white px-3 py-2 font-mono text-xs font-bold text-slate-700"
          />
        </label>
      </div>

      {error && (
        <p className="rounded bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">{error}</p>
      )}

      {/* Tarjetas KPI del filtro */}
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Kpi etiqueta="Total mesas" valor={String(totales?.total ?? "—")}
          sub={data ? `avance ${totales?.avance_pct ?? 0}%` : "cargando…"} color="text-[#002B66]" />
        <Kpi etiqueta="Registradas" valor={String(totales?.registradas ?? "—")}
          sub={totales ? pct(totales.registradas, totales.total) + " del total" : "cargando…"}
          color="text-emerald-700" />
        <Kpi etiqueta="Pendientes" valor={String(totales?.pendientes ?? "—")}
          sub={totales ? pct(totales.pendientes, totales.total) + " por cargar" : "cargando…"}
          color="text-slate-600" />
        <Kpi etiqueta="Observadas" valor={String(totales?.observadas ?? "—")}
          sub="para rectificar" color="text-amber-600" />
      </div>
      {totales && totales.total > 0 && (
        <div className="flex h-3 w-full overflow-hidden rounded-full bg-slate-100">
          <div className="h-full bg-emerald-500 transition-all"
            style={{ width: `${(100 * totales.registradas) / totales.total}%` }} />
          <div className="h-full bg-amber-500 transition-all"
            style={{ width: `${(100 * totales.observadas) / totales.total}%` }} />
        </div>
      )}

      {/* Tabla de actas */}
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
                    <td className="px-4 py-2.5 font-mono font-black tabular-nums text-[#002B66]">
                      {f.numero_mesa}
                    </td>
                    <td className="px-4 py-2.5 text-xs font-bold text-slate-700">
                      {f.distrito}
                      <span className="block font-mono text-[10px] font-normal text-slate-400">
                        {f.ubigeo}
                      </span>
                    </td>
                    <td className="px-4 py-2.5 text-xs text-slate-600">{f.local}</td>
                    <td className="px-4 py-2.5">
                      <span className={`rounded-full px-2.5 py-1 text-[11px] font-black ${BADGE[f.estado]}`}>
                        {f.estado === "REGISTRADA" ? "Registrada"
                          : f.estado === "OBSERVADA" ? "Observada" : "Pendiente"}
                      </span>
                    </td>
                    <td className="px-4 py-2.5 text-xs text-slate-600">{f.digitador ?? "—"}</td>
                    <td className="px-4 py-2.5 font-mono text-[11px] tabular-nums text-slate-500">
                      {fechaCorta(f.actualizada_en)}
                    </td>
                    <td className="px-4 py-2.5">
                      <div className="flex justify-end gap-1.5">
                        <button onClick={() => void abrirVer(f.acta_id, f.numero_mesa)}
                          className="rounded-lg bg-slate-100 px-2.5 py-1.5 text-[11px] font-bold text-slate-700 hover:bg-slate-200">
                          Ver
                        </button>
                        {f.estado === "PENDIENTE" ? (
                          <button
                            onClick={() => onCargarMesa?.(f.numero_mesa)}
                            className="rounded-lg bg-[#002B66] px-2.5 py-1.5 text-[11px] font-black text-white hover:bg-[#003a8c]"
                          >
                            ⬆ Cargar
                          </button>
                        ) : (
                          <>
                            <button onClick={() => void abrirEditar(f.acta_id)}
                              className="rounded-lg bg-blue-100 px-2.5 py-1.5 text-[11px] font-bold text-blue-800 hover:bg-blue-200">
                              Editar
                            </button>
                            {f.tiene_foto && (
                              <button onClick={() => void abrirFoto(f.acta_id)}
                                title="Abrir la foto en otra pestaña"
                                className="rounded-lg bg-violet-100 px-2.5 py-1.5 text-[11px] font-bold text-violet-800 hover:bg-violet-200">
                                🖼
                              </button>
                            )}
                          </>
                        )}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* Paginación */}
          <div className="flex flex-wrap items-center justify-between gap-3 text-xs font-bold text-slate-600">
            <span>
              {data.total_filas} acta{data.total_filas === 1 ? "" : "s"} · página {data.pagina} de {data.total_paginas}
            </span>
            <div className="flex items-center gap-1.5">
              <button disabled={data.pagina <= 1} onClick={() => setPagina((p) => p - 1)}
                className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 disabled:opacity-40">
                ← Anterior
              </button>
              {paginas.map((p) => (
                <button key={p} onClick={() => setPagina(p)}
                  className={`rounded-lg px-3 py-1.5 ${p === data.pagina
                    ? "bg-[#002B66] text-white" : "border border-slate-300 bg-white"}`}>
                  {p}
                </button>
              ))}
              <button disabled={data.pagina >= data.total_paginas} onClick={() => setPagina((p) => p + 1)}
                className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 disabled:opacity-40">
                Siguiente →
              </button>
              <select value={pageSize} onChange={(e) => { setPageSize(Number(e.target.value)); setPagina(1); }}
                className="ml-2 rounded-lg border border-slate-300 bg-white px-2 py-1.5">
                {[10, 15, 25, 50].map((n) => (
                  <option key={n} value={n}>{n} / pág.</option>
                ))}
              </select>
            </div>
          </div>
        </>
      )}

      {detalle && (
        <ActaDetailModal
          acta={detalle.acta}
          numeroMesa={detalle.mesa}
          onClose={() => setDetalle(null)}
          onEditar={(a) => { setDetalle(null); setEditarActa(a); }}
          onCargar={(m) => onCargarMesa?.(m)}
        />
      )}
      {editarActa && (
        <ActaEditModal
          acta={editarActa}
          onClose={() => setEditarActa(null)}
          onSave={() => { setEditarActa(null); void cargar(); }}
        />
      )}
    </div>
  );
}
