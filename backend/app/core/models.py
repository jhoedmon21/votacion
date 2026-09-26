"""VotoPaucarpata Engine — SQLAlchemy ORM models."""
from datetime import datetime

from sqlalchemy import (Boolean, Column, DateTime, Float, ForeignKey, Integer,
                        String, Text, UniqueConstraint, func)
from sqlalchemy.orm import relationship

from app.core.database import Base

# Roles del sistema (RBAC descentralizado del esquema PostgreSQL)
# Jerarquía operativa completa (migracion_jerarquia_completa.sql):
#   SUPER_ADMIN → COORD_PROVINCIAL → RESPONSABLE_DISTRITAL(=COORD_DISTRITAL)
#   → COORD_LOCAL → DELEGADO_MESA(=PERSONERO)
# Rol transversal (migracion_digitador_global.sql):
#   DIGITADOR_GLOBAL → alcance nacional, ignora filtros ubigeo; crea/rectifica
#   cualquier acta con auditoría obligatoria.
ROLES_SISTEMA = (
    "SUPER_ADMIN",
    "DIGITADOR_GLOBAL",
    "COORD_PROVINCIAL",
    "RESPONSABLE_DISTRITAL",
    "COORD_LOCAL",
    "DELEGADO_MESA",
    "PERSONERO",
)

# Roles con alcance nacional: [] significa "todo el país", sin filas en
# usuario_alcance. Todo chequeo territorial debe usar es_rol_global() para
# omitir el scope geográfico (ver app/core/auth.py).
ROLES_GLOBALES = ("SUPER_ADMIN", "DIGITADOR_GLOBAL")


class Usuario(Base):
    """Usuario del sistema. Espejo de `usuarios` del esquema PostgreSQL."""
    __tablename__ = "usuarios"
    id = Column(Integer, primary_key=True, index=True)
    email = Column(String(160), unique=True, nullable=False, index=True)
    dni = Column(String(8), unique=True, nullable=False)
    nombres = Column(String(80), nullable=False)
    apellidos = Column(String(80), nullable=False)
    telefono = Column(String(20))
    password_hash = Column(String(100), nullable=False)
    rol = Column(String(30), nullable=False, default="PERSONERO")
    activo = Column(Boolean, default=True, nullable=False)
    intentos_fallidos = Column(Integer, default=0, nullable=False)
    bloqueado_hasta = Column(DateTime(timezone=True))
    ultimo_acceso = Column(DateTime(timezone=True))
    debe_cambiar_clave = Column(Boolean, default=True, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    alcance = relationship("UsuarioAlcance", back_populates="usuario", cascade="all, delete-orphan")
    sesiones = relationship("Sesion", back_populates="usuario", cascade="all, delete-orphan")

    @property
    def nombre_completo(self) -> str:
        return f"{self.nombres} {self.apellidos}".strip()


class UsuarioAlcance(Base):
    """Alcance territorial: filas por ubigeo. SUPER_ADMIN no necesita (ve todo)."""
    __tablename__ = "usuario_alcance"
    usuario_id = Column(Integer, ForeignKey("usuarios.id", ondelete="CASCADE"), primary_key=True)
    ubigeo = Column(String(6), primary_key=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    usuario = relationship("Usuario", back_populates="alcance")


class Sesion(Base):
    """Sesión (token opaco). El token va al cliente; aquí sólo su SHA-256."""
    __tablename__ = "sesiones"
    id = Column(Integer, primary_key=True, index=True)
    usuario_id = Column(Integer, ForeignKey("usuarios.id", ondelete="CASCADE"), nullable=False, index=True)
    token_hash = Column(String(64), unique=True, nullable=False, index=True)
    dispositivo = Column(String(120))
    ip = Column(String(45))
    expira_at = Column(DateTime(timezone=True), nullable=False)
    revocada = Column(Boolean, default=False, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    usuario = relationship("Usuario", back_populates="sesiones")


class AccesoLog(Base):
    """Bitácora de intentos de acceso (detección de fuerza bruta)."""
    __tablename__ = "accesos_log"
    id = Column(Integer, primary_key=True, index=True)
    email = Column(String(160), index=True)
    exitoso = Column(Boolean, nullable=False)
    ip = Column(String(45))
    user_agent = Column(String(220))
    detalle = Column(String(220))
    created_at = Column(DateTime(timezone=True), server_default=func.now())


class Venue(Base):
    __tablename__ = "venues"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)
    sector = Column(String, nullable=False)
    address = Column(String)
    latitude = Column(Float, nullable=False)
    longitude = Column(Float, nullable=False)
    # Ubigeo INEI del distrito del local: llave del alcance territorial y de la
    # RLS. Los locales del prototipo son de Paucarpata (040112).
    ubigeo = Column(String(6), default="040112", index=True)
    total_tables = Column(Integer, default=0)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    tables = relationship("Table", back_populates="venue")


class Table(Base):
    __tablename__ = "tables"
    id = Column(Integer, primary_key=True, index=True)
    venue_id = Column(Integer, ForeignKey("venues.id"), nullable=False)
    numero_mesa = Column(String, unique=True, nullable=False, index=True)
    # Padrón ONPE por mesa: tope de la regla R2. Espejo de `mesas.electores_habiles`
    # del esquema PostgreSQL. Lo llena la ingesta (distribución) o el seed regional.
    electores_habiles = Column(Integer)
    processed = Column(Boolean, default=False)
    requires_review = Column(Boolean, default=False)
    status = Column(String, default="pending")
    ocr_confidence = Column(Float)
    image_url = Column(String)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    venue = relationship("Venue", back_populates="tables")


class DistrictCandidate(Base):
    __tablename__ = "district_candidates"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)
    party = Column(String)
    # Ubigeo del ámbito que compite (040112 = Paucarpata). Sin esta columna las
    # tres tablas son listas planas: el mismo partido compite en decenas de
    # ámbitos (AHORA NACION - AN en 68) y los votos caerían en el ámbito ajeno.
    ubigeo = Column(String(6), index=True, default="")
    color = Column(String, default="#3b82f6")
    symbol = Column(String)
    photo_url = Column(String)
    sort_order = Column(Integer, default=0)


class RegionalCandidate(Base):
    __tablename__ = "regional_candidates"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)
    party = Column(String)
    ubigeo = Column(String(6), index=True, default="")  # 040000 = Arequipa
    color = Column(String, default="#8b5cf6")
    symbol = Column(String)
    photo_url = Column(String)
    sort_order = Column(Integer, default=0)


class ProvincialCandidate(Base):
    __tablename__ = "provincial_candidates"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)
    party = Column(String)
    ubigeo = Column(String(6), index=True, default="")  # 040100 = Arequipa
    color = Column(String, default="#10b981")
    symbol = Column(String)
    photo_url = Column(String)
    sort_order = Column(Integer, default=0)


class ConsejeroCandidate(Base):
    """Candidato a CONSEJERO REGIONAL.

    En la cédula real de la ONPE el Consejo Regional se elige **por provincia**
    (cada provincia renueva sus escaños con su propia columna en el acta), así
    que su ``ubigeo`` es provincial (``040X00``) y compite una candidatura por
    organización en cada provincia — el mismo patrón territorial de
    ``ProvincialCandidate``, con la oferta saliendo del expediente regional del
    JNE filtrando ``cargo == CONSEJERO_REGIONAL`` por provincia de postulación.
    """
    __tablename__ = "consejero_candidates"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)
    party = Column(String)
    ubigeo = Column(String(6), index=True, default="")  # 040100, 040200, ...
    color = Column(String, default="#f59e0b")
    symbol = Column(String)
    photo_url = Column(String)
    sort_order = Column(Integer, default=0)


class Record(Base):
    __tablename__ = "records"
    id = Column(Integer, primary_key=True, index=True)
    table_id = Column(Integer, ForeignKey("tables.id"), nullable=False)
    candidate_type = Column(String, nullable=False)  # district | provincial | regional
    candidate_id = Column(Integer, nullable=False)
    votes = Column(Integer, default=0)
    verified = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class ActaMetadata(Base):
    __tablename__ = "acta_metadata"
    id = Column(Integer, primary_key=True, index=True)
    table_id = Column(Integer, ForeignKey("tables.id"), nullable=False)
    votos_blancos = Column(Integer, default=0)
    votos_nulos = Column(Integer, default=0)
    votos_impugnados = Column(Integer, default=0)
    total_electores = Column(Integer)
    # Votantes que sufragaron según la cabecera del acta física: es la cifra
    # contra la que debe cuadrar la suma de votos (NO contra los electores
    # hábiles, que casi siempre son más porque nadie está obligado a votar).
    total_votantes = Column(Integer)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


# ===========================================================================
# Cobertura de personeros — espejo del módulo PostgreSQL (modulo_campo_arequipa.sql)
# El semáforo VERDE/AMARILLO/ROJO de v_cobertura_locales se computa igual sobre
# estas tablas cuando el prototipo corre sobre SQLite.
# ===========================================================================

# Estados del personero (enum estado_personero del DDL)
ESTADOS_PERSONERO = ("ASIGNADO", "CONFIRMADO", "PRESENTE", "RETIRADO", "INHABILITADO")


class AsignacionPersonero(Base):
    """Personero asignado a una mesa (titular o suplente)."""
    __tablename__ = "asignacion_personeros"
    id = Column(Integer, primary_key=True, index=True)
    usuario_id = Column(Integer, ForeignKey("usuarios.id"), nullable=False, index=True)
    mesa_id = Column(Integer, ForeignKey("tables.id"), nullable=False, index=True)
    tipo = Column(String(10), default="TITULAR", nullable=False)  # TITULAR | SUPLENTE
    estado = Column(String(20), default="ASIGNADO", nullable=False, index=True)
    asignado_por = Column(Integer, ForeignKey("usuarios.id"))
    notas = Column(Text)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class CheckinPersonero(Base):
    """Check-in GPS del personero al llegar al local (validación Haversine en API)."""
    __tablename__ = "checkins_personero"
    id = Column(Integer, primary_key=True, index=True)
    asignacion_id = Column(Integer, ForeignKey("asignacion_personeros.id"), nullable=False, index=True)
    latitud = Column(Float, nullable=False)
    longitud = Column(Float, nullable=False)
    presicion_m = Column(Float)
    dentro_de_radio = Column(Boolean, default=False, nullable=False)
    distancia_m = Column(Float)
    dispositivo = Column(String(120))
    created_at = Column(DateTime(timezone=True), server_default=func.now())


# ===========================================================================
# Auditoría del Digitador Global — espejo ORM de `acta_auditoria_global`
# (migracion_digitador_global.sql). Cada CREAR/MODIFICAR guarda quién, desde
# qué IP, cuándo, y el diff completo en JSON (antes/después). Append-only:
# la API sólo INSERTA, nunca UPDATE/DELETE.
# ===========================================================================

ACCIONES_AUDITORIA_ACTA = ("CREAR", "MODIFICAR")


class ActaAuditoriaGlobal(Base):
    """Log estricto de cada intervención del Digitador Global sobre un acta."""

    __tablename__ = "acta_auditoria_global"
    id = Column(Integer, primary_key=True, index=True)
    # Acta intervenida (= tables.id del prototipo; mesa_id+tipo en el DDL UUID).
    acta_id = Column(Integer, ForeignKey("tables.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    numero_mesa = Column(String(6), nullable=False, index=True)
    accion = Column(String(10), nullable=False, index=True)  # CREAR | MODIFICAR
    usuario_id = Column(Integer, ForeignKey("usuarios.id", ondelete="SET NULL"),
                        index=True)
    usuario_email = Column(String(160), nullable=False)
    usuario_rol = Column(String(30), nullable=False)
    ip = Column(String(45))
    valores_anteriores = Column(Text, nullable=False, default="{}")  # JSON
    valores_nuevos = Column(Text, nullable=False, default="{}")  # JSON
    motivo = Column(Text)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), index=True)