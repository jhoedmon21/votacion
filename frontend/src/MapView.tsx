import { useEffect, useMemo, useState } from "react";
import { MapContainer, TileLayer, Marker, Popup } from "react-leaflet";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { api } from "./api";
import type { VenueMapItem } from "./types";

import iconUrl from "leaflet/dist/images/marker-icon.png";
import iconRetina from "leaflet/dist/images/marker-icon-2x.png";
import shadowUrl from "leaflet/dist/images/marker-shadow.png";

delete (L.Icon.Default.prototype as any)._getIconUrl;
L.Icon.Default.mergeOptions({
  iconRetinaUrl: iconRetina,
  iconUrl,
  shadowUrl,
});

interface Props {
  /** Ubigeo INEI del distrito; sin valor, muestra toda la región. */
  ubigeo?: string;
  alto?: string;
}

/* Centro por defecto de Arequipa (Plaza de Armas), para el ámbito regional. */
const AREQUIPA: [number, number] = [-16.409047, -71.537451];

export default function MapView({ ubigeo, alto = "100%" }: Props) {
  const [venues, setVenues] = useState<VenueMapItem[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [cargando, setCargando] = useState(true);

  useEffect(() => {
    api
      .map()
      .then(setVenues)
      .catch((e) => setError(String(e)))
      .finally(() => setCargando(false));
  }, []);

  const visibles = useMemo(
    () =>
      (ubigeo ? venues.filter((v) => v.ubigeo === ubigeo) : venues).filter(
        (v) => v.latitude != null && v.longitude != null
      ),
    [venues, ubigeo]
  );

  const centro = useMemo<[number, number]>(() => {
    if (visibles.length === 0) return AREQUIPA;
    const lat = visibles.reduce((s, v) => s + v.latitude, 0) / visibles.length;
    const lon = visibles.reduce((s, v) => s + v.longitude, 0) / visibles.length;
    return [lat, lon];
  }, [visibles]);

  if (error) {
    return (
      <div className="flex h-full items-center justify-center p-6 text-center text-sm font-semibold text-red-600">
        No se pudo cargar el mapa: {error}
      </div>
    );
  }
  if (cargando) {
    return (
      <div className="flex h-full items-center justify-center p-6 text-sm text-slate-500">
        Cargando locales…
      </div>
    );
  }
  if (visibles.length === 0) {
    return (
      <div className="flex h-full items-center justify-center p-6 text-center text-sm text-slate-500">
        Sin locales georreferenciados en este ámbito.
      </div>
    );
  }

  return (
    <div className="relative h-full w-full">
      {/* key: al cambiar el ámbito se recentra el mapa en lugar de quedar en el
          encuadre anterior. */}
      <MapContainer
        key={ubigeo ?? "region"}
        center={centro}
        zoom={ubigeo ? 13 : 10}
        style={{ height: alto, width: "100%" }}
        scrollWheelZoom={false}
      >
        <TileLayer
          attribution='&copy; OpenStreetMap contributors'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        {visibles.map((v) => (
          <Marker key={v.id} position={[v.latitude, v.longitude]}>
            <Popup>
              <strong>{v.name}</strong>
              <br />
              {v.sector}
              {v.ubigeo && (
                <>
                  <br />
                  Ubigeo: {v.ubigeo}
                </>
              )}
              <br />
              Mesas: {v.processed_tables}/{v.total_tables}
              {v.winner && (
                <>
                  <br />
                  <span style={{ color: v.winner.color }}>
                    Ganador: {v.winner.name} ({v.winner.votes})
                  </span>
                </>
              )}
            </Popup>
          </Marker>
        ))}
      </MapContainer>
      <span className="absolute right-2 top-2 z-[400] rounded-lg border border-slate-200 bg-white/95 px-2.5 py-1 text-[11px] font-black text-[#002B66] shadow-xs">
        {visibles.length} local{visibles.length === 1 ? "" : "es"}
      </span>
    </div>
  );
}
