"""VotoPaucarpata Engine — database engine & session factory."""
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

from app.core.config import settings

connect_args = {}
if settings.database_url.startswith("sqlite"):
    connect_args["check_same_thread"] = False

engine = create_engine(
    settings.database_url,
    connect_args=connect_args,
    pool_pre_ping=True,
    # El pool debe quedar POR DEBAJO de max_connections de PostgreSQL (30):
    # 20 permanentes + 5 de ráfaga, con reciclaje a los 30 min para que un
    # despliegue de larga vida no acumule conexiones zombies.
    pool_size=20,
    max_overflow=5,
    pool_recycle=1800,
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()