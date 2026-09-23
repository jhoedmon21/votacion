import { useCallback, useMemo, useState } from "react";
import type { ColumnaActa, PlantillaActa } from "./ActaIngresoForm";
import { sesionGuardada } from "../api";

/* ==================================================================== *
 *  ActaOficialForm — Réplica fiel del Acta de Escrutinio ONPE
 *  (Entregable 3 · brief: formulario multi-nivel, imagen, R1/R2, observaciones)
 *
 *  Diseño basado en el formato oficial de la ONPE:
 *    - Encabezado con datos del local y mesa
 *    - Pestañas por elección (Regional / Provincial / Distrital)
 *    - Dos columnas por elección (A: Alcalde/Gobernador, B: Regidores/Consejeros)
 *    - Lista de organizaciones políticas con sus candidatos
 *    - Campos de votos especiales (blancos, nulos, impugnados)
 *    - Validación matemática en tiempo real
 *    - Indicador visual de estado (válido/observado)
 *
 *  Consume  GET  /api/actas/plantilla?numero_mesa=XXXXXX
 *  Registra POST /api/actas/movil (una acta por nivel/elección)
 * ==================================================================== */

/* ------------------------------------------------------------------ *
 *  Tipos
 * ------------------------------------------------------------------ */

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

/* ------------------------------------------------------------------ *
 *  Constantes de estilo (paleta institucional ONPE)
 * ------------------------------------------------------------------ */

const COLORES = {
  azulOscuro: "#E02020",
  azulMedio: "#A01010",
  azulClaro: "#1e40af",
  rojo: "#dc2626",
  rojoBg: "#fef2f2",
  verde: "#16a34a",
  verdeBg: "#f0fdf4",
  amarillo: "#d97706",
  amarilloBg: "#fffbeb",
  gris: "#6b7280",
  grisBg: "#f9fafb",
  borde: "#e5e7eb",
} as const;

const CLAVE_COLA = "cola_actas";

/* ------------------------------------------------------------------ *
 *  Utilidades
 * ------------------------------------------------------------------ */

function encolarOffline(payload: unknown): void {
  try {
    const cola = JSON.parse(localStorage.getItem(CLAVE_COLA) || "[]") as unknown[];
    cola.push({ payload, encolado_en: new Date().toISOString() });
    localStorage.setItem(CLAVE_COLA, JSON.stringify(cola));
  } catch {
    /* localStorage lleno o corrupto */
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

/* ------------------------------------------------------------------ *
 *  Validación matemática (espejo de acta_validator.py)
 * ------------------------------------------------------------------ */

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
          mensaje: `${etiqueta}: votantes (${total}) supera electores hábiles (${habiles}).`,
        });
      }
    }
  }
  return hallazgos;
}

/* ------------------------------------------------------------------ *
 *  Componente principal
 * ------------------------------------------------------------------ */

interface Props {
  onGuardada: () => void;
  onCancelar: () => void;
}

export default function ActaOficialForm({ onGuardada, onCancelar }: Props) {
  const [mesa, setMesa] = useState("");
  const [plantilla, setPlantilla] = useState<PlantillaActa | null>(null);
  const [tab, setTab] = useState<string | null>(null);
  const [digitado, setDigitado] = useState<DigitadoActa>({ elecciones: {} });

  const [foto, setFoto] = useState<File | null>(null);
  const [fotoPreview, setFotoPreview] = useState<string | null>(null);
  const [fotoHash, setFotoHash] = useState<string | null>(null);

  const [ilegible, setIlegible] = useState(false);
  const [firmas, setFirmas] = useState(true);
  const [observaciones, setObservaciones] = useState("");

  const [cargando, setCargando] = useState(false);
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resultado, setResultado] = useState<string | null>(null);
  const [enviadas, setEnviadas] = useState<string[]>([]);

  /* ---- Carga de mesa ---- */
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

  /* ---- Foto ---- */
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

  /* ---- Setters ---- */
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

  /* ---- Validación ---- */
  const hallazgos = useMemo(
    () => (plantilla ? validarCliente(plantilla, digitado) : []),
    [plantilla, digitado]
  );

  const eleccionActiva =
    plantilla?.elecciones.find((e) => e.tipo_eleccion === tab) ?? plantilla?.elecciones[0] ?? null;

  const hallazgosActiva = useMemo(
    () => hallazgos.filter((h) => h.tipo_eleccion === eleccionActiva?.tipo_eleccion),
    [hallazgos, eleccionActiva]
  );
  const bloqueantesActiva = hallazgosActiva.filter((h) => h.severidad === "BLOQUEANTE");
  const hayBloqueantesGlobal = hallazgos.some((h) => h.severidad === "BLOQUEANTE");

  const mesaYaRegistrada = plantilla?.acta_existente != null;
  const editable = plantilla?.acta_existente?.editable !== false;

  /* ---- Envío ---- */
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

  /* ---- Render: Columna del acta (réplica ONPE) ---- */
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

    const estadoValidacion =
      diferencia === null
        ? "sin-datos"
        : diferencia === 0
          ? "valido"
          : "observado";

    return (
      <div
        key={col.columna}
        className="rounded-xl border-2 bg-white p-4"
        style={{
          borderColor:
            estadoValidacion === "valido"
              ? COLORES.verde
              : estadoValidacion === "observado"
                ? COLORES.rojo
                : COLORES.borde,
        }}
      >
        {/* Encabezado de columna */}
        <div
          className="mb-3 flex items-center justify-between rounded-lg px-4 py-2"
          style={{ backgroundColor: COLORES.azulOscuro }}
        >
          <div>
            <span className="text-xs font-bold uppercase tracking-widest text-white/70">
              Columna {col.columna === "ALCALDE" || col.columna === "GOBERNADOR_VICE" ? "A" : "B"}
            </span>
            <h4 className="text-sm font-black uppercase tracking-wider text-white">
              {col.etiqueta}
            </h4>
          </div>
          <div className="text-right">
            <label className="block text-[10px] font-bold uppercase text-white/70">
              Total votantes (papel)
            </label>
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
              className="w-24 rounded border border-white/30 bg-white/10 px-2 py-1 text-right font-mono text-lg font-bold text-white placeholder-white/40 focus:border-white focus:outline-none"
              placeholder="0"
            />
          </div>
        </div>

        {/* Lista de organizaciones políticas */}
        <div className="space-y-1">
          {col.organizaciones.map((o, idx) => (
            <div
              key={o.numero}
              className="flex items-center gap-3 rounded-lg px-3 py-2 transition-colors"
              style={{
                backgroundColor: idx % 2 === 0 ? COLORES.grisBg : "white",
              }}
            >
              {/* Número de orden */}
              <span
                className="flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-full text-xs font-black text-white"
                style={{ backgroundColor: COLORES.azulOscuro }}
              >
                {o.numero}
              </span>

              {/* Logo */}
              {o.logo_url && (
                <img
                  src={o.logo_url}
                  alt={o.nombre}
                  className="h-8 w-8 flex-shrink-0 rounded object-contain"
                />
              )}

              {/* Nombre partido + candidato */}
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm font-bold text-gray-900">{o.nombre}</p>
                <p className="truncate text-xs text-gray-500">{o.candidato}</p>
              </div>

              {/* Input de votos */}
              <input
                type="number"
                min={0}
                value={d.votos[o.numero] ?? ""}
                onChange={(ev) =>
                  setVoto(
                    tipo,
                    col.columna,
                    o.numero,
                    ev.target.value === "" ? null : Math.max(0, Number(ev.target.value))
                  )
                }
                placeholder="—"
                className="w-20 rounded border px-2 py-1.5 text-right font-mono text-sm font-bold focus:outline-none"
                style={{
                  borderColor: COLORES.borde,
                  color: COLORES.azulOscuro,
                }}
              />
            </div>
          ))}
        </div>

        {/* Subtotales: Votos por organización */}
        <div
          className="mt-3 flex items-center justify-between rounded-lg px-4 py-2"
          style={{ backgroundColor: COLORES.azulOscuro }}
        >
          <span className="text-xs font-bold uppercase text-white/80">
            Σ Votos por Organización
          </span>
          <span className="font-mono text-lg font-black text-white">{sumaOrgs}</span>
        </div>

        {/* Votos especiales */}
        <div className="mt-3 grid grid-cols-3 gap-3">
          {(
            [
              ["votos_blancos", "Votos en Blanco", COLORES.grisBg],
              ["votos_nulos", "Votos Nulos", COLORES.amarilloBg],
              ["votos_impugnados", "Votos Impugnados", COLORES.rojoBg],
            ] as const
          ).map(([campo, etiqueta, bg]) => (
            <div key={campo} className="rounded-lg p-3" style={{ backgroundColor: bg }}>
              <label className="mb-1 block text-[10px] font-bold uppercase tracking-wider text-gray-600">
                {etiqueta}
              </label>
              <input
                type="number"
                min={0}
                value={d[campo] ?? ""}
                onChange={(ev) =>
                  setCampo(
                    tipo,
                    col.columna,
                    campo,
                    ev.target.value === "" ? null : Number(ev.target.value)
                  )
                }
                className="w-full rounded border px-2 py-1.5 text-right font-mono text-sm font-bold focus:outline-none"
                style={{ borderColor: COLORES.borde }}
              />
            </div>
          ))}
        </div>

        {/* Fila de resumen y validación */}
        <div
          className="mt-3 flex items-center justify-between rounded-lg px-4 py-3"
          style={{
            backgroundColor:
              estadoValidacion === "valido"
                ? COLORES.verdeBg
                : estadoValidacion === "observado"
                  ? COLORES.rojoBg
                  : COLORES.grisBg,
            borderColor:
              estadoValidacion === "valido"
                ? COLORES.verde
                : estadoValidacion === "observado"
                  ? COLORES.rojo
                  : COLORES.borde,
            borderWidth: 2,
          }}
        >
          <div>
            <span className="text-xs font-bold uppercase tracking-wider text-gray-600">
              Σ Total de Votantes
            </span>
            <div className="font-mono text-xl font-black" style={{ color: COLORES.azulOscuro }}>
              {d.total_votantes_papel ?? "—"}
            </div>
          </div>
          <div className="text-center">
            <span className="text-xs font-bold uppercase tracking-wider text-gray-600">
              Válidos + B + N + I
            </span>
            <div className="font-mono text-xl font-black" style={{ color: COLORES.azulOscuro }}>
              {sumaPartes}
            </div>
          </div>
          <div className="text-right">
            <span className="text-xs font-bold uppercase tracking-wider text-gray-600">
              Diferencia
            </span>
            <div
              className={`font-mono text-2xl font-black ${
                diferencia === null
                  ? "text-gray-400"
                  : diferencia === 0
                    ? "text-green-600"
                    : "text-red-600"
              }`}
            >
              {diferencia === null ? "—" : diferencia > 0 ? `+${diferencia}` : diferencia}
            </div>
          </div>
        </div>

        {/* Alerta R2: excede padrón */}
        {excedePadron && (
          <div className="mt-2 rounded-lg border-2 border-red-300 bg-red-50 px-4 py-2">
            <p className="text-xs font-bold text-red-700">
              ⚠ R2: Votantes ({d.total_votantes_papel}) supera electores hábiles ({plantilla?.electores_habiles}).
            </p>
          </div>
        )}
      </div>
    );
  };

  /* ---- Render principal ---- */
  return (
    <div className="mx-auto max-w-4xl space-y-6">
      {/* ===== ENCABEZADO OFICIAL ===== */}
      <div
        className="rounded-2xl border-2 p-6 text-white shadow-lg"
        style={{ backgroundColor: COLORES.azulOscuro, borderColor: COLORES.azulMedio }}
      >
        <div className="mb-2 text-center">
          <p className="text-xs font-bold uppercase tracking-[0.3em] text-white/70">
            República del Perú
          </p>
          <p className="text-xs font-bold uppercase tracking-[0.3em] text-white/70">
            Oficina Nacional de Procesos Electorales
          </p>
          <h1 className="mt-2 text-2xl font-black uppercase tracking-wider">
            Acta de Escrutinio
          </h1>
          <p className="mt-1 text-sm text-white/80">
            Elecciones Regionales y Municipales · Arequipa 2026
          </p>
        </div>
      </div>

      {/* ===== BÚSQUEDA DE MESA ===== */}
      <section className="rounded-2xl border-2 bg-white p-5 shadow-sm" style={{ borderColor: COLORES.borde }}>
        <h3
          className="mb-3 text-xs font-black uppercase tracking-[0.2em]"
          style={{ color: COLORES.azulOscuro }}
        >
          1 · Identificación de Mesa
        </h3>
        <div className="flex flex-wrap items-end gap-3">
          <label className="flex-1">
            <span className="mb-1 block text-xs font-bold text-gray-600">
              N° de Mesa (6 dígitos)
            </span>
            <input
              inputMode="numeric"
              maxLength={6}
              value={mesa}
              onChange={(e) => setMesa(e.target.value.replace(/\D/g, ""))}
              placeholder="023001"
              className="w-full rounded-lg border-2 px-4 py-3 font-mono text-2xl tracking-[0.3em] focus:outline-none"
              style={{ borderColor: COLORES.borde, color: COLORES.azulOscuro }}
            />
          </label>
          <button
            onClick={cargarMesa}
            disabled={cargando || !/^\d{6}$/.test(mesa)}
            className="rounded-lg px-6 py-3 text-sm font-black uppercase tracking-wider text-white transition-all hover:shadow-lg disabled:opacity-50"
            style={{ backgroundColor: COLORES.azulOscuro }}
          >
            {cargando ? "Buscando…" : "Cargar Acta"}
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
          {/* ===== DATOS DEL LOCAL ===== */}
          <section className="rounded-2xl border-2 bg-white p-5 shadow-sm" style={{ borderColor: COLORES.borde }}>
            <h3
              className="mb-2 text-xs font-black uppercase tracking-[0.2em]"
              style={{ color: COLORES.azulOscuro }}
            >
              2 · Local de Votación
            </h3>
            <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
              <div>
                <span className="text-[10px] font-bold uppercase text-gray-500">Local</span>
                <p className="text-sm font-bold text-gray-900">{plantilla.local.nombre}</p>
              </div>
              <div>
                <span className="text-[10px] font-bold uppercase text-gray-500">Dirección</span>
                <p className="text-sm text-gray-700">{plantilla.local.direccion ?? "—"}</p>
              </div>
              <div>
                <span className="text-[10px] font-bold uppercase text-gray-500">Electores Hábiles</span>
                <p className="font-mono text-lg font-black" style={{ color: COLORES.azulOscuro }}>
                  {plantilla.electores_habiles ?? "—"}
                </p>
              </div>
              <div>
                <span className="text-[10px] font-bold uppercase text-gray-500">Ubigeo</span>
                <p className="font-mono text-sm font-bold text-gray-700">{plantilla.ubigeo_distrito}</p>
              </div>
            </div>

            {/* Evidencia fotográfica */}
            <div className="mt-4 rounded-xl border-2 border-dashed p-4" style={{ borderColor: COLORES.borde }}>
              <span className="mb-2 block text-xs font-bold text-gray-600">
                📷 Evidencia Fotográfica del Acta (R5)
              </span>
              <input
                type="file"
                accept="image/*"
                capture="environment"
                onChange={(e) => onSeleccionarFoto(e.target.files?.[0] ?? null)}
                className="w-full text-xs text-gray-500 file:mr-3 file:rounded file:border-0 file:px-4 file:py-2 file:text-xs file:font-bold file:text-white"
                style={{ "--tw-file-bg": COLORES.azulOscuro } as React.CSSProperties}
              />
              {fotoPreview && (
                <img
                  src={fotoPreview}
                  alt="Previsualización del acta"
                  className="mt-3 max-h-48 w-full rounded-lg object-contain bg-gray-50"
                />
              )}
              {fotoHash && (
                <p className="mt-2 break-all font-mono text-[10px] text-gray-400">
                  SHA-256: {fotoHash}
                </p>
              )}
              <div className="mt-3 flex flex-wrap gap-4">
                <label className="flex items-center gap-2 text-xs font-semibold text-gray-600">
                  <input
                    type="checkbox"
                    checked={ilegible}
                    onChange={(e) => setIlegible(e.target.checked)}
                    className="rounded"
                  />
                  Campos ilegibles (R6)
                </label>
                <label className="flex items-center gap-2 text-xs font-semibold text-gray-600">
                  <input
                    type="checkbox"
                    checked={firmas}
                    onChange={(e) => setFirmas(e.target.checked)}
                    className="rounded"
                  />
                  Firmas completas (R7)
                </label>
              </div>
            </div>
          </section>

          {/* ===== PESTAÑAS POR ELECCIÓN ===== */}
          <section className="rounded-2xl border-2 bg-white p-5 shadow-sm" style={{ borderColor: COLORES.borde }}>
            <h3
              className="mb-3 text-xs font-black uppercase tracking-[0.2em]"
              style={{ color: COLORES.azulOscuro }}
            >
              3 · Actas por Elección
            </h3>

            {/* Tabs */}
            <div className="mb-4 flex flex-wrap gap-2">
              {plantilla.elecciones.map((e) => (
                <button
                  key={e.tipo_eleccion}
                  onClick={() => setTab(e.tipo_eleccion)}
                  className={`rounded-lg px-5 py-2.5 text-xs font-black uppercase tracking-wider transition-all ${
                    tab === e.tipo_eleccion
                      ? "text-white shadow-md"
                      : "border-2 bg-white text-gray-500 hover:bg-gray-50"
                  }`}
                  style={{
                    backgroundColor:
                      tab === e.tipo_eleccion ? COLORES.azulOscuro : undefined,
                    borderColor: tab === e.tipo_eleccion ? COLORES.azulOscuro : COLORES.borde,
                  }}
                >
                  {e.tipo_eleccion}
                  {enviadas.includes(e.tipo_eleccion) && (
                    <span className="ml-2 text-green-300">✓</span>
                  )}
                </button>
              ))}
            </div>

            {eleccionActiva && (
              <>
                <p className="mb-4 text-xs text-gray-500">{eleccionActiva.cargos}</p>
                <div className="space-y-6">
                  {eleccionActiva.columnas.map((col) =>
                    renderColumna(col, eleccionActiva.tipo_eleccion)
                  )}
                </div>
              </>
            )}
          </section>

          {/* ===== VALIDACIÓN MATEMÁTICA ===== */}
          <section
            className="rounded-2xl border-2 p-5 shadow-sm"
            style={{
              backgroundColor: hayBloqueantesGlobal ? COLORES.rojoBg : COLORES.verdeBg,
              borderColor: hayBloqueantesGlobal ? COLORES.rojo : COLORES.verde,
            }}
          >
            <h3
              className="mb-2 text-xs font-black uppercase tracking-[0.2em]"
              style={{ color: hayBloqueantesGlobal ? COLORES.rojo : COLORES.verde }}
            >
              4 · Validación Matemática
            </h3>
            {hallazgos.length === 0 ? (
              <p className="text-sm font-bold" style={{ color: COLORES.verde }}>
                ✓ Las tres actas cuadran: válidos + blancos + nulos + impugnados = total votantes, por columna.
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
            <p className="mt-2 text-[10px] text-gray-500">
              R1 = Σ votos + blancos + nulos + impugnados = total votantes (por columna) ·
              R2 = votantes ≤ electores hábiles · R4 = una sola acta por mesa y elección.
            </p>
          </section>

          {/* ===== OBSERVACIONES ===== */}
          <section className="rounded-2xl border-2 bg-white p-5 shadow-sm" style={{ borderColor: COLORES.borde }}>
            <h3
              className="mb-2 text-xs font-black uppercase tracking-[0.2em]"
              style={{ color: COLORES.azulOscuro }}
            >
              5 · Observaciones del Acta
            </h3>
            <textarea
              value={observaciones}
              onChange={(e) => setObservaciones(e.target.value)}
              rows={3}
              placeholder="Retraso en instalación, material incompleto, diferencia declarada al cotejar, etc."
              className="w-full rounded-lg border-2 px-4 py-3 text-sm focus:outline-none"
              style={{ borderColor: COLORES.borde }}
            />
            <p className="mt-1 text-[10px] text-gray-400">
              Las observaciones bloqueantes se generan automáticamente (R1/R2). Aquí van las novedades del papel.
            </p>
          </section>

          {/* ===== ENVÍO ===== */}
          <section className="flex flex-wrap items-center justify-between gap-3">
            <div className="space-y-1">
              {resultado && (
                <p className="rounded-lg bg-green-50 px-4 py-2 text-sm font-semibold text-green-700">
                  {resultado}
                </p>
              )}
              {error && (
                <p className="rounded-lg bg-red-50 px-4 py-2 text-sm font-semibold text-red-700">
                  {error}
                </p>
              )}
            </div>
            <div className="ml-auto flex gap-3">
              <button
                onClick={onCancelar}
                className="rounded-lg border-2 px-5 py-2.5 text-sm font-bold text-gray-600 transition-colors hover:bg-gray-50"
                style={{ borderColor: COLORES.borde }}
              >
                Cancelar
              </button>
              <button
                onClick={enviar}
                disabled={botonDeshabilitado}
                title={
                  bloqueantesActiva.length
                    ? "El acta tiene validaciones bloqueantes (R1/R2)."
                    : undefined
                }
                className="rounded-lg px-8 py-2.5 text-sm font-black uppercase tracking-wider text-white transition-all hover:shadow-lg disabled:opacity-50"
                style={{ backgroundColor: COLORES.azulOscuro }}
              >
                {enviando
                  ? "Enviando…"
                  : `Registrar ${eleccionActiva ? eleccionActiva.tipo_eleccion : ""}`}
              </button>
            </div>
          </section>
        </>
      )}
    </div>
  );
}
