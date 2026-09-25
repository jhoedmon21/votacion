export interface CandidateVotes {
  candidate_id: number;
  votes: number;
}

export interface RankingEntry {
  /** Casita del acta en este ámbito (1..N): la fila de la columna. */
  candidate_id: number;
  name: string;
  party: string;
  color: string;
  votes: number;
  symbol?: string | null;
  photo_url?: string | null;
  /** Bloque de la cédula: 0 = nacional, 1 = movimiento regional. */
  bloque_cedula?: number | null;
  /** Posición de la organización dentro de su bloque del sorteo ONPE. */
  posicion_cedula?: number | null;
}

export interface Summary {
  total_venues: number;
  total_tables: number;
  processed_tables: number;
  review_tables: number;
  progress_pct: number;
  ranking: RankingEntry[];
  scope: string;
}

export interface VenueMapItem {
  id: number;
  name: string;
  sector: string;
  ubigeo: string | null;
  latitude: number;
  longitude: number;
  total_tables: number;
  processed_tables: number;
  winner: { name: string; color: string; votes: number } | null;
}

/* Mapa coroplético — estadísticas por distrito (GET /api/analytics/choropleth). */
export interface ChoroplethDistrito {
  ubigeo: string;
  mesas: number;
  procesadas: number;
  observadas: number;
  locales: number;
  avance: number;
  ganador: { name: string; color: string; votes: number } | null;
}

export interface PersoneroContacto {
  nombre: string;
  telefono: string | null;
  estado: string;
}

export interface CoberturaLocal {
  local_id: number;
  nombre: string;
  ubigeo: string | null;
  personeros: PersoneroContacto[];
  sector: string;
  latitude: number;
  longitude: number;
  mesas_total: number;
  mesas_con_presencia: number;
  mesas_con_personero: number;
  mesas_sin_personero: number;
  nivel: "VERDE" | "AMARILLO" | "ROJO";
  mesas_criticas: string[];
}

export interface ActaRecord {
  id: number;
  numero_mesa: string;
  status: string;
  requires_review: boolean;
  ocr_confidence: number | null;
  image_url: string | null;
  venue_id: number | null;
  venue_name: string | null;
  sector: string | null;
  latitude: number | null;
  longitude: number | null;
  votos_distrital: RankingEntry[];
  votos_provincial: RankingEntry[];
  votos_consejero?: RankingEntry[];
  votos_regional: RankingEntry[];
  votos_blancos: number;
  votos_nulos: number;
  votos_impugnados: number;
  total_electores: number;
  /* Ubicación real del acta (la agrega GET /api/actas/{id}). */
  ubigeo?: string | null;
  distrito?: string | null;
  provincia?: string | null;
  electores_habiles?: number | null;
}

/* Gestión de Actas — filtros en cascada + resumen de estado. */
export type ActaEstado = "todas" | "registradas" | "pendientes" | "observadas";

export interface ProvinciaOpt {
  provincia: string;
  nombre: string;
  distritos: number;
  locales: number;
  mesas: number;
}

export interface DistritoOpt {
  ubigeo: string;
  provincia: string;
  provincia_nombre: string;
  distrito: string;
  mesas: number;
}

export interface LocalOpt {
  id: number;
  nombre: string;
  ubigeo: string;
  mesas: number;
}

export interface ActaStatusFila {
  acta_id: number | null;
  numero_mesa: string;
  ubigeo: string;
  distrito: string;
  provincia: string;
  local_id: number;
  local: string;
  estado: "REGISTRADA" | "PENDIENTE" | "OBSERVADA";
  digitador: string | null;
  actualizada_en: string | null;
  tiene_foto: boolean;
}

export interface ActaStatusTotales {
  total: number;
  registradas: number;
  pendientes: number;
  observadas: number;
  avance_pct: number;
}

export interface ResumenStatusParams {
  departamento?: string;
  provincia?: string;
  distrito?: string;
  local_id?: number | null;
  estado?: ActaEstado;
  mesa?: string;
  /** Texto libre: n° de mesa (prefijo), local o distrito. */
  busqueda?: string;
  pagina?: number;
  page_size?: number;
}

export interface ResumenStatus {
  filtros: Record<string, string | null>;
  totales: ActaStatusTotales;
  pagina: number;
  page_size: number;
  total_filas: number;
  total_paginas: number;
  filas: ActaStatusFila[];
}

/* Credenciales de personeros — Fuerza Arequipeña (fotocheck 90x140mm). */
export interface CredencialAsignacion {
  mesa: string;
  tipo: string;
  estado: string;
  local: string;
  direccion: string | null;
  distrito: string;
  provincia: string;
  ubigeo: string;
}

export interface CredencialData {
  personero_id: number;
  nombres: string;
  apellidos: string;
  dni: string;
  rol: string;
  telefono: string | null;
  partido: string;
  proceso: string;
  foto_iniciales: string;
  asignacion: CredencialAsignacion;
  qr: string;
  qr_imagen: string;
  emitida_en: string;
}

export interface CredencialBulk {
  ubigeo: string;
  distrito: string;
  total: number;
  credenciales: CredencialData[];
}

export interface QrVerificacion {
  valida: boolean;
  motivo: string | null;
  dni: string | null;
  numero_mesa: string | null;
  personero: string | null;
  local: string | null;
  distrito: string | null;
}
/* Consulta ONPE — ficha de elector por DNI o mesa. */
export interface ElectorAsignacion {
  rol: string;
  mesa: string;
  tipo: string;
  estado: string;
  local: string;
}

export interface ElectorFicha {
  modo: "dni" | "mesa";
  dni: string | null;
  nombres: string | null;
  apellidos: string | null;
  ubigeo: string;
  region: string;
  provincia: string;
  distrito: string;
  esMiembroMesa: boolean;
  origen: string;
  asignacion: ElectorAsignacion | null;
  local: { id: number; nombre: string; direccion: string | null; referencia: string | null };
  numeroMesa: string;
  numeroOrden: number;
  electoresHabiles: number | null;
  estadoActa: "REGISTRADA" | "PENDIENTE" | "OBSERVADA";
  nota: string | null;
}