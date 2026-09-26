"""Actualización de la base de datos del cómputo electoral.

Ejecuta, EN ORDEN y de forma IDEMPOTENTE (se puede repetir sin romper nada):

  1. Esquema        — create_all del ORM + migraciones SQL idempotentes
                      (columnas/índices nuevos; nunca borra datos).
  2. Territorio     — catálogo de provincias/distritos (seed_arequipa).
  3. Oferta JNE     — candidatos por ubigeo (load_jne_data, incl. consejeros
                      de las 8 provincias) y fotos/logos a storage.
  4. Padrón ONPE    — locales de votación y mesas del Excel oficial
                      (seed_padron_real; NO toca actas registradas).
  5. Verificación   — conteos por tabla y resumen final.

Uso (desde backend/):
    python -m actualizar_bd                # actualización completa
    python -m actualizar_bd --dry-run      # muestra lo que haría, sin escribir
    python -m actualizar_bd --sin-padron   # salta el paso 4 (rápido)

Requiere que `backend/.env` apunte DATABASE_URL a la base del servidor.
"""
from __future__ import annotations

import argparse
import logging
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import inspect, text

from app.core.database import Base, SessionLocal, engine

logger = logging.getLogger("actualizar_bd")

BACKEND = Path(__file__).resolve().parent
SQL_DIR = BACKEND / "sql"

# Migraciones SQL idempotentes, en orden de dependencia. Cada script usa
# IF NOT EXISTS / ON CONFLICT donde aplica; repetirlos es seguro.
# (seed_auth_arequipa.sql queda fuera: crea la base desde cero y reinserta
#  el admin sin la columna activo; la migración de jerarquía ya siembra
#  usuarios demo compatibles con el esquema vivo.)
MIGRACIONES_SQL = [
    "schema_arequipa.sql",
    "modulo_campo_arequipa.sql",
    "migracion_digitador_global.sql",
]
# Segunda pasada: protege con RLS tablas creadas por módulos posteriores
# (incidencias_campo del módulo de campo) y re-aplica las vistas que
# dependían de columnas recién agregadas. Repetir es seguro.
MIGRACIONES_SEGUNDA = [
    "migracion_jerarquia_completa.sql",
]


def paso_esquema(dry_run: bool) -> None:
    """Crea tablas nuevas del ORM y aplica las migraciones SQL."""
    logger.info("[1/5] Esquema: create_all + migraciones SQL idempotentes")
    if not dry_run:
        Base.metadata.create_all(bind=engine)

    inspector = inspect(engine)
    tablas = set(inspector.get_table_names())

    # Migraciones de columnas sueltas que create_all no agrega a tablas ya
    # existentes (misma técnica que usa load_jne_data.asegurar_esquema).
    columnas_nuevas = {
        "acta_metadata": {
            # Votantes que sufragaron (cabecera del acta); regla de cuadre.
            "total_votantes": "INTEGER",
        },
        "consejero_candidates": {
            # Por si el despliegue viene de una base anterior al nivel.
            "sort_order": "INTEGER DEFAULT 0",
        },
    }
    for tabla, columnas in columnas_nuevas.items():
        if tabla not in tablas:
            continue  # la crea create_all completa
        presentes = {c["name"] for c in inspector.get_columns(tabla)}
        for columna, tipo in columnas.items():
            if columna not in presentes:
                if dry_run:
                    logger.info("  [dry-run] ALTER TABLE %s ADD COLUMN %s %s", tabla, columna, tipo)
                    continue
                with engine.begin() as conn:
                    conn.execute(text(
                        f"ALTER TABLE {tabla} ADD COLUMN IF NOT EXISTS {columna} {tipo}"
                    ))
                logger.info("  columna %s.%s agregada (%s)", tabla, columna, tipo)

    # Constraint que la migración de jerarquía asume en asignacion_personeros
    # (ON CONFLICT (usuario_id, mesa_id, tipo)); el ORM no la declara.
    # PostgreSQL no acepta ADD CONSTRAINT IF NOT EXISTS: se consulta el
    # catálogo y se agrega sólo si falta.
    if not dry_run and "asignacion_personeros" in tablas:
        with engine.begin() as conn:
            existe = conn.execute(text(
                "SELECT 1 FROM pg_constraint "
                "WHERE conname = 'uq_personero_mesa_rol'"
            )).scalar()
            if not existe:
                conn.execute(text(
                    "ALTER TABLE asignacion_personeros "
                    "ADD CONSTRAINT uq_personero_mesa_rol "
                    "UNIQUE (usuario_id, mesa_id, tipo)"
                ))
                logger.info("  constraint uq_personero_mesa_rol agregada")

    for nombre in [*MIGRACIONES_SQL, *MIGRACIONES_SEGUNDA]:
        ruta = SQL_DIR / nombre
        if not ruta.exists():
            logger.warning("  migración %s no existe; se omite", nombre)
            continue
        if dry_run:
            logger.info("  [dry-run] aplicaría %s", nombre)
            continue
        sql = ruta.read_text(encoding="utf-8")
        if nombre not in ("migracion_digitador_global.sql",):
            # Los scripts con CREATE sin IF NOT EXISTS (schema) o con
            # dependencias entre módulos (jerarquía↔campo) corren sentencia a
            # sentencia en AUTOCOMMIT, tolerando "ya existe"/"no existe":
            # lo que ya está queda como está y el resto del archivo sí aplica.
            # schema_arequipa usa CREATE TABLE/INDEX sin IF NOT EXISTS y la
            # de jerarquía referencia tablas de módulos posteriores: ambas se
            # aplican sentencia a sentencia en AUTOCOMMIT, tolerando "ya
            # existe"/"no existe" (en la 2ª pasada las RLS sí encuentran todo).
            aplicadas = omitidas = 0
            crudo = engine.raw_connection()  # DBAPI directo, sin gestor de SA
            try:
                crudo.autocommit = True  # cada sentencia es su propia transacción
                cursor = crudo.cursor()
                for sentencia in _sentencias(sql):
                    try:
                        cursor.execute(sentencia)
                        aplicadas += 1
                    except Exception as exc:  # noqa: BLE001
                        crudo.rollback()
                        msg = str(exc)
                        if ("ya existe" in msg or "already exists" in msg
                                or "no existe" in msg or "does not exist" in msg):
                            omitidas += 1
                            continue
                        raise
                cursor.close()
            finally:
                crudo.close()
            logger.info(
                "  %s: %s aplicadas, %s omitidas (ya existentes/pendientes)",
                nombre, aplicadas, omitidas,
            )
        else:
            with engine.begin() as conn:
                conn.execute(text(sql))
            logger.info("  migración %s aplicada", nombre)


def _sentencias(sql: str) -> list[str]:
    """Divide un script SQL por ';', respetando comentarios y $$…$$ de PL/pgSQL."""
    partes: list[str] = []
    actual: list[str] = []
    en_dolar = False
    for linea in sql.splitlines():
        if not en_dolar and linea.lstrip().startswith("--"):
            continue
        actual.append(linea)
        if linea.count("$$") % 2 == 1:
            en_dolar = not en_dolar
        if not en_dolar and linea.rstrip().endswith(";"):
            sentencia = "\n".join(actual).strip()
            if sentencia and sentencia != ";":
                partes.append(sentencia)
            actual = []
    resto = "\n".join(actual).strip()
    if resto:
        partes.append(resto)
    return partes


def _correr_modulo(modulo: str, dry_run: bool, extra: list[str] | None = None) -> bool:
    """Ejecuta `python -m <modulo>` como subprocess, heredando el .env."""
    cmd = [sys.executable, "-m", modulo, *(extra or [])]
    if dry_run:
        logger.info("  [dry-run] ejecutaría: %s", " ".join(cmd))
        return True
    logger.info("  ejecutando: %s", " ".join(cmd))
    resultado = subprocess.run(cmd, cwd=BACKEND)
    if resultado.returncode != 0:
        logger.error("  %s falló con código %s", modulo, resultado.returncode)
        return False
    return True


def paso_territorio(dry_run: bool) -> bool:
    logger.info("[2/5] Territorio: catálogo de provincias y distritos")
    return _correr_modulo("app.seed_arequipa", dry_run)


def paso_oferta_jne(dry_run: bool) -> bool:
    logger.info("[3/5] Oferta JNE: candidatos por ubigeo (consejeros incluidos)")
    return _correr_modulo("app.load_jne_data", dry_run)


def paso_padron(dry_run: bool) -> bool:
    logger.info("[4/5] Padrón ONPE: locales y mesas del Excel oficial")
    # --reemplazar sincroniza locales/mesas con el padrón; es idempotente y
    # no borra actas registradas (lo garantiza el propio script).
    return _correr_modulo("app.seed_padron_real", dry_run, ["--reemplazar"])


def paso_verificacion() -> bool:
    logger.info("[5/5] Verificación de conteos")
    esperado = {
        "venues": "locales de votación",
        "tables": "mesas",
        "district_candidates": "candidatos distritales",
        "provincial_candidates": "candidatos provinciales",
        "consejero_candidates": "organizaciones de consejeros",
        "regional_candidates": "candidatos regionales",
        "usuarios": "usuarios",
    }
    inspector = inspect(engine)
    tablas = set(inspector.get_table_names())
    db = SessionLocal()
    faltas = 0
    try:
        for tabla, descripcion in esperado.items():
            if tabla not in tablas:
                logger.warning("  %-24s tabla inexistente", tabla)
                faltas += 1
                continue
            total = db.execute(text(f"SELECT COUNT(*) FROM {tabla}")).scalar_one()
            if total == 0:
                logger.warning("  %-24s VACÍO (%s)", tabla, descripcion)
                faltas += 1
            else:
                logger.info("  %-24s %s", tabla, f"{total:,}".replace(",", "."))
        actas = 0
        if "records" in tablas:
            actas = db.execute(
                text("SELECT COUNT(DISTINCT table_id) FROM records")
            ).scalar_one()
            logger.info("  %-24s %s", "actas con votos", f"{actas:,}".replace(",", "."))
    finally:
        db.close()
    return faltas == 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Actualiza esquema + catálogos + padrón de la base de datos.",
    )
    parser.add_argument("--dry-run", action="store_true",
                        help="muestra lo que haría sin escribir")
    parser.add_argument("--sin-padron", action="store_true",
                        help="salta la sincronización del padrón ONPE (paso 4)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    inicio = datetime.now(timezone.utc)
    logger.info("=== ACTUALIZACIÓN DE BASE DE DATOS — %s ===", inicio.strftime("%d/%m/%Y %H:%M"))

    ok = True
    paso_esquema(args.dry_run)
    ok = paso_territorio(args.dry_run) and ok
    ok = paso_oferta_jne(args.dry_run) and ok
    if not args.sin_padron:
        ok = paso_padron(args.dry_run) and ok
    else:
        logger.info("[4/5] Padrón omitido por --sin-padron")
    if not args.dry_run:
        ok = paso_verificacion() and ok
        duracion = (datetime.now(timezone.utc) - inicio).total_seconds()
        if ok:
            logger.info("✅ BASE ACTUALIZADA CORRECTAMENTE en %.1fs", duracion)
        else:
            logger.error("❌ ACTUALIZACIÓN CON PENDIENTES (revisar avisos arriba)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
