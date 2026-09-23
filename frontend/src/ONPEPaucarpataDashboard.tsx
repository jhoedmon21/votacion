import { useEffect, useState } from "react";
import {
  api, logout, ROLES_CAMPO, ROLES_GESTIONAN_USUARIOS,
  ROLES_GESTORES_CAMPO, sesionGuardada,
} from "./api";
import {
  BarChart3, ClipboardList, IdCard, LayoutDashboard, MapPin, PieChart, Search,
  ShieldCheck, UserCheck, Users, Vote,
} from "lucide-react";
import Actas from "./Actas";
import CoberturaPanel from "./components/CoberturaPanel";
import ConsultaONPE from "./components/ConsultaONPE";
import Credenciales from "./components/Credenciales";
import Dashboard from "./Dashboard";
import MapView from "./MapView";
import ChoroplethMap from "./components/ChoroplethMap";
import MaterialShell, { type NavItem } from "./components/MaterialShell";
import MiPanel from "./components/MiPanel";
import PersonerosPanel from "./components/PersonerosPanel";
import UsuariosPanel from "./components/UsuariosPanel";

type Scope = "REGIONAL" | "PROVINCIAL" | "DISTRITAL";

interface DistritoOpt {
  ubigeo: string;
  provincia: string;
  provincia_nombre: string;
  distrito: string;
  mesas: number;
}

/* Orden oficial de la jornada: 1º Regional, 2º Provincial, 3º Distrital. */
const TABS: Array<{ value: Scope; desc: string }> = [
  { value: "REGIONAL", desc: "GOBIERNO REGIONAL DE AREQUIPA" },
  { value: "PROVINCIAL", desc: "MUNICIPAL PROVINCIAL (AREQUIPA)" },
  { value: "DISTRITAL", desc: "MUNICIPAL DISTRITAL" },
];

/* Vistas del panel. Cada una tiene su hash en la URL (#actas, #computo…) para
   compartir el enlace, que el botón atrás del navegador funcione y que recargar
   la página no devuelva siempre al panel principal. */
const VISTAS = ["panel", "actas", "computo", "consulta", "credenciales",
  "personeros", "usuarios"] as const;
type Vista = (typeof VISTAS)[number];

function vistaDeHash(): Vista {
  const h = (window.location.hash || "").replace(/^#\/?/, "").toLowerCase();
  return (VISTAS as readonly string[]).includes(h) ? (h as Vista) : "panel";
}

function formatVotes(n: number): string {
  return n.toLocaleString("es-PE");
}

/* Sombrea un color hex para degradados estilo Material. */
function sombrear(hex: string, factor: number): string {
  const h = (hex || "#002B66").replace("#", "");
  const n = parseInt(h.length === 3 ? h.split("").map((c) => c + c).join("") : h, 16);
  const f = (v: number) => Math.max(0, Math.min(255, Math.round(v * factor)));
  const r = f((n >> 16) & 255);
  const g = f((n >> 8) & 255);
  const b = f(n & 255);
  return `rgb(${r}, ${g}, ${b})`;
}

const ROL_BADGE: Record<string, string> = {
  SUPER_ADMIN: "bg-violet-600",
  DIGITADOR_GLOBAL: "bg-indigo-600",
  COORD_PROVINCIAL: "bg-blue-700",
  RESPONSABLE_DISTRITAL: "bg-sky-600",
  COORD_LOCAL: "bg-cyan-700",
  DELEGADO_MESA: "bg-emerald-700",
  PERSONERO: "bg-emerald-700",
};

const ROL_CORTO: Record<string, string> = {
  SUPER_ADMIN: "Super Admin",
  DIGITADOR_GLOBAL: "Digitador Global",
  COORD_PROVINCIAL: "Coord. Provincial",
  RESPONSABLE_DISTRITAL: "Coord. Distrital",
  COORD_LOCAL: "Coord. Local",
  DELEGADO_MESA: "Delegado",
  PERSONERO: "Personero",
};

function fechaHoy(): string {
  try {
    return new Date().toLocaleDateString("es-PE", {
      weekday: "short",
      day: "numeric",
      month: "short",
    });
  } catch {
    return "";
  }
}

export default function ONPEPaucarpataDashboard() {
  const [activeScope, setActiveScope] = useState<Scope>("REGIONAL");
  const [summary, setSummary] = useState<any>(null);
  const [error, setError] = useState<string | null>(null);
  const [vista, setVista] = useState<Vista>(vistaDeHash);
  const [seccion, setSeccion] = useState<"votos" | "personeros">("votos");
  // Mapa de la sección Ubicación Electoral: coroplético por defecto.
  const [vistaMapa, setVistaMapa] = useState<"coropletico" | "locales">("coropletico");
  // Orden del listado de agrupaciones: por defecto el del acta (sorteo ONPE),
  // que es el que el personero ve en el papel; "votos" para el ranking.
  const [ordenPartidos, setOrdenPartidos] = useState<"cedula" | "votos">("cedula");
  const [distritos, setDistritos] = useState<DistritoOpt[]>([]);
  const [ubigeoSel, setUbigeoSel] = useState<string>("");
  const miRol = sesionGuardada()?.usuario.rol ?? "";
  const esCampo = ROLES_CAMPO.includes(miRol);
  const puedeGestionarUsuarios = ROLES_GESTIONAN_USUARIOS.includes(miRol);
  const puedeVerPersoneros = ROLES_GESTORES_CAMPO.includes(miRol);

  const vistasPermitidas = new Set<Vista>([
    "panel", "actas", "computo", "consulta", "credenciales",
    ...(puedeVerPersoneros ? (["personeros"] as Vista[]) : []),
    ...(puedeGestionarUsuarios ? (["usuarios"] as Vista[]) : []),
  ]);

  const irA = (destino: Vista) => {
    if (!vistasPermitidas.has(destino)) return;
    setVista(destino);
    if (window.location.hash !== `#${destino}`) {
      window.history.pushState(null, "", `#${destino}`);
    }
  };

  /* El hash manda: atrás/adelante del navegador y los enlaces directos
     (#actas) reabren el panel correspondiente. */
  useEffect(() => {
    const sincronizar = () =>
      setVista(vistasPermitidas.has(vistaDeHash()) ? vistaDeHash() : "panel");
    window.addEventListener("hashchange", sincronizar);
    window.addEventListener("popstate", sincronizar);
    return () => {
      window.removeEventListener("hashchange", sincronizar);
      window.removeEventListener("popstate", sincronizar);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [puedeVerPersoneros, puedeGestionarUsuarios]);

  const [coberturaResumen, setCoberturaResumen] = useState<{
    rojos: number;
    amarillos: number;
    verdes: number;
    total: number;
  } | null>(null);

  useEffect(() => {
    fetch("/api/v1/ubigeo/distritos", {
      headers: sesionGuardada() ? { Authorization: `Bearer ${sesionGuardada()!.token}` } : {},
    })
      .then((r) => (r.ok ? r.json() : []))
      .then((d) => setDistritos(d as DistritoOpt[]))
      .catch(() => setDistritos([]));

    // Resumen ejecutivo de cobertura (una sola carga, todo el alcance).
    api
      .cobertura()
      .then((locs) => {
        const cuenta = (n: string) => locs.filter((l) => l.nivel === n).length;
        setCoberturaResumen({
          rojos: cuenta("ROJO"),
          amarillos: cuenta("AMARILLO"),
          verdes: cuenta("VERDE"),
          total: locs.length,
        });
      })
      .catch(() => setCoberturaResumen(null));
  }, []);

  useEffect(() => {
    const scopeParam = activeScope.toLowerCase();
    api.summary(scopeParam, ubigeoSel || undefined)
      .then(data => {
        setSummary(data);
        setError(null);
      })
      .catch(err => {
        setError(`Error: ${err.message}`);
        setSummary(null);
      });
  }, [activeScope, ubigeoSel]);

  const distSel = distritos.find((d) => d.ubigeo === ubigeoSel) ?? null;
  const nombreDistrito = distSel?.distrito ?? null;
  const etiquetaAmbito = distSel
    ? `${distSel.distrito} (${distSel.provincia_nombre})`
    : "Toda la región";

  const distritosPorProvincia = (() => {
    const mapa = new Map<string, { nombre: string; items: DistritoOpt[] }>();
    for (const d of distritos) {
      const g = mapa.get(d.provincia) ?? { nombre: d.provincia_nombre, items: [] };
      g.items.push(d);
      mapa.set(d.provincia, g);
    }
    return [...mapa.entries()];
  })();

  const onShowActas = () => irA("actas");

  /* Personal de campo: portada propia, sin dashboard general ni datos
     de la región. Sólo sus mesas, su check-in y sus actas. */
  if (esCampo) {
    return (
      <MaterialShell
        nav={[{ id: "mesas", etiqueta: "Mis mesas", icono: "📋", activo: true, onClick: () => undefined }]}
        titulo="Registro en campo"
        bajada={`${sesionGuardada()?.usuario.nombre_completo ?? ""} · ${ROL_CORTO[miRol] ?? miRol}`}
        usuario={sesionGuardada()?.usuario.nombre_completo ?? ""}
        insignia={ROL_CORTO[miRol] ?? miRol}
        colorInsignia={ROL_BADGE[miRol] ?? "bg-slate-500"}
        onSalir={() => { void logout().finally(() => window.location.reload()); }}
      >
        <MiPanel />
      </MaterialShell>
    );
  }

  if (error) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-[#F8F9FA] text-red-600">
        <div className="text-center">
          <h2 className="text-2xl font-bold mb-4">Error de Conexión</h2>
          <p className="text-lg">{error}</p>
          <div className="mt-6">
            <button 
              onClick={() => window.location.reload()}
              className="px-4 py-2 bg-[#002B66] text-white rounded hover:bg-[#003366]"
            >
              Recargar
            </button>
          </div>
        </div>
      </div>
    );
  }

  if (!summary) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-[#F8F9FA]">
        <div className="text-center">
          <h2 className="text-2xl font-bold mb-4">Cargando Dashboard...</h2>
          <p className="text-lg">Espere un momento mientras se cargan los datos...</p>
          <div className="mt-6 flex justify-center space-x-4">
            <div className="w-8 h-8 border-3 border-t-2 border-l-2 border-r-transparent border-b-transparent rounded-full animate-spin border-[#002B66]"></div>
            <span className="ml-2 text-sm text-slate-600">Cargando...</span>
          </div>
        </div>
      </div>
    );
  }

  // Calculate derived values
  // "Resultados Generales por Agrupación Política": se agrega por partido
  // (un mismo partido compite en decenas de distritos; la fila nominal es
  // por distrito y no debe sumarse como serie separada).
  const porPartido: Array<{
    party: string;
    votes: number;
    color: string;
    symbol?: string | null;
    candidato: string;
    /** Bloque y posición del sorteo oficial de la cédula (null si no está). */
    cedula: [number, number] | null;
    /** Casitas que ocupa el partido: son varias cuando la vista agrega ámbitos. */
    casitas: number[];
  }> = (() => {
    const mapa = new Map<
      string,
      {
        party: string;
        votes: number;
        color: string;
        symbol?: string | null;
        nombres: Set<string>;
        cedulas: Set<string>;
        casitas: Set<number>;
      }
    >();
    for (const c of summary.ranking ?? []) {
      const clave = c.party || c.name;
      const actual = mapa.get(clave) ?? {
        party: clave,
        votes: 0,
        color: c.color,
        symbol: c.symbol,
        nombres: new Set<string>(),
        cedulas: new Set<string>(),
        casitas: new Set<number>(),
      };
      actual.votes += c.votes;
      if (c.name) actual.nombres.add(c.name);
      if (!actual.symbol && c.symbol) actual.symbol = c.symbol;
      if (c.bloque_cedula !== null && c.bloque_cedula !== undefined
        && c.posicion_cedula !== null && c.posicion_cedula !== undefined) {
        actual.cedulas.add(`${c.bloque_cedula}:${c.posicion_cedula}`);
      }
      if (typeof c.candidate_id === "number") actual.casitas.add(c.candidate_id);
      mapa.set(clave, actual);
    }
    return [...mapa.values()]
      .map((p) => {
        const [unica] = [...p.cedulas];
        return {
          party: p.party,
          votes: p.votes,
          color: p.color,
          symbol: p.symbol,
          candidato:
            p.nombres.size === 1
              ? [...p.nombres][0]
              : `${p.nombres.size} candidatos`,
          cedula: unica
            ? ([Number(unica.split(":")[0]), Number(unica.split(":")[1])] as [number, number])
            : null,
          casitas: [...p.casitas].sort((a, b) => a - b),
        };
      })
      .sort((a, b) => b.votes - a.votes);
  })();

  // Cédula primero: nacional (bloque 0) en el orden del sorteo, después los
  // movimientos regionales. Quien no pasó por el sorteo va al final.
  const compararCedula = (a: (typeof porPartido)[number], b: (typeof porPartido)[number]) => {
    if (a.cedula && b.cedula) {
      return a.cedula[0] - b.cedula[0] || a.cedula[1] - b.cedula[1];
    }
    if (a.cedula) return -1;
    if (b.cedula) return 1;
    return a.party.localeCompare(b.party);
  };
  const porPartidoOrdenado = ordenPartidos === "cedula"
    ? [...porPartido].sort(compararCedula)
    : porPartido;
  const totalValidVotes = porPartido.reduce((sum, p) => sum + p.votes, 0);
  const sorted = [...(summary.ranking ?? [])].sort((a, b) => b.votes - a.votes);
  const topTwo = sorted.slice(0, 2);
  const processed = summary.processed_tables ?? 0;
  const observed = summary.review_tables ?? 0;
  const pending = Math.max(0, (summary.total_tables ?? 0) - processed - observed);
  const progressPct = summary.progress_pct ?? 0;

  const algunaVista = vista !== "panel";
  const vistaActual: Vista = vista;

  const TITULOS: Record<string, [string, string]> = {
    panel: ["Panel principal", `${etiquetaAmbito} · Regionales y Municipales 2026 · ${fechaHoy()}`],
    actas: ["Gestión de Actas", "Registro, revisión y validación"],
    computo: ["Cómputo Electoral", "KPIs y resultados en vivo"],
    personeros: ["Personeros en Campo", "Equipo, cobertura y check-ins"],
    usuarios: ["Gestión de Usuarios", "Alta y alcance por rol"],
    consulta: ["Consulta ONPE", "Local de votación por DNI o mesa"],
    credenciales: ["Credenciales FA", "Fotochecks Fuerza Arequipeña + QR"],
  };

  const nav: NavItem[] = [
    { id: "panel", etiqueta: "Panel", icono: <LayoutDashboard className="h-5 w-5" />,
      activo: vistaActual === "panel", onClick: () => irA("panel") },
    ...(!esCampo
      ? [
          { id: "actas", etiqueta: "Actas", icono: <ClipboardList className="h-5 w-5" />,
            activo: vistaActual === "actas", onClick: onShowActas },
          { id: "computo", etiqueta: "Cómputo", icono: <BarChart3 className="h-5 w-5" />,
            activo: vistaActual === "computo",
            onClick: () => irA("computo") },
          { id: "consulta", etiqueta: "Consulta", icono: <Search className="h-5 w-5" />,
            activo: vistaActual === "consulta",
            onClick: () => irA("consulta") },
          { id: "credenciales", etiqueta: "Credenciales", icono: <IdCard className="h-5 w-5" />,
            activo: vistaActual === "credenciales",
            onClick: () => irA("credenciales") },
        ]
      : []),
    ...(puedeVerPersoneros
      ? [{ id: "personeros", etiqueta: "Personeros", icono: <UserCheck className="h-5 w-5" />,
            activo: vistaActual === "personeros",
            onClick: () => irA("personeros") }]
      : []),
    ...(puedeGestionarUsuarios
      ? [{ id: "usuarios", etiqueta: "Usuarios", icono: <Users className="h-5 w-5" />,
            activo: vistaActual === "usuarios",
            onClick: () => irA("usuarios") }]
      : []),
  ];

  const [tituloVista, bajadaVista] = TITULOS[vistaActual];

  return (
    <MaterialShell
      nav={nav}
      titulo={tituloVista}
      bajada={bajadaVista}
      usuario={sesionGuardada()?.usuario.nombre_completo ?? ""}
      insignia={ROL_CORTO[miRol] ?? miRol}
      colorInsignia={ROL_BADGE[miRol] ?? "bg-slate-500"}
      onSalir={() => { void logout().finally(() => window.location.reload()); }}
    >

      {vista === "actas" && (
        <div className="rounded-2xl bg-white p-4 shadow-md sm:p-6">
          <Actas />
        </div>
      )}

      {vista === "usuarios" && (
        <div className="rounded-2xl bg-white p-4 shadow-md sm:p-6">
          <UsuariosPanel />
        </div>
      )}

      {vista === "computo" && (
        <div className="rounded-2xl bg-white p-4 shadow-md sm:p-6">
          <Dashboard />
        </div>
      )}

      {vista === "consulta" && (
        <div className="rounded-2xl bg-white p-4 shadow-md sm:p-6">
          <ConsultaONPE />
        </div>
      )}

      {vista === "credenciales" && (
        <div className="rounded-2xl bg-white p-4 shadow-md sm:p-6">
          <Credenciales />
        </div>
      )}

      {vista === "personeros" && (
        <div className="rounded-2xl bg-white p-4 shadow-md sm:p-6">
          <PersonerosPanel />
        </div>
      )}

      {/* MAIN CONTENT: dos secciones separadas — Votos y Personeros */}
      {!algunaVista && (
        <div className="space-y-6">
          {/* ALERTAS OPERATIVAS */}
          {(observed > 0 || (coberturaResumen?.rojos ?? 0) > 0) && (
            <div className="flex flex-wrap items-center gap-x-5 gap-y-2 rounded-2xl border border-amber-300 bg-amber-50 px-5 py-3.5">
              <span className="text-sm font-black uppercase tracking-wider text-amber-800">
                ⚠ Requiere atención
              </span>
              {observed > 0 && (
                <button
                  onClick={onShowActas}
                  className="text-xs font-bold text-amber-800 underline decoration-amber-400 underline-offset-2 hover:text-amber-900"
                >
                  {observed} acta{observed === 1 ? "" : "s"} observada{observed === 1 ? "" : "s"} por revisar →
                </button>
              )}
              {(coberturaResumen?.rojos ?? 0) > 0 && (
                <button
                  onClick={() => setSeccion("personeros")}
                  className="text-xs font-bold text-amber-800 underline decoration-amber-400 underline-offset-2 hover:text-amber-900"
                >
                  {coberturaResumen?.rojos}{" "}
                  {coberturaResumen?.rojos === 1 ? "local sin cubrir" : "locales sin cubrir"} →
                </button>
              )}
            </div>
          )}

          {/* KPIs EJECUTIVOS (estilo Material: baldosa + dato) */}
          <section aria-label="Indicadores" className="grid grid-cols-2 gap-2.5 sm:grid-cols-3 lg:grid-cols-5">
            {([
              ["Mesas en padrón", formatVotes(summary.total_tables ?? 0), "locales en tu alcance",
                <ClipboardList key="k1" className="h-5 w-5" />, "bg-[#002B66]"],
              ["Contabilizadas", formatVotes(processed), `${formatVotes(observed)} observadas`,
                <BarChart3 key="k2" className="h-5 w-5" />, "bg-emerald-600"],
              ["Observadas", formatVotes(observed), "requieren revisión",
                <ShieldCheck key="k3" className="h-5 w-5" />, "bg-amber-500"],
              ["Avance", `${progressPct}%`, "actas sobre mesas",
                <PieChart key="k4" className="h-5 w-5" />, "bg-blue-700"],
              ["Sin cubrir", formatVotes(coberturaResumen?.rojos ?? 0), `de ${formatVotes(coberturaResumen?.total ?? 0)} locales`,
                <MapPin key="k5" className="h-5 w-5" />, "bg-red-600"],
            ] as const).map(([etiqueta, valor, bajada, icono, color]) => (
              <div key={etiqueta} className="flex items-center gap-3 rounded-2xl border border-slate-200 bg-white p-4 shadow-xs">
                <span className={`flex h-11 w-11 shrink-0 items-center justify-center rounded-xl text-white shadow-xs ${color}`}>
                  {icono}
                </span>
                <span className="min-w-0">
                  <span className="block truncate text-[10px] font-black uppercase tracking-wider text-slate-400">
                    {etiqueta}
                  </span>
                  <span className="block font-mono text-xl font-black tabular-nums text-slate-900">
                    {valor}
                  </span>
                  <span className="block truncate text-[11px] text-slate-400">{bajada}</span>
                </span>
              </div>
            ))}
          </section>

          {/* SELECTOR DE SECCIÓN */}
          <div className="grid grid-cols-2 gap-2 rounded-2xl border border-slate-200 bg-white p-2 shadow-xs">
            {([
              ["votos", "Votos", "Actas, resultados y cómputo", <Vote key="v" className="h-5 w-5" />],
              ["personeros", "Personeros", "Cobertura, mapa y equipo de campo", <UserCheck key="p" className="h-5 w-5" />],
            ] as const).map(([valor, titulo, bajada, icono]) => (
              <button
                key={valor}
                onClick={() => setSeccion(valor)}
                aria-pressed={seccion === valor}
                className={`flex min-h-[64px] items-center gap-3 rounded-xl px-4 py-2.5 text-left transition active:scale-[0.99] ${
                  seccion === valor
                    ? "bg-[#002B66] text-white shadow"
                    : "bg-white text-slate-500 hover:bg-slate-50"
                }`}
              >
                <span className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-xl ${
                  seccion === valor ? "bg-white/20 text-white" : "bg-slate-100 text-slate-500"
                }`}>
                  {icono}
                </span>
                <span>
                  <span className="block text-sm font-black">{titulo}</span>
                  <span className={`block text-[11px] ${seccion === valor ? "text-blue-200" : "text-slate-400"}`}>
                    {bajada}
                  </span>
                </span>
              </button>
            ))}
          </div>

          {seccion === "votos" && (
          <>
          {/* SCOPE TABS (orden oficial R → P → D) + SELECTOR DE DISTRITO */}
          <nav className="border-b border-slate-200 bg-slate-100">
            <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-2 px-6">
              {TABS.map(({ value, desc }) => (
                <button
                  key={value}
                  onClick={() => setActiveScope(value)}
                  className={`flex items-center gap-2 border-b-4 px-6 py-3.5 text-xs font-black transition ${
                    activeScope === value
                      ? "border-[#002B66] bg-white text-[#002B66]"
                      : "border-transparent text-slate-500 hover:bg-slate-200"
                  }`}
                >
                  <span>{value === "DISTRITAL" && nombreDistrito ? `MUNICIPAL DISTRITAL (${nombreDistrito})` : desc}</span>
                </button>
              ))}
              <label className="ml-auto flex items-center gap-2 py-2 text-xs font-bold text-slate-600">
                Distrito
                <select
                  value={ubigeoSel}
                  onChange={(e) => setUbigeoSel(e.target.value)}
                  className="max-w-64 rounded-lg border border-slate-300 bg-white px-3 py-2 text-xs font-bold text-slate-700"
                >
                  <option value="">Toda la región (8 provincias)</option>
                  {distritosPorProvincia.map(([prov, g]) => (
                    <optgroup key={prov} label={g.nombre}>
                      {g.items.map((d) => (
                        <option key={d.ubigeo} value={d.ubigeo}>
                          {d.distrito} ({d.mesas} mesas)
                        </option>
                      ))}
                    </optgroup>
                  ))}
                </select>
              </label>
            </div>
          </nav>

          {/* PROGRESS STATUS */}
          <section className="mb-8 rounded-2xl border border-slate-200 bg-white p-6 shadow-xs">
            <div className="flex flex-wrap items-center justify-between gap-4 border-b border-slate-100 pb-4">
              <div>
                <span className="text-xs font-extrabold uppercase tracking-wider text-slate-400">
                  Actas Contabilizadas
                </span>
                <div className="mt-1 flex items-baseline gap-3">
                  <span className="text-4xl font-black text-[#002B66]">{progressPct} %</span>
                  <span className="text-xs font-bold text-slate-600">
                    Total de actas: <strong>{summary.total_tables}</strong> ({etiquetaAmbito})
                  </span>
                </div>
              </div>

              <div className="flex items-center gap-5 text-xs font-bold text-slate-600">
                <span className="flex items-center gap-2">
                  <span className="h-3.5 w-3.5 rounded-full bg-[#002B66]"></span> Contabilizadas
                  ({processed})
                </span>
                <span className="flex items-center gap-2">
                  <span className="h-3.5 w-3.5 rounded-full bg-amber-500"></span> Observadas JEE
                  ({observed})
                </span>
                <span className="flex items-center gap-2">
                  <span className="h-3.5 w-3.5 rounded-full bg-slate-300"></span> Pendientes (
                  {pending})
                </span>
              </div>
            </div>

            <div className="mt-4 h-3.5 w-full overflow-hidden rounded-full bg-slate-100">
              <div
                className="h-full bg-[#002B66] transition-all duration-700"
                style={{ width: `${progressPct}%` }}
              />
            </div>
          </section>

          {/* TOP 2 — tarjetas estilo Material con logo del partido */}
          <div className="mb-6 flex items-center gap-2 text-xs font-black uppercase tracking-wider text-[#002B66]">
            <PieChart className="h-4 w-4" />
            <span>Primeros Lugares (Top 2 Candidatos)</span>
          </div>

          {!summary ? (
            <p className="py-12 text-center text-slate-400">Cargando resultados…</p>
          ) : (
            <section className="mb-10 grid grid-cols-1 gap-6 md:grid-cols-2">
              {topTwo.map((c, idx) => {
                const base = c.color || "#002B66";
                const pctValidos =
                  totalValidVotes > 0 ? (100 * c.votes) / totalValidVotes : 0;
                return (
                  <article
                    key={c.candidate_id}
                    className="overflow-hidden rounded-2xl bg-white shadow-md transition duration-300 hover:-translate-y-0.5 hover:shadow-xl"
                  >
                    {/* Franja superior en degradado del partido */}
                    <div
                      className="px-5 py-4"
                      style={{
                        background: `linear-gradient(135deg, ${base} 0%, ${sombrear(base, 0.55)} 100%)`,
                      }}
                    >
                      <span className="inline-flex items-center rounded-full bg-white/20 px-3 py-1 text-[11px] font-black uppercase tracking-widest text-white">
                        #{idx + 1} en {activeScope.toLowerCase()}
                      </span>
                      <p className="mt-1.5 font-mono text-3xl font-black tabular-nums text-white">
                        {pctValidos.toFixed(1)}
                        <span className="text-lg">%</span>
                        <span className="ml-2 align-middle text-[11px] font-semibold uppercase tracking-wider text-white/70">
                          de votos válidos
                        </span>
                      </p>
                    </div>
                    {/* Identidad: foto + datos + logo, sin superposiciones */}
                    <div className="flex items-center gap-3 px-5 py-4">
                      {c.photo_url ? (
                        <img
                          src={c.photo_url}
                          alt={c.name}
                          className="h-16 w-16 shrink-0 rounded-full bg-slate-100 object-cover shadow-md ring-2 ring-white"
                        />
                      ) : (
                        <span className="flex h-16 w-16 shrink-0 items-center justify-center rounded-full bg-slate-200 text-xl font-black text-slate-500 shadow-md">
                          {(c.name ?? "?").charAt(0)}
                        </span>
                      )}
                      <div className="min-w-0 flex-1">
                        <h3 className="truncate text-base font-black text-slate-900">
                          {c.name}
                        </h3>
                        <p className="truncate text-xs font-bold uppercase tracking-wide text-slate-500">
                          {c.party}
                        </p>
                        <p className="mt-0.5 font-mono text-xs text-slate-500">
                          {formatVotes(c.votes)} votos
                        </p>
                      </div>
                      {c.symbol ? (
                        <img
                          src={c.symbol}
                          alt={c.party}
                          title={c.party}
                          className="h-12 w-12 shrink-0 rounded-xl border border-slate-200 bg-white object-contain p-1 shadow-xs"
                        />
                      ) : (
                        <span
                          className="flex h-12 w-12 shrink-0 items-center justify-center rounded-xl text-base font-black text-white shadow-xs"
                          style={{ backgroundColor: base }}
                          title={c.party}
                        >
                          {(c.party ?? "?").charAt(0)}
                        </span>
                      )}
                    </div>
                    {/* Barra de progreso */}
                    <div className="px-5 pb-5">
                      <div className="h-2.5 overflow-hidden rounded-full bg-slate-100">
                        <div
                          className="h-full rounded-full"
                          style={{
                            width: `${Math.min(100, pctValidos)}%`,
                            background: `linear-gradient(90deg, ${base}, ${sombrear(base, 0.7)})`,
                          }}
                        />
                      </div>
                    </div>
                  </article>
                );
              })}
            </section>
          )}

          {/* BAR CHART (sección votos) */}
          <section>
            <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-xs">
              <div className="mb-6 flex items-center justify-between border-b border-slate-100 pb-3">
                <h3 className="flex items-center gap-2 text-xs font-black uppercase tracking-wider text-[#002B66]">
                  <BarChart3 className="h-4 w-4" />
                  <span>Resultados Generales por Agrupación Política</span>
                </h3>
                <div className="flex items-center gap-3">
                  <div
                    className="flex items-center gap-0.5 rounded-lg bg-slate-100 p-0.5"
                    role="group"
                    aria-label="Orden del listado de agrupaciones"
                  >
                    <button
                      type="button"
                      onClick={() => setOrdenPartidos("cedula")}
                      aria-pressed={ordenPartidos === "cedula"}
                      title="Orden de la cédula (sorteo de la ONPE): nacionales primero, movimientos regionales después"
                      className={`rounded-md px-2.5 py-1 text-[11px] font-black uppercase transition ${
                        ordenPartidos === "cedula"
                          ? "bg-white text-[#002B66] shadow-xs"
                          : "text-slate-500 hover:text-slate-700"
                      }`}
                    >
                      Cédula
                    </button>
                    <button
                      type="button"
                      onClick={() => setOrdenPartidos("votos")}
                      aria-pressed={ordenPartidos === "votos"}
                      title="Ordenar por votos (ranking)"
                      className={`rounded-md px-2.5 py-1 text-[11px] font-black uppercase transition ${
                        ordenPartidos === "votos"
                          ? "bg-white text-[#002B66] shadow-xs"
                          : "text-slate-500 hover:text-slate-700"
                      }`}
                    >
                      Votos
                    </button>
                  </div>
                  <span className="text-[11px] font-bold uppercase text-slate-400">
                    Votos Válidos: {formatVotes(totalValidVotes)}
                  </span>
                </div>
              </div>

              <div className="space-y-2">
                {porPartido.length === 0 && (
                  <p className="py-4 text-center text-sm text-slate-400">
                    Sin votos contabilizados en este ámbito.
                  </p>
                )}
                {porPartidoOrdenado.map((p, idx) => {
                  const pct =
                    totalValidVotes > 0
                      ? ((p.votes / totalValidVotes) * 100).toFixed(2)
                      : "0.00";
                  // Con un solo ámbito la casita es inequívoca; si la vista
                  // agrega distritos, el mismo partido ocupa varias y no se
                  // muestra un número que no correspondería a ninguna acta.
                  const casita = p.casitas.length === 1 ? p.casitas[0] : null;
                  return (
                    <div
                      key={p.party}
                      className="flex items-center gap-3 rounded-xl px-3 py-2.5 transition hover:bg-slate-50"
                    >
                      <span className="w-6 shrink-0 font-mono text-xs font-black text-slate-300">
                        {String(idx + 1).padStart(2, "0")}
                      </span>
                      {p.symbol ? (
                        <img
                          src={p.symbol}
                          alt={p.party}
                          className="h-10 w-10 shrink-0 rounded-xl border border-slate-200 bg-white object-contain p-1 shadow-xs"
                        />
                      ) : (
                        <span
                          className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl text-sm font-black text-white shadow-xs"
                          style={{ backgroundColor: p.color }}
                        >
                          {p.party.charAt(0)}
                        </span>
                      )}
                      <div className="min-w-0 flex-1">
                        <div className="flex items-baseline justify-between gap-2">
                          <p className="truncate text-sm font-black text-slate-800">
                            {p.party}
                          </p>
                          <p className="shrink-0 font-mono text-xs font-bold text-[#002B66]">
                            {pct}% · {formatVotes(p.votes)}
                          </p>
                        </div>
                        <p className="flex items-center gap-1.5 text-[11px] font-semibold text-slate-500">
                          <span className="truncate">{p.candidato}</span>
                          {casita !== null && (
                            <span
                              className="shrink-0 rounded border border-slate-200 bg-slate-50 px-1 py-px font-mono text-[10px] font-bold text-slate-500"
                              title="Casita del acta: la fila de la columna en la cédula"
                            >
                              casita {casita}
                            </span>
                          )}
                        </p>
                        <div className="mt-1.5 h-2 w-full overflow-hidden rounded-full bg-slate-100">
                          <div
                            className="h-full rounded-full transition-all duration-500"
                            style={{
                              width: `${pct}%`,
                              background: `linear-gradient(90deg, ${p.color}, ${sombrear(p.color, 0.7)})`,
                            }}
                          />
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          </section>
          </>
          )}

          {/* ============ SECCIÓN PERSONEROS ============ */}
          {seccion === "personeros" && (
          <>
          {/* Acceso directo a la gestión del equipo */}
          <button
            onClick={() => irA("personeros")}
            className="mb-6 flex w-full min-h-[64px] items-center justify-between gap-3 rounded-2xl border-2 border-[#002B66] bg-blue-50 px-5 py-3 text-left transition hover:bg-blue-100 active:scale-[0.99]"
          >
            <span>
              <span className="block text-sm font-black text-[#002B66]">
                🦺 Gestionar personeros y asignaciones
              </span>
              <span className="block text-[11px] text-slate-500">
                Equipo de campo, mesas asignadas y check-ins del día
              </span>
            </span>
            <span className="text-xl font-black text-[#002B66]">→</span>
          </button>

          {/* Semáforo de cobertura */}
          <CoberturaPanel />

          {/* MAPA DE LOCALES */}
          <section>
            <div className="flex flex-col items-center justify-between rounded-2xl border border-slate-200 bg-white p-6 shadow-xs">
              <div className="mb-4 w-full border-b border-slate-100 pb-2 text-left">
                <h3 className="flex items-center gap-2 text-xs font-black uppercase tracking-wider text-[#002B66]">
                  <MapPin className="h-4 w-4" />
                   <span>Ubicación Electoral: {etiquetaAmbito}</span>
                </h3>
                <p className="text-[11px] text-slate-500">
                  Locales y mesas reales del padrón ONPE de Arequipa
                </p>
              </div>

              {/* Pestañas: coroplético territorial vs. puntos por local. */}
              <div className="mb-3 flex w-full items-center gap-2">
                <div className="flex overflow-hidden rounded-lg border border-slate-200">
                  {([
                    ["coropletico", "Mapa coroplético"],
                    ["locales", "Locales de votación"],
                  ] as const).map(([id, etiqueta]) => (
                    <button
                      key={id}
                      onClick={() => setVistaMapa(id)}
                      className={`px-3 py-1.5 text-[11px] font-black ${
                        vistaMapa === id
                          ? "bg-[#002B66] text-white"
                          : "bg-white text-slate-600 hover:bg-slate-100"
                      }`}
                    >
                      {etiqueta}
                    </button>
                  ))}
                </div>
                {vistaMapa === "coropletico" && !ubigeoSel && (
                  <span className="text-[11px] font-semibold text-slate-400">
                    Clic en un distrito para filtrar el tablero
                  </span>
                )}
              </div>

              <div className="my-4 h-96 w-full overflow-hidden rounded-xl border border-slate-100 bg-slate-50">
                {vistaMapa === "coropletico" ? (
                  <ChoroplethMap
                    ubigeoSel={ubigeoSel}
                    onSelectUbigeo={(u) => setUbigeoSel(u)}
                    alto="24rem"
                  />
                ) : (
                  <MapView ubigeo={ubigeoSel || undefined} alto="24rem" />
                )}
              </div>

              <div className="w-full text-center text-[11px] font-medium text-slate-400">
                {vistaMapa === "coropletico"
                  ? "Siluetas oficiales INEI coloreadas por avance de actas (o ganador distrital). " +
                    "El clic sobre un distrito o provincia enfoca su silueta y recalcula KPIs y ranking."
                  : "Locales reales del padrón ONPE de Arequipa. Cada marcador se ubica " +
                    "en el centro de su distrito: el padrón no publica coordenadas por local."}
              </div>
            </div>
          </section>
          </>
          )}

          {/* BARRA DE ESTADO */}
          <footer className="mt-8 flex flex-wrap items-center justify-between gap-x-6 gap-y-2 rounded-2xl border border-slate-200 bg-white px-6 py-4 text-xs text-slate-500 shadow-xs">
            <span className="flex items-center gap-2 font-bold text-slate-600">
              <ShieldCheck className="h-4 w-4 text-emerald-600" />
              Reconciliación de actas verificada
            </span>
            <span className="flex items-center gap-1.5 font-semibold">
              <span className="h-2 w-2 animate-pulse rounded-full bg-emerald-500" />
              API operativa
            </span>
            <span className="hidden sm:block">
              {etiquetaAmbito} · {activeScope}
            </span>
            <span className="font-mono text-slate-400">Cómputo Arequipa 2026 · v1</span>
          </footer>
        </div>
      )}
    </MaterialShell>
  );
}
