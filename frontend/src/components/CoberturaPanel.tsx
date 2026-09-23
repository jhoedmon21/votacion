import { useEffect, useMemo, useState } from "react";
import { MapContainer, TileLayer, Marker, Popup } from "react-leaflet";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { api, sesionGuardada } from "../api";
import type { CoberturaLocal } from "../types";
import { Alerta, Barra, Cargando, Contacto, Insignia, Tarjeta, Vacio } from "./ui";

/* ==================================================================== *
 *  Semáforo de Cobertura de Personeros (rediseño UX)
 *
 *  Lenguaje claro primero, término técnico después:
 *    🟢 Listo ...... todas las mesas con gente presente (VERDE)
 *    🟡 A medias ... todas asignadas, falta presencia en alguna (AMARILLO)
 *    🔴 Sin cubrir . hay mesas sin ningún personero (ROJO)
 *
 *  Vista de lista por defecto (rápida y legible); mapa opcional.
 * ==================================================================== */

type Nivel = CoberturaLocal["nivel"];

const NIVEL: Record<Nivel, { color: string; titulo: string; accion: string }> = {
  VERDE: {
    color: "#10B981",
    titulo: "Listos",
    accion: "Todo cubierto, sin acciones pendientes.",
  },
  AMARILLO: {
    color: "#F59E0B",
    titulo: "A medias",
    accion: "Falta que lleguen al local.",
  },
  ROJO: {
    color: "#DC2626",
    titulo: "Sin cubrir",
    accion: "Urgente: asignar personeros.",
  },
};

interface DistritoOpt {
  ubigeo: string;
  distrito: string;
}

function pinCobertura(nivel: Nivel): L.DivIcon {
  return L.divIcon({
    className: "",
    html: `<div style="width:30px;height:30px;border-radius:50%;background:${NIVEL[nivel].color};border:3px solid #fff;box-shadow:0 1px 6px rgba(0,0,0,.45);"></div>`,
    iconSize: [30, 30],
    iconAnchor: [15, 15],
    popupAnchor: [0, -16],
  });
}

export default function CoberturaPanel() {
  const [locales, setLocales] = useState<CoberturaLocal[]>([]);
  const [nombres, setNombres] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [cargando, setCargando] = useState(true);
  const [filtro, setFiltro] = useState<Nivel | "TODOS">("TODOS");
  const [busqueda, setBusqueda] = useState("");
  const [distrito, setDistrito] = useState("");
  const [vista, setVista] = useState<"lista" | "mapa">("lista");

  useEffect(() => {
    setCargando(true);
    api
      .cobertura()
      .then((l) => {
        setLocales(l);
        setError(null);
      })
      .catch((e) => setError(String(e)))
      .finally(() => setCargando(false));

    const s = sesionGuardada();
    fetch("/api/v1/ubigeo/distritos", {
      headers: s ? { Authorization: `Bearer ${s.token}` } : {},
    })
      .then((r) => (r.ok ? r.json() : []))
      .then((d: DistritoOpt[]) =>
        setNombres(Object.fromEntries(d.map((x) => [x.ubigeo, x.distrito])))
      )
      .catch(() => undefined);
  }, []);

  const resumen = useMemo(() => {
    const r: Record<Nivel, number> = { VERDE: 0, AMARILLO: 0, ROJO: 0 };
    for (const l of locales) r[l.nivel] += 1;
    return r;
  }, [locales]);

  const ubigeos = useMemo(
    () => [...new Set(locales.map((l) => l.ubigeo).filter((u): u is string => !!u))].sort(),
    [locales]
  );

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return locales.filter(
      (l) =>
        (filtro === "TODOS" || l.nivel === filtro) &&
        (!distrito || l.ubigeo === distrito) &&
        (!q ||
          l.nombre.toLowerCase().includes(q) ||
          (l.sector ?? "").toLowerCase().includes(q) ||
          (nombres[l.ubigeo ?? ""] ?? "").toLowerCase().includes(q))
    );
  }, [locales, filtro, busqueda, distrito, nombres]);

  const nombreDistrito = (u: string | null) =>
    (u && nombres[u]) || u || "—";

  if (cargando) {
    return (
      <Tarjeta clase="mb-8">
        <Cargando texto="Cargando cobertura de personeros…" />
      </Tarjeta>
    );
  }

  if (error) {
    return (
      <div className="mb-8">
        <Alerta tono="error">No se pudo cargar la cobertura: {error}</Alerta>
      </div>
    );
  }

  const centro: [number, number] =
    visibles.length > 0
      ? [visibles[0].latitude, visibles[0].longitude]
      : [-16.409, -71.537];

  return (
    <section className="mb-8 rounded-2xl border border-slate-200 bg-white p-4 shadow-xs sm:p-6">
      <h3 className="text-base font-black text-[#E02020]">
        ¿Dónde falta gente?
      </h3>
      <p className="mt-0.5 text-xs text-slate-500">
        Semáforo de cobertura de personeros por local ·{" "}
        {locales.length} locales en tu alcance
      </p>

      {/* Tarjetas de estado: tocar filtra */}
      <div className="mt-4 grid grid-cols-3 gap-2 sm:gap-3">
        {(["ROJO", "AMARILLO", "VERDE"] as const).map((n) => {
          const activo = filtro === n;
          return (
            <button
              key={n}
              onClick={() => setFiltro(activo ? "TODOS" : n)}
              aria-pressed={activo}
              className={`min-h-[76px] rounded-2xl border-2 p-3 text-left transition active:scale-[0.98] ${
                activo ? "border-slate-800 shadow" : "border-slate-200 hover:border-slate-300"
              }`}
            >
              <span
                className="inline-block h-3.5 w-3.5 rounded-full"
                style={{ backgroundColor: NIVEL[n].color }}
              />
              <span className="mt-1 block font-mono text-2xl font-black text-slate-800">
                {resumen[n]}
              </span>
              <span className="block text-xs font-black text-slate-700">
                {NIVEL[n].titulo}
              </span>
              <span className="hidden text-[11px] text-slate-400 sm:block">
                {NIVEL[n].accion}
              </span>
            </button>
          );
        })}
      </div>

      {/* Buscador + filtros */}
      <div className="mt-4 flex flex-col gap-2 sm:flex-row">
        <input
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
          placeholder="🔍 Buscar colegio, sector o distrito…"
          className="min-h-[44px] flex-1 rounded-xl border-2 border-slate-300 px-4 text-sm focus:border-[#E02020] focus:outline-none"
        />
        <div className="flex gap-2">
          {ubigeos.length > 0 && (
            <select
              value={distrito}
              onChange={(e) => setDistrito(e.target.value)}
              className="min-h-[44px] rounded-xl border-2 border-slate-300 bg-white px-3 text-sm font-semibold"
              aria-label="Filtrar por distrito"
            >
              <option value="">Todos los distritos</option>
              {ubigeos.map((u) => (
                <option key={u} value={u}>
                  {nombreDistrito(u)}
                </option>
              ))}
            </select>
          )}
          <div className="flex overflow-hidden rounded-xl border-2 border-slate-300">
            {(["lista", "mapa"] as const).map((v) => (
              <button
                key={v}
                onClick={() => setVista(v)}
                className={`min-h-[44px] px-4 text-sm font-bold capitalize ${
                  vista === v ? "bg-[#E02020] text-white" : "bg-white text-slate-500"
                }`}
              >
                {v === "lista" ? "📋 Lista" : "🗺 Mapa"}
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* Resultados */}
      {visibles.length === 0 ? (
        <div className="mt-4">
          <Vacio
            titulo="Sin locales con esos filtros"
            bajada="Prueba con otra búsqueda o toca una tarjeta de estado."
          />
        </div>
      ) : vista === "lista" ? (
        <ul className="mt-4 max-h-[480px] space-y-2 overflow-y-auto pr-1">
          {visibles.map((l) => {
            const pct =
              l.mesas_total > 0
                ? Math.round((100 * l.mesas_con_presencia) / l.mesas_total)
                : 0;
            const faltan = l.mesas_total - l.mesas_con_presencia;
            return (
              <li
                key={l.local_id}
                className="rounded-xl border border-slate-200 p-3"
              >
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-bold text-slate-800">
                      {l.nombre}
                    </p>
                    <p className="text-[11px] text-slate-500">
                      {nombreDistrito(l.ubigeo)}
                      {l.sector ? ` · ${l.sector}` : ""}
                    </p>
                  </div>
                  <Insignia color={NIVEL[l.nivel].color}>
                    {NIVEL[l.nivel].titulo}
                  </Insignia>
                </div>
                <div className="mt-2">
                  <Barra pct={pct} color={NIVEL[l.nivel].color} />
                </div>
                <p className="mt-1.5 text-xs font-semibold text-slate-600">
                  {l.mesas_con_presencia}/{l.mesas_total} mesas con gente
                  {faltan > 0 && l.nivel === "ROJO" && (
                    <span className="text-red-700">
                      {" "}· faltan {faltan} por cubrir
                    </span>
                  )}
                  {faltan > 0 && l.nivel === "AMARILLO" && (
                    <span className="text-amber-700">
                      {" "}· {faltan} sin llegar
                    </span>
                  )}
                </p>
                {l.mesas_criticas.length > 0 && (
                  <p className="mt-1 text-[11px] font-semibold text-red-600">
                    Mesas críticas: {l.mesas_criticas.join(", ")}
                  </p>
                )}
                {l.personeros.length > 0 && (
                  <div className="mt-2 space-y-1 border-t border-slate-100 pt-2">
                    {l.personeros.slice(0, 3).map((p) => (
                      <div key={p.nombre} className="flex flex-wrap items-center justify-between gap-1.5">
                        <span className="text-[11px] font-semibold text-slate-600">
                          {p.estado === "PRESENTE" ? "🟢" : "⚪"} {p.nombre}
                        </span>
                        <Contacto telefono={p.telefono} compacto />
                      </div>
                    ))}
                    {l.personeros.length > 3 && (
                      <p className="text-[11px] text-slate-400">
                        +{l.personeros.length - 3} más en la pestaña Personeros
                      </p>
                    )}
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      ) : (
        <div className="mt-4 h-[380px] overflow-hidden rounded-xl border border-slate-200">
          <MapContainer
            center={centro}
            zoom={12}
            style={{ height: "100%", width: "100%" }}
            scrollWheelZoom={false}
          >
            <TileLayer
              attribution="&copy; OpenStreetMap contributors"
              url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
            />
            {visibles.map((l) => (
              <Marker
                key={l.local_id}
                position={[l.latitude, l.longitude]}
                icon={pinCobertura(l.nivel)}
              >
                <Popup>
                  <div style={{ minWidth: 200 }}>
                    <strong>{l.nombre}</strong>
                    <br />
                    <span style={{ color: NIVEL[l.nivel].color, fontWeight: 700 }}>
                      ● {NIVEL[l.nivel].titulo}
                    </span>
                    <br />
                    <span style={{ fontSize: 12 }}>
                      {nombreDistrito(l.ubigeo)}
                      {l.sector ? ` · ${l.sector}` : ""}
                      <br />
                      {l.mesas_con_presencia}/{l.mesas_total} mesas con gente
                    </span>
                    {l.mesas_criticas.length > 0 && (
                      <>
                        <br />
                        <span style={{ color: "#DC2626", fontSize: 11 }}>
                          Sin cubrir: {l.mesas_criticas.join(", ")}
                        </span>
                      </>
                    )}
                  </div>
                </Popup>
              </Marker>
            ))}
          </MapContainer>
        </div>
      )}

      {/* Leyenda en claro */}
      <div className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-[11px] font-semibold text-slate-500">
        <span>🟢 Listo = todas las mesas con gente presente</span>
        <span>🟡 A medias = asignadas, falta que lleguen</span>
        <span>🔴 Sin cubrir = hay mesas sin personero</span>
      </div>
    </section>
  );
}
