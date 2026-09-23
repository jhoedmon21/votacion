"""Tests del crawler de nombres reales (funciones puras, sin red).

Ejecución:
    cd onpe-scraper && python -m unittest tests.test_nombres_locales -v
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import crawler_nombres_locales as C  # noqa: E402


class TestDetectores(unittest.TestCase):
    def test_columna_local(self):
        for buena in ("LOCAL", "Nombre del Local", "NOMBRE_LOCAL",
                      "Local de Votación", "COLEGIO", "SEDE"):
            self.assertTrue(C.es_columna_local(buena), buena)
        for mala in ("UBIGEO", "MESA", "DISTRITO", "VOTOS_OBTENIDOS",
                     "AGRUPACION_POLITICA", "UBICACION_EN_CEDULA"):
            self.assertFalse(C.es_columna_local(mala), mala)

    def test_columna_ubigeo_mesa(self):
        self.assertTrue(C.es_columna_ubigeo("UBIGEO"))
        self.assertTrue(C.es_columna_ubigeo("Ubigeo INEI"))
        self.assertFalse(C.es_columna_ubigeo("MESA"))
        self.assertTrue(C.es_columna_mesa("MESA"))
        self.assertTrue(C.es_columna_mesa("Nro Mesa"))
        self.assertFalse(C.es_columna_mesa("MESAS_TOTAL"))

    def test_norm_sin_acentos(self):
        self.assertEqual(C._norm("NÚMERO DE MESA"), "numero_de_mesa")
        self.assertEqual(C._norm("Ubicación en Cédula"), "ubicacion_en_cedula")


class TestExtraccion(unittest.TestCase):
    CSV = ("UBIGEO,DEPARTAMENTO,PROVINCIA,DISTRITO,LOCAL,MESA\n"
           "040201,AREQUIPA,CAMANA,CAMANA,IE SEBASTIAN BARRANCA,000001\n"
           "040201,AREQUIPA,CAMANA,CAMANA,IE SEBASTIAN BARRANCA,000002\n"
           "040208,AREQUIPA,CAMANA,SAMUEL PASTOR,IE FAUSTINO FRANCO,000003\n"
           "150101,LIMA,LIMA,LIMA,IE LIMA,000004\n").encode("utf-8")

    def test_extrae_solo_arequipa(self):
        por_ub, rep = C.extraer_locales_csv("t.csv", self.CSV, set())
        self.assertEqual(set(por_ub), {"040201", "040208"})
        self.assertEqual(por_ub["040201"]["IE SEBASTIAN BARRANCA"], 2)
        self.assertEqual(rep["veredicto"], "OK")

    def test_sin_columna_local_veredicto(self):
        por_ub, rep = C.extraer_locales_csv(
            "t.csv", "UBIGEO,MESA\n040201,000001\n".encode(), set())
        self.assertEqual(por_ub, {})
        self.assertIn("LOCAL", rep["veredicto"])

    def test_filtro_solo(self):
        por_ub, _ = C.extraer_locales_csv("t.csv", self.CSV, {"040208"})
        self.assertEqual(set(por_ub), {"040208"})

    def test_fusion_ordena_por_mesas(self):
        fusion = C.fusionar([{"040201": {"B": 1, "A": 5}}])
        self.assertEqual([f["nombre"] for f in fusion["040201"]], ["A", "B"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
