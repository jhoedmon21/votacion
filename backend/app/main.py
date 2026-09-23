"""FastAPI application entrypoint."""
import logging
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import Base, engine
from app.core.models import (ActaAuditoriaGlobal, ActaMetadata,  # noqa: F401
                              AsignacionPersonero, CheckinPersonero,
                              DistrictCandidate, Record, RegionalCandidate,
                              Table, Venue)
from app.routers import (actas, analytics, auth, campo, credenciales,
                         digitador_global, elector, imagenes, ingesta, museo_ia,
                         plantilla, realtime, v1)
from app.services.seed_auth import asegurar_ubigeo_venues, asegurar_usuario_demo

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

Base.metadata.create_all(bind=engine)

# Usuarios demo (bcrypt) y ubigeo de venues: idempotente
with Session(bind=engine) as _seed_db:
    asegurar_ubigeo_venues(_seed_db)
    asegurar_usuario_demo(_seed_db)

app = FastAPI(title="VotoPaucarpata Engine", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# plantilla antes de actas: registra GET /api/actas/plantilla antes de que
# GET /api/actas/{acta_id} capture 'plantilla' como int (orden de resolución de FastAPI).
app.include_router(plantilla.router)
app.include_router(auth.router)
app.include_router(actas.router)
app.include_router(digitador_global.router)
app.include_router(realtime.router)
app.include_router(museo_ia.router)
app.include_router(analytics.router)
app.include_router(ingesta.router)
app.include_router(v1.router)
app.include_router(elector.router)
app.include_router(imagenes.router)
app.include_router(credenciales.router)
app.include_router(campo.router)


@app.websocket("/ws/dashboard")
async def ws_dashboard(websocket):
    """Push en tiempo real del cómputo (ver app/routers/realtime.py)."""
    from app.routers.realtime import websocket_dashboard

    await websocket_dashboard(websocket)


@app.get("/api/health")
def health():
    return {"status": "ok"}


# Serve local storage files if using local backend
storage_dir = Path(settings.storage_local_dir)
if settings.storage_backend == "local":
    storage_dir.mkdir(parents=True, exist_ok=True)
    app.mount("/storage", StaticFiles(directory=storage_dir), name="storage")