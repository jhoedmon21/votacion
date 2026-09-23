"""Museo IA — endpoint generador de prompts JSON para el LLM.

``POST /api/museo-ia/prompt`` consolida el cómputo nacional (mismo agregado
que ``GET /api/v1/resultados/resumen`` pero sin filtro ubigeo: el Digitador
Global y el SUPER_ADMIN ven todo el país) y lo convierte en un prompt
dinámico vía ``app/services/museo_ia.py``. El dashboard lo consume para
alimentar a Muse Spark / GPT / Gemini sin exponer la base.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.core.auth import es_rol_global, usuario_actual
from app.core.database import get_db
from app.core.models import (ActaMetadata, DistrictCandidate,
                              ProvincialCandidate, Record, RegionalCandidate,
                              Table, Usuario, Venue)
from app.core.schemas import MuseoIaPromptIn, MuseoIaPromptOut
from app.core.ubigeo import nivel_desde_tipo, ubigeo_de_nivel
from app.core.ubigeo_catalogo import UBIGEO_DISTRITO
from app.services.museo_ia import MuseoIaError, construir_prompt_consolidado
from app.services.processor import ensure_seed_data

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/museo-ia", tags=["museo-ia"])

MODELOS = {
    "district": DistrictCandidate,
    "provincial": ProvincialCandidate,
    "regional": RegionalCandidate,
}


def _consolidado_nacional(
    db: Session, usuario: Usuario, tipo_eleccion: str, top: int
) -> dict:
    """Agregado nacional del cómputo (bypass ubigeo sólo para rol global).

    Los roles territoriales obtienen su consolidado acotado a su alcance
    (misma regla por prefijo que /analytics/summary); el Digitador Global y
    el SUPER_ADMIN consolidan todo el país.
    """
    ensure_seed_data(db)
    clave = nivel_desde_tipo((tipo_eleccion or "").upper()) or "district"

    venues_q = db.query(Venue)
    if not es_rol_global(usuario):
        from app.core.auth import alcance_ubigeos

        ubigeos = alcance_ubigeos(usuario)
        prefijos = sorted({(u or "").rstrip("0") or u for u in ubigeos})
        if not prefijos:
            raise HTTPException(status_code=403,
                                detail="Rol territorial sin alcance asignado")
        # Multi-prefijo: OR de LIKE (un coordinador puede tener 2 provincias).
        from sqlalchemy import or_

        venues_q = venues_q.filter(
            or_(*[Venue.ubigeo.like(f"{p}%") for p in prefijos]))
    venues = venues_q.all()
    vids = [v.id for v in venues]

    mesas = db.query(Table).filter(Table.venue_id.in_(vids)).all() if vids else []
    procesadas = [t for t in mesas if t.processed and not t.requires_review]
    observadas = [t for t in mesas if t.requires_review]
    pids = [t.id for t in procesadas]

    habiles = sum(t.electores_habiles or 0 for t in procesadas)
    votos_org = (
        db.query(func.coalesce(func.sum(Record.votes), 0))
        .filter(Record.candidate_type == clave, Record.table_id.in_(pids)).scalar()
        if pids else 0
    ) or 0
    meta = (
        db.query(func.coalesce(func.sum(ActaMetadata.votos_blancos), 0),
                 func.coalesce(func.sum(ActaMetadata.votos_nulos), 0),
                 func.coalesce(func.sum(ActaMetadata.votos_impugnados), 0))
        .filter(ActaMetadata.table_id.in_(pids)).first()
        if pids else (0, 0, 0)
    )
    blancos, nulos, impug = (int(x or 0) for x in meta)
    emitidos = int(votos_org) + blancos + nulos + impug

    modelo = MODELOS[clave]
    ambitos = sorted({ubigeo_de_nivel(v.ubigeo or "", clave) for v in venues})
    oferta = db.query(modelo).filter(modelo.ubigeo.in_(ambitos)).all() if ambitos else []
    totales = dict(
        db.query(Record.candidate_id, func.sum(Record.votes))
        .filter(Record.candidate_type == clave, Record.table_id.in_(pids))
        .group_by(Record.candidate_id).all()) if pids else {}
    filas = sorted(
        ({"organizacion": c.party or c.name, "candidato": c.name,
          "color": c.color or "#6b7280",
          "votos": int(totales.get(c.id, 0) or 0)} for c in oferta),
        key=lambda r: r["votos"], reverse=True)[:top]
    total_v = sum(r["votos"] for r in filas) or 1
    partidos = [{**r, "porcentaje": round(100.0 * r["votos"] / total_v, 2)}
                for r in filas]

    por_ubigeo: dict[str, dict] = {}
    for v in venues:
        u = v.ubigeo or ""
        d = por_ubigeo.setdefault(u, {"mesas": 0, "actas": 0, "obs": 0})
        tm = [t for t in mesas if t.venue_id == v.id]
        d["mesas"] += len(tm)
        d["actas"] += sum(1 for t in tm if t.processed and not t.requires_review)
        d["obs"] += sum(1 for t in tm if t.requires_review)
    distritos = sorted(
        ({"ubigeo": u, "distrito": UBIGEO_DISTRITO.get(u, u),
          "mesas": d["mesas"], "actas": d["actas"], "observadas": d["obs"],
          "avance_pct": round(100.0 * d["actas"] / d["mesas"], 1) if d["mesas"] else 0.0}
         for u, d in por_ubigeo.items() if u),
        key=lambda r: (r["avance_pct"], -r["mesas"]))

    venue_por_id = {v.id: v for v in venues}
    obs_lista = sorted(
        ({"numero_mesa": t.numero_mesa,
          "local": venue_por_id.get(t.venue_id).name if venue_por_id.get(t.venue_id) else "",
          "ubigeo": venue_por_id.get(t.venue_id).ubigeo if venue_por_id.get(t.venue_id) else "",
          "distrito": UBIGEO_DISTRITO.get(
              venue_por_id.get(t.venue_id).ubigeo if venue_por_id.get(t.venue_id) else "", "")}
         for t in observadas),
        key=lambda r: r["numero_mesa"])[:100]

    total_mesas = len(mesas)
    return {
        "total_mesas": total_mesas,
        "total_actas": len(procesadas) + len(observadas),
        "actas_normales": len(procesadas),
        "actas_observadas": len(observadas),
        "avance_pct": round(100.0 * len(procesadas) / total_mesas, 2) if total_mesas else 0.0,
        "participacion_pct": round(100.0 * emitidos / habiles, 2) if habiles else 0.0,
        "tipo_eleccion": (tipo_eleccion or "DISTRITAL").upper(),
        "electores_habiles": habiles,
        "votos_validos": int(votos_org),
        "votos_blancos": blancos,
        "votos_nulos": nulos,
        "votos_impugnados": impug,
        "votos_emitidos": emitidos,
        "partidos": partidos,
        "distritos": distritos,
        "observadas": obs_lista,
    }


@router.post("/prompt", response_model=MuseoIaPromptOut)
def generar_prompt(
    payload: MuseoIaPromptIn,
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(usuario_actual),
):
    """Consolida el cómputo tras la carga de actas y devuelve el prompt JSON.

    Ejemplo de consumo desde el dashboard::

        const prompt = await fetch("/api/museo-ia/prompt", {...}).then(r => r.json());
        const analisis = await llamarLLM(prompt.system, prompt.user_prompt);
    """
    try:
        resumen = _consolidado_nacional(db, usuario, payload.tipo_eleccion, payload.top)
        prompt = construir_prompt_consolidado(
            resumen=resumen,
            tipo_eleccion=payload.tipo_eleccion,
            top=payload.top,
            tono=payload.tono,
            incluir_observadas=payload.incluir_observadas,
            pregunta=payload.pregunta,
        )
    except MuseoIaError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    logger.info("museo-ia prompt %s top=%s por %s",
                payload.tipo_eleccion, payload.top, usuario.email)
    return prompt


@router.get("/prompt", response_model=MuseoIaPromptOut)
def generar_prompt_get(
    tipo_eleccion: str = Query(default="DISTRITAL"),
    top: int = Query(default=10, ge=1, le=50),
    tono: str = Query(default="institucional"),
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(usuario_actual),
):
    """Variante GET para probar el generador desde el navegador/Swagger."""
    return generar_prompt(
        MuseoIaPromptIn(tipo_eleccion=tipo_eleccion, top=top, tono=tono),
        db, usuario,
    )
