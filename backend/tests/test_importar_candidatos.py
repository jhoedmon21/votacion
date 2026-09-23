"""Pruebas del importador JNE -> PostgreSQL.

Se ejecutan sin pytest (no está instalado en este entorno):

    cd backend && python tests/test_importar_candidatos.py

Cubren dos niveles:

1. Unidades puras: normalización de tipo de elección, mapa de estados,
   clasificación de organizaciones, validación de cargo/DNI y una corrida
   completa contra un FAKE de la base (sin PostgreSQL).
2. Integración real (opcional): si hay un PostgreSQL con el esquema cargado,
   el importador corre contra una base TEMPORAL (computo_arequipa_test, que se
   crea y se destruye) para probar idempotencia de verdad, sin tocar la base
   principal.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

import importar_candidatos as imp  # noqa: E402


# ---------------------------------------------------------------------------
# 1. Unidades puras
# ---------------------------------------------------------------------------
class TestNormalizacion(unittest.TestCase):
    def test_tipos_de_eleccion_del_jne(self):
        self.assertEqual(imp.NORMALIZAR_TIPO["REGIONAL"], "REGIONAL")
        self.assertEqual(imp.NORMALIZAR_TIPO["MUNICIPAL PROVINCIAL"], "PROVINCIAL")
        self.assertEqual(imp.NORMALIZAR_TIPO["MUNICIPAL DISTRITAL"], "DISTRITAL")
        self.assertNotIn("REGIONAL LOCO", imp.NORMALIZAR_TIPO)

    def test_mapa_de_estados(self):
        self.assertEqual(imp.MAPA_ESTADO["INSCRITO"], "INSCRITO")
        # Variantes que trae la API del JNE
        self.assertEqual(imp.MAPA_ESTADO["EXCLUSION"], "EXCLUIDO")
        self.assertEqual(imp.MAPA_ESTADO["RETIRO"], "RETIRADO")
        # Estados que aparecieron al recorrer los 110 ámbitos reales: una tacha
        # y una candidatura no admitida salen de la carrera igual que una
        # exclusión, y sus filas traen datos que no se deben perder.
        self.assertEqual(imp.MAPA_ESTADO["TACHADO"], "EXCLUIDO")
        self.assertEqual(imp.MAPA_ESTADO["IMPROCEDENTE"], "EXCLUIDO")
        self.assertNotIn("ESTADO INVENTADO", imp.MAPA_ESTADO)

    def test_limpieza_de_valores(self):
        self.assertIsNone(imp.limpiar(None))
        self.assertIsNone(imp.limpiar("   "))
        self.assertEqual(imp.limpiar("  X  "), "X")

    def test_clasificacion_de_organizaciones(self):
        self.assertEqual(imp.clasificar_tipo_org("PARTIDO APRISTA PERUANO"), "PARTIDO_NACIONAL")
        self.assertEqual(imp.clasificar_tipo_org("FRENTE POPULAR"), "PARTIDO_NACIONAL")
        self.assertEqual(imp.clasificar_tipo_org("YO AREQUIPA"), "MOVIMIENTO_REGIONAL")

    def test_cargo_coherente_por_tipo(self):
        self.assertTrue(imp.cargo_valido("GOBERNADOR", "REGIONAL"))
        self.assertTrue(imp.cargo_valido("ALCALDE_DISTRITAL", "DISTRITAL"))
        self.assertTrue(imp.cargo_valido("REGIDOR_PROVINCIAL", "PROVINCIAL"))
        # Cargo de otro nivel: debe rechazarse (CHECK de la base)
        self.assertFalse(imp.cargo_valido("ALCALDE_DISTRITAL", "REGIONAL"))
        self.assertFalse(imp.cargo_valido("GOBERNADOR", "DISTRITAL"))


class _FakeCursor:
    """Cursor mínimo que imita la base: UNIQUE de candidatos y resolución de orgs."""

    def __init__(self):
        self.orgs: dict[int, dict] = {}          # id_jne -> fila
        self.orgs_por_nombre: dict[str, int] = {}
        self.candidatos: dict[tuple, dict] = {}  # (org_id, ubigeo, cargo, numero) -> fila
        self._sig_id = 1

    def execute(self, sql, params=None):
        sql_norm = " ".join(sql.split())
        # Savepoints y transacciones: el FAKE es un no-op aquí
        if sql_norm.startswith(("SAVEPOINT", "RELEASE", "ROLLBACK TO", "BEGIN", "COMMIT")):
            self._resultado = []
            return None
        if sql_norm.startswith("SELECT ubigeo, ubigeo_reniec"):
            (ubigeo,) = params
            # El FAKE conoce el departamento y un distrito de ejemplo
            conocidos = {
                "040000": ["040000", None],
                "040100": ["040100", None],
                "040112": ["040112", None],
            }
            fila = conocidos.get(ubigeo)
            self._resultado = [fila] if fila else []
        elif sql_norm.startswith("SELECT id, nombre"):
            (id_jne,) = params
            self._resultado = [self.orgs[id_jne]] if id_jne in self.orgs else []
        elif sql_norm.startswith("SELECT id, dni, nombres"):
            (org_id, ubigeo, cargo, numero) = params
            fila = self.candidatos.get((org_id, ubigeo, cargo, numero))
            self._resultado = [fila] if fila else []
        elif sql_norm.startswith("INSERT INTO organizaciones_politicas"):
            nombre, tipo, id_jne, logo = params
            org_id = self._sig_id
            self._sig_id += 1
            fila = [org_id, nombre, tipo, id_jne, logo, "#6b7280"]
            self.orgs[id_jne] = fila
            self.orgs_por_nombre[nombre.lower()] = org_id
            self._resultado = [fila]
        elif sql_norm.startswith("UPDATE organizaciones_politicas"):
            nombre, tipo, logo, org_id = params
            for fila in self.orgs.values():
                if fila[0] == org_id:
                    fila[1], fila[2], fila[4] = nombre, tipo, logo
            self._resultado = []
        elif sql_norm.startswith("INSERT INTO candidatos"):
            (org_id, ubigeo, tipo, cargo, numero, dni, nombres,
             apellidos, completo, foto, estado) = params
            cand_id = self._sig_id
            self._sig_id += 1
            nueva = [cand_id, dni, nombres, apellidos, completo, foto, estado]
            self.candidatos[(org_id, ubigeo, cargo, numero)] = nueva
            self._resultado = [[cand_id]]
        elif sql_norm.startswith("UPDATE candidatos"):
            dni, nombres, apellidos, completo, foto, estado, cand_id = params
            for fila in self.candidatos.values():
                if fila[0] == cand_id:
                    fila[1:] = [dni, nombres, apellidos, completo, foto, estado]
            self._resultado = []
        else:
            raise AssertionError(f"SQL no simulado: {sql_norm[:70]}")
        return None

    def fetchone(self):
        return self._resultado[0] if self._resultado else None

    def fetchall(self):
        return list(self._resultado)


class _FakeConn:
    def __init__(self):
        self.cursor_obj = _FakeCursor()

    def cursor(self):
        return self.cursor_obj

    def set_session(self, **kw):
        pass

    def commit(self):
        pass

    def rollback(self):
        pass

    def close(self):
        pass


class TestCorridaConFake(unittest.TestCase):
    """Corrida completa del pipeline contra un doble de la base."""

    def _importador(self, execute: bool) -> tuple[imp.ImportadorJNE, _FakeConn]:
        importador = imp.ImportadorJNE("dsn-fake", execute)
        conn = _FakeConn()
        importador._conn = conn  # inyección: no toca PostgreSQL
        return importador, conn

    def _archivo_tmp(self, tmp: Path, payload: dict) -> Path:
        p = tmp / "ambito.json"
        p.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        return p

    def test_inserta_todo_y_segunda_corrida_no_repite(self):
        payload = {
            "tipoEleccion": "MUNICIPAL DISTRITAL",
            "ubigeo": "040112",
            "organizaciones": [
                {
                    "organizacionPolitica": "PARTIDO FAKE",
                    "idOrganizacionPolitica": 999,
                    "logo_url": "http://x/999.png",
                    "candidatos": [
                        {
                            "dni": "12345678", "nombres": "ANA", "apellidoPaterno": "QUISPE",
                            "apellidoMaterno": "LOZA", "nombre_completo": "ANA QUISPE LOZA",
                            "cargo": "ALCALDE_DISTRITAL", "posicion": 1, "estado": "INSCRITO",
                            "foto_url": "http://x/ana.jpg",
                        },
                        {
                            "dni": "87654321", "nombres": "BOA", "apellidoPaterno": "MAMANI",
                            "apellidoMaterno": None, "nombre_completo": "BOA MAMANI",
                            "cargo": "REGIDOR_DISTRITAL", "posicion": 2, "estado": "RETIRO",
                        },
                    ],
                }
            ],
        }
        with tempfile.TemporaryDirectory() as td:
            archivo = self._archivo_tmp(Path(td), payload)
            importador, conn = self._importador(True)
            rc = importador.correr([archivo])

            self.assertEqual(rc, 0, importador.stats.como_texto())
            self.assertEqual(importador.stats.organizaciones_nuevas, 1)
            self.assertEqual(importador.stats.candidatos_nuevos, 2)
            self.assertEqual(importador.stats.candidatos_no_inscritos, 1)
            self.assertEqual(len(conn.cursor_obj.candidatos), 2)
            # RETIRO se guarda como RETIRADO
            guardados = list(conn.cursor_obj.candidatos.values())
            estados = {f[6] for f in guardados}
            self.assertEqual(estados, {"INSCRITO", "RETIRADO"})

            # Segunda corrida sobre LA MISMA base (mismo FAKE): nada nuevo
            importador2 = imp.ImportadorJNE("dsn-fake", True)
            importador2._conn = conn
            importador2.correr([archivo])
            self.assertEqual(importador2.stats.candidatos_nuevos, 0)
            self.assertEqual(importador2.stats.candidatos_actualizados, 0)
            self.assertEqual(importador2.stats.candidatos_sin_cambio, 2)

    def test_dry_run_no_persiste(self):
        payload = {
            "tipoEleccion": "REGIONAL",
            "ubigeo": "040000",
            "organizaciones": [{
                "organizacionPolitica": "PARTIDO FAKE 2",
                "idOrganizacionPolitica": 998,
                "candidatos": [{
                    "dni": "11111111", "nombres": "CAMILA", "apellidoPaterno": "TORRES",
                    "apellidoMaterno": "PALZA", "nombre_completo": "CAMILA TORRES PALZA",
                    "cargo": "GOBERNADOR", "posicion": 1, "estado": "INSCRITO",
                }],
            }],
        }
        with tempfile.TemporaryDirectory() as td:
            archivo = self._archivo_tmp(Path(td), payload)
            importador, conn = self._importador(False)  # dry-run
            rc = importador.correr([archivo])
            self.assertEqual(rc, 0)
            # El FAKE procesa igual; lo que garantiza el dry-run es que el
            # importador llame rollback y no commit:
            self.assertFalse(importador.execute)

    def test_numero_posicion_repetido_no_pisa_candidatos(self):
        """El bug que motivó usar `posicion`: numero_posicion se repite entre
        circunscripciones y habría pisado consejeros distintos."""
        payload = {
            "tipoEleccion": "REGIONAL",
            "ubigeo": "040000",
            "organizaciones": [{
                "organizacionPolitica": "PARTIDO FAKE 3",
                "idOrganizacionPolitica": 997,
                "candidatos": [
                    {"dni": "22222221", "nombres": "DARIO", "apellidoPaterno": "ROJAS",
                     "apellidoMaterno": "NINA", "nombre_completo": "DARIO ROJAS NINA",
                     "cargo": "CONSEJERO_REGIONAL", "posicion": 3, "numero_posicion": 1,
                     "estado": "INSCRITO"},
                    {"dni": "22222222", "nombres": "ELENA", "apellidoPaterno": "PACO",
                     "apellidoMaterno": "RIO", "nombre_completo": "ELENA PACO RIO",
                     "cargo": "CONSEJERO_REGIONAL", "posicion": 19, "numero_posicion": 1,
                     "estado": "INSCRITO"},
                ],
            }],
        }
        with tempfile.TemporaryDirectory() as td:
            archivo = self._archivo_tmp(Path(td), payload)
            importador, conn = self._importador(True)
            rc = importador.correr([archivo])
            self.assertEqual(rc, 0, importador.stats.como_texto())
            # Los dos consejeros deben convivir (llaves distintas) y cada uno
            # con SU posicion del JNE:
            llaves = sorted(k[3] for k in conn.cursor_obj.candidatos)
            self.assertEqual(llaves, [3, 19])

    def test_estado_desconocido_falla_y_cargo_incoherente_se_omita(self):
        payload = {
            "tipoEleccion": "DISTRITAL",
            "ubigeo": "040112",
            "organizaciones": [{
                "organizacionPolitica": "PARTIDO FAKE 4",
                "idOrganizacionPolitica": 996,
                "candidatos": [
                    {"dni": "33333331", "nombres": "FABIO", "apellidoPaterno": "COPA",
                     "apellidoMaterno": "SORO", "nombre_completo": "FABIO COPA SORO",
                     "cargo": "ALCALDE_DISTRITAL", "posicion": 1, "estado": "SECUESTRADO"},
                    {"dni": "33333332", "nombres": "GLORIA", "apellidoPaterno": "VILCA",
                     "apellidoMaterno": "QUISPE", "nombre_completo": "GLORIA VILCA QUISPE",
                     "cargo": "GOBERNADOR",  # incoherente con DISTRITAL
                     "posicion": 2, "estado": "INSCRITO"},
                ],
            }],
        }
        with tempfile.TemporaryDirectory() as td:
            archivo = self._archivo_tmp(Path(td), payload)
            importador, conn = self._importador(True)
            rc = importador.correr([archivo])
            # Hubo dos filas problemáticas: una omitida por estado desconocido
            # y otra por cargo incoherente => nada guardado y rc == 1
            self.assertEqual(rc, 1)
            self.assertEqual(len(conn.cursor_obj.candidatos), 0)
            self.assertEqual(len(importador.stats.errores), 2)

    def test_ubigeo_inexistente_se_reporta_y_no_aborta(self):
        payload = {
            "tipoEleccion": "DISTRITAL",
            "ubigeo": "999999",  # no está en el FAKE... ni en la base real
            "organizaciones": [{
                "organizacionPolitica": "PARTIDO FAKE 5",
                "idOrganizacionPolitica": 995,
                "candidatos": [],
            }],
        }
        with tempfile.TemporaryDirectory() as td:
            archivo = self._archivo_tmp(Path(td), payload)
            importador, conn = self._importador(True)
            # El FAKE no resuelve ubigeo: el importador debe reportarlo y seguir
            rc = importador.correr([archivo])
            self.assertEqual(rc, 1)
            self.assertTrue(any("999999" in e for e in importador.stats.errores))


# ---------------------------------------------------------------------------
# 2. Integración real (opcional: requiere el PostgreSQL de prueba)
# ---------------------------------------------------------------------------
def hay_postgres() -> bool:
    try:
        import psycopg2
        conn = psycopg2.connect(imp.DSN_DEFAULT, connect_timeout=3)
        conn.close()
        return True
    except Exception:  # noqa: BLE001
        return False


@unittest.skipUnless(hay_postgres(), "PostgreSQL de prueba no disponible")
class TestIntegracionPostgres(unittest.TestCase):
    """Corre el importador de verdad contra una base TEMPORAL que se crea y
    se destruye: idempotencia, unicidad y contenido, sin tocar la principal."""

    BASE_TEST = "computo_arequipa_test"
    DSN_SERVIDOR = "host=127.0.0.1 port=55433 dbname=postgres user=postgres"

    @classmethod
    def setUpClass(cls):
        import psycopg2
        conn = psycopg2.connect(cls.DSN_SERVIDOR)
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(f"DROP DATABASE IF EXISTS {cls.BASE_TEST} WITH (FORCE)")
            cur.execute(f"CREATE DATABASE {cls.BASE_TEST} ENCODING 'UTF8'")
        conn.close()

        raiz = RAIZ
        dsn = f"host=127.0.0.1 port=55433 dbname={cls.BASE_TEST} user=postgres"

        # Localiza psql.exe del PostgreSQL portable (mismo procedimiento que el
        # run doc); si no está, los tests de integración se saltan.
        psql = None
        for candidato in (Path(tempfile.gettempdir()) / "pgtest" / "pg" / "Library" / "bin" / "psql.exe",):
            if candidato.is_file():
                psql = str(candidato)
                break
        if psql is None:
            raise unittest.SkipTest("psql.exe del PostgreSQL portable no encontrado")

        sql = [
            raiz / "backend" / "sql" / "schema_arequipa.sql",
            raiz / "backend" / "sql" / "seed_ubigeo_arequipa.sql",
        ]
        import subprocess
        env_plano = {k: v for k, v in os.environ.items() if k != "PGCLIENTENCODING"}
        for f in sql:
            r = subprocess.run(
                [psql, "-h", "127.0.0.1", "-p", "55433", "-U", "postgres",
                 "-d", cls.BASE_TEST, "-v", "ON_ERROR_STOP=1", "-f", str(f)],
                capture_output=True, text=True, encoding="utf-8", errors="replace",
            )
            if r.returncode != 0:
                raise RuntimeError(f"no se pudo cargar {f.name}: {(r.stderr or r.stdout)[-400:]}")
        cls.dsn = dsn

    @classmethod
    def tearDownClass(cls):
        import psycopg2
        conn = psycopg2.connect(cls.DSN_SERVIDOR)
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(f"DROP DATABASE IF EXISTS {cls.BASE_TEST} WITH (FORCE)")
        conn.close()

    def _correr(self, execute: bool) -> imp.ImportadorJNE:
        archivos = [
            imp.DIR_DATOS / "regional" / "040000.json",
            imp.DIR_DATOS / "provincial" / "040100.json",
            imp.DIR_DATOS / "distrital" / "040112.json",
        ]
        self.assertTrue(all(a.is_file() for a in archivos), "faltan JSON del crawler")
        importador = imp.ImportadorJNE(self.dsn, execute)
        rc = importador.correr(archivos)
        return importador, rc

    def test_carga_y_idempotencia_real(self):
        import psycopg2

        # 1ra corrida: carga completa
        importador, rc = self._correr(True)
        self.assertEqual(rc, 0, importador.stats.como_texto())
        self.assertEqual(importador.stats.candidatos_nuevos, 633)
        self.assertEqual(importador.stats.organizaciones_nuevas, 28)

        # 2da corrida: idempotente
        importador2, rc2 = self._correr(True)
        self.assertEqual(rc2, 0, importador2.stats.como_texto())
        self.assertEqual(importador2.stats.candidatos_nuevos, 0)
        self.assertEqual(importador2.stats.candidatos_actualizados, 0)
        self.assertEqual(importador2.stats.candidatos_sin_cambio, 633)

        # Contenido real en la base temporal
        conn = psycopg2.connect(self.dsn)
        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM candidatos")
            self.assertEqual(cur.fetchone()[0], 633)
            cur.execute("SELECT count(*) FROM organizaciones_politicas")
            self.assertEqual(cur.fetchone()[0], 28)
            cur.execute(
                "SELECT count(*) FROM candidatos "
                "WHERE organizacion_id IN (SELECT id FROM organizaciones_politicas "
                "WHERE nombre='ACCION POPULAR') AND ubigeo='040112' AND cargo='ALCALDE_DISTRITAL'"
            )
            self.assertEqual(cur.fetchone()[0], 1)
            cur.execute("SELECT nombre_completo FROM candidatos WHERE ubigeo='040112' "
                        "AND cargo='ALCALDE_DISTRITAL' AND numero_lista=1 "
                        "AND organizacion_id IN (SELECT id FROM organizaciones_politicas "
                        "WHERE nombre='ACCION POPULAR')")
            self.assertEqual(cur.fetchone()[0], "LUIS JUSTO MAYTA LIVISI")
        conn.close()


def main() -> int:
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    suite.addTests(loader.loadTestsFromModule(sys.modules[__name__]))
    runner = unittest.TextTestRunner(verbosity=2)
    resultado = runner.run(suite)
    return 0 if resultado.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
