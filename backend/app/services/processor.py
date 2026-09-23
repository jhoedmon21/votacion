"""Data persistence service — insert parsed actas into the database."""
import logging

from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.models import (ActaMetadata, AsignacionPersonero, DistrictCandidate,
                             ProvincialCandidate, Record, RegionalCandidate, ROLES_SISTEMA,
                             Table, Usuario, Venue)
from app.core.schemas import ActaParseResult
from app.core.ubigeo import candidatos_del_ambito, ubigeo_de_nivel

logger = logging.getLogger(__name__)


def ensure_seed_data(db: Session) -> None:
    """Insert default venues and candidates if missing."""
    if db.query(Venue).count() == 0:
        venues = [
            ("I.E. Manuel Veramendi", "Ciudad de Dios", "Av. Arequipa 123, Paucarpata", -16.4333, -71.5167, 40),
            ("I.E. Teobaldo Paredes", "Miguel Grau", "Calle Grau 456, Paucarpata", -16.4411, -71.5233, 35),
            ("I.E. Campo Marte", "Campo Marte", "Av. Campo Marte 789", -16.4500, -71.5100, 30),
            ("I.E. Israel", "Israel", "Jr. Israel 101", -16.4200, -71.5300, 28),
            ("I.E. 15 de Agosto", "15 de Agosto", "Av. 15 de Agosto 202", -16.4600, -71.5050, 25),
        ]
        for name, sector, addr, lat, lon, total in venues:
            db.add(Venue(name=name, sector=sector, address=addr, latitude=lat, longitude=lon, total_tables=total))

    # La oferta electoral NO se simula: la publica el cargador real
    # (``python -m app.load_jne_data``). Sembrar partidos ficticios aquí haría
    # que un acta se pudiera registrar contra organizaciones que no existen.
    if db.query(DistrictCandidate).count() == 0:
        logger.warning(
            "No hay oferta electoral cargada. Ejecuta 'python -m app.load_jne_data' "
            "para publicar los candidatos reales del JNE."
        )

    _asegurar_cobertura_demo(db)
    db.commit()


def _asegurar_cobertura_demo(db: Session) -> None:
    """Personeros demo para el semáforo de cobertura (idempotente).

    Reparte asignaciones sobre las mesas reales del padrón: locales con
    cobertura total (VERDE), parcial (AMARILLO) y sin cubrir (ROJO), para que
    el dashboard muestre los tres estados desde el primer arranque.
    Idempotente: si ya hay asignaciones, no toca nada.
    """
    if db.query(AsignacionPersonero).count() > 0:
        return

    usuario = db.query(Usuario).filter(Usuario.rol == "SUPER_ADMIN").first()
    if usuario is None:
        logger.info("cobertura demo omitida: no hay usuarios aún")
        return

    venues = db.query(Venue).order_by(Venue.id).all()
    mesas_por_venue: dict[int, list[Table]] = {}
    for v in venues:
        mesas = db.query(Table).filter(Table.venue_id == v.id).all()
        if mesas:
            mesas_por_venue[v.id] = mesas
    if not mesas_por_venue:
        return

    # Patrón de cobertura por posición: 1º y 2º local completos (VERDE),
    # 3º con la mitad (AMARILLO), resto sin personeros (ROJO).
    orden_venues = sorted(mesas_por_venue.keys())
    creadas = 0
    for idx, venue_id in enumerate(orden_venues):
        mesas = mesas_por_venue[venue_id]
        if idx < 2:
            cubiertas = mesas                    # VERDE: todas
            estado = "PRESENTE"
        elif idx == 2:
            cubiertas = mesas[: len(mesas) // 2]  # AMARILLO: la mitad
            estado = "CONFIRMADO"
        else:
            cubiertas = []                        # ROJO: ninguna
            estado = "ASIGNADO"
        for mesa in cubiertas:
            db.add(AsignacionPersonero(
                usuario_id=usuario.id,
                mesa_id=mesa.id,
                tipo="TITULAR",
                estado=estado,
                asignado_por=usuario.id,
                notas="seed demo de cobertura",
            ))
            creadas += 1
    if creadas:
        logger.info("seed de cobertura demo: %d asignaciones", creadas)


def _upsert_table(db: Session, numero_mesa: str, image_url: str, confidence: float) -> tuple[Table, bool]:
    """Find existing table by mesa number or create a new one. Returns (table, created)."""
    table = db.query(Table).filter(Table.numero_mesa == numero_mesa).first()
    created = table is None
    if table is None:
        # Attach to a venue by hashing mesa number for stable assignment
        venue = db.query(Venue).first()
        if venue is None:
            raise RuntimeError("No venues in database; run ensure_seed_data first.")
        table = Table(numero_mesa=numero_mesa, venue_id=venue.id)
        db.add(table)
        db.flush()

    table.processed = True
    table.requires_review = confidence < settings.ocr_confidence_threshold
    table.status = "requires_review" if table.requires_review else "processed"
    table.ocr_confidence = confidence
    table.image_url = image_url
    db.flush()
    return table, created


def save_acta(db: Session, result: ActaParseResult, image_url: str) -> Table:
    """Persist parsed acta into DB. Returns the Table record."""
    ensure_seed_data(db)

    table, _created = _upsert_table(
        db, result.numero_mesa, image_url, result.ocr_confidence
    )

    # Upsert candidate vote records. Los mapas se acotan al ámbito del local:
    # ``sort_order`` es la posición de la organización en el acta, así que sin
    # el filtro los votos de un distrito se guardarían contra el partido
    # homónimo de otro ámbito.
    venue = db.query(Venue).filter(Venue.id == table.venue_id).first()
    ubigeo = (venue.ubigeo if venue else "") or ""
    district_map = {
        c.sort_order: c.id
        for c in candidatos_del_ambito(db, DistrictCandidate, ubigeo_de_nivel(ubigeo, "district")).all()
    }
    provincial_map = {
        c.sort_order: c.id
        for c in candidatos_del_ambito(db, ProvincialCandidate, ubigeo_de_nivel(ubigeo, "provincial")).all()
    }
    regional_map = {
        c.sort_order: c.id
        for c in candidatos_del_ambito(db, RegionalCandidate, ubigeo_de_nivel(ubigeo, "regional")).all()
    }

    def _save(candidate_type: str, votes_list: list, id_map: dict) -> None:
        for item in votes_list:
            candidate_id = id_map.get(item.candidate_id)
            if candidate_id is None:
                continue
            rec = (
                db.query(Record)
                .filter(
                    Record.table_id == table.id,
                    Record.candidate_type == candidate_type,
                    Record.candidate_id == candidate_id,
                )
                .first()
            )
            if rec is None:
                rec = Record(
                    table_id=table.id,
                    candidate_type=candidate_type,
                    candidate_id=candidate_id,
                    votes=item.votes,
                )
                db.add(rec)
            else:
                rec.votes = item.votes

    _save("district", result.votos_distrital, district_map)
    _save("provincial", result.votos_provincial, provincial_map)
    _save("regional", result.votos_regional, regional_map)

    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
    if meta is None:
        meta = ActaMetadata(
            table_id=table.id,
            votos_blancos=result.votos_blancos,
            votos_nulos=result.votos_nulos,
            votos_impugnados=result.votos_impugnados,
        )
        db.add(meta)
    else:
        meta.votos_blancos = result.votos_blancos
        meta.votos_nulos = result.votos_nulos
        meta.votos_impugnados = result.votos_impugnados

    db.commit()
    db.refresh(table)
    return table