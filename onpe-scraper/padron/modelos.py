"""ORM del padrón: `locales_votacion` y `mesas_votacion`.

Espejo Python del DDL (`onpe-scraper/sql/ddl_locales_mesas.sql`). El DDL es
canónico en PostgreSQL/MySQL; este ORM sirve al loader y crea las tablas en
desarrollo (SQLite) vía `crear_tablas()`. `schema` califica los INSERT cuando
el padrón vive en un schema dedicado (PADRON_SCHEMA=padron).
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import (CHAR, VARCHAR, CheckConstraint, DateTime, Float,
                        ForeignKey, Integer, String, UniqueConstraint,
                        create_engine, func)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker


class Base(DeclarativeBase):
    pass


def _esquema(nombre: str) -> dict:
    return {"schema": nombre} if nombre else {}


class LocalVotacion(Base):
    """Un recinto de votación de un distrito de Arequipa."""

    __tablename__ = "locales_votacion"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    ubigeo: Mapped[str] = mapped_column(CHAR(6), nullable=False)
    departamento: Mapped[str] = mapped_column(VARCHAR(60), nullable=False,
                                              default="AREQUIPA")
    provincia: Mapped[str] = mapped_column(VARCHAR(60), nullable=False)
    distrito: Mapped[str] = mapped_column(VARCHAR(60), nullable=False)
    codigo_local: Mapped[str] = mapped_column(VARCHAR(20), nullable=False,
                                              default="SIN-CODIGO")
    nombre_local: Mapped[str] = mapped_column(VARCHAR(160), nullable=False)
    direccion: Mapped[str | None] = mapped_column(VARCHAR(260))
    referencia: Mapped[str | None] = mapped_column(VARCHAR(220))
    latitud: Mapped[float | None] = mapped_column(Float)
    longitud: Mapped[float | None] = mapped_column(Float)
    total_mesas: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    fuente: Mapped[str] = mapped_column(VARCHAR(40), nullable=False, default="ONPE")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True),
                                                 server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True),
                                                 server_default=func.now(),
                                                 onupdate=func.now())

    __table_args__ = (
        UniqueConstraint("ubigeo", "codigo_local", name="locales_codigo_por_ubigeo"),
    )

    def __repr__(self) -> str:  # pragma: no cover
        return (f"<Local {self.ubigeo}/{self.codigo_local} "
                f"{self.nombre_local!r} mesas={self.total_mesas}>")


class MesaVotacion(Base):
    """Una mesa de sufragio dentro de un local (FK -> locales_votacion)."""

    __tablename__ = "mesas_votacion"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    local_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("locales_votacion.id", ondelete="CASCADE",
                            onupdate="CASCADE"), nullable=False)
    numero_mesa: Mapped[str] = mapped_column(CHAR(6), nullable=False)
    electores_habiles: Mapped[int | None] = mapped_column(Integer)
    estado_acta: Mapped[str] = mapped_column(String(20), nullable=False,
                                             default="PENDIENTE")
    fecha_registro: Mapped[datetime] = mapped_column(DateTime(timezone=True),
                                                     server_default=func.now())
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True),
                                                 server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True),
                                                 server_default=func.now(),
                                                 onupdate=func.now())

    __table_args__ = (
        UniqueConstraint("local_id", "numero_mesa", name="mesas_unica_por_local"),
    )

    def __repr__(self) -> str:  # pragma: no cover
        return f"<Mesa {self.numero_mesa} local={self.local_id}>"


def aplicar_schema(schema: str) -> None:
    """Califica ambas tablas con el schema (llamar antes de crear engine)."""
    for modelo in (LocalVotacion, MesaVotacion):
        if schema:
            modelo.__table__.schema = schema
        elif modelo.__table__.schema:
            modelo.__table__.schema = None


def crear_engine_y_sesion(database_url: str, schema: str = ""):
    """Engine + fábrica de sesiones (SQLite con check_same_thread=False)."""
    aplicar_schema(schema)
    kwargs: dict = {"pool_pre_ping": True}
    if database_url.startswith("sqlite"):
        kwargs["connect_args"] = {"check_same_thread": False}
    engine = create_engine(database_url, **kwargs)
    if schema and engine.dialect.name == "postgresql":
        with engine.begin() as conn:
            conn.exec_driver_sql(f'CREATE SCHEMA IF NOT EXISTS "{schema}"')
    return engine, sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def crear_tablas(engine) -> None:
    """Crea las tablas si faltan (desarrollo/SQLite; en PG manda el DDL)."""
    Base.metadata.create_all(bind=engine, checkfirst=True)
