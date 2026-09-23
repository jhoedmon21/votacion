import { useEffect, useMemo, useState } from "react";
import { GeoJSON, MapContainer, useMap } from "react-leaflet";
import L from "leaflet";
import type { Feature, GeoJsonObject, Geometry } from "geojson";
import { api } from "../api";
import type { ChoroplethDistrito } from "../types";

/* Capas vectoriales de Arequipa generadas desde el GeoJSON nacional de Perú
   (backend/tools/generar_geo_arequipa.py): ubigeo INEI en "u". */
interface FeatureGeo {
  u: string;
  n: string;
  pv?: string;
  pvn?: string;
  geo: Geometry;
}
interface DatosGeo {
  region: FeatureGeo | null;
  provincias: FeatureGeo[];
  distritos: FeatureGeo[];
}

interface Props {
  /** Ubigeo INEI del distrito seleccionado (filtro del tablero); "" = región. */
  ubigeoSel: string;
  /** Al hacer clic en un distrito: sincroniza el filtro y los KPIs del tablero. */
  onSelectUbigeo: (ubigeo: string) => void;
  alto?: string;
  /** Modo de coloreado inicial (el usuario puede alternar en el mapa). */
  modoInicial?: "avance" | "ganador";
}

type Nivel = "distritos" | "provincias";
type Modo = "avance" | "ganador";

/* Escala secuencial de avance (0 → 100 %), azul institucional. */
const RAMPA: Array<{ hasta: number; color: string; etiqueta: string }> = [
  { hasta: 0, color: "#E2E8F0", etiqueta: "0 %" },
  { hasta: 25, color: "#C7D9F2", etiqueta: "1–25 %" },
  { hasta: 50, color: "#8FB3E3", etiqueta: "25–50 %" },
  { hasta: 75, color: "#4E7DC4", etiqueta: "50–75 %" },
  { hasta: 99.9, color: "#2C5BA8", etiqueta: "75–99 %" },
  { hasta: 100, color: "#E02020", etiqueta: "100 %" },
];

function colorAvance(avance: number): string {
  for (const r of RAMPA) if (avance <= r.hasta) return r.color;
  return RAMPA[RAMPA.length - 1].color;
}

/* Encaja el mapa sobre la silueta indicada cada vez que cambia `llave`.
   Debe renderizarse DENTRO de <MapContainer> (usa useMap). */
function Enfoque({ objetivo, llave }: { objetivo: Geometry | null; llave: string }) {
  const map = useMap();
  useEffect(() => {
    if (!objetivo) return;
    /* El paquete de tipos 'geojson' de react-leaflet no incluye Feature en
       GeoJsonObject; el objeto es válido en runtime (Leaflet sí lo acepta). */
    const capa = L.geoJSON(
      { type: "Feature", geometry: objetivo, properties: {} } as unknown as GeoJsonObject
    );
    const b = capa.getBounds();
    if (b.isValid()) {
      map.flyToBounds(b, { padding: [28, 28], duration: 0.8 });
    }
  }, [llave, objetivo, map]);
  return null;
}

export default function ChoroplethMap({ ubigeoSel, onSelectUbigeo, alto = "100%", modoInicial = "avance" }: Props) {
  const [datos, setDatos] = useState<DatosGeo | null>(null);
  const [stats, setStats] = useState<ChoroplethDistrito[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [nivel, setNivel] = useState<Nivel>("distritos");
  const [modo, setModo] = useState<Modo>(modoInicial);
  const [provinciaFoco, setProvinciaFoco] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([
      fetch("/data/geo/arequipa_geo.json").then((r) => {
        if (!r.ok) throw new Error(`capas geográficas (${r.status})`);
        return r.json() as Promise<DatosGeo>;
      }),
      api.choropleth(),
    ])
      .then(([geo, st]) => {
        setDatos(geo);
        setStats(st);
      })
      .catch((e) => setError(String(e?.message ?? e)));
  }, []);

  /* Si el filtro del tablero cambia, el coroplético baja a distritos. */
  useEffect(() => {
    if (ubigeoSel) setNivel("distritos");
  }, [ubigeoSel]);

  const statPor = useMemo(() => {
    const m = new Map<string, ChoroplethDistrito>();
    for (const s of stats) m.set(s.ubigeo, s);
    return m;
  }, [stats]);

  /* Agregado provincial: mesas/procesadas sumadas por prefijo 040X. */
  const statsProvincia = useMemo(() => {
    const m = new Map<string, { mesas: number; procesadas: number }>();
    for (const s of stats) {
      const k = s.ubigeo.slice(0, 4);
      const f = m.get(k) ?? { mesas: 0, procesadas: 0 };
      f.mesas += s.mesas;
      f.procesadas += s.procesadas;
      m.set(k, f);
    }
    return m;
  }, [stats]);

  if (error) {
    return (
      <div className="flex h-full items-center justify-center p-6 text-center text-sm font-semibold text-red-600">
        No se pudo cargar el mapa coroplético: {error}
      </div>
    );
  }
  if (!datos) {
    return (
      <div className="flex h-full items-center justify-center p-6 text-sm text-slate-500">
        Cargando capas geográficas…
      </div>
    );
  }

  const distritoSel = datos.distritos.find((d) => d.u === ubigeoSel) ?? null;
  const provinciaFocoFeat = provinciaFoco
    ? datos.provincias.find((p) => p.u === provinciaFoco) ?? null
    : null;

  /* Silueta al enfocar (prioridad: distrito sel. > provincia en foco > región). */
  const objetivo = distritoSel?.geo ?? provinciaFocoFeat?.geo ?? datos.region?.geo ?? null;
  const llaveEnfoque = `foco:${ubigeoSel || "-"}|${provinciaFoco ?? "-"}|${nivel}`;

  /* Modo "ganador" sólo aplica a distritos; en provincias se cae a avance. */
  const porGanador = modo === "ganador" && nivel === "distritos";

  const estiloDistrito = (d: FeatureGeo): L.PathOptions => {
    const s = statPor.get(d.u);
    const sel = d.u === ubigeoSel;
    return {
      fillColor: porGanador
        ? s?.ganador?.color ?? "#CBD5E1"
        : colorAvance(s?.avance ?? 0),
      fillOpacity: sel ? 0.95 : 0.82,
      color: sel ? "#B91C1C" : "#FFFFFF",
      weight: sel ? 2.5 : 0.8,
    };
  };

  const estiloProvincia = (p: FeatureGeo): L.PathOptions => {
    const f = statsProvincia.get(p.u);
    const avance = f && f.mesas ? (f.procesadas / f.mesas) * 100 : 0;
    const foco = p.u === provinciaFoco;
    return {
      fillColor: colorAvance(avance),
      fillOpacity: 0.82,
      color: foco ? "#B91C1C" : "#FFFFFF",
      weight: foco ? 2.5 : 1,
    };
  };

  const tooltipDistrito = (d: FeatureGeo): string => {
    const s = statPor.get(d.u);
    if (!s) return `<b>${d.n}</b><br/>Sin locales en tu alcance`;
    const gan = s.ganador
      ? `<br/><span style="color:${s.ganador.color};font-weight:700">▲ ${s.ganador.name}: ${s.ganador.votes} votos</span>`
      : "<br/><i>Sin votos registrados</i>";
    return (
      `<b>${d.n}</b> <span style="color:#64748B">(${d.pvn})</span>` +
      `<br/>Mesas: ${s.procesadas}/${s.mesas} · Avance ${s.avance}%` +
      `<br/>Observadas JEE: ${s.observadas} · Locales: ${s.locales}` +
      gan
    );
  };

  const tooltipProvincia = (p: FeatureGeo): string => {
    const f = statsProvincia.get(p.u);
    if (!f || !f.mesas) return `<b>Provincia ${p.n}</b><br/>Sin mesas en tu alcance`;
    return (
      `<b>Provincia ${p.n}</b>` +
      `<br/>Mesas: ${f.procesadas}/${f.mesas} · Avance ${Math.round((f.procesadas / f.mesas) * 100)}%` +
      `<br/><i>Clic para ver sus distritos</i>`
    );
  };

  /* Features visibles según nivel/foco. */
  const feats: Feature<Geometry, FeatureGeo>[] = [];
  if (nivel === "distritos") {
    const lista = provinciaFoco
      ? datos.distritos.filter((d) => d.pv === provinciaFoco)
      : datos.distritos;
    for (const d of lista) feats.push({ type: "Feature", properties: d, geometry: d.geo });
  } else {
    for (const p of datos.provincias) feats.push({ type: "Feature", properties: p, geometry: p.geo });
  }
  const colección =
    { type: "FeatureCollection", features: feats } as unknown as GeoJsonObject;

  const totalMesas = stats.reduce((s, x) => s + x.mesas, 0);
  const totalProc = stats.reduce((s, x) => s + x.procesadas, 0);

  return (
    <div className="relative h-full w-full">
      <MapContainer
        center={[-16.25, -71.7]}
        zoom={8}
        style={{ height: alto, width: "100%", background: "#F1F5F9" }}
        scrollWheelZoom={false}
        attributionControl={false}
      >
        {/* Sin basemap: fondo neutro local, el protagonismo es del coroplético vectorial. */}
        <Enfoque objetivo={objetivo} llave={llaveEnfoque} />
        <GeoJSON
          /* Remonte completo al cambiar nivel/foco/selección: re-estila y
             re-enlaza eventos sin parchear capas a mano. */
          key={`capa-${nivel}-${modo}-${ubigeoSel}-${provinciaFoco ?? "toda"}`}
          data={colección}
          style={(f) => {
            const p = (f?.properties ?? {}) as FeatureGeo;
            return nivel === "distritos" ? estiloDistrito(p) : estiloProvincia(p);
          }}
          onEachFeature={(feature, layer) => {
            const p = feature.properties as FeatureGeo;
            if (nivel === "distritos") {
              layer.bindTooltip(tooltipDistrito(p), { sticky: true });
              layer.on({
                click: () => onSelectUbigeo(p.u === ubigeoSel ? "" : p.u),
                mouseover: (e) => (e.target as L.Path).setStyle({ weight: 2, color: "#E02020" }),
                mouseout: (e) =>
                  (e.target as L.Path).setStyle({
                    weight: p.u === ubigeoSel ? 2.5 : 0.8,
                    color: p.u === ubigeoSel ? "#B91C1C" : "#FFFFFF",
                  }),
              });
            } else {
              layer.bindTooltip(tooltipProvincia(p), { sticky: true });
              layer.on({
                click: () => {
                  setProvinciaFoco(p.u);
                  setNivel("distritos");
                },
                mouseover: (e) => (e.target as L.Path).setStyle({ weight: 2, color: "#E02020" }),
                mouseout: (e) => (e.target as L.Path).setStyle({ weight: 1, color: "#FFFFFF" }),
              });
            }
          }}
        />
      </MapContainer>

      {/* Controles de nivel y modo */}
      <div className="absolute left-2 top-2 z-[400] flex flex-col gap-1">
        <div className="flex overflow-hidden rounded-lg border border-slate-200 bg-white/95 shadow-xs">
          {(["distritos", "provincias"] as Nivel[]).map((n) => (
            <button
              key={n}
              onClick={() => {
                setNivel(n);
                if (n === "provincias") setProvinciaFoco(null);
              }}
              className={`px-2.5 py-1 text-[11px] font-black ${
                nivel === n ? "bg-[#E02020] text-white" : "text-slate-600 hover:bg-slate-100"
              }`}
            >
              {n === "distritos" ? "Distritos" : "Provincias"}
            </button>
          ))}
        </div>
        <div className="flex overflow-hidden rounded-lg border border-slate-200 bg-white/95 shadow-xs">
          {(["avance", "ganador"] as Modo[]).map((m) => (
            <button
              key={m}
              onClick={() => setModo(m)}
              className={`px-2.5 py-1 text-[11px] font-black capitalize ${
                modo === m ? "bg-[#B91C1C] text-white" : "text-slate-600 hover:bg-slate-100"
              }`}
            >
              {m === "avance" ? "Por avance" : "Por ganador"}
            </button>
          ))}
        </div>
        {(ubigeoSel || provinciaFoco) && (
          <button
            onClick={() => {
              setProvinciaFoco(null);
              onSelectUbigeo("");
            }}
            className="rounded-lg border border-slate-200 bg-white/95 px-2.5 py-1 text-left text-[11px] font-black text-[#B91C1C] shadow-xs hover:bg-red-50"
          >
            ✕ Ver toda la región
          </button>
        )}
      </div>

      {/* Leyenda */}
      <div className="absolute bottom-3 left-2 z-[400] max-w-56 rounded-lg border border-slate-200 bg-white/95 px-2.5 py-2 shadow-xs">
        {porGanador ? (
          <>
            <div className="mb-1 text-[10px] font-black uppercase tracking-wide text-slate-500">
              Ganador distrital
            </div>
            <div className="flex flex-wrap gap-x-3 gap-y-1">
              {[...new Map(
                stats.filter((s) => s.ganador).map((s) => [s.ganador!.name, s.ganador!])
              ).values()]
                .sort((a, b) => b.votes - a.votes)
                .slice(0, 6)
                .map((g) => (
                  <span key={g.name} className="flex items-center gap-1 text-[10px] font-bold text-slate-600">
                    <span className="h-2.5 w-2.5 rounded-sm" style={{ background: g.color }} />
                    {g.name}
                  </span>
                ))}
              {stats.every((s) => !s.ganador) && (
                <span className="text-[10px] text-slate-400">Aún sin votos</span>
              )}
            </div>
          </>
        ) : (
          <>
            <div className="mb-1 text-[10px] font-black uppercase tracking-wide text-slate-500">
              Avance de actas
            </div>
            <div className="flex flex-col gap-0.5">
              {RAMPA.map((r) => (
                <span key={r.etiqueta} className="flex items-center gap-1.5 text-[10px] font-bold text-slate-600">
                  <span className="h-2.5 w-4 rounded-sm" style={{ background: r.color }} />
                  {r.etiqueta}
                </span>
              ))}
            </div>
          </>
        )}
      </div>

      {/* Contador del ámbito */}
      <span className="absolute right-2 top-2 z-[400] rounded-lg border border-slate-200 bg-white/95 px-2.5 py-1 text-[11px] font-black text-[#E02020] shadow-xs">
        {totalProc}/{totalMesas} actas · {nivel === "distritos" ? "109 distritos" : "8 provincias"}
      </span>
    </div>
  );
}
