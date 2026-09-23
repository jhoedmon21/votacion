import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { PlantillaActa } from "./ActaIngresoForm";

/* ==================================================================== *
 *  ActaCargaModal — carga/rectificación rápida del acta de una mesa.
 *
 *  1) Foto opcional del acta (POST /api/actas/ocr → image_url, sin guardar).
 *  2) Votos por organización (oferta DISTRITAL de la plantilla) + blancos,
 *     nulos e impugnados, pre-cargados si el acta ya existe.
 *  3) Guardado inmediato: POST /api/actas (nueva) o PUT /api/actas/{id}
 *     (rectificación). Roles con permiso según el backend.
 * ==================================================================== */

interface OrgFila {
  numero: number;
  nombre: string;
  candidato: string;
  votos: number;
}

export default function ActaCargaModal({ mesa, onClose, onSaved }: {
  mesa: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [plantilla, setPlantilla] = useState<PlantillaActa | null>(null);
  const [orgs, setOrgs] = useState<OrgFila[]>([]);
  const [blancos, setBlancos] = useState(0);
  const [nulos, setNulos] = useState(0);
  const [impugnados, setImpugnados] = useState(0);
  const [imageUrl, setImageUrl] = useState<string | null>(null);
  const [confianza, setConfianza] = useState(1.0);
  const [fotoNombre, setFotoNombre] = useState<string | null>(null);
  const [subiendo, setSubiendo] = useState(false);
  const [guardando, setGuardando] = useState(false);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  /* Plantilla + pre-carga de lo ya digitado. */
  useEffect(() => {
    api.plantillaActa(mesa)
      .then((p) => {
        setPlantilla(p);
        const dist = p.elecciones.find((e) => e.tipo_eleccion === "DISTRITAL")
          ?? p.elecciones[0];
        const col = dist?.columnas.find((c) => c.es_principal) ?? dist?.columnas[0];
        setOrgs((col?.organizaciones ?? []).map((o) => ({
          numero: o.numero, nombre: o.nombre, candidato: o.candidato,
          votos: o.votos ?? 0,
        })));
        if (col?.votos_blancos != null) setBlancos(col.votos_blancos);
        if (col?.votos_nulos != null) setNulos(col.votos_nulos);
        if (col?.votos_impugnados != null) setImpugnados(col.votos_impugnados);
      })
      .catch((e) => setError(e instanceof Error ? e.message : String(e)))
      .finally(() => setCargando(false));
  }, [mesa]);

  const totalOrgs = orgs.reduce((s, o) => s + (o.votos || 0), 0);
  const totalEmitidos = totalOrgs + blancos + nulos + impugnados;
  const habiles = plantilla?.electores_habiles ?? null;
  const excedePadron = habiles != null && habiles > 0 && totalEmitidos > habiles;

  const setVoto = (numero: number, v: number) =>
    setOrgs((prev) => prev.map((o) =>
      o.numero === numero ? { ...o, votos: Math.max(0, v || 0) } : o));

  const subirFoto = async () => {
    const f = fileRef.current?.files?.[0];
    if (!f) return;
    setSubiendo(true);
    setError(null);
    try {
      const res = await api.ocrActa(f);
      setImageUrl(res.image_url ?? null);
      if (typeof res.ocr_confidence === "number") setConfianza(res.ocr_confidence);
      setFotoNombre(f.name);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubiendo(false);
      if (fileRef.current) fileRef.current.value = "";
    }
  };

  const guardar = async () => {
    if (!plantilla) return;
    setGuardando(true);
    setError(null);
    setOk(null);
    try {
      const votos = orgs.map((o) => ({ candidate_id: o.numero, votes: o.votos || 0 }));
      const existente = plantilla.acta_existente;
      if (existente && existente.editable) {
        const acta = await api.getActa(existente.id);
        await api.updateActa(acta.id, {
          votos_distrital: votos, votos_blancos: blancos,
          votos_nulos: nulos, votos_impugnados: impugnados,
          ...(imageUrl ? { image_url: imageUrl } : {}),
          verified: true,
        });
        setOk(`Acta ${mesa} rectificada correctamente.`);
      } else {
        await api.createActa({
          numero_mesa: mesa, votos_distrital: votos,
          votos_blancos: blancos, votos_nulos: nulos,
          votos_impugnados: impugnados, image_url: imageUrl,
          ocr_confidence: confianza, total_electores: habiles,
          verified: true,
        });
        setOk(`Acta ${mesa} cargada correctamente.`);
      }
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setGuardando(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      role="dialog" aria-modal="true" aria-label={`Cargar acta de mesa ${mesa}`}>
      <div className="max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-2xl bg-white shadow-2xl">
        <div className="sticky top-0 flex items-center justify-between bg-[#002B66] px-6 py-4 text-white">
          <h3 className="font-black">📝 Acta de mesa {mesa}</h3>
          <button onClick={onClose} aria-label="Cerrar"
            className="rounded-lg bg-white/15 px-3 py-1.5 font-black hover:bg-white/25">✕</button>
        </div>

        <div className="space-y-5 p-6">
          {error && (
            <p className="rounded-xl bg-red-50 px-4 py-3 text-sm font-semibold text-red-700">{error}</p>
          )}
          {ok && (
            <p className="rounded-xl bg-emerald-50 px-4 py-3 text-sm font-semibold text-emerald-700">{ok}</p>
          )}
          {cargando ? (
            <p className="py-8 text-center text-sm text-slate-500">Cargando oferta electoral…</p>
          ) : !plantilla ? (
            <p className="py-8 text-center text-sm text-slate-500">Sin plantilla para esta mesa.</p>
          ) : (
            <>
              {plantilla.acta_existente && (
                <p className={`rounded-xl px-4 py-3 text-xs font-bold ${
                  plantilla.acta_existente.editable
                    ? "bg-amber-50 text-amber-800" : "bg-slate-100 text-slate-600"}`}>
                  Esta mesa ya tiene acta en estado {plantilla.acta_existente.estado}
                  {plantilla.acta_existente.editable ? " (editable: se rectificará)." : " (solo lectura)."}
                </p>
              )}

              {/* 1 · Foto */}
              <section>
                <h4 className="mb-2 text-xs font-black uppercase tracking-wider text-slate-500">
                  1 · Foto del acta (opcional)
                </h4>
                <div className="flex items-center gap-3">
                  <input ref={fileRef} type="file" accept="image/*" onChange={() => void subirFoto()}
                    className="text-xs text-slate-600" />
                  {subiendo && <span className="text-xs text-slate-500">Subiendo…</span>}
                  {fotoNombre && (
                    <span className="rounded-lg bg-emerald-50 px-2.5 py-1 font-mono text-[11px] text-emerald-700">
                      ✓ {fotoNombre}
                    </span>
                  )}
                </div>
              </section>

              {/* 2 · Votos */}
              <section>
                <h4 className="mb-2 text-xs font-black uppercase tracking-wider text-slate-500">
                  2 · Votos por organización
                </h4>
                <div className="space-y-2">
                  {orgs.map((o) => (
                    <div key={o.numero} className="flex items-center gap-3">
                      <span className="w-8 shrink-0 font-mono text-xs font-black text-slate-400">
                        {String(o.numero).padStart(2, "0")}
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-bold text-slate-800">{o.nombre}</span>
                        <span className="block truncate text-[11px] text-slate-500">{o.candidato}</span>
                      </span>
                      <input
                        type="number" min={0} value={o.votos}
                        onChange={(e) => setVoto(o.numero, Number(e.target.value))}
                        className="w-24 rounded-lg border border-slate-300 px-3 py-2 text-right font-mono font-black"
                      />
                    </div>
                  ))}
                </div>
                <div className="mt-3 grid grid-cols-3 gap-2">
                  {([["Blancos", blancos, setBlancos], ["Nulos", nulos, setNulos],
                     ["Impugnados", impugnados, setImpugnados]] as const).map(([et, v, set]) => (
                    <label key={et} className="text-[11px] font-black uppercase text-slate-500">
                      {et}
                      <input type="number" min={0} value={v}
                        onChange={(e) => set(Math.max(0, Number(e.target.value) || 0))}
                        className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-right font-mono font-black text-slate-800" />
                    </label>
                  ))}
                </div>
                <p className={`mt-2 font-mono text-xs ${excedePadron ? "font-black text-red-600" : "text-slate-500"}`}>
                  Total emitidos: {totalEmitidos}
                  {habiles != null && ` / ${habiles} hábiles`}
                  {excedePadron && " ⚠ supera el padrón"}
                </p>
              </section>

              {/* 3 · Guardar */}
              <div className="flex justify-end gap-2">
                <button onClick={onClose}
                  className="rounded-xl border border-slate-300 px-5 py-2.5 text-sm font-bold text-slate-600">
                  Cancelar
                </button>
                <button onClick={() => void guardar()} disabled={guardando || excedePadron}
                  className="rounded-xl bg-[#e31837] px-6 py-2.5 text-sm font-black uppercase tracking-wider text-white hover:bg-[#c11230] disabled:opacity-50">
                  {guardando ? "Guardando…" : "💾 Guardar acta"}
                </button>
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
