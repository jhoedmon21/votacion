"""Data persistence service — insert parsed actas into the database."""
import logging

from sqlalchemy import func
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.models import (ActaMetadata, AsignacionPersonero, ConsejeroCandidate,
                              DistrictCandidate, ProvincialCandidate, Record,
                              RegionalCandidate, ROLES_SISTEMA, Table, Usuario, Venue)
from app.core.schemas import ActaParseResult
from app.core.ubigeo import candidatos_del_ambito, ubigeo_de_nivel

logger = logging.getLogger(__name__)

# Niveles de elección del acta (pie por columna, norma ONPE) y su clave en
# ``records.candidate_type``.
NIVELES_ACTA = ("distrital", "provincial", "consejero", "regional")
CLAVE_A_NIVEL = {
    "district": "distrital",
    "provincial": "provincial",
    "consejero": "consejero",
    "regional": "regional",
}


def obtener_metadata(db: Session, table_id: int) -> ActaMetadata:
    """Metadata del acta, creándola si no existe (sin commit).

    Hace ``flush`` antes de buscar: la sesión corre con ``autoflush=False``
    y una metadata recién agregada en el mismo request (aún sin flush) no
    sería visible para la query — se crearía una fila DUPLICADA por mesa.
    """
    db.flush()
    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table_id).first()
    if meta is None:
        meta = ActaMetadata(table_id=table_id)
        db.add(meta)
    return meta


def asignar_pie_acta(
    db: Session,
    table_id: int,
    nivel: str,
    *,
    blancos: int | None,
    nulos: int | None,
    impugnados: int | None,
    sincronizar: bool = True,
) -> ActaMetadata:
    """ÚNICO punto de escritura del pie (blancos/nulos/impugnados) de un nivel.

    El origen de verdad son las columnas por nivel del acta
    (``blancos_distrital`` … ``impugnados_regional``): el consolidado
    histórico (``votos_blancos`` …) se RECONSTRUYE desde ellas en
    ``sincronizar_consolidado_pie`` — nunca se asigna dos veces desde el
    payload. Los ``None`` se normalizan a 0 para que la aritmética de
    cuadre nunca opere contra NULL.

    ``sincronizar=False`` permite asignar varios niveles (p. ej. el PUT
    multi-nivel) y reconstruir el consolidado UNA sola vez al final.
    """
    if nivel not in NIVELES_ACTA:
        raise ValueError(f"Nivel de acta inválido: {nivel!r}")
    meta = obtener_metadata(db, table_id)
    setattr(meta, f"blancos_{nivel}", blancos or 0)
    setattr(meta, f"nulos_{nivel}", nulos or 0)
    setattr(meta, f"impugnados_{nivel}", impugnados or 0)
    if sincronizar:
        sincronizar_consolidado_pie(db, meta, nivel_referencia=nivel)
    return meta


def sincronizar_consolidado_pie(
    db: Session, meta: ActaMetadata, nivel_referencia: str | None = None
) -> None:
    """Reconstruye el consolidado histórico desde el pie por columna.

    * ``nivel_referencia``: consolidado = pie de esa columna (la que se
      acaba de registrar — p. ej. el nivel de la elección del formulario).
    * Sin referencia (PUT multi-nivel): consolidado = pie de la COLUMNA
      MAYOR (la de más votos válidos persistidos), que es la que resume la
      cabecera del papel.
    * Si ningún nivel tiene pie (> 0), se CONSERVA el consolidado previo:
      actas históricas que sólo trajeron el consolidado no se borran.
    """
    if meta is None:
        return
    if nivel_referencia is not None:
        meta.votos_blancos = getattr(meta, f"blancos_{nivel_referencia}") or 0
        meta.votos_nulos = getattr(meta, f"nulos_{nivel_referencia}") or 0
        meta.votos_impugnados = getattr(meta, f"impugnados_{nivel_referencia}") or 0
        return

    tiene_pie = any(
        (getattr(meta, f"blancos_{n}") or 0)
        + (getattr(meta, f"nulos_{n}") or 0)
        + (getattr(meta, f"impugnados_{n}") or 0)
        > 0
        for n in NIVELES_ACTA
    )
    if not tiene_pie:
        return  # legacy: sin pie por columna se mantiene el consolidado

    db.flush()  # ver los records pendientes de la sesión antes de medir
    mayor, mayor_suma = NIVELES_ACTA[0], -1
    for nivel in NIVELES_ACTA:
        suma = (
            db.query(func.coalesce(func.sum(Record.votes), 0))
            .filter(
                Record.table_id == meta.table_id,
                Record.candidate_type == next(
                    c for c, n in CLAVE_A_NIVEL.items() if n == nivel
                ),
            )
            .scalar()
        )
        if int(suma or 0) > mayor_suma:
            mayor, mayor_suma = nivel, int(suma or 0)
    meta.votos_blancos = getattr(meta, f"blancos_{mayor}") or 0
    meta.votos_nulos = getattr(meta, f"nulos_{mayor}") or 0
    meta.votos_impugnados = getattr(meta, f"impugnados_{mayor}") or 0


def validar_cierre_acta(
    table: Table,
    *,
    total_validos: int = 0,
    votos_blancos: int | None = None,
    votos_nulos: int | None = None,
    votos_impugnados: int | None = None,
    total_papel: int | None = None,
    columnas: list[dict] | None = None,
    marcar_procesada: bool = True,
) -> dict:
    """Validación de cierre previa al ``db.commit()`` (regla R1, norma ONPE).

    Compara la suma física calculada de una columna del acta

        Σ votos válidos de organizaciones + blancos + nulos + impugnados

    contra el total de ciudadanos que votaron impreso en el papel
    (``total_papel``). Un descuadre NO rechaza el acta: se registra tal
    cual está el papel, queda OBSERVADA (``requires_review=True``, fuera
    del cómputo) y la observación documenta la diferencia para el
    coordinador. Los contadores se persisten UNA sola vez — esta función
    sólo fija el estado de la mesa, nunca toca la metadata de votos.

    ``columnas`` (opcional) permite validar varias columnas del mismo
    papel (p. ej. GOBERNADOR_VICE y CONSEJEROS del acta regional): cada
    dict trae ``nombre``, ``validos``, ``blancos``, ``nulos``,
    ``impugnados`` y ``papel``. Si una sola columna descuadra, el acta
    completa queda observada. Sin ``columnas`` se usa la columna principal
    con los kwargs individuales (firma del caso simple).

    ``marcar_procesada=False`` (PUT sin ``verified``: autoguardado) deja
    el estado previo intacto cuando la suma CUADRA; el descuadre siempre
    observa.

    Devuelve el diagnóstico: ``cuadra``, ``suma_calculada``,
    ``total_papel``, ``diferencia`` y ``descuadres`` por columna.
    """
    descuadres: list[dict] = []
    if columnas is None:
        columnas = [
            {
                "nombre": "",
                "validos": total_validos or 0,
                "blancos": votos_blancos or 0,
                "nulos": votos_nulos or 0,
                "impugnados": votos_impugnados or 0,
                "papel": total_papel or 0,
            }
        ]
    for col in columnas:
        suma_calculada = (
            (col.get("validos") or 0)
            + (col.get("blancos") or 0)
            + (col.get("nulos") or 0)
            + (col.get("impugnados") or 0)
        )
        papel = col.get("papel") or 0
        if suma_calculada != papel:
            descuadres.append(
                {
                    "columna": col.get("nombre") or "",
                    "suma_calculada": suma_calculada,
                    "total_papel": papel,
                    "diferencia": papel - suma_calculada,
                }
            )

    principal = columnas[0] if columnas else {
        "validos": 0, "blancos": 0, "nulos": 0, "impugnados": 0, "papel": 0
    }
    suma_calculada = (
        (principal.get("validos") or 0)
        + (principal.get("blancos") or 0)
        + (principal.get("nulos") or 0)
        + (principal.get("impugnados") or 0)
    )
    total_papel = principal.get("papel") or 0

    if descuadres:
        detalle = " | ".join(
            (
                f"Columna {d['columna']}: " if d["columna"] else ""
            )
            + f"Suma calculada ({d['suma_calculada']}) difiere del total del papel ({d['total_papel']})"
            for d in descuadres
        )
        table.requires_review = True
        table.status = "requires_review"
        table.processed = False
        table.observacion = f"Descuadre: {detalle}"
    else:
        table.observacion = None
        if marcar_procesada:
            table.requires_review = False
            table.status = "processed"
            table.processed = True

    return {
        "cuadra": not descuadres,
        "suma_calculada": suma_calculada,
        "total_papel": total_papel,
        "diferencia": total_papel - suma_calculada,
        "descuadres": descuadres,
    }


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
    consejero_map = {
        c.sort_order: c.id
        for c in candidatos_del_ambito(db, ConsejeroCandidate, ubigeo_de_nivel(ubigeo, "consejero")).all()
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
    _save("consejero", result.votos_consejero, consejero_map)
    _save("regional", result.votos_regional, regional_map)

    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
    if meta is None:
        meta = ActaMetadata(table_id=table.id)
        db.add(meta)
    # El OCR no distingue el nivel del pie: sin columna por nivel conocida
    # sólo se alimenta el consolidado (``or 0`` evita NULL en la aritmética
    # de cuadre). El pie por columna llega con la digitación/rectificación
    # vía ``asignar_pie_acta``, que reconstruye este consolidado.
    meta.votos_blancos = result.votos_blancos or 0
    meta.votos_nulos = result.votos_nulos or 0
    meta.votos_impugnados = result.votos_impugnados or 0

    db.commit()
    db.refresh(table)
    return table