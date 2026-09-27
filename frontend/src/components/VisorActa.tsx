import { useEffect, useRef, useState } from "react";

/* ==================================================================== *
 *  VisorActa — columna izquierda del split-view de carga de actas.
 *
 *  UX especificada:
 *   · ESTADO VACÍO  → dropzone atractiva (arrastrar o seleccionar) con
 *     el CTA "Cargar Acta"; la foto NUNCA se renderiza abajo del todo.
 *   · ESTADO CARGADO → la imagen ocupa el visor al instante (80vh en
 *     escritorio) con fade-in; sin scroll para verla.
 *   · Barra de herramientas FLOTANTE sobre la imagen: zoom ±, reset,
 *     rotar 90°, filtro de contraste/B&N para manuscritos borrosos y
 *     pantalla completa.
 *   · Atajos de teclado: + / − (zoom), R (rotar), C (contraste),
 *     F (pantalla completa). Se ignoran mientras se escribe en inputs.
 *   · La marca institucional (rojo) destaca el CTA; el resto es blanco/
 *     gris muy claro para que el acta sea la protagonista.
 * ==================================================================== */

interface VisorActaProps {
  /** URL de la foto ya subida (null = estado vacío). */
  fotoUrl: string | null;
  /** Subida en curso: overlay de progreso sobre el visor. */
  subiendo: boolean;
  /** Archivo elegido/arrastrado → el padre lo sube al servidor. */
  onArchivo: (file: File) => void;
  /** Quita la foto cargada (permite reintentar). */
  onQuitar: () => void;
  /** Métricas WebP del servidor (chip informativo). */
  pesos?: { original: number | null; final: number | null } | null;
}

type Filtro = "normal" | "mejora" | "byn";

const ZOOM_MIN = 0.5;
const ZOOM_MAX = 4;
const ZOOM_PASO = 0.25;

const FILTROS: Array<{ clave: Filtro; etiqueta: string; css: string }> = [
  { clave: "normal", etiqueta: "Original", css: "none" },
  { clave: "mejora", etiqueta: "Contraste+", css: "contrast(1.4) brightness(1.06) saturate(0.85)" },
  { clave: "byn", etiqueta: "B/N", css: "grayscale(1) contrast(1.3)" },
];

export default function VisorActa({ fotoUrl, subiendo, onArchivo, onQuitar, pesos }: VisorActaProps) {
  const [zoom, setZoom] = useState(1);
  const [rotacion, setRotacion] = useState(0);
  const [filtro, setFiltro] = useState<Filtro>("normal");
  const [arrastrando, setArrastrando] = useState(false);
  const [pantallaCompleta, setPantallaCompleta] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const marcoRef = useRef<HTMLDivElement>(null);

  /* Nueva foto → transformas a su estado base. */
  useEffect(() => {
    setZoom(1);
    setRotacion(0);
    setFiltro("normal");
  }, [fotoUrl]);

  /* Estado del botón de pantalla completa (el usuario puede salir con Esc). */
  useEffect(() => {
    const sync = () => setPantallaCompleta(Boolean(document.fullscreenElement));
    document.addEventListener("fullscreenchange", sync);
    return () => document.removeEventListener("fullscreenchange", sync);
  }, []);

  const acercar = () => setZoom((z) => Math.min(ZOOM_MAX, +(z + ZOOM_PASO).toFixed(2)));
  const alejar = () => setZoom((z) => Math.max(ZOOM_MIN, +(z - ZOOM_PASO).toFixed(2)));
  const rotar = () => setRotacion((r) => (r + 90) % 360);
  const ciclarFiltro = () =>
    setFiltro((f) => FILTROS[(FILTROS.findIndex((x) => x.clave === f) + 1) % FILTROS.length].clave);
  const alternarPantallaCompleta = () => {
    if (document.fullscreenElement) void document.exitFullscreen();
    else void marcoRef.current?.requestFullscreen();
  };

  /* Atajos globales (guard: no robar teclas mientras se digita). */
  useEffect(() => {
    const enInput = (t: EventTarget | null) =>
      t instanceof HTMLElement && ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName);
    const onKey = (e: KeyboardEvent) => {
      if (enInput(e.target) || e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.key === "+" || e.key === "=") acercar();
      else if (e.key === "-") alejar();
      else if (e.key.toLowerCase() === "r") rotar();
      else if (e.key.toLowerCase() === "c") ciclarFiltro();
      else if (e.key.toLowerCase() === "f" && fotoUrl) alternarPantallaCompleta();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fotoUrl]);

  const soltar = (e: React.DragEvent) => {
    e.preventDefault();
    setArrastrando(false);
    if (subiendo) return;
    const f = e.dataTransfer.files?.[0];
    if (f && f.type.startsWith("image/")) onArchivo(f);
  };

  const filtroCss = FILTROS.find((f) => f.clave === filtro)?.css ?? "none";
  const indiceFiltro = FILTROS.findIndex((f) => f.clave === filtro);

  const botonHerramienta =
    "flex h-9 items-center gap-1 rounded-lg border border-slate-200 bg-white/95 px-2.5 text-sm font-bold text-slate-700 shadow-sm transition hover:bg-white hover:shadow disabled:opacity-40";

  return (
    <div id="visor-acta" className="scroll-mt-20 lg:sticky lg:top-4">
      <div
        ref={marcoRef}
        className={`visor-marco relative flex min-h-[46vh] items-center justify-center overflow-hidden rounded-2xl border bg-slate-100 shadow-sm transition-colors lg:min-h-[80vh] ${
          pantallaCompleta ? "border-slate-800" : arrastrando ? "border-2 border-dashed border-[#E02020] bg-red-50" : "border-slate-200"
        }`}
        onDragOver={(e) => { e.preventDefault(); if (!fotoUrl) setArrastrando(true); }}
        onDragLeave={() => setArrastrando(false)}
        onDrop={soltar}
      >
        {fotoUrl ? (
          <>
            {/* Imagen: fade-in al cargar; transformaciones sin recortar */}
            <div className="visor-fade h-full w-full overflow-auto p-3">
              <img
                key={fotoUrl}
                src={fotoUrl}
                alt="Acta electoral cargada"
                className="mx-auto max-h-[84vh] w-auto max-w-full rounded-lg shadow-md transition-transform duration-200"
                style={{ transform: `scale(${zoom}) rotate(${rotacion}deg)`, filter: filtroCss }}
              />
            </div>

            {/* Barra de herramientas FLOTANTE sobre la imagen */}
            <div className="absolute inset-x-2 top-2 z-10 flex flex-wrap items-center justify-center gap-1.5 rounded-xl border border-slate-200 bg-white/85 p-1.5 shadow-lg backdrop-blur">
              <button className={botonHerramienta} onClick={alejar} title="Alejar (−)" aria-label="Alejar">−</button>
              <span className="w-14 text-center font-mono text-xs font-black text-slate-600">{Math.round(zoom * 100)}%</span>
              <button className={botonHerramienta} onClick={acercar} title="Acercar (+)" aria-label="Acercar">+</button>
              <button className={botonHerramienta} onClick={() => { setZoom(1); setRotacion(0); }} title="Restablecer (100%)">⟲</button>
              <span className="mx-0.5 h-6 w-px bg-slate-200" aria-hidden="true" />
              <button className={botonHerramienta} onClick={rotar} title="Rotar 90° (R)">⟳</button>
              <button
                className={`${botonHerramienta} ${filtro !== "normal" ? "border-[#E02020] bg-[#E02020] text-white hover:bg-[#c41b1b]" : ""}`}
                onClick={ciclarFiltro}
                title="Filtro de contraste para manuscritos (C)"
              >
                ◐ {FILTROS[indiceFiltro].etiqueta}
              </button>
              <span className="mx-0.5 h-6 w-px bg-slate-200" aria-hidden="true" />
              <button className={botonHerramienta} onClick={alternarPantallaCompleta} title="Pantalla completa (F)">
                {pantallaCompleta ? "⤡" : "⛶"}
              </button>
              <button className={botonHerramienta} onClick={() => inputRef.current?.click()} disabled={subiendo} title="Cambiar foto">
                📷 Cambiar
              </button>
            </div>

            {/* Chip de métricas + quitar */}
            <div className="absolute bottom-2 left-1/2 z-10 flex -translate-x-1/2 items-center gap-2 rounded-full border border-slate-200 bg-white/90 px-3 py-1 text-[11px] font-bold text-slate-600 shadow backdrop-blur">
              <span className="text-emerald-700">Foto lista ✓</span>
              {pesos?.final != null && <span className="text-slate-400">· {Math.round(pesos.final)} KB</span>}
              <button onClick={onQuitar} className="font-bold text-red-600 hover:underline">Quitar</button>
            </div>
          </>
        ) : (
          /* ============ ESTADO VACÍO: DROPZONE ============ */
          <div className="flex flex-col items-center justify-center px-6 py-14 text-center">
            <div className="flex h-20 w-20 items-center justify-center rounded-2xl border-2 border-dashed border-[#E02020]/40 bg-white text-4xl shadow-xs">
              📄
            </div>
            <p className="mt-4 text-lg font-black text-slate-800">Arrastra o selecciona el acta aquí</p>
            <p className="mt-1 max-w-sm text-sm text-slate-500">
              La fotografía del acta física es obligatoria como evidencia y se
              asociará a la mesa al registrar.
            </p>
            <button
              onClick={() => inputRef.current?.click()}
              disabled={subiendo}
              className="mt-5 rounded-xl bg-[#E02020] px-8 py-3 text-sm font-black uppercase tracking-wider text-white shadow-lg shadow-red-200 transition hover:bg-[#c41b1b] disabled:opacity-50"
            >
              {subiendo ? "⏳ Subiendo…" : "📷 Cargar Acta"}
            </button>
            <p className="mt-3 text-xs text-slate-400">Formatos de imagen · se optimiza a WebP en el servidor</p>
          </div>
        )}

        {/* Overlay de subida en curso */}
        {subiendo && (
          <div className="absolute inset-0 z-20 flex items-center justify-center bg-white/70 backdrop-blur-sm">
            <p className="rounded-xl bg-white px-5 py-3 text-sm font-black text-[#E02020] shadow-lg">
              ⏳ Optimizando y subiendo el acta…
            </p>
          </div>
        )}
      </div>

      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        capture="environment"
        className="hidden"
        onChange={(e) => {
          const f = e.target.files?.[0];
          if (f) onArchivo(f);
          e.target.value = "";
        }}
      />
    </div>
  );
}
