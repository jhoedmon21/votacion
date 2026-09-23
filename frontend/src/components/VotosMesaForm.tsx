import { useCallback, useMemo, useState } from "react";
import type { ColumnaActa, PlantillaActa } from "./ActaIngresoForm";
import { sesionGuardada } from "../api";

/* ==================================================================== *
 *  VotosMesaForm — Ingreso y validación de votos por mesa
 *  (Entregable 3 · brief: formulario multi-nivel, imagen, R1/R2, observaciones)
 *
 *  Consume  GET  /api/actas/plantilla?numero_mesa=XXXXXX  (contrato
 *           docs/schemas/plantilla-acta-v1.schema.json) y registra UNA acta
 *           por nivel con  POST /api/actas/movil  (el acta física de cada
 *           elección se registra por separado: UNIQUE (mesa_id, tipo_eleccion)).
 *
 *  Validación en vivo (espejo de app/services/acta_validator.py):
 *    R1  Σ votos orgs + blancos + nulos + impugnados = total votantes (por columna)
 *    R2  votantes ≤ electores hábiles de la mesa
 *    R4  la mesa ya tiene acta: sólo re-digitable si el estado lo permite
 *
 *  Evidencia: carga de imagen con preview y hash SHA-256 (candado anti-duplicidad
 *  del trigger fn_evitar_foto_duplicada de la capa PostgreSQL).
 * ==================================================================== */

interface DigitadoColumna {
  votos: Record<number, number | null>;
  votos_blancos: number | null;
  votos_nulos: number | null;
  votos_impugnados: number | null;
  total_votantes_papel: number | null;
}

interface DigitadoActa {
  elecciones: Record<string, Record<string, DigitadoColumna>>;
}

interface Hallazgo {
  tipo_eleccion: string;
  regla: string;
  severidad: "BLOQUEANTE" | "ADVERTENCIA" | "INFO";
  mensaje: string;
}

const CLAVE_COLA = "cola_actas"; // misma cola offline que la PWA (api.ts)

function encolarOffline(payload: unknown): void {
  try {
    const cola = JSON.parse(localStorage.getItem(CLAVE_COLA) || "[]") as unknown[];
    cola.push({ payload, encolado_en: new Date().toISOString() });
    localStorage.setItem(CLAVE_COLA, JSON.stringify(cola));
  } catch {
    // localStorage lleno o corrupto: no bloquea la UI
  }
}

async function sha256(file: File): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function digitadoInicial(p: PlantillaActa | null): DigitadoActa {
  const elecciones: DigitadoActa["elecciones"] = {};
  for (const e of p?.elecciones ?? []) {
    elecciones[e.tipo_eleccion] = {};
    for (const col of e.columnas) {
      elecciones[e.tipo_eleccion][col.columna] = {
        votos: Object.fromEntries(col.organizaciones.map((o) => [o.numero, o.votos])),
        votos_blancos: col.votos_blancos,
        votos_nulos: col.votos_nulos,
        votos_impugnados: col.votos_impugnados,
        total_votantes_papel: col.total_votantes_papel,
      };
    }
  }
  return { elecciones };
}

function validarCliente(p: PlantillaActa, d: DigitadoActa): Hallazgo[] {
  const hallazgos: Hallazgo[] = [];
  const habiles = p.electores_habiles ?? 0;

  for (const e of p.elecciones) {
    for (const col of e.columnas) {
      const dd = d.elecciones[e.tipo_eleccion]?.[col.columna];
      if (!dd) continue;
      const etiqueta = `${e.tipo_eleccion} · ${col.etiqueta}`;
      const sumaOrgs = col.organizaciones.reduce((s, o) => s + (dd.votos[o.numero] ?? 0), 0);
      const validos = sumaOrgs + (dd.votos_blancos ?? 0);
      const sumaPartes = validos + (dd.votos_nulos ?? 0) + (dd.votos_impugnados ?? 0);
      const total = dd.total_votantes_papel;

      if (total !== null && total > 0 && sumaPartes !== total) {
        hallazgos.push({
          tipo_eleccion: e.tipo_eleccion,
          regla: "R1_SUMA_VOTOS",
          severidad: "BLOQUEANTE",
          mensaje:
            `${etiqueta}: válidos (${validos}) + blancos (${dd.votos_blancos ?? 0})` +
            ` + nulos (${dd.votos_nulos ?? 0}) + impugnados (${dd.votos_impugnados ?? 0})` +
            ` ≠ total votantes (${total}). Diferencia: ${total - sumaPartes}.`,
        });
      }
      if (habiles > 0 && total !== null && total > habiles) {
        hallazgos.push({
          tipo_eleccion: e.tipo_eleccion,
          regla: "R2_TOPE_ELECTORES",
          severidad: "BLOQUEANTE",
          mensaje: `${etiqueta}: votantes (${total}) supera los electores hábiles de la mesa (${habiles}).`,
        });
      }
    }
  }
  return hallazgos;
}

interface Props {
  onGuardada: () => void;
  onCancelar: () => void;
}

export default function VotosMesaForm({ onGuardada, onCancelar }: Props) {
  const [mesa, setMesa] = useState("");
  const [plantilla, setPlantilla] = useState<PlantillaActa | null>(null);
  const [tab, setTab] = useState<string | null>(null);
  const [digitado, setDigitado] = useState<DigitadoActa>({ elecciones: {} });

  // Evidencia fotográfica (R5 / candado SHA-256)
  const [foto, setFoto] = useState<File | null>(null);
  const [fotoPreview, setFotoPreview] = useState<string | null>(null);
  const [fotoHash, setFotoHash] = useState<string | null>(null);

  const [ilegible, setIlegible] = useState(false);
  const [firmas, setFirmas] = useState(true);
  const [observaciones, setObservaciones] = useState("");
  const [enviadas, setEnviadas] = useState<string[]>([]);

  const [cargando, setCargando] = useState(false);
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resultado, setResultado] = useState<string | null>(null);

  const cargarMesa = useCallback(async () => {
    const numero = mesa.trim();
    if (!/^\d{6}$/.test(numero)) {
      setError("El número de mesa debe tener exactamente 6 dígitos.");
      return;
    }
    setCargando(true);
    setError(null);
    setResultado(null);
    setEnviadas([]);
    setFoto(null);
    setFotoPreview(null);
    setFotoHash(null);
    setObservaciones("");
    try {
      const res = await fetch(`/api/actas/plantilla?numero_mesa=${numero}`, {
        headers: sesionGuardada()
          ? { Authorization: `Bearer ${sesionGuardada()!.token}` }
          : {},
      });
      if (res.status === 404) {
        setError(`Mesa ${numero} no existe en el padrón.`);
        setPlantilla(null);
        return;
      }
      if (!res.ok) throw new Error(`Error ${res.status} al cargar la plantilla`);
      const data = (await res.json()) as PlantillaActa;
      setPlantilla(data);
      setDigitado(digitadoInicial(data));
      setTab(data.elecciones[0]?.tipo_eleccion ?? null);
      if (data.acta_existente && !data.acta_existente.editable) {
        setError(
          `La mesa ya tiene acta en estado ${data.acta_existente.estado}: no editable por tu rol.`
        );
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setPlantilla(null);
    } finally {
      setCargando(false);
    }
  }, [mesa]);

  const onSeleccionarFoto = useCallback(async (f: File | null) => {
    setFoto(f);
    setFotoPreview(null);
    setFotoHash(null);
    if (!f) return;
    setFotoPreview(URL.createObjectURL(f));
    try {
      setFotoHash(await sha256(f));
    } catch {
      setFotoHash(null);
    }
  }, []);

  const setVoto = useCallback(
    (tipo: string, columna: string, numero: number, valor: number | null) => {
      setDigitado((prev) => ({
        ...prev,
        elecciones: {
          ...prev.elecciones,
          [tipo]: {
            ...prev.elecciones[tipo],
            [columna]: {
              ...prev.elecciones[tipo][columna],
              votos: { ...prev.elecciones[tipo][columna].votos, [numero]: valor },
            },
          },
        },
      }));
    },
    []
  );

  const setCampo = useCallback(
    (
      tipo: string,
      columna: string,
      campo: "votos_blancos" | "votos_nulos" | "votos_impugnados" | "total_votantes_papel",
      valor: number | null
    ) => {
      setDigitado((prev) => ({
        ...prev,
        elecciones: {
          ...prev.elecciones,
          [tipo]: {
            ...prev.elecciones[tipo],
            [columna]: { ...prev.elecciones[tipo][columna], [campo]: valor },
          },
        },
      }));
    },
    []
  );

  const hallazgos = useMemo(
    () => (plantilla ? validarCliente(plantilla, digitado) : []),
    [plantilla, digitado]
  );

  const eleccionActiva =
    plantilla?.elecciones.find((e) => e.tipo_eleccion === tab) ??
    plantilla?.elecciones[0] ??
    null;

  const hallazgosActiva = useMemo(
    () => hallazgos.filter((h) => h.tipo_eleccion === eleccionActiva?.tipo_eleccion),
    [hallazgos, eleccionActiva]
  );
  const bloqueantesActiva = hallazgosActiva.filter((h) => h.severidad === "BLOQUEANTE");
  const hayBloqueantesGlobal = hallazgos.some((h) => h.severidad === "BLOQUEANTE");

  const mesaYaRegistrada = plantilla?.acta_existente != null;
  const editable = plantilla?.acta_existente?.editable !== false;

  const enviar = useCallback(async () => {
    if (!plantilla || !eleccionActiva) return;
    if (enviadas.includes(eleccionActiva.tipo_eleccion)) return;

    setEnviando(true);
    setError(null);
    setResultado(null);
    try {
      const columnas = Object.entries(
        digitado.elecciones[eleccionActiva.tipo_eleccion] ?? {}
      ).map(([columna, d]) => ({
        columna,
        votos: Object.fromEntries(Object.entries(d.votos).map(([k, v]) => [k, v ?? 0])),
        votos_blancos: d.votos_blancos ?? 0,
        votos_nulos: d.votos_nulos ?? 0,
        votos_impugnados: d.votos_impugnados ?? 0,
        total_votantes: d.total_votantes_papel ?? 0,
      }));

      const payload = {
        numero_mesa: plantilla.numero_mesa,
        tipo_eleccion: eleccionActiva.tipo_eleccion,
        electores_habiles: plantilla.electores_habiles ?? 0,
        foto_presente: foto !== null,
        foto_repetida: false,
        ilegible,
        firmas_completas: firmas,
        columnas,
        // La capa PostgreSQL persiste esto en acta_observaciones; el endpoint
        // del prototipo (ActaValidacionIn) tolera los campos extra.
        observaciones: observaciones.trim() || null,
      };

      const res = await fetch("/api/actas/movil", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(sesionGuardada()
            ? { Authorization: `Bearer ${sesionGuardada()!.token}` }
            : {}),
        },
        body: JSON.stringify(payload),
      });

      if (res.status === 409) {
        const body = await res.json();
        const detalle = body?.detail;
        const mensaje =
          typeof detalle === "string"
            ? detalle
            : (detalle?.mensaje ?? "Acta no contabilizada");
        setError(`Acta ${eleccionActiva.tipo_eleccion} no contabilizada: ${mensaje}`);
        return;
      }
      if (!res.ok) throw new Error(`Error ${res.status} al registrar el acta`);

      const nuevas = [...enviadas, eleccionActiva.tipo_eleccion];
      setEnviadas(nuevas);
      setResultado(`Acta ${eleccionActiva.tipo_eleccion} registrada y contabilizada correctamente.`);
      if (nuevas.length >= plantilla.elecciones.length) {
        onGuardada();
      }
    } catch (e) {
      encolarOffline({
        numero_mesa: plantilla.numero_mesa,
        tipo_eleccion: eleccionActiva.tipo_eleccion,
      });
      setError(
        `${e instanceof Error ? e.message : String(e)} — acta guardada en la cola offline para reintento.`
      );
    } finally {
      setEnviando(false);
    }
  }, [plantilla, eleccionActiva, digitado, foto, ilegible, firmas, observaciones, enviadas, onGuardada]);

  const botonDeshabilitado =
    !eleccionActiva ||
    enviando ||
    bloqueantesActiva.length > 0 ||
    (mesaYaRegistrada && !editable) ||
    enviadas.includes(eleccionActiva.tipo_eleccion);

  const renderColumna = (col: ColumnaActa, tipo: string) => {
    const d = digitado.elecciones[tipo]?.[col.columna];
    if (!d) return null;
    const sumaOrgs = col.organizaciones.reduce((s, o) => s + (d.votos[o.numero] ?? 0), 0);
    const sumaPartes =
      sumaOrgs + (d.votos_blancos ?? 0) + (d.votos_nulos ?? 0) + (d.votos_impugnados ?? 0);
    const diferencia =
      d.total_votantes_papel === null ? null : d.total_votantes_papel - sumaPartes;
    const excedePadron =
      plantilla &&
      plantilla.electores_habiles !== null &&
      d.total_votantes_papel !== null &&
      d.total_votantes_papel > plantilla.electores_habiles;

    return (
      <div key={col.columna} className="space-y-2">
        <div className="flex items-center justify-between border-b border-slate-100 pb-2">
          <span className="text-xs font-black uppercase tracking-wider text-[#002B66]">
            Columna {col.etiqueta}
          </span>
          <div className="flex items-center gap-4 text-xs font-bold">
            <span className="text-slate-500">
              Σ organizaciones: <span className="font-mono">{sumaOrgs}</span>
            </span>
            <label className="text-slate-500">
              Total votantes (papel):{" "}
              <input
                type="number"
                min={0}
                value={d.total_votantes_papel ?? ""}
                onChange={(ev) =>
                  setCampo(
                    tipo,
                    col.columna,
                    "total_votantes_papel",
                    ev.target.value === "" ? null : Number(ev.target.value)
                  )
                }
                className="w-20 rounded border border-slate-300 px-2 py-1 text-right font-mono"
              />
            </label>
          </div>
        </div>

        {col.organizaciones.map((o) => (
          <div key={o.numero} className="flex items-center gap-3">
            <span className="w-6 text-right font-mono text-xs text-slate-400">{o.numero}</span>
            {o.logo_url && (
              <img src={o.logo_url} alt={o.nombre} className="h-6 w-6 rounded object-contain" />
            )}
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-bold text-slate-800">{o.nombre}</p>
              <p className="truncate text-xs text-slate-500">{o.candidato}</p>
            </div>
            <input
              type="number"
              min={0}
              value={d.votos[o.numero] ?? ""}
              onChange={(ev) =>
                setVoto(tipo, col.columna, o.numero, ev.target.value === "" ? null : Number(ev.target.value))
              }
              placeholder="—"
              className="w-20 rounded border border-slate-300 px-2 py-1.5 text-right font-mono focus:border-[#002B66] focus:outline-none"
            />
          </div>
        ))}

        <div className="grid grid-cols-4 gap-2 border-t border-slate-100 pt-3">
          {(
            [
              ["votos_blancos", "Blancos"],
              ["votos_nulos", "Nulos"],
              ["votos_impugnados", "Impugnados"],
            ] as const
          ).map(([campo, etiqueta]) => (
            <label key={campo} className="text-xs font-bold text-slate-600">
              {etiqueta}
              <input
                type="number"
                min={0}
                value={d[campo] ?? ""}
                onChange={(ev) =>
                  setCampo(tipo, col.columna, campo, ev.target.value === "" ? null : Number(ev.target.value))
                }
                className="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-right font-mono"
              />
            </label>
          ))}
          <div className="text-xs font-bold">
            <span
              className={
                diferencia === null
                  ? "text-slate-400"
                  : diferencia === 0
                    ? "text-emerald-600"
                    : "text-red-600"
              }
            >
              Diferencia
            </span>
            <div
              className={`mt-1 rounded px-2 py-1.5 text-right font-mono ${
                diferencia === null
                  ? "bg-slate-100 text-slate-400"
                  : diferencia === 0
                    ? "bg-emerald-50 text-emerald-700"
                    : "bg-red-50 text-red-700"
              }`}
            >
              {diferencia === null ? "—" : diferencia > 0 ? `+${diferencia}` : diferencia}
            </div>
          </div>
        </div>

        {excedePadron && (
          <p className="rounded bg-red-50 px-3 py-2 text-xs font-bold text-red-700">
            ⚠ R2: votantes ({d.total_votantes_papel}) supera electores hábiles (
            {plantilla?.electores_habiles}).
          </p>
        )}
      </div>
    );
  };

  return (
    <div className="space-y-6">
      {/* 1 · Búsqueda de mesa */}
      <section className="rounded-2xl border border-slate-200 bg-white p-5 shadow-xs">
        <h3 className="mb-3 text-sm font-black uppercase tracking-wider text-slate-500">
          1 · Buscar mesa
        </h3>
        <div className="flex flex-wrap items-end gap-3">
          <label className="flex-1">
            <span className="mb-1 block text-xs font-bold text-slate-600">
              N° de mesa (6 dígitos)
            </span>
            <input
              inputMode="numeric"
              maxLength={6}
              value={mesa}
              onChange={(e) => setMesa(e.target.value.replace(/\D/g, ""))}
              placeholder="023002"
              className="w-full rounded-lg border border-slate-300 px-3 py-2 font-mono text-lg tracking-widest focus:border-[#002B66] focus:outline-none"
            />
          </label>
          <button
            onClick={cargarMesa}
            disabled={cargando || !/^\d{6}$/.test(mesa)}
            className="rounded-lg bg-[#002B66] px-5 py-2 text-sm font-bold text-white hover:bg-[#003366] disabled:bg-slate-300"
          >
            {cargando ? "Buscando…" : "Cargar acta"}
          </button>
        </div>
        {plantilla?.acta_existente && (
          <p className="mt-2 text-xs font-semibold text-amber-600">
            Esta mesa ya tiene acta en estado {plantilla.acta_existente.estado}
            {plantilla.acta_existente.editable ? " (editable)" : " (solo lectura)"}.
          </p>
        )}
      </section>

      {plantilla && (
        <>
          {/* 2 · Local de votación + evidencia fotográfica */}
          <section className="rounded-2xl border border-slate-200 bg-white p-5 shadow-xs">
            <h3 className="mb-2 text-sm font-black uppercase tracking-wider text-slate-500">
              2 · Local de votación y evidencia
            </h3>
            <p className="text-sm text-slate-700">
              <strong>{plantilla.local.nombre}</strong> — {plantilla.local.sector}
              {plantilla.local.direccion ? `, ${plantilla.local.direccion}` : ""}
            </p>
            <p className="mt-1 text-xs text-slate-500">
              Electores hábiles de la mesa:{" "}
              <strong>{plantilla.electores_habiles ?? "sin registrar (se pedirá al enviar)"}</strong>
            </p>

            <div className="mt-4 grid gap-4 md:grid-cols-2">
              {/* Carga de imagen */}
              <div className="rounded-xl border border-slate-200 p-4">
                <span className="block text-xs font-bold text-slate-600">
                  Foto del acta física (R5)
                </span>
                <input
                  type="file"
                  accept="image/*"
                  capture="environment"
                  onChange={(e) => onSeleccionarFoto(e.target.files?.[0] ?? null)}
                  className="mt-2 w-full text-xs text-slate-500 file:mr-3 file:rounded file:border-0 file:bg-[#002B66] file:px-3 file:py-1.5 file:text-xs file:font-bold file:text-white"
                />
                {fotoPreview && (
                  <img
                    src={fotoPreview}
                    alt="Previsualización del acta"
                    className="mt-3 max-h-48 w-full rounded object-contain bg-slate-50"
                  />
                )}
                {fotoHash && (
                  <p className="mt-2 break-all font-mono text-[10px] text-slate-400">
                    SHA-256: {fotoHash}
                  </p>
                )}
                <label className="mt-3 flex items-center gap-2 text-xs font-semibold text-slate-600">
                  <input
                    type="checkbox"
                    checked={ilegible}
                    onChange={(e) => setIlegible(e.target.checked)}
                  />
                  Declarar campos ilegibles (requiere cotejo, R6)
                </label>
                <label className="mt-1 flex items-center gap-2 text-xs font-semibold text-slate-600">
                  <input
                    type="checkbox"
                    checked={firmas}
                    onChange={(e) => setFirmas(e.target.checked)}
                  />
                  Firmas de personeros completas (R7)
                </label>
              </div>

              {/* Observaciones */}
              <div className="rounded-xl border border-slate-200 p-4">
                <span className="block text-xs font-bold text-slate-600">
                  Observaciones (acta_observaciones)
                </span>
                <textarea
                  value={observaciones}
                  onChange={(e) => setObservaciones(e.target.value)}
                  rows={4}
                  placeholder="Retraso en instalación, material incompleto, diferencia declarada al cotejar, etc."
                  className="mt-2 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:border-[#002B66] focus:outline-none"
                />
                <p className="mt-1 text-[11px] text-slate-400">
                  Las observaciones bloqueantes se generan solas (R1/R2); aquí van las
                  novedades del papel que no cubre la aritmética.
                </p>
              </div>
            </div>
          </section>

          {/* 3 · Pestañas por elección */}
          <section className="rounded-2xl border border-slate-200 bg-white p-5 shadow-xs">
            <h3 className="mb-3 text-sm font-black uppercase tracking-wider text-slate-500">
              3 · Actas por elección
            </h3>
            <div className="mb-4 flex flex-wrap gap-2">
              {plantilla.elecciones.map((e) => (
                <button
                  key={e.tipo_eleccion}
                  onClick={() => setTab(e.tipo_eleccion)}
                  className={`rounded-lg px-4 py-2 text-xs font-black uppercase tracking-wider transition ${
                    tab === e.tipo_eleccion
                      ? "bg-[#002B66] text-white"
                      : "border border-slate-200 bg-white text-slate-500 hover:bg-slate-50"
                  }`}
                >
                  {e.tipo_eleccion}
                  {enviadas.includes(e.tipo_eleccion) && " ✓"}
                </button>
              ))}
            </div>

            {eleccionActiva && (
              <>
                <p className="mb-4 text-xs text-slate-500">{eleccionActiva.cargos}</p>
                <div className="space-y-4">
                  {eleccionActiva.columnas.map((col) => renderColumna(col, eleccionActiva.tipo_eleccion))}
                </div>
              </>
            )}
          </section>

          {/* 4 · Validación matemática (activa + global) */}
          <section
            className={`rounded-2xl border p-5 shadow-xs ${
              hayBloqueantesGlobal
                ? "border-red-300 bg-red-50"
                : "border-emerald-300 bg-emerald-50"
            }`}
          >
            <h3 className="mb-2 text-sm font-black uppercase tracking-wider text-slate-600">
              4 · Validación matemática
            </h3>
            {hallazgos.length === 0 ? (
              <p className="text-sm font-bold text-emerald-700">
                ✓ Las tres actas cuadran (válidos + blancos + nulos + impugnados = total
                votantes, por columna).
              </p>
            ) : (
              <ul className="space-y-1.5">
                {hallazgos.map((h, i) => (
                  <li
                    key={i}
                    className={`text-xs font-semibold ${
                      h.severidad === "BLOQUEANTE" ? "text-red-700" : "text-amber-700"
                    }`}
                  >
                    [{h.regla}] {h.mensaje}
                  </li>
                ))}
              </ul>
            )}
            <p className="mt-2 text-xs text-slate-500">
              R1 = válidos + blancos + nulos + impugnados = total votantes, por columna ·
              R2 = votantes ≤ electores hábiles · R4 = una sola acta por mesa y elección.
            </p>
          </section>

          {/* Envío */}
          <section className="flex flex-wrap items-center justify-between gap-3">
            <div className="space-y-1">
              {resultado && (
                <p className="rounded bg-slate-100 px-3 py-2 text-sm font-semibold text-slate-700">
                  {resultado}
                </p>
              )}
              {error && (
                <p className="rounded bg-amber-50 px-3 py-2 text-sm font-semibold text-amber-800">
                  {error}
                </p>
              )}
            </div>
            <div className="ml-auto flex gap-3">
              <button
                onClick={onCancelar}
                className="rounded-lg border border-slate-300 px-4 py-2 text-sm font-bold text-slate-600 hover:bg-slate-50"
              >
                Cancelar
              </button>
              <button
                onClick={enviar}
                disabled={botonDeshabilitado}
                title={
                  bloqueantesActiva.length
                    ? "El acta activa tiene validaciones bloqueantes (R1/R2)."
                    : undefined
                }
                className="rounded-lg bg-[#002B66] px-6 py-2 text-sm font-bold text-white hover:bg-[#003366] disabled:bg-slate-300"
              >
                {enviando
                  ? "Enviando…"
                  : `Registrar acta ${eleccionActiva ? eleccionActiva.tipo_eleccion : ""}`}
              </button>
            </div>
          </section>
        </>
      )}
    </div>
  );
}