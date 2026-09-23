import type { ActaRecord, ChoroplethDistrito, CoberturaLocal, CredencialBulk, CredencialData,
  DistritoOpt, ElectorFicha, LocalOpt, ProvinciaOpt, QrVerificacion,
  ResumenStatus, ResumenStatusParams, Summary, VenueMapItem } from "./types";

const BASE = "/api";

/* ------------------------------------------------------------------ *
 * Sesión (compartida con la PWA móvil: misma clave de localStorage)
 * ------------------------------------------------------------------ */
const CLAVE_SESION = "sesion_computo";

export interface SesionUsuario {
  id: number;
  email: string;
  nombre_completo: string;
  rol: string;
  alcance_ubigeos: string[];
}

export interface UsuarioAdmin {
  id: number;
  email: string;
  dni: string;
  nombres: string;
  apellidos: string;
  nombre_completo: string;
  telefono: string | null;
  rol: string;
  activo: boolean;
  alcance_ubigeos: string[];
  debe_cambiar_clave: boolean;
  ultimo_acceso: string | null;
}

export interface UsuarioCrear {
  email: string;
  dni: string;
  nombres: string;
  apellidos: string;
  telefono?: string;
  rol: string;
  contrasena: string;
  alcance_ubigeos: string[];
}

/** Roles que cada rol puede crear (espejo de ROLES_CREABLES del backend). */
export const ROLES_CREABLES: Record<string, string[]> = {
  SUPER_ADMIN: [
    "SUPER_ADMIN",
    "DIGITADOR_GLOBAL",
    "COORD_PROVINCIAL",
    "RESPONSABLE_DISTRITAL",
    "COORD_LOCAL",
    "DELEGADO_MESA",
    "PERSONERO",
  ],
  COORD_PROVINCIAL: [
    "RESPONSABLE_DISTRITAL",
    "COORD_LOCAL",
    "DELEGADO_MESA",
    "PERSONERO",
  ],
  RESPONSABLE_DISTRITAL: ["COORD_LOCAL", "DELEGADO_MESA", "PERSONERO"],
};

export const ROLES_GESTIONAN_USUARIOS = [
  "SUPER_ADMIN",
  "COORD_PROVINCIAL",
  "RESPONSABLE_DISTRITAL",
];

/** Rol transversal: alcance nacional, sin filtro ubigeo, con auditoría. */
export const ROL_DIGITADOR_GLOBAL = "DIGITADOR_GLOBAL";
export const ROLES_GLOBALES = ["SUPER_ADMIN", "DIGITADOR_GLOBAL"];

export function esRolGlobal(rol?: string | null): boolean {
  return !!rol && ROLES_GLOBALES.includes(rol);
}

export const ROLES_CAMPO = ["PERSONERO", "DELEGADO_MESA"];

export const ROLES_GESTORES_CAMPO = [
  "SUPER_ADMIN",
  "COORD_PROVINCIAL",
  "RESPONSABLE_DISTRITAL",
  "COORD_LOCAL",
];

export interface MesaAsignada {
  numero_mesa: string;
  local: string;
  ubigeo: string;
  tipo: string;
  estado: string;
  checkin_hoy: boolean;
  asignacion_id?: number;
}

export interface MiEstado {
  asignaciones: MesaAsignada[];
  presencia_validada: boolean;
  ultimo_checkin: string | null;
}

export interface PersoneroEquipo {
  id: number;
  email: string;
  dni: string;
  nombre_completo: string;
  telefono: string | null;
  rol: string;
  activo: boolean;
  alcance_ubigeos: string[];
  mesas: Array<MesaAsignada & {
    ultimo_checkin: string | null;
    dentro_de_radio: boolean | null;
    distancia_m: number | null;
  }>;
  presente_hoy: boolean;
}

export interface CheckItem {
  clave: string;
  etiqueta: string;
  ok: boolean;
  detalle: string;
}

export interface Checklist {
  numero_mesa: string;
  local: string;
  ubigeo: string;
  electores_habiles: number | null;
  presencia_validada: boolean;
  oferta_por_nivel: Record<string, number>;
  actas_existentes: string[];
  puede_registrar: boolean;
  items: CheckItem[];
}

interface SesionLocal {
  token: string;
  usuario: SesionUsuario;
  expira_at?: string;
}

export function sesionGuardada(): SesionLocal | null {
  try {
    const s = JSON.parse(localStorage.getItem(CLAVE_SESION) || "null") as SesionLocal | null;
    if (!s || !s.token) return null;
    if (s.expira_at && new Date(s.expira_at) <= new Date()) return null;
    return s;
  } catch {
    return null;
  }
}

export async function login(email: string, contrasena: string): Promise<SesionLocal> {
  const res = await fetch(`${BASE}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, contrasena }),
  });
  const data = await res.json();
  if (!res.ok) {
    throw new Error(
      typeof data?.detail === "string" ? data.detail : `Login falló (${res.status})`
    );
  }
  localStorage.setItem(CLAVE_SESION, JSON.stringify(data));
  return data as SesionLocal;
}

export async function logout(): Promise<void> {
  try {
    await fetch(`${BASE}/auth/logout`, { method: "POST", ...headersAuth() });
  } catch {
    // aunque falle el servidor, la sesión local se descarta
  }
  localStorage.removeItem(CLAVE_SESION);
}

function headersAuth(extra: Record<string, string> = {}): RequestInit["headers"] {
  const s = sesionGuardada();
  return {
    "Content-Type": "application/json",
    ...(s ? { Authorization: `Bearer ${s.token}` } : {}),
    ...extra,
  };
}

/** Build a readable message, preferring the `detail` returned by FastAPI. */
async function errorMessage(res: Response, fallback: string): Promise<string> {
  try {
    const body = await res.json();
    if (body && typeof body.detail === "string") {
      return `${fallback}: ${body.detail}`;
    }
  } catch {
    // non-JSON error body — fall through to the status line
  }
  return `${fallback}: ${res.status} ${res.statusText}`;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    headers: headersAuth(),
    ...init,
  });
  if (res.status === 401) {
    // Token expirado o revocado: fuera y a re-login
    localStorage.removeItem(CLAVE_SESION);
    window.location.reload();
    throw new Error("Sesión expirada");
  }
  if (!res.ok) {
    throw new Error(await errorMessage(res, "Request failed"));
  }
  return res.json() as Promise<T>;
}

export const api = {
  sesionGuardada,
  summary: (scope: string = "district", ubigeo?: string) =>
    request<Summary>(
      `/analytics/summary?scope=${scope}${ubigeo ? `&ubigeo=${ubigeo}` : ""}`
    ),
  map: () => request<VenueMapItem[]>("/analytics/map"),
  choropleth: () => request<ChoroplethDistrito[]>("/analytics/choropleth"),
  cobertura: () => request<CoberturaLocal[]>("/analytics/cobertura"),
  reviewList: () => request<ActaRecord[]>("/actas/review"),
  getActa: (id: number) => request<ActaRecord>(`/actas/${id}`),
  updateActa: (id: number, payload: unknown) =>
    request<ActaRecord>(`/actas/${id}`, { method: "PUT", body: JSON.stringify(payload) }),
  ocrActa: (file: File) => {
    const fd = new FormData();
    fd.append("file", file);
    const s = sesionGuardada();
    return fetch(`${BASE}/actas/ocr`, {
      method: "POST",
      body: fd,
      headers: s ? { Authorization: `Bearer ${s.token}` } : {},
    }).then(async (r) => {
      if (r.status === 401) {
        localStorage.removeItem(CLAVE_SESION);
        window.location.reload();
        throw new Error("Sesión expirada");
      }
      if (!r.ok) throw new Error(await errorMessage(r, "OCR failed"));
      return r.json();
    });
  },
  createActa: (payload: unknown) =>
    request<ActaRecord>(`/actas`, { method: "POST", body: JSON.stringify(payload) }),
  usuarios: () => request<UsuarioAdmin[]>("/auth/usuarios"),
  crearUsuario: (payload: UsuarioCrear) =>
    request<UsuarioAdmin>("/auth/usuarios", { method: "POST", body: JSON.stringify(payload) }),
  editarUsuario: (id: number, payload: { telefono?: string; activo?: boolean; alcance_ubigeos?: string[] }) =>
    request<UsuarioAdmin>(`/auth/usuarios/${id}`, { method: "PATCH", body: JSON.stringify(payload) }),
  resetClave: (id: number, nueva_clave: string) =>
    request<{ ok: boolean; mensaje: string }>(`/auth/usuarios/${id}/clave`, {
      method: "POST",
      body: JSON.stringify({ nueva_clave }),
    }),
  miEstado: () => request<MiEstado>("/v1/campo/mi-estado"),
  personeros: () => request<PersoneroEquipo[]>("/v1/campo/personeros"),
  asignar: (payload: { usuario_id: number; numero_mesa: string; tipo: string; notas?: string }) =>
    request<{ id: number; usuario: string; numero_mesa: string; tipo: string; estado: string }>(
      "/v1/campo/asignar", { method: "POST", body: JSON.stringify(payload) }
    ),
  asignarLote: (payload: { usuario_id: number; numero_mesas: string[]; tipo: string; notas?: string }) =>
    request<{ usuario: string; tipo: string; total: number; mesas: Array<{ numero_mesa: string; resultado: string }> }>(
      "/v1/campo/asignar-lote", { method: "POST", body: JSON.stringify(payload) }
    ),
  desasignar: (asignacion_id: number) =>
    request<{ ok: boolean; asignacion_id: number }>(
      "/v1/campo/desasignar", { method: "POST", body: JSON.stringify({ asignacion_id }) }
    ),
  mesasDeLocal: (venueId: number, usuarioId?: number) =>
    request<Array<{
      id: number; numero_mesa: string; electores_habiles: number | null;
      estado: string | null; asignacion_id: number | null; asignado_a: string | null;
      asignado_a_id: number | null; tipo: string | null; es_del_personero: boolean;
    }>>(`/v1/campo/mesas-local?venue_id=${venueId}${usuarioId ? `&usuario_id=${usuarioId}` : ""}`),
  checkin: (payload: { numero_mesa: string; latitud: number; longitud: number; precision_m?: number | null; dispositivo?: string }) =>
    request<{ dentro_de_radio: boolean; distancia_m: number; estado: string; local: string; mensaje: string }>(
      "/v1/campo/checkin", { method: "POST", body: JSON.stringify(payload) }
    ),
  checklist: (numero_mesa: string) =>
    request<Checklist>(`/v1/actas/checklist?numero_mesa=${numero_mesa}`),
  /* Consulta ONPE — ficha de elector por DNI o N° de mesa. */
  electorBuscar: (params: { dni?: string; mesa?: string }) => {
    const q = new URLSearchParams();
    if (params.dni) q.set("dni", params.dni);
    if (params.mesa) q.set("mesa", params.mesa);
    return request<ElectorFicha>(`/v1/elector/buscar?${q.toString()}`);
  },
  plantillaActa: (numeroMesa: string) =>
    request<import("./components/ActaIngresoForm").PlantillaActa>(
      `/actas/plantilla?numero_mesa=${encodeURIComponent(numeroMesa)}`
    ),
  /* Credenciales Fuerza Arequipeña — datos, PDF y verificación QR. */
  credencialData: (id: number, mesa?: string) =>
    request<CredencialData>(
      `/v1/personeros/${id}/credencial-data${mesa ? `?mesa=${mesa}` : ""}`
    ),
  credencialPdf: async (id: number, mesa?: string): Promise<Blob> => {
    const s = sesionGuardada();
    const r = await fetch(
      `${BASE}/v1/personeros/${id}/credencial.pdf${mesa ? `?mesa=${mesa}` : ""}`,
      { headers: s ? { Authorization: `Bearer ${s.token}` } : {} });
    if (!r.ok) throw new Error(await errorMessage(r, "PDF failed"));
    return r.blob();
  },
  credencialesDistrito: (ubigeo: string) =>
    request<CredencialBulk>(
      `/v1/personeros/credencial/distrito?ubigeo=${encodeURIComponent(ubigeo)}`
    ),
  credencialesDistritoPdf: async (ubigeo: string): Promise<Blob> => {
    const s = sesionGuardada();
    const r = await fetch(
      `${BASE}/v1/personeros/credencial/distrito.pdf?ubigeo=${encodeURIComponent(ubigeo)}`,
      { headers: s ? { Authorization: `Bearer ${s.token}` } : {} });
    if (!r.ok) throw new Error(await errorMessage(r, "PDF bulk failed"));
    return r.blob();
  },
  verificarQr: (qr: string) =>
    request<QrVerificacion>("/v1/personeros/verificar-qr", {
      method: "POST", body: JSON.stringify({ qr }),
    }),
  /* Gestión de Actas — cascada territorial + resumen de estado. */
  provincias: () => request<ProvinciaOpt[]>("/v1/ubigeo/provincias"),
  distritos: (provincia?: string) =>
    request<DistritoOpt[]>(
      `/v1/ubigeo/distritos${provincia ? `?provincia=${encodeURIComponent(provincia)}` : ""}`
    ),
  localesUbigeo: (ubigeo: string) =>
    request<LocalOpt[]>(`/v1/ubigeo/locales?ubigeo=${encodeURIComponent(ubigeo)}`),
  resumenStatus: (p: ResumenStatusParams) => {
    const q = new URLSearchParams();
    q.set("departamento", p.departamento ?? "AREQUIPA");
    if (p.provincia) q.set("provincia", p.provincia);
    if (p.distrito) q.set("distrito", p.distrito);
    if (p.local_id != null) q.set("local_id", String(p.local_id));
    q.set("estado", p.estado ?? "todas");
    if (p.mesa) q.set("mesa", p.mesa);
    if (p.busqueda) q.set("busqueda", p.busqueda);
    q.set("pagina", String(p.pagina ?? 1));
    q.set("page_size", String(p.page_size ?? 15));
    return request<ResumenStatus>(`/v1/actas/resumen-status?${q.toString()}`);
  },
  /* Digitador Global — CRUD nacional con auditoría + realtime. */
  digitadorCrearActa: (payload: unknown) =>
    request<{ acta: ActaRecord; auditoria_id: number; realtime: unknown }>(
      `/digitador/actas`, { method: "POST", body: JSON.stringify(payload) }
    ),
  digitadorRectificarActa: (id: number, payload: unknown) =>
    request<{ acta: ActaRecord; auditoria_id: number; realtime: unknown }>(
      `/digitador/actas/${id}`, { method: "PATCH", body: JSON.stringify(payload) }
    ),
  digitadorAuditoria: (actaId: number) =>
    request<Array<{
      id: number; accion: string; usuario_email: string; ip: string | null;
      valores_anteriores: Record<string, unknown>;
      valores_nuevos: Record<string, unknown>;
      motivo: string | null; created_at: string | null;
    }>>(`/digitador/actas/${actaId}/auditoria`),
  auditoriaReciente: (limite = 50, numero_mesa?: string) =>
    request<unknown[]>(
      `/digitador/auditoria?limite=${limite}${numero_mesa ? `&numero_mesa=${numero_mesa}` : ""}`
    ),
  /* Dashboard en tiempo real (WS + polling fallback). */
  realtimeEstado: () => request<unknown>("/realtime/estado"),
  realtimeRecalcular: () =>
    request<{ ok: boolean; version: number; resumen: unknown; broadcast_a: number }>(
      "/realtime/recalcular", { method: "POST" }
    ),
  dashboardWS: (token: string) =>
    new WebSocket(
      `${window.location.protocol === "https:" ? "wss" : "ws"}://${window.location.host}/ws/dashboard?token=${token}`
    ),
  /* Museo IA — prompt JSON consolidado para el LLM. */
  museoIaPrompt: (payload: {
    tipo_eleccion?: string; top?: number; tono?: string;
    incluir_observadas?: boolean; pregunta?: string;
  }) =>
    request<{
      modelo_sugerido: string; system: string; user_prompt: string;
      contexto: Record<string, unknown>;
      formato_respuesta: Record<string, unknown>;
      metadatos: Record<string, unknown>;
    }>("/museo-ia/prompt", { method: "POST", body: JSON.stringify(payload) }),
  process: (file: File) => {
    const fd = new FormData();
    fd.append("file", file);
    const s = sesionGuardada();
    return fetch(`${BASE}/actas/process`, {
      method: "POST",
      body: fd,
      headers: s ? { Authorization: `Bearer ${s.token}` } : {},
    }).then(async (r) => {
      if (r.status === 401) {
        localStorage.removeItem(CLAVE_SESION);
        window.location.reload();
        throw new Error("Sesión expirada");
      }
      if (!r.ok) throw new Error(await errorMessage(r, "Upload failed"));
      return r.json();
    });
  },
};