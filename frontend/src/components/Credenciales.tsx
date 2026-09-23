import { useEffect, useState } from "react";
import { api, type PersoneroEquipo } from "../api";
import type { CredencialData, DistritoOpt, QrVerificacion } from "../types";

/* ==================================================================== *
 *  Credenciales Fuerza Arequipeña — fotocheck 90×140mm (vista 320×500).
 *
 *  Paleta: rojo carmesí #b91c1c, blanco, azul arequipeño #0B2C6B.
 *  Individual: selector personero+mesa → previsualización → PDF/Imprimir.
 *  Masivo: distrito → PDF multipágina. Verificación QR para el Digitador.
 * ==================================================================== */

function descargarBlob(blob: Blob, nombre: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = nombre;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
}

function TarjetaCredencial({ data }: { data: CredencialData }) {
  const a = data.asignacion;
  return (
    <div id="credencial-print" className="flex h-[500px] w-[320px] flex-col overflow-hidden rounded-xl bg-white shadow-2xl ring-1 ring-slate-900/10">
      {/* Cabecera carmesí */}
      <div className="bg-[#b91c1c] px-4 pb-2 pt-3 text-center text-white">
        <p className="text-lg font-black tracking-wide">{data.partido}</p>
        <p className="text-[9px] font-bold uppercase tracking-[0.18em]">Elecciones regionales y municipales</p>
        <p className="text-[9px] font-semibold text-white/85">Arequipa 2026 · Credencial de personero</p>
      </div>
      <div className="h-1.5 bg-[#0B2C6B]" />
      {/* Identidad */}
      <div className="flex gap-3 px-4 pt-3">
        <div className="relative shrink-0">
          <div className="flex h-[104px] w-[88px] items-center justify-center rounded-lg border-2 border-[#0B2C6B] bg-slate-100">
            <span className="text-3xl font-black text-[#0B2C6B]">{data.foto_iniciales}</span>
          </div>
          <span className="absolute -right-2 -top-2 flex h-7 w-7 items-center justify-center rounded-full bg-[#b91c1c] text-[10px] font-black text-white ring-2 ring-white">
            FA
          </span>
        </div>
        <div className="min-w-0 flex-1">
          <p className="text-[9px] font-black uppercase tracking-wider text-slate-400">Nombres y apellidos</p>
          <p className="truncate text-sm font-black leading-tight text-slate-900">{data.nombres}</p>
          <p className="truncate text-sm font-black leading-tight text-slate-900">{data.apellidos}</p>
          <p className="mt-1 text-[9px] font-black uppercase tracking-wider text-slate-400">DNI</p>
          <p className="font-mono text-base font-black tabular-nums text-slate-900">{data.dni}</p>
        </div>
      </div>
      {/* Asignación */}
      <div className="space-y-1 px-4 pt-2">
        <p className="text-[9px] font-black uppercase tracking-wider text-[#0B2C6B]">Distrito</p>
        <p className="-mt-0.5 truncate text-sm font-black text-slate-900">{a.distrito}</p>
        <p className="text-[9px] font-black uppercase tracking-wider text-[#0B2C6B]">Local de votación</p>
        <p className="-mt-0.5 truncate text-sm font-black text-slate-900">{a.local}</p>
        <p className="truncate text-[11px] text-slate-500">{a.direccion || "—"}</p>
        <div className="flex items-end justify-between pt-1">
          <div>
            <p className="text-[9px] font-black uppercase tracking-wider text-[#b91c1c]">N° de mesa</p>
            <p className="font-mono text-3xl font-black tabular-nums text-[#b91c1c]">{a.mesa}</p>
          </div>
          <p className="text-[10px] font-bold text-slate-500">{a.tipo} · {a.estado}</p>
        </div>
      </div>
      {/* QR + firma */}
      <div className="mt-auto flex items-end gap-3 px-4 pb-2">
        <div className="text-center">
          <img src={data.qr_imagen} alt="QR de verificación"
            className="h-[88px] w-[88px] rounded border border-slate-200" />
          <p className="mt-0.5 text-[8px] font-semibold text-slate-500">Escanee para verificar</p>
        </div>
        <div className="flex-1 pb-1 text-center">
          <div className="border-b border-slate-400" style={{ height: 28 }} />
          <p className="mt-1 text-[9px] font-bold text-slate-600">Firma Personero Legal</p>
          <p className="text-[9px] font-black text-[#b91c1c]">FUERZA AREQUIPEÑA</p>
        </div>
      </div>
      <div className="bg-[#0B2C6B] px-4 py-1.5 text-center text-white">
        <p className="font-mono text-[8px]">{data.qr}</p>
      </div>
    </div>
  );
}

export default function Credenciales() {
  const [equipo, setEquipo] = useState<PersoneroEquipo[]>([]);
  const [distritos, setDistritos] = useState<DistritoOpt[]>([]);
  const [pid, setPid] = useState("");
  const [mesa, setMesa] = useState("");
  const [data, setData] = useState<CredencialData | null>(null);
  const [cargando, setCargando] = useState(false);
  const [bajando, setBajando] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [ubigeoBulk, setUbigeoBulk] = useState("");
  const [totalBulk, setTotalBulk] = useState<number | null>(null);
  const [bajandoBulk, setBajandoBulk] = useState(false);

  const [qrTexto, setQrTexto] = useState("");
  const [verif, setVerif] = useState<QrVerificacion | null>(null);
  const [verificando, setVerificando] = useState(false);

  useEffect(() => {
    api.personeros().then(setEquipo).catch(() => setEquipo([]));
    api.distritos().then(setDistritos).catch(() => setDistritos([]));
  }, []);

  const sel = equipo.find((p) => String(p.id) === pid) ?? null;
  const mesasSel = sel?.mesas ?? [];

  const ver = async () => {
    if (!pid) return setError("Elija al personero.");
    setCargando(true);
    setError(null);
    try {
      setData(await api.credencialData(Number(pid), mesa || undefined));
    } catch (e) {
      setData(null);
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCargando(false);
    }
  };

  const bajarPdf = async () => {
    if (!pid) return;
    setBajando(true);
    try {
      descargarBlob(await api.credencialPdf(Number(pid), mesa || undefined),
        `credencial-${data?.dni ?? pid}-${mesa || "mesa"}.pdf`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBajando(false);
    }
  };

  const contarBulk = async (ub: string) => {
    setUbigeoBulk(ub);
    setTotalBulk(null);
    if (!ub) return;
    try {
      setTotalBulk((await api.credencialesDistrito(ub)).total);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const bajarBulk = async () => {
    if (!ubigeoBulk) return;
    setBajandoBulk(true);
    try {
      descargarBlob(await api.credencialesDistritoPdf(ubigeoBulk),
        `credenciales-${ubigeoBulk}.pdf`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBajandoBulk(false);
    }
  };

  const verificar = async () => {
    if (!qrTexto.trim()) return;
    setVerificando(true);
    setVerif(null);
    try {
      setVerif(await api.verificarQr(qrTexto.trim()));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setVerificando(false);
    }
  };

  return (
    <div className="space-y-6">
      <h3 className="text-sm font-black uppercase tracking-wider text-[#E02020]">
        Credenciales Fuerza Arequipeña
      </h3>
      {error && (
        <p className="rounded bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">{error}</p>
      )}

      <div className="grid gap-6 lg:grid-cols-[1fr_auto]">
        {/* Selector + acciones */}
        <div className="space-y-4">
          <section className="rounded-2xl border border-slate-200 bg-white p-5">
            <h4 className="mb-3 text-xs font-black uppercase tracking-wider text-slate-500">
              1 · Personero y mesa
            </h4>
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="text-xs font-bold text-slate-600">Personero
                <select value={pid} onChange={(e) => { setPid(e.target.value); setMesa(""); setData(null); }}
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2">
                  <option value="">— elegir —</option>
                  {equipo.map((p) => (
                    <option key={p.id} value={p.id}>{p.nombre_completo} ({p.dni})</option>
                  ))}
                </select>
              </label>
              <label className="text-xs font-bold text-slate-600">Mesa
                <select value={mesa} onChange={(e) => setMesa(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 font-mono">
                  <option value="">TITULAR vigente</option>
                  {mesasSel.map((m) => (
                    <option key={m.numero_mesa} value={m.numero_mesa}>
                      {m.numero_mesa} · {m.local}
                    </option>
                  ))}
                </select>
              </label>
            </div>
            <div className="mt-3 flex flex-wrap gap-2">
              <button onClick={() => void ver()} disabled={cargando || !pid}
                className="rounded-xl bg-[#0B2C6B] px-5 py-2.5 text-xs font-black uppercase tracking-wider text-white disabled:opacity-50">
                {cargando ? "Cargando…" : "👁 Previsualizar"}
              </button>
              <button onClick={() => void bajarPdf()} disabled={bajando || !data}
                className="rounded-xl bg-[#b91c1c] px-5 py-2.5 text-xs font-black uppercase tracking-wider text-white disabled:opacity-50">
                {bajando ? "Generando…" : "⬇ Descargar PDF"}
              </button>
              <button onClick={() => window.print()} disabled={!data}
                className="rounded-xl border border-slate-300 px-5 py-2.5 text-xs font-black uppercase tracking-wider text-slate-600 disabled:opacity-50">
                🖨 Imprimir
              </button>
            </div>
          </section>

          {/* Bulk por distrito */}
          <section className="rounded-2xl border border-slate-200 bg-white p-5">
            <h4 className="mb-3 text-xs font-black uppercase tracking-wider text-slate-500">
              2 · Descarga masiva por distrito (PDF multipágina)
            </h4>
            <div className="flex flex-wrap items-end gap-3">
              <label className="min-w-52 flex-1 text-xs font-bold text-slate-600">Distrito
                <select value={ubigeoBulk} onChange={(e) => void contarBulk(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2">
                  <option value="">— elegir —</option>
                  {distritos.map((d) => (
                    <option key={d.ubigeo} value={d.ubigeo}>
                      {d.distrito} ({d.provincia_nombre}) · {d.mesas} mesas
                    </option>
                  ))}
                </select>
              </label>
              <button onClick={() => void bajarBulk()}
                disabled={bajandoBulk || !ubigeoBulk || totalBulk === 0}
                className="rounded-xl bg-[#b91c1c] px-5 py-2.5 text-xs font-black uppercase tracking-wider text-white disabled:opacity-50">
                {bajandoBulk ? "Generando…" : `⬇ PDF del distrito${totalBulk != null ? ` (${totalBulk})` : ""}`}
              </button>
            </div>
          </section>

          {/* Verificador QR */}
          <section className="rounded-2xl border border-slate-200 bg-white p-5">
            <h4 className="mb-3 text-xs font-black uppercase tracking-wider text-slate-500">
              3 · Verificar QR escaneado
            </h4>
            <div className="flex flex-col gap-2 sm:flex-row">
              <input value={qrTexto} onChange={(e) => setQrTexto(e.target.value)}
                placeholder="FA-AREQUIPA|DNI|MESA|firma" spellCheck={false}
                className="min-w-0 flex-1 rounded-lg border border-slate-300 px-3 py-2 font-mono text-xs" />
              <button onClick={() => void verificar()} disabled={verificando || !qrTexto.trim()}
                className="rounded-xl bg-emerald-700 px-5 py-2.5 text-xs font-black uppercase tracking-wider text-white disabled:opacity-50">
                {verificando ? "Verificando…" : "✓ Validar"}
              </button>
            </div>
            {verif && (
              <div className={`mt-3 rounded-xl px-4 py-3 text-sm font-bold ${
                verif.valida ? "bg-emerald-50 text-emerald-800" : "bg-red-50 text-red-700"}`}>
                {verif.valida
                  ? `✓ Válida — ${verif.personero} · Mesa ${verif.numero_mesa} · ${verif.local} (${verif.distrito}) · ${verif.motivo}`
                  : `✕ Inválida — ${verif.motivo ?? "rechazada"}`}
              </div>
            )}
          </section>
        </div>

        {/* Previsualización 320×500 */}
        <div className="flex flex-col items-center gap-2">
          {data ? <TarjetaCredencial data={data} /> : (
            <div className="flex h-[500px] w-[320px] items-center justify-center rounded-xl border border-dashed border-slate-300 bg-slate-50 p-6 text-center text-sm text-slate-400">
              Elija un personero y pulse Previsualizar.
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
