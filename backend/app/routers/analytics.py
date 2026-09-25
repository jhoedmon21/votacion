"""Analytics / dashboard router."""
from fastapi import APIRouter, Depends
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.core.auth import (alcance_ubigeos, es_rol_global, usuario_actual,
                            venues_en_alcance)
from app.core.database import get_db
from app.core.models import (ActaMetadata, AsignacionPersonero, ConsejeroCandidate,
                             DistrictCandidate, ProvincialCandidate, Record,
                             RegionalCandidate, Table, Usuario, Venue)
from app.core.orden_cedula import BLOQUE_DESCONOCIDO, bloque_y_posicion
from app.core.ubigeo import NIVELES, ubigeo_de_nivel, ubigeos_de_nivel
from app.services.processor import ensure_seed_data

router = APIRouter(prefix="/api/analytics", tags=["analytics"])

# Nivel de elección -> tabla de su oferta electoral.
CANDIDATE_MODELS = {
    "district": DistrictCandidate,
    "provincial": ProvincialCandidate,
    "consejero": ConsejeroCandidate,
    "regional": RegionalCandidate,
}


@router.get("/summary")
def summary(scope: str = "district", ubigeo: str | None = None,
            db: Session = Depends(get_db),
            usuario: Usuario = Depends(usuario_actual)):
    """Resumen para el dashboard, acotado al alcance territorial del usuario.

    SUPER_ADMIN ve toda la región; los roles territoriales sólo suman los
    locales de su ámbito. Con ``ubigeo`` se ciñe a un distrito: la oferta
    electoral es entonces la de ESE distrito (y su provincia/región según el
    nivel), no la mezcla de toda la región.
    """
    from fastapi import HTTPException

    ensure_seed_data(db)
    venues_ok = venues_en_alcance(db, usuario)
    scope = scope if scope in NIVELES else "district"

    if ubigeo:
        if not (len(ubigeo) == 6 and ubigeo.isdigit()):
            raise HTTPException(status_code=422, detail="Ubigeo de 6 dígitos")
        if not es_rol_global(usuario):
            prefijos = sorted({(u or "").rstrip("0") or u for u in alcance_ubigeos(usuario)})
            if not prefijos or not any(ubigeo.startswith(p) for p in prefijos):
                raise HTTPException(status_code=403, detail="Distrito fuera de tu alcance")
        venues_ok = venues_ok.filter(Venue.ubigeo == ubigeo)

    total_venues = venues_ok.count()
    total_tables = (
        db.query(func.coalesce(func.sum(Venue.total_tables), 0))
        .filter(Venue.id.in_([v.id for v in venues_ok.all()]))
        .scalar()
        or 0
    )
    venues = venues_ok.all()
    venues_ids = [v.id for v in venues]
    processed_tables = (
        db.query(Table)
        .filter(Table.processed == True, Table.venue_id.in_(venues_ids))  # noqa: E712
        .count()
    )
    review_tables = (
        db.query(Table)
        .filter(Table.requires_review == True, Table.venue_id.in_(venues_ids))  # noqa: E712
        .count()
    )

    # La oferta electoral es la del ámbito, no la de toda la región: la misma
    # organización compite en decenas de distritos, así que el ranking se ciñe
    # a los ubigeos visibles en su nivel (un local de 040112 vota además la
    # oferta provincial 040100 y la regional 040000). Los votos ya estaban
    # limitados por el alcance vía venues_ids al sumar por mesa.
    ubigeos_ambito = sorted(ubigeos_de_nivel((v.ubigeo for v in venues), scope))
    modelo_scope = CANDIDATE_MODELS[scope]
    oferta = (
        db.query(modelo_scope).filter(modelo_scope.ubigeo.in_(ubigeos_ambito)).all()
        if ubigeos_ambito else []
    )
    base_ranking = _ranking(db, scope, oferta, venues_ids)

    # Apply scope-specific sorting
    if scope == "provincial":
        # Sort by candidate name ascending for provincial view
        ranking = sorted(base_ranking, key=lambda x: x["name"])
    elif scope == "district" or scope == "regional" or scope == "consejero":
        # For district, consejero and regional, keep the vote-based sorting (descending) from _ranking
        ranking = base_ranking
    else:
        ranking = base_ranking

    # Consejo Regional por provincia (sólo scope=consejero): el panel pinta
    # una tarjeta por circunscripción en lugar del ranking general mezclado.
    consejeros: list = []
    if scope == "consejero":
        from app.services.consejeros import resultado_por_provincia
        mesas_ok = [
            t.id for t in db.query(Table.id)
            .filter(Table.processed == True,  # noqa: E712
                    Table.venue_id.in_(venues_ids)).all()
        ]
        consejeros = [
            {
                "provincia": p.provincia,
                "ubigeo": p.ubigeo,
                "curules": p.curules,
                "ganador": ({
                    "organizacion": p.ganador.organizacion,
                    "color": p.ganador.color,
                    "votos": p.ganador.votos,
                    "electos": p.ganador.electos,
                } if p.ganador else None),
                "escanos": [{
                    "organizacion": e.organizacion,
                    "color": e.color,
                    "votos": e.votos,
                    "curules_ganados": e.curules_ganados,
                    "electos": e.electos,
                } for e in p.escanos],
            }
            for p in resultado_por_provincia(db, mesas_ok)
        ]

    return {
        "total_venues": total_venues,
        "total_tables": total_tables,
        "processed_tables": processed_tables,
        "review_tables": review_tables,
        "progress_pct": round((processed_tables / total_tables * 100), 1) if total_tables else 0,
        "ranking": ranking,
        "scope": scope,
        "ubigeo": ubigeo,
        "consejeros": consejeros,
    }


@router.get("/map")
def map_data(db: Session = Depends(get_db), usuario: Usuario = Depends(usuario_actual)):
    """Mapa de locales, acotado al alcance territorial."""
    ensure_seed_data(db)

    venues = venues_en_alcance(db, usuario).all()
    result = []
    for v in venues:
        tables = db.query(Table).filter(Table.venue_id == v.id).all()
        # Determine winning candidate for this venue (district)
        winner = _venue_winner(db, v.id)
        result.append({
            "id": v.id,
            "name": v.name,
            "sector": v.sector,
            # Ubigeo INEI: el mapa filtra por distrito sin adivinar por nombre.
            "ubigeo": v.ubigeo,
            "latitude": v.latitude,
            "longitude": v.longitude,
            "total_tables": v.total_tables,
            "processed_tables": len([t for t in tables if t.processed]),
            "winner": winner,
        })
    return result


@router.get("/choropleth")
def choropleth_distritos(db: Session = Depends(get_db),
                         usuario: Usuario = Depends(usuario_actual)):
    """Estadísticas por distrito para el mapa coroplético.

    Una fila por ubigeo distrital del alcance: mesas del padrón, procesadas,
    observadas, locales, avance (%) y ganador de la elección distrital (si hay
    votos). El frontend colorea por avance o por ganador y enfoca la silueta
    del distrito al hacer clic (ver ChoroplethMap.tsx).
    """
    ensure_seed_data(db)
    venues = venues_en_alcance(db, usuario).all()
    venue_ids = [v.id for v in venues]
    if not venue_ids:
        return []

    mesas = (
        db.query(Venue.ubigeo, Table.processed, Table.requires_review)
        .join(Table, Table.venue_id == Venue.id)
        .filter(Venue.id.in_(venue_ids))
        .all()
    )
    stats: dict[str, dict[str, int]] = {}
    for ubigeo, procesada, revision in mesas:
        f = stats.setdefault(ubigeo, {
            "mesas": 0, "procesadas": 0, "observadas": 0, "locales": 0,
        })
        f["mesas"] += 1
        if procesada:
            f["procesadas"] += 1
        if revision:
            f["observadas"] += 1
    for v in venues:
        stats.setdefault(v.ubigeo or "", {"mesas": 0, "procesadas": 0,
                                          "observadas": 0, "locales": 0})["locales"] += 1

    # Ganador distrital por ubigeo (una sola consulta agregada).
    filas = (
        db.query(Venue.ubigeo, Record.candidate_id, func.sum(Record.votes))
        .join(Table, Table.venue_id == Venue.id)
        .join(Record, Record.table_id == Table.id)
        .filter(Record.candidate_type == "district", Venue.id.in_(venue_ids))
        .group_by(Venue.ubigeo, Record.candidate_id)
        .all()
    )
    mejor: dict[str, tuple[int, int]] = {}  # ubigeo -> (candidate_id, votos)
    for ubigeo, candidate_id, votos in filas:
        previa = mejor.get(ubigeo)
        if previa is None or votos > previa[1]:
            mejor[ubigeo] = (candidate_id, int(votos))
    candidatos = {
        c.id: c
        for c in db.query(DistrictCandidate)
        .filter(DistrictCandidate.id.in_([cid for cid, _ in mejor.values()])).all()
    } if mejor else {}

    salida = []
    for ubigeo, f in stats.items():
        ganador = None
        m = mejor.get(ubigeo)
        if m:
            c = candidatos.get(m[0])
            if c is not None:
                ganador = {"name": c.name, "color": c.color, "votes": m[1]}
        salida.append({
            "ubigeo": ubigeo,
            "mesas": f["mesas"],
            "procesadas": f["procesadas"],
            "observadas": f["observadas"],
            "locales": f["locales"],
            "avance": round(f["procesadas"] / f["mesas"] * 100, 1) if f["mesas"] else 0,
            "ganador": ganador,
        })
    salida.sort(key=lambda r: r["ubigeo"])
    return salida


@router.get("/cobertura")
def cobertura(db: Session = Depends(get_db), usuario: Usuario = Depends(usuario_actual)):
    """Semáforo de cobertura de personeros por local (brief §2).

    Espeja ``v_cobertura_locales`` del esquema PostgreSQL
    (``modulo_campo_arequipa.sql``). Regla del semáforo:

    * **ROJO**    — al menos una mesa del local sin ningún personero asignado.
    * **AMARILLO**— todas las mesas con personero asignado, pero alguna sin
                    personero PRESENTE (sin check-in GPS válido).
    * **VERDE**   — todas las mesas del local con ≥1 personero PRESENTE.

    En PostgreSQL la vista vive en la base; sobre el prototipo SQLite el
    mismo cómputo se hace aquí, acotado al alcance territorial del usuario.
    """
    ensure_seed_data(db)

    venues = venues_en_alcance(db, usuario).all()
    venue_ids = [v.id for v in venues]
    mesas = (
        db.query(Table).filter(Table.venue_id.in_(venue_ids)).all()
        if venue_ids else []
    )
    mesa_ids = [m.id for m in mesas]
    asignaciones = (
        db.query(AsignacionPersonero)
        .filter(AsignacionPersonero.mesa_id.in_(mesa_ids))
        .all()
        if mesa_ids else []
    )

    # Mesa -> cobertura: con_presente (≥1 PRESENTE) y con_asignado (≥1 activo)
    cobertura_mesa: dict[int, dict[str, bool]] = {}
    for a in asignaciones:
        c = cobertura_mesa.setdefault(a.mesa_id, {"con_presente": False, "con_asignado": False})
        if a.estado == "PRESENTE":
            c["con_presente"] = True
            c["con_asignado"] = True
        elif a.estado in ("ASIGNADO", "CONFIRMADO"):
            c["con_asignado"] = True

    # Agregación por local (una fila por venue, igual que la vista)
    por_venue: dict[int, dict[str, int]] = {
        v.id: {"mesas_total": 0, "con_presencia": 0, "con_asignado": 0} for v in venues
    }
    criticas_por_venue: dict[int, list[str]] = {v.id: [] for v in venues}
    for m in mesas:
        fila = por_venue.setdefault(
            m.venue_id, {"mesas_total": 0, "con_presencia": 0, "con_asignado": 0}
        )
        criticas = criticas_por_venue.setdefault(m.venue_id, [])
        fila["mesas_total"] += 1
        estado_mesa = cobertura_mesa.get(m.id)
        if estado_mesa is None:
            criticas.append(m.numero_mesa)
        elif estado_mesa["con_presente"]:
            fila["con_presencia"] += 1
        elif estado_mesa["con_asignado"]:
            fila["con_asignado"] += 1

    # Personeros por local (contacto directo desde el semáforo).
    asig_por_venue: dict[int, list] = {v.id: [] for v in venues}
    for a in asignaciones:
        mesa = next((m for m in mesas if m.id == a.mesa_id), None)
        if mesa is None:
            continue
        asig_por_venue.setdefault(mesa.venue_id, []).append(a)
    usuarios = {u.id: u for u in db.query(Usuario).all()} if asignaciones else {}

    result = []
    for v in venues:
        f = por_venue[v.id]
        criticas = criticas_por_venue.get(v.id, [])
        criticas.sort()
        sin_asignar = len(criticas)
        con_asignado_sin_presente = f["con_asignado"]
        # Regla del semáforo (idéntica a la vista PostgreSQL)
        if sin_asignar > 0:
            nivel = "ROJO"
        elif con_asignado_sin_presente > 0:
            nivel = "AMARILLO"
        else:
            nivel = "VERDE"
        equipo = []
        vistos = set()
        for a in asig_por_venue.get(v.id, []):
            u = usuarios.get(a.usuario_id)
            if u is None or u.id in vistos:
                continue
            vistos.add(u.id)
            equipo.append({
                "nombre": u.nombre_completo,
                "telefono": u.telefono,
                "estado": a.estado,
            })
        equipo.sort(key=lambda p: (p["estado"] != "PRESENTE", p["nombre"]))
        result.append({
            "local_id": v.id,
            "nombre": v.name,
            "ubigeo": v.ubigeo,
            "personeros": equipo,
            "sector": v.sector,
            "latitude": v.latitude,
            "longitude": v.longitude,
            "mesas_total": f["mesas_total"],
            "mesas_con_presencia": f["con_presencia"],
            "mesas_con_personero": f["con_asignado"],
            "mesas_sin_personero": sin_asignar,
            "nivel": nivel,
            "mesas_criticas": criticas,
        })

    # Locales rojos primero: es la fila que mira el coordinador
    orden = {"ROJO": 0, "AMARILLO": 1, "VERDE": 2}
    result.sort(key=lambda r: (orden[r["nivel"]], r["nombre"]))
    return result


def _ranking(db: Session, candidate_type: str, candidates, venues_ids: list[int] | None = None) -> list:
    """Totales por candidato; si se dan venues_ids, sólo esas mesas suman."""
    q = db.query(Record.candidate_id, func.sum(Record.votes)).filter(
        Record.candidate_type == candidate_type
    )
    if venues_ids is not None:
        mesas = [t.id for t in db.query(Table.id).filter(Table.venue_id.in_(venues_ids)).all()]
        q = q.filter(Record.table_id.in_(mesas) if mesas else Record.id < 0)
    rows = q.group_by(Record.candidate_id).all()
    totals = {cid: int(votes) for cid, votes in rows}
    ranking = []
    for c in candidates:
        bloque, posicion, _ = bloque_y_posicion(c.party)
        en_sorteo = bloque != BLOQUE_DESCONOCIDO
        ranking.append({
            # La casita del acta de este ámbito (1..N).
            "candidate_id": c.sort_order,
            "name": c.name,
            "party": c.party,
            "color": c.color,
            "votes": totals.get(c.id, 0),
            "symbol": c.symbol,
            "photo_url": c.photo_url,
            # Orden oficial de la cédula (sorteo ONPE del 10-jun-2026), para que
            # el dashboard pueda listar los partidos como en el acta y no sólo
            # por votos. Es del bloque nacional/movimientos, así que sirve
            # también cuando la vista agrega varios distritos.
            "bloque_cedula": bloque if en_sorteo else None,
            "posicion_cedula": posicion if en_sorteo else None,
        })
    ranking.sort(key=lambda x: x["votes"], reverse=True)
    return ranking


def _venue_winner(db: Session, venue_id: int):
    table_ids = [t.id for t in db.query(Table).filter(Table.venue_id == venue_id).all()]
    if not table_ids:
        return None
    # Sólo la oferta distrital de ese local: el mismo partido compite en los
    # 101 distritos y el ganador debe salir del ámbito, no de un homónimo.
    venue = db.query(Venue).filter(Venue.id == venue_id).first()
    ubigeo = ubigeo_de_nivel(venue.ubigeo if venue else "", "district")
    district_map = {
        c.id: c for c in db.query(DistrictCandidate)
        .filter(DistrictCandidate.ubigeo == ubigeo).all()
    }
    rows = (
        db.query(Record.candidate_id, func.sum(Record.votes))
        .filter(Record.candidate_type == "district", Record.table_id.in_(table_ids))
        .group_by(Record.candidate_id)
        .all()
    )
    if not rows:
        return None
    best_id, best_votes = max(rows, key=lambda x: x[1])
    candidate = district_map.get(best_id)
    if not candidate:
        return None
    return {"name": candidate.name, "color": candidate.color, "votes": int(best_votes)}