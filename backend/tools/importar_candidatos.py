#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Importador: JSON del crawler del JNE -> PostgreSQL (esquema computo_arequipa).

Carga la oferta electoral extraída por ``jne-scraper/crawler_arequipa.py`` en las
tablas ``organizaciones_politicas`` y ``candidatos`` del esquema de producción.

Reejecutable (idempotente)
--------------------------
* ``organizaciones_politicas`` se resuelve por ``id_jne`` (el id del JNE), con
  el nombre como respaldo; se hace UPDATE de logo/nombre/tipo si cambiaron.
* ``candidatos`` se resuelve por la llave de negocio
  ``(organizacion_id, ubigeo, cargo, numero_lista)``: si existe se hace UPDATE
  de dni/nombres/foto/estado (cambios oficiales entre corridas), si no INSERT.
* El importador nunca borra: si el JNE retira una lista, el candidato queda con
  su ``estado`` actualizado, no eliminado. Los votos ya digitados conservan su
  referencia.

Modo dry-run
------------
``--dry-run`` ejecuta TODO el pipeline contra una transacción que termina en
ROLLBACK (sobre la base real, sin psycopg ``autocommit`` ni sesiones paralelas),
imprime el plan completo y no persiste nada. Sin ``--execute`` también es
dry-run: es el default, deliberadamente, para no escribir la base por accidente.

Requisitos previos
------------------
Esquema y seed de ubigeo cargados:
    psql -d computo_arequipa -f backend/sql/schema_arequipa.sql
    psql -d computo_arequipa -f backend/sql/seed_ubigeo_arequipa.sql

Uso
---
    # Ver qué haría, sin tocar la base (transacción revertida):
    python backend/tools/importar_candidatos.py --dry-run

    # Cargar los tres ámbitos ya crawleados:
    python backend/tools/importar_candidatos.py --execute

    # Sólo Paucarpata, con auto-correlación de códigos si el seed está viejo:
    python backend/tools/importar_candidatos.py --execute --archivo \
        jne-scraper/data/arequipa/distrital/040112.json

    # Cualquier combinación, con otra conexión:
    python backend/tools/importar_candidatos.py --execute \
        --dsn "host=127.0.0.1 port=5432 dbname=computo_arequipa user=postgres"
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Sequence

import psycopg2

# ---------------------------------------------------------------------------
# Constantes del dominio
# ---------------------------------------------------------------------------

RAIZ = Path(__file__).resolve().parents[2]          # ...\alcaldia
DIR_DATOS = RAIZ / "jne-scraper" / "data" / "arequipa"

DSN_DEFAULT = os.environ.get(
    "COMPUTO_AREQUIPA_DSN",
    "host=127.0.0.1 port=55433 dbname=computo_arequipa user=postgres",
)

# Estados del JSON del crawler -> enum estado_candidato de la base. Todo lo que
# no esté aquí es un ERROR (el JNE inventó un estado nuevo: mejor fallar).
#
# Ojo con los dos últimos, que aparecieron al recorrer los 110 ámbitos reales:
#   * TACHADO      — la candidatura fue tachada (Ley 26859). Sale de la carrera
#                    igual que una exclusión, y las filas SÍ traen el nombre del
#                    candidato: descartarlas perdería el dato.
#   * IMPROCEDENTE — la candidatura no fue admitida. Las filas llegan sin
#                    nombre ni datos, así que además caen en `filas_sin_nombre`.
# Ambos se mapean a EXCLUIDO para no tocar el enum `estado_candidato` del
# esquema (6 valores), pero conservando el estado real en la columna, que es lo
# que exige la política del importador: el candidato se actualiza, no se borra.
MAPA_ESTADO = {
    "INSCRITO": "INSCRITO",
    "RENUNCIA": "RENUNCIA",
    "EXCLUIDO": "EXCLUIDO",
    "EXCLUSION": "EXCLUIDO",     # variante que trae la API del JNE
    "TACHADO": "EXCLUIDO",       # tacha resuelta por el JEE
    "IMPROCEDENTE": "EXCLUIDO",  # candidatura no admitida
    "FALLECIDO": "FALLECIDO",
    "SUSPENDIDO": "SUSPENDIDO",
    "RETIRADO": "RETIRADO",
    "RETIRO": "RETIRADO",        # variante que trae la API del JNE
}

# La codificación RENIEC (la que responde la API del JNE) puede no coincidir con
# la INEI del seed. La base guarda ambas columnas, así que el importador acepta
# cualquiera de las dos como llave de búsqueda.
SQL_UBIGEO = """
    SELECT ubigeo, ubigeo_reniec
      FROM ubigeo
     WHERE ubigeo = %s OR ubigeo_reniec = %s
"""

SQL_ORG_POR_ID_JNE = """
    SELECT id, nombre, tipo, id_jne, logo_url, color_hex
      FROM organizaciones_politicas
     WHERE id_jne = %s
"""

SQL_ORG_POR_NOMBRE = """
    SELECT id, nombre, tipo, id_jne, logo_url, color_hex
      FROM organizaciones_politicas
     WHERE lower(nombre) = lower(%s)
"""

SQL_INSERT_ORG = """
    INSERT INTO organizaciones_politicas (nombre, tipo, id_jne, logo_url)
    VALUES (%s, %s, %s, %s)
    RETURNING id, nombre, tipo, id_jne, logo_url, color_hex
"""

SQL_UPDATE_ORG = """
    UPDATE organizaciones_politicas
       SET nombre = %s, tipo = %s, logo_url = %s, updated_at = now()
     WHERE id = %s
"""

SQL_CAND_EXISTE = """
    SELECT id, dni, nombres, apellidos, nombre_completo, foto_url, estado
      FROM candidatos
     WHERE organizacion_id = %s AND ubigeo = %s AND cargo = %s AND numero_lista = %s
"""

SQL_INSERT_CAND = """
    INSERT INTO candidatos (organizacion_id, ubigeo, tipo_eleccion, cargo,
                            numero_lista, dni, nombres, apellidos,
                            nombre_completo, foto_url, estado)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    RETURNING id
"""

SQL_UPDATE_CAND = """
    UPDATE candidatos
       SET dni = %s, nombres = %s, apellidos = %s, nombre_completo = %s,
           foto_url = %s, estado = %s, updated_at = now()
     WHERE id = %s
"""

RE_DNI = re.compile(r"^\d{8}$")
RE_UBIGEO = re.compile(r"^\d{6}$")

# El JSON del JNE dice "MUNICIPAL PROVINCIAL"/"MUNICIPAL DISTRITAL"; el enum de
# la base es REGIONAL/PROVINCIAL/DISTRITAL.
NORMALIZAR_TIPO = {
    "REGIONAL": "REGIONAL",
    "MUNICIPAL REGIONAL": "REGIONAL",
    "MUNICIPAL PROVINCIAL": "PROVINCIAL",
    "MUNICIPAL DISTRITAL": "DISTRITAL",
    "PROVINCIAL": "PROVINCIAL",
    "DISTRITAL": "DISTRITAL",
}

# Palabras que delatan un partido nacional aunque el JNE no lo etiquete.
PALABRAS_PARTIDO = (
    "PARTIDO", "FRENTE", "ALIANZA PARA EL PROGRESO",
)


@dataclass
class Stats:
    """Contadores del corrimiento, para el resumen final."""

    archivos: int = 0
    organizaciones_nuevas: int = 0
    organizaciones_actualizadas: int = 0
    organizaciones_sin_cambio: int = 0
    candidatos_nuevos: int = 0
    candidatos_actualizados: int = 0
    candidatos_sin_cambio: int = 0
    candidatos_no_inscritos: int = 0
    filas_sin_nombre: int = 0
    errores: list[str] = field(default_factory=list)

    def como_texto(self) -> str:
        lineas = [
            f"archivos leídos            : {self.archivos}",
            f"organizaciones nuevas      : {self.organizaciones_nuevas}",
            f"organizaciones actualizadas: {self.organizaciones_actualizadas}",
            f"organizaciones sin cambio  : {self.organizaciones_sin_cambio}",
            f"candidatos nuevos          : {self.candidatos_nuevos}",
            f"candidatos actualizados    : {self.candidatos_actualizados}",
            f"candidatos sin cambio      : {self.candidatos_sin_cambio}",
            f"candidatos no inscritos    : {self.candidatos_no_inscritos} (guardados con su estado)",
            f"filas sin nombre (omitidas): {self.filas_sin_nombre} (renuncias sin datos en el JSON)",
        ]
        if self.errores:
            lineas.append(f"ERRORES ({len(self.errores)}):")
            lineas += [f"  - {e}" for e in self.errores]
        return "\n".join(lineas)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def log(msg: str) -> None:
    print(msg, flush=True)


def limpiar(valor: Any) -> str | None:
    """None si viene vacío; texto recortado si no."""
    if valor is None:
        return None
    texto = str(valor).strip()
    return texto or None


def clasificar_tipo_org(nombre: str) -> str:
    """PARTIDO_NACIONAL si el nombre lo delata; si no, MOVIMIENTO_REGIONAL."""
    nombre_up = nombre.upper()
    for palabra in PALABRAS_PARTIDO:
        if palabra in nombre_up:
            return "PARTIDO_NACIONAL"
    return "MOVIMIENTO_REGIONAL"


def cargo_valido(cargo: str, tipo_eleccion: str) -> bool:
    """Chequeo temprano del CHECK candidatos_cargo_coherente, para fallar con
    un mensaje claro y no con un error crudo de la base."""
    pares = {
        "REGIONAL": {"GOBERNADOR", "VICE_GOBERNADOR", "CONSEJERO_REGIONAL"},
        "PROVINCIAL": {"ALCALDE_PROVINCIAL", "REGIDOR_PROVINCIAL"},
        "DISTRITAL": {"ALCALDE_DISTRITAL", "REGIDOR_DISTRITAL"},
    }
    return cargo in pares.get(tipo_eleccion, set())


# ---------------------------------------------------------------------------
# Importador
# ---------------------------------------------------------------------------

class ImportadorJNE:
    """Carga los JSON del crawler a PostgreSQL, idempotente y con dry-run."""

    def __init__(self, dsn: str, execute: bool):
        self.dsn = dsn
        self.execute = execute
        self.stats = Stats()
        self._conn: psycopg2.extensions.connection | None = None

    # -- conexión -----------------------------------------------------------

    def conectar(self) -> None:
        self._conn = psycopg2.connect(self.dsn)
        self._conn.set_session(readonly=False, autocommit=False)

    def cerrar(self) -> None:
        if self._conn is not None:
            self._conn.close()
            self._conn = None

    # -- ayuda sobre la transacción ------------------------------------------

    def _finalizar(self, ctx: str) -> None:
        """En modo execute: COMMIT. En dry-run: ROLLBACK (no ensucia nada)."""
        if self.execute:
            self._conn.commit()
        else:
            self._conn.rollback()
            log(f"  (dry-run: transacción revertida — {ctx})")

    # -- ubigeo ---------------------------------------------------------------

    def _resolver_ubigeo(self, cur, ubigeo_json: str, codigos_jne: dict) -> str:
        """Devuelve el ubigeo INEI canónico del ámbito.

        La API del JNE habla RENIEC; la base guarda ambas codificaciones, así
        que se busca por cualquiera de las dos. Para el ámbito REGIONAL el JSON
        no aporta código RENIEC útil (sus partes dep/pro/dis son de 2 dígitos
        y a nivel departamento son '00'), así que sólo se usa 040000.
        """
        e_inei = limpiar(ubigeo_json)
        if not e_inei or not RE_UBIGEO.fullmatch(e_inei):
            raise ValueError(f"ubigeo raíz del JSON inválido: {e_inei!r}")

        # El ubigeo raíz del JSON SIEMPRE es INEI (040000, 040100, 040112...).
        cur.execute("SELECT ubigeo, ubigeo_reniec FROM ubigeo WHERE ubigeo = %s", (e_inei,))
        fila = cur.fetchone()
        if fila is None:
            raise ValueError(
                f"el ubigeo {e_inei} no existe en la tabla ubigeo; "
                "recarga seed_ubigeo_arequipa.sql"
            )
        return (fila[0] or "").strip()

    # -- organizaciones --------------------------------------------------------

    # -- organizaciones --------------------------------------------------------

    def _resolver_organizacion(self, cur, org_json: dict) -> tuple[int, bool]:
        """Devuelve (id, creado). Resuelve por id_jne; respaldo por nombre."""
        id_jne = org_json.get("idOrganizacionPolitica")
        nombre = limpiar(org_json.get("organizacionPolitica"))
        logo = limpiar(org_json.get("logo_url"))
        if not nombre:
            raise ValueError("organización sin nombre en el JSON")

        fila = None
        if id_jne is not None:
            cur.execute(SQL_ORG_POR_ID_JNE, (int(id_jne),))
            fila = cur.fetchone()
        if fila is None:
            cur.execute(SQL_ORG_POR_NOMBRE, (nombre,))
            fila = cur.fetchone()

        if fila is None:
            tipo = clasificar_tipo_org(nombre)
            cur.execute(SQL_INSERT_ORG, (nombre, tipo, id_jne, logo))
            nueva = cur.fetchone()
            self.stats.organizaciones_nuevas += 1
            log(f"    + org [{nueva[0]}] {nombre} ({tipo})")
            return nueva[0], True

        org_id, nombre_bd, tipo_bd, _idjne, logo_bd, _color = fila
        nombre_bd = (nombre_bd or "").strip()
        logo_bd = (logo_bd or "").strip() or None

        cambios: list[str] = []
        if nombre_bd != nombre:
            cambios.append(nombre)
        if logo != logo_bd:
            cambios.append(logo)
        # El tipo no se toca si ya está bien clasificado en la base.
        if cambios:
            cur.execute(SQL_UPDATE_ORG, (nombre, tipo_bd, logo, org_id))
            self.stats.organizaciones_actualizadas += 1
            log(f"    ~ org [{org_id}] {nombre}: actualizada")
        else:
            self.stats.organizaciones_sin_cambio += 1
        return org_id, False

    # -- candidatos -------------------------------------------------------------

    def _procesar_candidatos(
        self,
        cur,
        org_id: int,
        ambito: dict,
        candidatos_json: list[dict],
    ) -> None:
        tipo_eleccion: str = ambito["tipoEleccion"]
        ubigeo: str = ambito["ubigeo_bd"]

        for c in candidatos_json:
            estado_raw = (limpiar(c.get("estado")) or "INSCRITO").upper()
            if estado_raw not in MAPA_ESTADO:
                self.stats.errores.append(
                    f"[{ambito['archivo'].name}] estado desconocido "
                    f"'{estado_raw}' en {c.get('nombre_completo')!r}: fila omitida"
                )
                continue
            estado = MAPA_ESTADO[estado_raw]

            cargo = limpiar(c.get("cargo")) or ""
            if not cargo_valido(cargo, tipo_eleccion):
                self.stats.errores.append(
                    f"[{ambito['archivo'].name}] cargo '{cargo}' incoherente con "
                    f"{tipo_eleccion}: {c.get('nombre_completo')!r} omitido"
                )
                continue

            dni = limpiar(c.get("dni"))
            if dni and not RE_DNI.fullmatch(dni):
                self.stats.errores.append(
                    f"[{ambito['archivo'].name}] DNI inválido {dni!r} en "
                    f"{c.get('nombre_completo')!r}: se guarda como NULL"
                )
                dni = None

            # Posición en la lista. El JSON trae dos campos y NO son
            # equivalentes:
            #   * numero_posicion: reinicia dentro de cada circunscripción
            #     electoral (los consejeros regionales se eligen POR PROVINCIA,
            #     y el JSON no indica a cuál pertenece cada fila), así que se
            #     REPITE: usarlo como llave pisaría candidatos distintos.
            #   * posicion: orden de fila del JNE, único por (org, cargo) en
            #     los tres ámbitos. Es el que puede servir de numero_lista.
            # Queda pendiente de fuente oficial el mapeo fila->provincia de los
            # consejeros; hasta entonces no hay data inventada.
            numero = c.get("posicion")
            if not isinstance(numero, int) or numero < 1:
                self.stats.errores.append(
                    f"[{ambito['archivo'].name}] sin posición de lista válida: "
                    f"{c.get('nombre_completo')!r} omitido"
                )
                continue

            nombres = limpiar(c.get("nombres")) or ""
            apellidos = " ".join(
                p for p in (limpiar(c.get("apellidoPaterno")), limpiar(c.get("apellidoMaterno"))) if p
            )
            nombre_completo = limpiar(c.get("nombre_completo")) or f"{nombres} {apellidos}".strip()
            if not nombre_completo:
                # Filas de renuncia sin datos en el JSON del JNE: no hay nada
                # que insertar y no es un fallo del importador.
                self.stats.filas_sin_nombre += 1
                continue

            foto = limpiar(c.get("foto_url"))
            cur.execute(SQL_CAND_EXISTE, (org_id, ubigeo, cargo, numero))
            existente = cur.fetchone()

            if existente is None:
                cur.execute(
                    SQL_INSERT_CAND,
                    (org_id, ubigeo, tipo_eleccion, cargo, numero,
                     dni, nombres, apellidos, nombre_completo, foto, estado),
                )
                nuevo_id = cur.fetchone()[0]
                self.stats.candidatos_nuevos += 1
                if estado != "INSCRITO":
                    self.stats.candidatos_no_inscritos += 1
                log(f"      + cand [{nuevo_id}] {numero:>2} {cargo:<20} {nombre_completo}")
            else:
                cand_id, dni_bd, nombres_bd, apellidos_bd, nombre_bd, foto_bd, estado_bd = existente
                same = (
                    (dni_bd or None) == (dni or None)
                    and (nombres_bd or "") == nombres
                    and (apellidos_bd or "") == apellidos
                    and (nombre_bd or "") == nombre_completo
                    and (foto_bd or None) == (foto or None)
                    and estado_bd == estado
                )
                if not same:
                    cur.execute(
                        SQL_UPDATE_CAND,
                        (dni, nombres, apellidos, nombre_completo, foto, estado, cand_id),
                    )
                    self.stats.candidatos_actualizados += 1
                    if estado != "INSCRITO" and estado_bd == "INSCRITO":
                        self.stats.candidatos_no_inscritos += 1
                    log(f"      ~ cand [{cand_id}] {numero:>2} {cargo:<20} {nombre_completo}")
                else:
                    self.stats.candidatos_sin_cambio += 1

    # -- archivos ----------------------------------------------------------------

    def _ambitos_a_procesar(self, archivos: Sequence[Path]) -> list[dict]:
        """Lee y valida los JSON; devuelve el plan completo antes de tocar la base."""
        ambitos = []
        for path in archivos:
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                self.stats.errores.append(f"no se pudo leer {path}: {exc}")
                continue

            if not data.get("organizaciones"):
                self.stats.errores.append(f"{path.name}: sin organizaciones, omitido")
                continue

            tipo = NORMALIZAR_TIPO.get((limpiar(data.get("tipoEleccion")) or "").upper())
            if tipo is None:
                self.stats.errores.append(
                    f"{path.name}: tipoEleccion '{data.get('tipoEleccion')}' desconocido, omitido"
                )
                continue

            ambitos.append(
                {
                    "archivo": path,
                    "data": data,
                    "ubigeo_json": limpiar(data.get("ubigeo")),
                    "codigos_jne": data.get("codigos_jne") or {},
                    "tipoEleccion": tipo,
                }
            )
        return ambitos

    def correr(self, archivos: Sequence[Path]) -> int:
        """Pipeline completo. Devuelve el código de salida del proceso."""
        ambitos = self._ambitos_a_procesar(archivos)
        if not ambitos:
            log("No hay archivos válidos que importar.")
            self._reporte()
            return 1 if self.stats.errores else 0

        modo = "EJECUCIÓN" if self.execute else "DRY-RUN"
        log(f"=== IMPORTADOR JNE -> PostgreSQL ({modo}) ===")
        log(f"archivos: {', '.join(a['archivo'].name for a in ambitos)}")

        # Costura para pruebas: si ya hay conexión inyectada, no se reconecta.
        if self._conn is None:
            try:
                self.conectar()
            except psycopg2.OperationalError as exc:
                log(f"ERROR de conexión: {exc}")
                log(f"DSN usado: {self.dsn}")
                return 2

        try:
            cur = self._conn.cursor()
            for ambito in ambitos:
                path = ambito["archivo"]
                self.stats.archivos += 1
                log(f"\n-- {path.name} ({ambito['tipoEleccion']}) --")

                cur.execute("SAVEPOINT sp_ambito")
                try:
                    ubigeo_bd = self._resolver_ubigeo(cur, ambito["ubigeo_json"], ambito["codigos_jne"])
                except (ValueError, psycopg2.Error) as exc:
                    cur.execute("ROLLBACK TO SAVEPOINT sp_ambito")
                    self.stats.errores.append(f"{path.name}: {exc}")
                    continue
                ambito["ubigeo_bd"] = ubigeo_bd
                log(f"   ámbito: {ambito['ubigeo_json']} -> {ubigeo_bd} (INEI canónico)")

                for org_json in ambito["data"]["organizaciones"]:
                    nombre_org = org_json.get("organizacionPolitica")
                    # SAVEPOINT por organización: si una falla (un dato que
                    # viola un CHECK, un enum desconocido), se deshace SÓLO esa
                    # organización y el resto del lote sigue. Un rollback de la
                    # transacción entera perdería todo lo ya importado.
                    cur.execute("SAVEPOINT sp_org")
                    try:
                        org_id, _ = self._resolver_organizacion(cur, org_json)
                        self._procesar_candidatos(cur, org_id, ambito, org_json.get("candidatos") or [])
                        cur.execute("RELEASE SAVEPOINT sp_org")
                    except (psycopg2.Error, ValueError) as exc:
                        self.stats.errores.append(
                            f"{path.name} / {nombre_org}: {str(exc).strip()[:300]}"
                        )
                        log(f"    ! ERROR en {nombre_org}: {exc}")
                        cur.execute("ROLLBACK TO SAVEPOINT sp_org")

            self._finalizar("fin del pipeline")
        finally:
            self.cerrar()

        self._reporte()
        return 1 if self.stats.errores else 0

    def _reporte(self) -> None:
        log("\n=== RESUMEN ===")
        log(self.stats.como_texto())
        if not self.execute and not self.stats.errores:
            log("\n(dry-run: nada se escribió; usa --execute para aplicar)")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Importa los JSON del crawler del JNE a PostgreSQL (organizaciones_politicas y candidatos).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--execute", action="store_true",
        help="aplica los cambios (COMMIT). Sin esto, dry-run con ROLLBACK.",
    )
    p.add_argument(
        "--dry-run", action="store_true",
        help="explícito: no escribe nada (es el default sin --execute).",
    )
    p.add_argument(
        "--archivo", action="append", default=[],
        metavar="RUTA_JSON",
        help="importa sólo este archivo JSON del crawler (repetible).",
    )
    p.add_argument(
        "--todos", action="store_true",
        help="importa todos los data/arequipa/<nivel>/<ubigeo>.json encontrados.",
    )
    p.add_argument(
        "--dsn", default=DSN_DEFAULT,
        help="cadena de conexión PostgreSQL (default: %(default)s)",
    )
    return p.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    execute = args.execute and not args.dry_run

    if args.archivo:
        archivos = [Path(a) for a in args.archivo]
    elif args.todos:
        candidatos = sorted(glob.glob(str(DIR_DATOS / "*" / "*.json")))
        archivos = [Path(p) for p in candidatos if not Path(p).name.startswith("_")]
    else:
        # Default sensato: los tres ámbitos que el crawler ya trae.
        archivos = [
            DIR_DATOS / "regional" / "040000.json",
            DIR_DATOS / "provincial" / "040100.json",
            DIR_DATOS / "distrital" / "040112.json",
        ]

    faltantes = [a for a in archivos if not a.is_file()]
    if faltantes:
        for a in faltantes:
            print(f"ERROR: no existe {a}", file=sys.stderr)
        return 2

    importador = ImportadorJNE(args.dsn, execute)
    return importador.correr(archivos)


if __name__ == "__main__":
    raise SystemExit(main())
