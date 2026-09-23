"""Publica los candidatos reales del JNE en la base que lee el dashboard.

Lee los 110 ámbitos crawleados por ``jne-scraper`` (regional 040000, 8
provinciales y 101 distritales) y los carga en las tres tablas de candidatos
del prototipo, que hasta ahora contenían datos simulados (provincial y
regional) o un único distrito (Paucarpata).

Cada fila guarda su ``ubigeo`` porque **el nombre de una organización se repite
entre ámbitos** — ``AHORA NACION - AN`` compite en 68 — así que sin la
dimensión territorial los votos de un distrito se atribuirían a la
organización homónima de otro. ``sort_order`` es la posición de la
organización **en el formulario del acta** (el índice en el arreglo
``organizaciones`` del JSON que también consume la PWA, primero **en el orden
de la cédula** que fija ``app/core/orden_cedula.py`` (sorteo de la ONPE del
10-jun-2026, no el alfabético del JNE) y después **compactado**: la ONPE numera
las casitas de la columna del acta sin huecos, así que la organización que el
JNE retira corre a las siguientes. Como el voto digitado viaja identificado por
esta posición, reordenar o renumerar exige reejecutar la carga y volver a
digitar lo que estuviera en cola: los votos ya guardados se resuelven por
``candidate_id``, pero un formulario abierto antes del cambio sigue numerando
a la manera vieja.

La carga es idempotente: hace upsert por ``(ubigeo, party)`` **preservando el
id**, así que los votos ya registrados (``records.candidate_id``) siguen
apuntando al mismo candidato. Reejecutarla tras un re-crawl actualiza nombres,
fotos y logos sin tocar un solo voto.

Uso:
    python -m app.load_jne_data                # los 110 ámbitos
    python -m app.load_jne_data --dry-run      # informa sin escribir nada
    python -m app.load_jne_data --solo 040112 --solo 040100
"""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import re
import shutil
from collections import Counter
from pathlib import Path
from typing import NamedTuple

from sqlalchemy import inspect, text
from sqlalchemy.orm import Session

from app.core.database import Base, SessionLocal, engine
from app.core.models import (DistrictCandidate, ProvincialCandidate, Record,
                             RegionalCandidate)
from app.core.orden_cedula import esta_ordenada, ordenar_organizaciones

logger = logging.getLogger(__name__)

# --- rutas ------------------------------------------------------------------
RAIZ = Path(__file__).resolve().parents[2]
DATA_DIR = RAIZ / "jne-scraper" / "data" / "arequipa"
MEDIA_DIR = RAIZ / "jne-scraper" / "media"
# El directorio que main.py monta en /storage (settings.storage_local_dir).
STORAGE_DIR = RAIZ / "backend" / "storage"
STORAGE_URL = "/storage"

# Arequipa: los ubigeos del departamento empiezan con 04.
DEPARTAMENTO = "04"

# Sólo compite quien está en carrera. Una renuncia, exclusión, tacha o
# candidatura improcedente llega sin nombre y no debe figurar en el ranking.
ESTADO_EN_CARRERA = "INSCRITO"


class Ambito(NamedTuple):
    """Un nivel de elección y de dónde sale su oferta electoral."""

    carpeta: str  # subcarpeta del crawler
    cargo: str  # cargo que encabeza la lista del acta
    nivel: str  # nombre del nivel en la base (district|provincial|regional)
    modelo: type


NIVELES = (
    Ambito("regional", "GOBERNADOR", "regional", RegionalCandidate),
    Ambito("provincial", "ALCALDE_PROVINCIAL", "provincial", ProvincialCandidate),
    Ambito("distrital", "ALCALDE_DISTRITAL", "district", DistrictCandidate),
)

# Color estable por organización: el mismo partido se ve igual en los 68
# ámbitos donde compite (antes el color dependía del orden de inserción).
PALETA = ["#002B66", "#0056B3", "#D97706", "#10B981", "#8B5CF6", "#EC4899",
          "#DC2626", "#0D9488", "#7C3AED", "#CA8A04"]

# Ubigeo con el que se migran las filas anteriores a la dimensión territorial.
# El prototipo sólo llegó a cargar Paucarpata y sus ámbitos superiores.
LEGADO = {"district": "040112", "provincial": "040100", "regional": "040000"}


def slugify(texto: str) -> str:
    """Misma convención de nombre de archivo que usa el crawler."""
    limpio = re.sub(r"[^A-Za-z0-9]+", "_", texto or "").strip("_").lower()
    return limpio[:60] or "organizacion"


def color_de(partido: str) -> str:
    """Color determinista derivado del nombre de la organización."""
    digest = hashlib.sha1((partido or "").encode("utf-8")).hexdigest()
    return PALETA[int(digest, 16) % len(PALETA)]


def nombre_de(candidato: dict) -> str:
    """Nombre completo, tolerando el campo vacío del JNE."""
    completo = (candidato.get("nombre_completo") or "").strip()
    if completo:
        return completo
    partes = (candidato.get("nombres"), candidato.get("apellidoPaterno"),
              candidato.get("apellidoMaterno"))
    return " ".join(p.strip() for p in partes if p and p.strip())


def _buscar_logo(partido: str, logo_local: str | None) -> str | None:
    """Archivo local del logo de la organización, si el crawler lo descargó.

    El JSON sólo trae ``logo_local`` en algunos ámbitos, así que se cae al
    nombre convencional ``partido_<slug>.<ext>``. Si no aparece, se usará la
    URL remota del JNE.
    """
    partidos_dir = MEDIA_DIR / "partidos"
    if logo_local and (partidos_dir / logo_local).exists():
        return logo_local
    slug = slugify(partido)
    for ext in (".png", ".jpg", ".jpeg"):
        candidato = f"partido_{slug}{ext}"
        if (partidos_dir / candidato).exists():
            return candidato
    return None


def leer_ambitos(solo: set[str] | None = None) -> tuple[list[dict], Counter]:
    """Construye las filas a publicar y las incidencias encontradas.

    No toca la base ni el disco: sólo lee los JSON del crawler.
    """
    filas: list[dict] = []
    incidencias: Counter = Counter()
    ambitos_vistos: set[str] = set()

    for nivel in NIVELES:
        carpeta = DATA_DIR / nivel.carpeta
        if not carpeta.exists():
            logger.warning("No existe %s; se omite el nivel %s", carpeta, nivel.nivel)
            continue

        for archivo in sorted(carpeta.glob("*.json")):
            data = json.loads(archivo.read_text(encoding="utf-8"))
            ubigeo = str(data.get("ubigeo") or archivo.stem).strip()
            if len(ubigeo) != 6 or not ubigeo.isdigit():
                incidencias[f"{nivel.nivel}: ubigeo inválido"] += 1
                logger.warning("Ubigeo inválido %r en %s", ubigeo, archivo.name)
                continue
            if not ubigeo.startswith(DEPARTAMENTO):
                incidencias[f"{nivel.nivel}: fuera de Arequipa"] += 1
                logger.warning("Ubigeo %s no es de Arequipa (%s)", ubigeo, archivo.name)
                continue
            if solo and ubigeo not in solo:
                continue

            ambitos_vistos.add(f"{nivel.nivel}:{ubigeo}")
            organizaciones = data.get("organizaciones") or []
            if organizaciones and not esta_ordenada(organizaciones):
                # El índice de este arreglo es la posición en el acta, y la PWA
                # lee el mismo archivo: si el crawler lo reescribió en orden
                # alfabético hay que reordenarlo en disco con
                # ``python tools/ordenar_cedula.py`` para que la base y el
                # formulario móvil numeren igual. Aquí se ordena igual, para no
                # dejar la base desordenada mientras tanto.
                logger.warning(
                    "Oferta de %s no viene en orden de cédula; reordenando en "
                    "memoria (ejecutar python tools/ordenar_cedula.py)", ubigeo,
                )
                ordenar_organizaciones(organizaciones)
            # Posición en la columna del acta impresa, empezando en 1 (así lo
            # exige el contrato: ``numero`` con "minimum: 1" en
            # docs/schemas/plantilla-acta-v1.schema.json). La ONPE compacta la
            # cédula cuando el JNE retira una candidatura —"su posición será
            # ocupada por la organización política siguiente, evitando espacios
            # vacíos"— así que la columna no tiene huecos: se numera sólo lo que
            # entra en carrera, y el acta digital coincide casita por casita con
            # el papel que tiene delante el digitador.
            posicion = 1
            for org in organizaciones:
                partido = (org.get("organizacionPolitica") or "").strip()
                if not partido:
                    incidencias[f"{nivel.nivel}: organización sin nombre"] += 1
                    continue

                del_cargo = [
                    c for c in (org.get("candidatos") or [])
                    if (c.get("cargo") or "").upper() == nivel.cargo
                ]
                elegido = next(
                    (
                        c for c in del_cargo
                        if (c.get("estado") or "").upper() == ESTADO_EN_CARRERA
                        and nombre_de(c)
                    ),
                    None,
                )
                if elegido is None:
                    estado = (del_cargo[0].get("estado") if del_cargo else "SIN CARGO")
                    incidencias[f"{nivel.nivel}: {estado}"] += 1
                    logger.info(
                        "Omitiendo %s - %s: sin candidato a %s en carrera (%s)",
                        ubigeo, partido, nivel.cargo, estado,
                    )
                    continue

                foto_local = (elegido.get("foto_local") or "").strip()
                foto_archivo = (
                    foto_local if (MEDIA_DIR / "candidatos" / foto_local).exists() else None
                )
                logo_archivo = _buscar_logo(partido, org.get("logo_local"))
                logo_remoto = (org.get("logo_url") or "").strip() or None

                filas.append({
                    "nivel": nivel.nivel,
                    "modelo": nivel.modelo,
                    "ubigeo": ubigeo,
                    "party": partido,
                    # sort_order = casita del acta (1..N, sin huecos)
                    "sort_order": posicion,
                    "name": nombre_de(elegido),
                    "color": color_de(partido),
                    "symbol": (f"{STORAGE_URL}/partidos/{logo_archivo}"
                               if logo_archivo else logo_remoto),
                    "photo_url": (f"{STORAGE_URL}/candidatos/{foto_archivo}"
                                  if foto_archivo else None),
                    "_logo": logo_archivo,
                    "_foto": foto_archivo,
                })
                posicion += 1

    incidencias["ámbitos"] = len(ambitos_vistos)
    return filas, incidencias


def copiar_media(filas: list[dict], dry_run: bool) -> Counter:
    """Copia a backend/storage las fotos y logos que referencia la carga."""
    resumen: Counter = Counter()
    for fila in filas:
        for sub, nombre in (("partidos", fila["_logo"]), ("candidatos", fila["_foto"])):
            if not nombre:
                resumen["sin medio"] += 1
                continue
            destino = STORAGE_DIR / sub / nombre
            if destino.exists():
                resumen["ya en storage"] += 1
                continue
            origen = MEDIA_DIR / sub / nombre
            if not origen.exists():
                resumen["falta en el crawler"] += 1
                continue
            if dry_run:
                resumen["se copiaría"] += 1
                continue
            destino.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(origen, destino)
            resumen["copiados"] += 1
    return resumen


def asegurar_esquema(db: Session, dry_run: bool) -> None:
    """Crea las tablas y añade ``ubigeo`` a las que vienen de antes.

    ``create_all`` no altera tablas existentes, así que la columna se agrega a
    mano. Las filas anteriores quedan con el ubigeo del único ámbito que el
    prototipo llegó a cargar, para que el upsert las reconozca por
    ``(ubigeo, party)`` en vez de borrarlas y perder sus votos.
    """
    if not dry_run:
        Base.metadata.create_all(bind=engine)
    inspector = inspect(engine)
    existentes = set(inspector.get_table_names())

    for nivel in NIVELES:
        tabla = nivel.modelo.__tablename__
        if tabla not in existentes:
            if dry_run:
                logger.info("[dry-run] Crearía la tabla %s ya con ubigeo", tabla)
                continue
            Base.metadata.create_all(bind=engine, tables=[nivel.modelo.__table__])
            existentes.add(tabla)
        if "ubigeo" in {c["name"] for c in inspector.get_columns(tabla)}:
            continue
        ubigeo_legado = LEGADO[nivel.nivel]
        if dry_run:
            logger.info("[dry-run] Añadiría ubigeo a %s (legado -> %s)", tabla, ubigeo_legado)
            continue
        db.execute(text(f"ALTER TABLE {tabla} ADD COLUMN ubigeo VARCHAR(6) DEFAULT ''"))
        db.execute(text(
            f"CREATE INDEX IF NOT EXISTS ix_{tabla}_ubigeo ON {tabla} (ubigeo)"
        ))
        resultado = db.execute(
            text(f"UPDATE {tabla} SET ubigeo = :u WHERE ubigeo IS NULL OR ubigeo = ''"),
            {"u": ubigeo_legado},
        )
        logger.info(
            "Añadida la dimensión territorial a %s: %s filas legadas -> ubigeo %s",
            tabla, resultado.rowcount, ubigeo_legado,
        )
    db.commit()


def cargar(db: Session, filas: list[dict]) -> Counter:
    """Inserta/actualiza filas y retira las que ya no existen en el JNE."""
    resumen: Counter = Counter()
    por_modelo: dict[type, list[dict]] = {}
    for fila in filas:
        por_modelo.setdefault(fila["modelo"], []).append(fila)

    for modelo, destino in por_modelo.items():
        existentes = {
            (c.ubigeo or "", c.party or ""): c for c in db.query(modelo).all()
        }
        objetivo = {(f["ubigeo"], f["party"]) for f in destino}

        for fila in destino:
            actual = existentes.get((fila["ubigeo"], fila["party"]))
            if actual is None:
                db.add(modelo(
                    name=fila["name"], party=fila["party"], ubigeo=fila["ubigeo"],
                    color=fila["color"], symbol=fila["symbol"],
                    photo_url=fila["photo_url"], sort_order=fila["sort_order"],
                ))
                resumen["insertadas"] += 1
            else:
                actual.name = fila["name"]
                actual.color = fila["color"]
                actual.symbol = fila["symbol"]
                actual.photo_url = fila["photo_url"]
                actual.sort_order = fila["sort_order"]
                resumen["actualizadas"] += 1

        # Las filas que el JNE ya no publica salen del ranking; sus votos se
        # retiran también para no dejar registros huérfanos apuntando a un
        # candidato inexistente.
        obsoletas = [c for clave, c in existentes.items() if clave not in objetivo]
        if obsoletas:
            ids = [c.id for c in obsoletas]
            tipo = next(n.nivel for n in NIVELES if n.modelo is modelo)
            borrados = (
                db.query(Record)
                .filter(Record.candidate_type == tipo, Record.candidate_id.in_(ids))
                .delete(synchronize_session=False)
            )
            db.query(modelo).filter(modelo.id.in_(ids)).delete(synchronize_session=False)
            resumen["eliminadas"] += len(obsoletas)
            resumen["votos retirados"] += borrados
            logger.warning(
                "Retiradas %s organizaciones de %s que el JNE ya no publica (%s votos)",
                len(obsoletas), modelo.__tablename__, borrados,
            )

    db.commit()
    return resumen


def verificar(db: Session) -> Counter:
    """Comprueba la integridad de lo cargado y de los votos ya existentes."""
    informe: Counter = Counter()
    for nivel in NIVELES:
        modelo = nivel.modelo
        filas = db.query(modelo).all()
        informe[f"{nivel.nivel}: filas"] = len(filas)
        informe[f"{nivel.nivel}: ámbitos"] = len({c.ubigeo for c in filas})
        sin_ubigeo = [c for c in filas if not (c.ubigeo or "").strip()]
        informe[f"{nivel.nivel}: sin ubigeo"] = len(sin_ubigeo)
        duplicados = [
            clave for clave, n in
            Counter((c.ubigeo, c.party) for c in filas).items() if n > 1
        ]
        informe[f"{nivel.nivel}: (ubigeo,partido) duplicado"] = len(duplicados)
        # sort_order debe ser único dentro del ámbito: es la llave con la que
        # los endpoints de edición vuelven a mapear los votos.
        colisiones = [
            clave for clave, n in
            Counter((c.ubigeo, c.sort_order) for c in filas).items() if n > 1
        ]
        informe[f"{nivel.nivel}: sort_order colisionado"] = len(colisiones)
        if duplicados:
            logger.error("Duplicados en %s: %s", modelo.__tablename__, duplicados[:5])
        if colisiones:
            logger.error("sort_order colisionado en %s: %s", modelo.__tablename__, colisiones[:5])

    # Ningún voto puede quedar apuntando a un candidato que no existe.
    modelos = {n.nivel: n.modelo for n in NIVELES}
    huerfanos = 0
    for record in db.query(Record).all():
        modelo = modelos.get(record.candidate_type)
        if modelo is None:
            continue
        if db.query(modelo).filter(modelo.id == record.candidate_id).first() is None:
            huerfanos += 1
            logger.error(
                "Voto huérfano: mesa %s, %s, candidate_id %s",
                record.table_id, record.candidate_type, record.candidate_id,
            )
    informe["votos huérfanos"] = huerfanos
    return informe


def main() -> None:
    parser = argparse.ArgumentParser(description="Carga los candidatos reales del JNE.")
    parser.add_argument("--dry-run", action="store_true",
                        help="informa lo que haría sin escribir en la base ni copiar archivos")
    parser.add_argument("--solo", action="append", default=None, metavar="UBIGEO",
                        help="cargar sólo estos ubigeos (repetible)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    solo = set(args.solo) if args.solo else None

    filas, incidencias = leer_ambitos(solo)
    por_nivel = Counter(f["nivel"] for f in filas)
    logger.info(
        "Leídos %s ámbitos: %s filas (%s)",
        incidencias["ámbitos"], len(filas),
        ", ".join(f"{n}: {por_nivel[n]}" for n in ("regional", "provincial", "district")),
    )
    for motivo, cantidad in sorted(incidencias.items()):
        if motivo != "ámbitos" and cantidad:
            logger.info("Incidencia — %s: %s", motivo, cantidad)

    medios = copiar_media(filas, args.dry_run)
    logger.info("Medios: %s", dict(medios))

    db = SessionLocal()
    try:
        asegurar_esquema(db, args.dry_run)
        if args.dry_run:
            logger.info("[dry-run] No se escribió nada en la base.")
            return
        resumen = cargar(db, filas)
        logger.info("Base actualizada: %s", dict(resumen))
        informe = verificar(db)
        for clave in sorted(informe):
            logger.info("Verificación — %s: %s", clave, informe[clave])
    finally:
        db.close()


if __name__ == "__main__":
    main()
