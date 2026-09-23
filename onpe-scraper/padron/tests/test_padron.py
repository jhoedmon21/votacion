"""Tests del ETL del padrón: normalización + UPSERT idempotente + DDL.

Ejecución:
    cd onpe-scraper && python -m unittest padron.tests.test_padron -v

Usan SQLite temporal (no tocan ninguna base real) y los fixtures CSV
existentes. No requieren red.
"""
from __future__ import annotations

import re
import sys
import tempfile
import unittest
from pathlib import Path

PADRON_DIR = Path(__file__).resolve().parents[1]
SCRAPER_DIR = PADRON_DIR.parent
for p in (str(SCRAPER_DIR),):
    if p not in sys.path:
        sys.path.insert(0, p)

from padron.carga import cargar_provincia  # noqa: E402
from padron.config import PROVINCIAS, provincia_de_ubigeo  # noqa: E402
from padron.fuentes import (  # noqa: E402
    es_mesa_valida, es_ubigeo_valido, leer_registros_crudos, mapear_columnas,
    normalizar, reclamar_barrido_dni,
)
from padron.modelos import (  # noqa: E402
    LocalVotacion, MesaVotacion, crear_engine_y_sesion, crear_tablas,
)

FIX_EJEMPLO = SCRAPER_DIR / "fixtures" / "locales_mesas_ejemplo.csv"
FIX_HOSTIL = SCRAPER_DIR / "fixtures" / "locales_mesas_hostil.csv"
DDL = SCRAPER_DIR / "sql" / "ddl_locales_mesas.sql"


class TestTerritorio(unittest.TestCase):
    def test_ocho_provincias(self):
        self.assertEqual(len(PROVINCIAS), 8)
        self.assertEqual(
            sorted(p for _, p in PROVINCIAS),
            sorted(["AREQUIPA", "CAMANA", "CARAVELI", "CASTILLA",
                    "CAYLLOMA", "CONDESUYOS", "ISLAY", "LA UNION"]),
        )

    def test_prefijo_a_provincia(self):
        self.assertEqual(provincia_de_ubigeo("040112"), "AREQUIPA")
        self.assertEqual(provincia_de_ubigeo("040501"), "CAYLLOMA")
        self.assertIsNone(provincia_de_ubigeo("150101"))  # Lima, no Arequipa
        self.assertIsNone(provincia_de_ubigeo("04011"))   # formato corto

    def test_validadores(self):
        self.assertTrue(es_ubigeo_valido("040112"))
        self.assertFalse(es_ubigeo_valido("40112"))
        self.assertTrue(es_mesa_valida("023001"))
        self.assertFalse(es_mesa_valida("23001"))

    def test_barrido_dni_prohibido(self):
        with self.assertRaises(RuntimeError):
            reclamar_barrido_dni("algun-dni")


class TestMapeoColumnas(unittest.TestCase):
    """Los encabezados oficiales (con DE/DEL/LA) sí alimentan los destinos."""

    def test_encabezados_oficiales_largos(self):
        mapa = mapear_columnas([
            "UBIGEO", "DEPARTAMENTO", "PROVINCIA", "DISTRITO",
            "CODIGO DE LOCAL", "NOMBRE DEL LOCAL", "DIRECCION DEL LOCAL",
            "NUMERO DE MESA", "ELECTORES", "LATITUD", "LONGITUD",
        ])
        self.assertEqual(mapa["local_nombre"], "NOMBRE DEL LOCAL")
        self.assertEqual(mapa["local_direccion"], "DIRECCION DEL LOCAL")
        self.assertEqual(mapa["local_codigo"], "CODIGO DE LOCAL")
        self.assertEqual(mapa["mesa"], "NUMERO DE MESA")
        self.assertEqual(mapa["ubigeo"], "UBIGEO")

    def test_variantes_cortas_siguen_iguales(self):
        mapa = mapear_columnas([
            "ubigeo", "distrito", "local_codigo", "local_nombre",
            "local_direccion", "mesa", "electores",
        ])
        self.assertEqual(
            (mapa["local_nombre"], mapa["local_direccion"], mapa["mesa"]),
            ("local_nombre", "local_direccion", "mesa"))

    def test_no_confunde_codigo_con_nombre(self):
        mapa = mapear_columnas(["CODIGO", "NOMBRE DE LOCAL", "NRO MESA"])
        self.assertEqual(mapa["local_codigo"], "CODIGO")
        self.assertEqual(mapa["local_nombre"], "NOMBRE DE LOCAL")
        self.assertEqual(mapa["mesa"], "NRO MESA")

    def test_referencia_separada_de_direccion(self):
        mapa = mapear_columnas(["DIRECCION", "REFERENCIA"])
        self.assertEqual(mapa["local_direccion"], "DIRECCION")
        self.assertEqual(mapa["local_referencia"], "REFERENCIA")


class TestNormalizacion(unittest.TestCase):
    def test_ejemplo_limpio(self):
        filas = leer_registros_crudos(FIX_EJEMPLO)
        res = normalizar(filas)
        self.assertEqual(res.descartes, [])
        self.assertEqual(len(res.locales), 5)  # 4 en Arequipa + 1 en Caylloma
        pauc = next(l for l in res.locales if l.codigo_local == "023001")
        self.assertEqual(pauc.provincia, "AREQUIPA")
        self.assertEqual([m.numero for m in pauc.mesas],
                         ["023001", "023002", "023003"])
        self.assertEqual(pauc.total_mesas, 3)

    def test_hostil_descarta_sin_romper(self):
        filas = leer_registros_crudos(FIX_HOSTIL)
        res = normalizar(filas)
        self.assertGreaterEqual(len(res.descartes), 1)
        # Todo descarte explica su motivo.
        self.assertTrue(all(": " in d or "(" in d for d in res.descartes))

    def test_filtro_provincia(self):
        filas = leer_registros_crudos(FIX_EJEMPLO)
        res = normalizar(filas, solo_provincia="CAYLLOMA")
        self.assertTrue(res.locales)
        self.assertTrue(all(l.provincia == "CAYLLOMA" for l in res.locales))

    def test_sin_codigo_agrupa_por_nombre(self):
        # Sin columna de código: dos nombres distintos NO se mezclan.
        filas = [
            {"ubigeo": "040112", "local_nombre": "IE Uno", "mesa": "023001"},
            {"ubigeo": "040112", "local_nombre": "IE Dos", "mesa": "023002"},
        ]
        res = normalizar(filas)
        self.assertEqual(len(res.locales), 2)
        por_nombre = {l.nombre_local: [m.numero for m in l.mesas]
                      for l in res.locales}
        self.assertEqual(por_nombre, {"IE Uno": ["023001"], "IE Dos": ["023002"]})

    def test_mismo_codigo_distinto_nombre_avisa(self):
        filas = [
            {"ubigeo": "040112", "local_codigo": "023001",
             "local_nombre": "IE Uno", "mesa": "023001"},
            {"ubigeo": "040112", "local_codigo": "023001",
             "local_nombre": "IE Otro", "mesa": "023002"},
        ]
        res = normalizar(filas)
        self.assertEqual(len(res.locales), 1)
        self.assertEqual(res.locales[0].nombre_local, "IE Uno")
        self.assertTrue(any("nombres distintos" in d for d in res.descartes))

    def test_sin_codigo_ni_nombre_se_descarta(self):
        res = normalizar([{"ubigeo": "040112", "mesa": "023001"}])
        self.assertEqual(res.locales, [])
        self.assertTrue(any("sin código ni nombre" in d for d in res.descartes))


class TestUpsertIdempotente(unittest.TestCase):
    def _cargar(self, url: str):
        engine, Fabrica = crear_engine_y_sesion(url)
        crear_tablas(engine)
        return engine, Fabrica

    def test_recorrer_dos_veces_no_duplica(self):
        with tempfile.TemporaryDirectory() as tmp:
            url = f"sqlite:///{Path(tmp) / 'padron.db'}"
            engine, Fabrica = self._cargar(url)
            try:
                filas = leer_registros_crudos(FIX_EJEMPLO)
                res = normalizar(filas)
                from collections import defaultdict
                por_prov: dict[str, list] = defaultdict(list)
                for local in res.locales:
                    por_prov[local.provincia].append(local)
                with Fabrica() as s:
                    for prov, locs in sorted(por_prov.items()):
                        cargar_provincia(s, prov, locs)
                with Fabrica() as s:
                    n_locales_1 = s.query(LocalVotacion).count()
                    n_mesas_1 = s.query(MesaVotacion).count()
                    for prov, locs in sorted(por_prov.items()):
                        st = cargar_provincia(s, prov, locs)
                        self.assertEqual(st.locales_nuevos, 0)
                        self.assertEqual(st.mesas_nuevas, 0)
                    self.assertEqual(s.query(LocalVotacion).count(), n_locales_1)
                    self.assertEqual(s.query(MesaVotacion).count(), n_mesas_1)
                    # total_mesas derivado correcto.
                    loc = s.query(LocalVotacion).filter_by(codigo_local="023001").one()
                    self.assertEqual(loc.total_mesas, 3)
            finally:
                engine.dispose()  # Windows: suelta el lock del .db antes del cleanup

    def test_actualiza_electores_en_segunda_pasada(self):
        with tempfile.TemporaryDirectory() as tmp:
            url = f"sqlite:///{Path(tmp) / 'p.db'}"
            engine, Fabrica = self._cargar(url)
            try:
                filas = leer_registros_crudos(FIX_EJEMPLO)
                res = normalizar(filas)
                with Fabrica() as s:
                    cargar_provincia(s, "AREQUIPA",
                                     [l for l in res.locales if l.provincia == "AREQUIPA"])
                # Segunda pasada con electores distintos → UPDATE, no INSERT.
                res.locales[0].mesas[0].electores = 999
                with Fabrica() as s:
                    st = cargar_provincia(s, "AREQUIPA",
                                          [l for l in res.locales if l.provincia == "AREQUIPA"])
                    self.assertEqual(st.mesas_nuevas, 0)
                    self.assertGreaterEqual(st.mesas_actualizadas, 1)
            finally:
                engine.dispose()


class TestDDL(unittest.TestCase):
    def test_ddl_existe_y_estructural(self):
        self.assertTrue(DDL.exists(), "falta sql/ddl_locales_mesas.sql")
        sql = DDL.read_text(encoding="utf-8")
        for tabla in ("locales_votacion", "mesas_votacion"):
            self.assertIn(f"CREATE TABLE IF NOT EXISTS {tabla}", sql)
        for columna in ("ubigeo", "departamento", "provincia", "distrito",
                        "nombre_local", "direccion", "referencia", "latitud",
                        "longitud", "total_mesas", "local_id", "numero_mesa",
                        "estado_acta", "fecha_registro"):
            self.assertIn(columna, sql)
        self.assertIn("REFERENCES locales_votacion (id)", sql)  # FK mesas→locales
        self.assertIn("UNIQUE (ubigeo, codigo_local)", sql)
        self.assertIn("UNIQUE (local_id, numero_mesa)", sql)
        # Paréntesis balanceados (chequeo superficial de sintaxis).
        self.assertEqual(sql.count("("), sql.count(")"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
