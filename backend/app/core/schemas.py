"""VotoPaucarpata Engine — Pydantic schemas."""
from typing import Optional

from pydantic import BaseModel, Field, field_validator


class CandidateVotes(BaseModel):
    candidate_id: int
    votes: int = 0


class ActaParseResult(BaseModel):
    numero_mesa: str = Field(min_length=6, max_length=6)
    votos_distrital: list[CandidateVotes] = []
    votos_provincial: list[CandidateVotes] = []
    votos_consejero: list[CandidateVotes] = []
    votos_regional: list[CandidateVotes] = []
    votos_blancos: int = 0
    votos_nulos: int = 0
    votos_impugnados: int = 0
    ocr_confidence: float = Field(ge=0.0, le=1.0)


class ActaOCRResult(BaseModel):
    numero_mesa: str = Field(min_length=6, max_length=6)
    votos_distrital: list[CandidateVotes] = []
    votos_provincial: list[CandidateVotes] = []
    votos_consejero: list[CandidateVotes] = []
    votos_regional: list[CandidateVotes] = []
    votos_blancos: int = 0
    votos_nulos: int = 0
    votos_impugnados: int = 0
    ocr_confidence: float = Field(ge=0.0, le=1.0)
    image_url: Optional[str] = None


class ActaUpdate(BaseModel):
    numero_mesa: str
    votos_distrital: list[CandidateVotes] = []
    votos_provincial: list[CandidateVotes] = []
    votos_consejero: list[CandidateVotes] = []
    votos_regional: list[CandidateVotes] = []
    votos_blancos: int = 0
    votos_nulos: int = 0
    votos_impugnados: int = 0
    ocr_confidence: float = Field(ge=0.0, le=1.0)
    image_url: Optional[str] = None
    total_electores: Optional[int] = None
    verified: bool = True


# ---------------------------------------------------------------------------
# Validación de actas — reglas matemáticas de la ONPE (PWA móvil)
# ---------------------------------------------------------------------------
class ColumnaActaIn(BaseModel):
    """Una columna del acta física (ALCALDE/REGIDORES o GOBERNADOR_VICE/CONSEJEROS)."""
    columna: str
    votos: dict[str, int] = Field(default_factory=dict)  # posición del candidato -> votos
    votos_blancos: int = 0
    votos_nulos: int = 0
    votos_impugnados: int = 0
    total_votantes: int = 0


class ActaValidacionIn(BaseModel):
    tipo_eleccion: str = Field(description="REGIONAL | PROVINCIAL | DISTRITAL")
    electores_habiles: int = Field(gt=0)
    columnas: list[ColumnaActaIn]
    numero_mesa: Optional[str] = None
    foto_presente: bool = True
    foto_repetida: bool = False
    ilegible: bool = False
    firmas_completas: bool = True
    diferencia_manual: Optional[int] = None


class ActaUpdatePayload(BaseModel):
    """Partial update for an existing acta (all fields optional)."""
    numero_mesa: Optional[str] = None
    votos_distrital: Optional[list[CandidateVotes]] = None
    votos_provincial: Optional[list[CandidateVotes]] = None
    votos_consejero: Optional[list[CandidateVotes]] = None
    votos_regional: Optional[list[CandidateVotes]] = None
    votos_blancos: Optional[int] = None
    votos_nulos: Optional[int] = None
    votos_impugnados: Optional[int] = None
    ocr_confidence: Optional[float] = Field(default=None, ge=0.0, le=1.0)
    image_url: Optional[str] = None
    total_electores: Optional[int] = None
    verified: bool = False


class ActaResponse(BaseModel):
    id: int
    numero_mesa: str
    status: str
    ocr_confidence: Optional[float]
    image_url: Optional[str]
    venue_id: Optional[int]
    venue_name: Optional[str]
    requires_review: bool

    class Config:
        from_attributes = True


# ---------------------------------------------------------------------------
# Ingesta oficial de la jornada — nómina y distribución (Arequipa)
# Contrato: docs/schemas/ingesta-jornada-v1.schema.json
# Consolida en un solo POST la NÓMINA (organizaciones y candidatos por ámbito,
# que construye el acta digital de los tres niveles) y la DISTRIBUCIÓN
# (locales y mesas con su padrón de electores hábiles, tope de la regla R2).
# ---------------------------------------------------------------------------
class IngestaFuenteIn(BaseModel):
    organismo: str  # JNE | ONPE | RENIEC
    bloque: str  # NOMINA | DISTRIBUCION | PADRON
    fecha_extraccion: str
    url: Optional[str] = None


class IngestaJornadaIn(BaseModel):
    fecha: str
    departamento: str = "AREQUIPA"
    ubigeo_departamento: str = "040000"
    generada_en: Optional[str] = None
    fuentes: list[IngestaFuenteIn] = Field(default_factory=list)


class IngestaCandidatoIn(BaseModel):
    numero: int = Field(ge=1)
    dni: str = Field(min_length=8, max_length=8)
    nombres: str
    apellidos: str
    nombre_completo: Optional[str] = None
    cargo: str
    estado: str = "INSCRITO"
    foto_url: Optional[str] = None
    hoja_vida_url: Optional[str] = None


class IngestaOrganizacionIn(BaseModel):
    numero: int = Field(ge=1)  # posición en la columna del acta
    organizacionPolitica: str
    nombreCorto: Optional[str] = None
    idOrganizacionPolitica: Optional[int] = None
    tipo: Optional[str] = None  # PARTIDO_NACIONAL | MOVIMIENTO_REGIONAL | ALIANZA_ELECTORAL
    logo_url: Optional[str] = None
    color_hex: Optional[str] = None
    candidatos: list[IngestaCandidatoIn] = Field(default_factory=list)


class IngestaAmbitoIn(BaseModel):
    tipo_eleccion: str  # REGIONAL | PROVINCIAL | DISTRITAL
    ubigeo: str = Field(min_length=6, max_length=6)  # INEI canónico
    ubigeo_reniec: Optional[str] = None
    provincia: Optional[str] = None
    distrito: Optional[str] = None
    organizaciones: list[IngestaOrganizacionIn] = Field(default_factory=list)


class IngestaMesaIn(BaseModel):
    numero_mesa: str = Field(min_length=6, max_length=6)
    electores_habiles: int = Field(gt=0)  # tope de R2_TOPE_ELECTORES
    pabellon: Optional[str] = None
    piso: Optional[str] = None
    numero_orden: Optional[int] = None


class IngestaLocalIn(BaseModel):
    codigo_local: str
    ubigeo: str = Field(min_length=6, max_length=6)
    nombre: str
    direccion: Optional[str] = None
    referencia: Optional[str] = None
    latitud: Optional[float] = None
    longitud: Optional[float] = None
    mesas: list[IngestaMesaIn] = Field(default_factory=list)


class IngestaJornadaPayload(BaseModel):
    """Body de POST /api/ingesta/jornada (superset nómina + distribución).

    Acepta la forma del contrato ``ingesta-jornada-v1.schema.json``
    (``nomina.ambitos[]``, ``distribucion.locales[]``) y la forma plana
    (listas directas), para que el ejemplo documentado se publique tal cual.
    """

    jornada: IngestaJornadaIn
    nomina: list[IngestaAmbitoIn] = Field(default_factory=list)
    distribucion: list[IngestaLocalIn] = Field(default_factory=list)

    @field_validator("nomina", mode="before")
    @classmethod
    def _unwrap_nomina(cls, v):
        if isinstance(v, dict):
            return v.get("ambitos", [])
        return v or []

    @field_validator("distribucion", mode="before")
    @classmethod
    def _unwrap_distribucion(cls, v):
        if isinstance(v, dict):
            return v.get("locales", [])
        return v or []


class IngestaResultado(BaseModel):
    ambitos: int = 0
    organizaciones: int = 0
    candidatos: int = 0
    candidatos_omitidos: int = 0  # no INSCRITO
    locales: int = 0
    mesas: int = 0
    mesas_existentes: int = 0


# ---------------------------------------------------------------------------
# API v1 — Registro, OCR y Cómputo (contrato OpenAPI estable)
# ---------------------------------------------------------------------------
class V1RegistrarIn(BaseModel):
    """JSON del formulario réplica ONPE para POST /api/v1/actas/registrar."""

    numero_mesa: str = Field(min_length=6, max_length=6, pattern=r"^[0-9]{6}$")
    tipo_eleccion: str = Field(description="REGIONAL | PROVINCIAL | DISTRITAL")
    votos: dict[str, int] = Field(
        default_factory=dict,
        description="organización -> votos (clave: posición en el acta o nombre)",
    )
    votos_blancos: int = Field(default=0, ge=0)
    votos_nulos: int = Field(default=0, ge=0)
    votos_impugnados: int = Field(
        default=0, ge=0, description="impugnación de identidad")
    total_emitidos: int = Field(default=0, ge=0)
    impugnada: bool = False
    motivo_impugnacion: Optional[str] = None
    # URL pública de la foto del acta (opcional; la sube antes
    # POST /api/v1/actas/foto y el formulario la asocia aquí).
    image_url: Optional[str] = None
    foto_hash_sha256: Optional[str] = Field(default=None, pattern=r"^[0-9a-f]{64}$")


class V1HallazgoOut(BaseModel):
    regla: str
    severidad: str
    mensaje: str
    diferencia: Optional[int] = None


class V1RegistrarOut(BaseModel):
    acta_id: int
    numero_mesa: str
    tipo_eleccion: str
    estado: str  # NORMAL | OBSERVADA | IMPUGNADA
    total_emitidos: int
    suma_partes: int
    diferencia: int
    participacion_pct: float
    contabilizada: bool
    hallazgos: list[V1HallazgoOut] = Field(default_factory=list)


class V1OcrPreviewOut(BaseModel):
    numero_mesa: str | None
    digitos: list[int]
    total_campos: int
    umbral_otsu: float
    confianza: float
    advertencia: Optional[str] = None


class V1PartidoResumen(BaseModel):
    organizacion: str
    candidato: str = ""  # nombre del candidato principal (dualidad)
    color: str
    votos: int
    porcentaje: float


class V1DistritoAvance(BaseModel):
    ubigeo: str
    distrito: str
    mesas: int
    actas: int
    observadas: int
    avance_pct: float


class V1ActaObservada(BaseModel):
    numero_mesa: str
    local: str
    ubigeo: str
    distrito: str


class V1GanadorDistrito(BaseModel):
    """Organización ganadora (o más votada) en un distrito para el mapa."""
    organizacion: str
    color: str = "#6b7280"
    votos: int = 0


class V1ConsejeroProvincia(BaseModel):
    """Resultado de CONSEJERO REGIONAL en una provincia.

    Cada provincia renueva escaños del Consejo Regional con su propia columna
    del acta: ``ganador`` es la lista más votada y ``escanos`` reparte los
    curules de la provincia por **d'Hondt** entre las listas en carrera
    (proyección sobre las actas procesadas, no resultado oficial).
    """
    provincia: str
    ubigeo: str
    ganador: V1GanadorDistrito | None = None
    escanos: list[V1GanadorDistrito] = Field(default_factory=list)
    curules: int = 0


class V1ResumenOut(BaseModel):
    total_mesas: int
    total_actas: int
    actas_normales: int
    actas_observadas: int
    avance_pct: float
    participacion_pct: float
    tipo_eleccion: str
    # Desglose específico del cómputo
    electores_habiles: int = 0
    votos_validos: int = 0
    votos_blancos: int = 0
    votos_nulos: int = 0
    votos_impugnados: int = 0
    votos_emitidos: int = 0
    partidos: list[V1PartidoResumen] = Field(default_factory=list)
    distritos: list[V1DistritoAvance] = Field(default_factory=list)
    observadas: list[V1ActaObservada] = Field(default_factory=list)
    # Ganador por distrito (ubigeo -> org/color/votos) para el mapa de resultados.
    ganadores: dict[str, V1GanadorDistrito] = Field(default_factory=dict)
    # Consejo Regional: resultado POR PROVINCIA (sólo nivel CONSEJERO).
    consejeros: list[V1ConsejeroProvincia] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Digitador Global — auditoría obligatoria y rectificación nacional
# ---------------------------------------------------------------------------
class DigitadorActaCrearIn(BaseModel):
    """Alta nacional de acta por el Digitador Global (sin filtro ubigeo).

    ``venue_id`` es opcional: si se omite se usa el local del padrón de la
    mesa (``tables.venue_id``) o el primer venue como fallback del prototipo.
    """

    numero_mesa: str = Field(min_length=6, max_length=6, pattern=r"^[0-9]{6}$")
    venue_id: Optional[int] = None
    votos_distrital: list[CandidateVotes] = []
    votos_provincial: list[CandidateVotes] = []
    votos_consejero: list[CandidateVotes] = []
    votos_regional: list[CandidateVotes] = []
    votos_blancos: int = Field(default=0, ge=0)
    votos_nulos: int = Field(default=0, ge=0)
    votos_impugnados: int = Field(default=0, ge=0)
    total_electores: Optional[int] = Field(default=None, ge=0)
    ocr_confidence: Optional[float] = Field(default=None, ge=0.0, le=1.0)
    image_url: Optional[str] = None
    motivo: Optional[str] = Field(default=None, max_length=500)


class DigitadorActaRectificarIn(BaseModel):
    """Rectificación parcial de cualquier acta (todos los campos opcionales).

    Acepta votos por nivel, conteos (blancos/nulos/impugnados/emitidos),
    observaciones y estado de bloqueo (processed/requires_review/status).
    """

    votos_distrital: Optional[list[CandidateVotes]] = None
    votos_provincial: Optional[list[CandidateVotes]] = None
    votos_consejero: Optional[list[CandidateVotes]] = None
    votos_regional: Optional[list[CandidateVotes]] = None
    votos_blancos: Optional[int] = Field(default=None, ge=0)
    votos_nulos: Optional[int] = Field(default=None, ge=0)
    votos_impugnados: Optional[int] = Field(default=None, ge=0)
    total_electores: Optional[int] = Field(default=None, ge=0)
    ocr_confidence: Optional[float] = Field(default=None, ge=0.0, le=1.0)
    image_url: Optional[str] = None
    observacion: Optional[str] = Field(default=None, max_length=1000)
    forzar_desbloqueo: bool = False
    motivo: str = Field(min_length=3, max_length=500)


class ActaAuditoriaOut(BaseModel):
    """Fila del log estricto de auditoría (sólo lectura)."""

    id: int
    acta_id: int
    numero_mesa: str
    accion: str
    usuario_id: Optional[int] = None
    usuario_email: str
    usuario_rol: str
    ip: Optional[str] = None
    valores_anteriores: dict = Field(default_factory=dict)
    valores_nuevos: dict = Field(default_factory=dict)
    motivo: Optional[str] = None
    created_at: Optional[str] = None

    class Config:
        from_attributes = True


# ---------------------------------------------------------------------------
# Dashboard en tiempo real — eventos de recálculo tras cada intervención
# ---------------------------------------------------------------------------
class DashboardRecalcularOut(BaseModel):
    """Respuesta del endpoint de recálculo (cache + broadcast)."""

    ok: bool = True
    version: int
    acta_id: int
    numero_mesa: str
    alcance: str = "nacional"
    resumen: dict = Field(default_factory=dict)
    broadcast_a: int = 0


class DashboardEstadoOut(BaseModel):
    """Versión actual del cómputo cacheado (polling fallback del WS)."""

    version: int
    actualizado_en: Optional[str] = None
    actas_procesadas: int = 0
    actas_observadas: int = 0
    avance_pct: float = 0.0


# ---------------------------------------------------------------------------
# Museo IA — generador de prompts JSON para el LLM
# ---------------------------------------------------------------------------
class MuseoIaPromptIn(BaseModel):
    """Parámetros del prompt: nivel, top de organizaciones y tono."""

    tipo_eleccion: str = Field(default="DISTRITAL",
                               description="REGIONAL | PROVINCIAL | DISTRITAL")
    top: int = Field(default=10, ge=1, le=50)
    tono: str = Field(default="institucional",
                      description="institucional | periodistico | tecnico")
    incluir_observadas: bool = True
    pregunta: Optional[str] = Field(default=None, max_length=500)


class MuseoIaPromptOut(BaseModel):
    """Prompt dinámico formateado en JSON, listo para el LLM."""

    modelo_sugerido: str
    system: str
    user_prompt: str
    contexto: dict
    formato_respuesta: dict
    metadatos: dict


# ---------------------------------------------------------------------------
# Campo — presencia del personero y check de validación del acta
# ---------------------------------------------------------------------------
class V1AsignarIn(BaseModel):
    usuario_id: int
    numero_mesa: str = Field(min_length=6, max_length=6, pattern=r"^[0-9]{6}$")
    tipo: str = Field(default="TITULAR", pattern=r"^(TITULAR|SUPLENTE)$")
    notas: Optional[str] = None


class V1AsignarLoteIn(BaseModel):
    """Asignación masiva: un personero a varias mesas de un mismo local."""
    usuario_id: int
    numero_mesas: list[str] = Field(
        min_length=1, max_length=200,
        description="N° de mesa (6 dígitos) de las mesas a asignar")
    tipo: str = Field(default="TITULAR", pattern=r"^(TITULAR|SUPLENTE)$")
    notas: Optional[str] = None


class V1DesasignarIn(BaseModel):
    """Quita una asignación personero↔mesa por su id."""
    asignacion_id: int


class V1CheckinIn(BaseModel):
    numero_mesa: str = Field(min_length=6, max_length=6, pattern=r"^[0-9]{6}$")
    latitud: float = Field(ge=-19, le=0)
    longitud: float = Field(ge=-82, le=-68)
    precision_m: Optional[float] = Field(default=None, ge=0)
    dispositivo: Optional[str] = None


class V1CheckinOut(BaseModel):
    dentro_de_radio: bool
    distancia_m: float
    estado: str  # estado de la asignación tras el check-in
    local: str
    mensaje: str


class V1MiEstadoOut(BaseModel):
    asignaciones: list[dict] = Field(default_factory=list)
    presencia_validada: bool = False
    ultimo_checkin: Optional[str] = None


class V1CheckItem(BaseModel):
    clave: str
    etiqueta: str
    ok: bool
    detalle: str


class V1ChecklistOut(BaseModel):
    numero_mesa: str
    local: str
    ubigeo: str
    electores_habiles: Optional[int] = None
    presencia_validada: bool = False
    oferta_por_nivel: dict[str, int] = Field(default_factory=dict)
    actas_existentes: list[str] = Field(default_factory=list)
    puede_registrar: bool = False
    items: list[V1CheckItem] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Gestión de Actas — resumen de estado con filtros en cascada
# (GET /api/v1/actas/resumen-status). Una sola llamada: agregados SQL
# (COUNT/SUM/CASE WHEN) + lista paginada, ambos bajo el mismo filtro.
# Estados: REGISTRADA (processed, sin revisión) | PENDIENTE (sin cargar) |
# OBSERVADA (requires_review, para rectificar).
# ---------------------------------------------------------------------------
class V1ActaStatusFila(BaseModel):
    acta_id: Optional[int] = None
    numero_mesa: str
    ubigeo: str
    distrito: str
    provincia: str
    local_id: int
    local: str
    estado: str
    digitador: Optional[str] = None
    actualizada_en: Optional[str] = None
    tiene_foto: bool = False


class V1ActaStatusTotales(BaseModel):
    total: int = 0
    registradas: int = 0
    pendientes: int = 0
    observadas: int = 0
    avance_pct: float = 0.0


class V1ResumenStatusOut(BaseModel):
    filtros: dict[str, Optional[str]] = Field(default_factory=dict)
    totales: V1ActaStatusTotales = Field(default_factory=V1ActaStatusTotales)
    pagina: int = 1
    page_size: int = 15
    total_filas: int = 0
    total_paginas: int = 0
    filas: list[V1ActaStatusFila] = Field(default_factory=list)


class V1LocalOpt(BaseModel):
    id: int
    nombre: str
    ubigeo: str
    mesas: int = 0


# ---------------------------------------------------------------------------
# Credenciales de personeros — Fuerza Arequipeña (fotocheck CR80 90x140mm).
# QR: "FA-AREQUIPA|DNI|MESA|firma" (firma = HMAC-SHA256 truncado; los 3
# primeros segmentos respetan el formato estructurado del requerimiento).
# ---------------------------------------------------------------------------
class V1CredencialAsignacion(BaseModel):
    mesa: str
    tipo: str
    estado: str
    local: str
    direccion: Optional[str] = None
    distrito: str
    provincia: str
    ubigeo: str


class V1CredencialOut(BaseModel):
    personero_id: int
    nombres: str
    apellidos: str
    dni: str
    rol: str
    telefono: Optional[str] = None
    partido: str = "FUERZA AREQUIPEÑA"
    proceso: str = "Elecciones Regionales y Municipales · Arequipa 2026"
    foto_iniciales: str
    asignacion: V1CredencialAsignacion
    qr: str
    qr_imagen: str  # data URL PNG del QR, lista para <img>
    emitida_en: str


class V1CredencialBulkOut(BaseModel):
    ubigeo: str
    distrito: str
    total: int
    credenciales: list[V1CredencialOut] = Field(default_factory=list)


class V1QrVerificarIn(BaseModel):
    qr: str = Field(min_length=1, max_length=200)


class V1QrVerificarOut(BaseModel):
    valida: bool
    motivo: Optional[str] = None
    dni: Optional[str] = None
    numero_mesa: Optional[str] = None
    personero: Optional[str] = None
    local: Optional[str] = None
    distrito: Optional[str] = None


# ---------------------------------------------------------------------------
# Consulta ONPE — búsqueda de elector por DNI o mesa
# (GET /api/v1/elector/buscar). Replica la ficha oficial: estado de miembro,
# identidad, jerarquía territorial, local, mesa y orden. Sin padrón nacional
# de ciudadanos en la base, el DNI resuelve contra usuarios del sistema y su
# asignación operativa de mesa (origen: "asignacion_operativa"); la búsqueda
# por mesa resuelve íntegra contra el padrón de locales cargado.
# ---------------------------------------------------------------------------
class V1ElectorAsignacion(BaseModel):
    rol: str
    mesa: str
    tipo: str
    estado: str
    local: str


class V1ElectorLocal(BaseModel):
    id: int
    nombre: str
    direccion: Optional[str] = None
    referencia: Optional[str] = None


class V1ElectorBuscarOut(BaseModel):
    modo: str  # "dni" | "mesa"
    dni: Optional[str] = None
    nombres: Optional[str] = None
    apellidos: Optional[str] = None
    ubigeo: str
    region: str = "AREQUIPA"
    provincia: str
    distrito: str
    esMiembroMesa: bool = False
    origen: str = "sistema"  # "sistema" | "padron_onpe"
    asignacion: Optional[V1ElectorAsignacion] = None
    local: V1ElectorLocal
    numeroMesa: str
    numeroOrden: int
    electoresHabiles: Optional[int] = None
    estadoActa: str = "PENDIENTE"  # REGISTRADA | PENDIENTE | OBSERVADA
    nota: Optional[str] = None