"""Pruebas del detector de cambios entre capturas del JNE.

Sin red y sin disco: se comparan diccionarios construidos aquí.

    cd jne-scraper && python tests/test_cambios.py
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ))

import cambios  # noqa: E402


def candidato(nombre="", dni="", cargo="ALCALDE_DISTRITAL", estado="INSCRITO", posicion=1):
    return {
        "nombre_completo": nombre,
        "dni": dni,
        "cargo": cargo,
        "estado": estado,
        "posicion": posicion,
    }


def organizacion(nombre, *candidatos):
    return {"organizacionPolitica": nombre, "candidatos": list(candidatos)}


def ambito(ubigeo="040112", nivel="distrital", *organizaciones):
    return {"nivel": nivel, "ubigeo": ubigeo, "organizaciones": list(organizaciones)}


def tipos(cambios_detectados):
    return [c.tipo for c in cambios_detectados]


class TestCategorias(unittest.TestCase):
    """Las tres categorías pedidas: nuevo, retirado y estado distinto."""

    def test_candidato_nuevo(self):
        antes = ambito("040112", "distrital", organizacion("AP", candidato("Uno", "111", posicion=1)))
        ahora = ambito("040112", "distrital", organizacion(
            "AP", candidato("Uno", "111", posicion=1), candidato("Dos", "222", posicion=2)))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(tipos(detectados), ["candidato_nuevo"])
        self.assertEqual(detectados[0].detalle.split(" · ")[0], "Dos")
        self.assertTrue(detectados[0].critico, "entra en carrera: hay que mirarlo")

    def test_candidato_retirado(self):
        antes = ambito("040112", "distrital", organizacion(
            "AP", candidato("Uno", "111", posicion=1), candidato("Dos", "222", posicion=2)))
        ahora = ambito("040112", "distrital", organizacion("AP", candidato("Uno", "111", posicion=1)))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(tipos(detectados), ["candidato_retirado"])
        self.assertTrue(detectados[0].critico)

    def test_estado_distinto(self):
        antes = ambito("040112", "distrital", organizacion("AP", candidato("Uno", "111")))
        ahora = ambito("040112", "distrital", organizacion(
            "AP", candidato("Uno", "111", estado="TACHADO")))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(tipos(detectados), ["estado_cambiado"])
        self.assertEqual((detectados[0].anterior, detectados[0].nuevo), ("INSCRITO", "TACHADO"))
        self.assertTrue(detectados[0].critico, "sale de la carrera")
        self.assertIn("INSCRITO -> TACHADO", str(detectados[0]))

    def test_sin_cambios(self):
        antes = ambito("040112", "distrital", organizacion("AP", candidato("Uno", "111")))
        self.assertEqual(cambios.comparar_ambito(antes, antes), [])

    def test_estado_distinto_entre_no_inscritos_no_es_critico(self):
        """Pasar de RENUNCIA a TACHADO no cambia quién está en carrera."""
        antes = ambito("040112", "distrital", organizacion(
            "AP", candidato("Uno", "111", estado="RENUNCIA")))
        ahora = ambito("040112", "distrital", organizacion(
            "AP", candidato("Uno", "111", estado="TACHADO")))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(tipos(detectados), ["estado_cambiado"])
        self.assertFalse(detectados[0].critico)


class TestEmparejamiento(unittest.TestCase):
    """El DNI desaparece justo cuando alguien sale de la carrera."""

    def test_anonimizacion_es_datos_cambiados_no_retirado_mas_nuevo(self):
        """Caso real 040119: el JNE borra DNI y nombre del candidato retirado."""
        antes = ambito("040119", "distrital", organizacion(
            "AHORA NACION - AN",
            candidato("EDGAR CHOQUE RODRIGUEZ", "29483030", estado="RETIRO", posicion=1)))
        ahora = ambito("040119", "distrital", organizacion(
            "AHORA NACION - AN", candidato("", "", estado="RETIRO", posicion=1)))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(tipos(detectados), ["datos_cambiados"],
                         "el mismo candidato sigue ahí: no es un retirado más un nuevo")
        self.assertFalse(detectados[0].critico, "cambia cómo se ve, no quién compite")
        detalle = detectados[0].detalle
        self.assertIn("'29483030' -> '(vacío)'", detalle)
        self.assertIn("'EDGAR CHOQUE RODRIGUEZ' -> '(vacío)'", detalle)

    def test_empareja_por_posicion_cuando_uno_quedo_sin_nombre(self):
        """La posición rescata al anonimizado, que es el caso para el que existe."""
        parejas, faltantes, nuevos = cambios.emparejar(
            [candidato("JUAN PEREZ", "", posicion=3)],
            [candidato("", "", posicion=3)],
        )
        self.assertEqual((len(parejas), faltantes, nuevos), (1, [], []))

    def test_la_posicion_no_tapa_un_cambio_de_persona(self):
        """Dos nombres distintos en el mismo número de lista son dos personas."""
        antes = ambito("040112", "distrital", organizacion(
            "AP", candidato("JUAN PEREZ", "111", posicion=3)))
        ahora = ambito("040112", "distrital", organizacion(
            "AP", candidato("PEDRO GOMEZ", "222", posicion=3)))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(sorted(tipos(detectados)), ["candidato_nuevo", "candidato_retirado"])
        self.assertTrue(all(c.critico for c in detectados))

    def test_empareja_por_nombre_y_detecta_dni_corregido(self):
        antes = ambito("040112", "distrital", organizacion(
            "AP", candidato("JOSE QUISPE MAMANI", "11111111", posicion=1)))
        ahora = ambito("040112", "distrital", organizacion(
            "AP", candidato("JOSE QUISPE MAMANI", "99999999", posicion=2)))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(tipos(detectados), ["datos_cambiados"])
        self.assertIn("'11111111' -> '99999999'", detectados[0].detalle)
        self.assertIn("posición", detectados[0].detalle)

    def test_no_confunde_dos_homonimos_en_la_misma_lista(self):
        """Dos candidatos con el mismo nombre se consumen uno a uno."""
        antes = ambito("040112", "distrital", organizacion(
            "AP", candidato("JOSE QUISPE", "", posicion=1), candidato("JOSE QUISPE", "", posicion=2)))
        ahora = ambito("040112", "distrital", organizacion(
            "AP", candidato("JOSE QUISPE", "", posicion=1)))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(tipos(detectados), ["candidato_retirado"])

    def test_ignora_acentos_y_mayusculas_al_emparejar(self):
        antes = ambito("040112", "distrital", organizacion(
            "AP", candidato("JOSÉ  QUISPE", "", posicion=1)))
        ahora = ambito("040112", "distrital", organizacion(
            "AP", candidato("jose quispe", "", posicion=9)))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(tipos(detectados), ["datos_cambiados"], "es la misma persona")
        self.assertIn("posición", detectados[0].detalle)

    def test_no_mezcla_cargos_distintos(self):
        """Un regidor que se vuelve alcalde no es el mismo candidato."""
        antes = ambito("040112", "distrital", organizacion(
            "AP", candidato("UNO", "111", cargo="REGIDOR_DISTRITAL", posicion=1)))
        ahora = ambito("040112", "distrital", organizacion(
            "AP", candidato("UNO", "111", cargo="ALCALDE_DISTRITAL", posicion=1)))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(sorted(tipos(detectados)), ["candidato_nuevo", "candidato_retirado"])


class TestOrganizacionesYAmbitos(unittest.TestCase):
    def test_organizacion_retirada_es_critica(self):
        antes = ambito("040000", "regional",
                       organizacion("VISION PERU", candidato("A", "1", estado="RETIRO"),
                                    candidato("B", "2", estado="RETIRO")))
        ahora = ambito("040000", "regional", organizacion("OTRA", candidato("C", "3")))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertIn("organizacion_retirada", tipos(detectados))
        retirada = next(c for c in detectados if c.tipo == "organizacion_retirada")
        self.assertTrue(retirada.critico)
        self.assertIn("2 candidatos", retirada.detalle)

    def test_no_lista_candidatos_de_una_organizacion_retirada(self):
        """Se informa la organización, no cada uno de sus candidatos."""
        antes = ambito("040112", "distrital", organizacion(
            "SE VA", *[candidato(f"C{i}", str(i), posicion=i) for i in range(1, 6)]))
        ahora = ambito("040112", "distrital")

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(tipos(detectados), ["organizacion_retirada"])

    def test_ambito_nuevo_y_retirado(self):
        anteriores = {"regional:040000": ambito("040000", "regional")}
        nuevos = {"distrital:040112": ambito("040112", "distrital")}

        detectados = cambios.comparar(anteriores, nuevos)

        self.assertEqual(sorted(tipos(detectados)), ["ambito_nuevo", "ambito_retirado"])
        self.assertTrue(all(c.critico for c in detectados))

    def test_cambios_se_agrupan_por_ambito(self):
        antes = {
            "distrital:040112": ambito("040112", "distrital", organizacion("AP", candidato("Uno", "1"))),
            "distrital:040113": ambito("040113", "distrital", organizacion("AP", candidato("Uno", "1"))),
        }
        nuevos = {
            "distrital:040112": ambito("040112", "distrital", organizacion("AP", candidato("Uno", "1"))),
            "distrital:040113": ambito("040113", "distrital"),
        }

        lineas = cambios.formatear(cambios.comparar(antes, nuevos))

        self.assertEqual(lineas[0], "  distrital:040113")
        self.assertTrue(lineas[1].startswith("      "))
        self.assertNotIn("040112", "\n".join(lineas), "el ámbito sin cambios no se imprime")

    def test_solo_criticos_filtra_pero_el_resumen_los_cuenta_todos(self):
        antes = ambito("040112", "distrital", organizacion(
            "AP", candidato("Uno", "111", estado="RETIRO")))
        ahora = ambito("040112", "distrital", organizacion(
            "AP", candidato("Uno", "", estado="RETIRO")))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(len(detectados), 1)
        self.assertEqual(cambios.formatear(detectados, solo_criticos=True), [])
        self.assertEqual(cambios.formatear(detectados), [
            "  distrital:040112",
            "      · datos_cambiados: AP · ALCALDE_DISTRITAL · DNI '111' -> '(vacío)'",
        ])

    def test_resumen_cuenta_por_tipo(self):
        antes = ambito("040112", "distrital", organizacion(
            "AP", candidato("Uno", "111"), candidato("Dos", "222", posicion=2)))
        ahora = ambito("040112", "distrital", organizacion(
            "AP", candidato("Uno", "111", estado="TACHADO"), candidato("Tres", "333", posicion=2)))

        detectados = cambios.comparar_ambito(antes, ahora)

        self.assertEqual(dict(cambios.resumen(detectados)),
                         {"estado_cambiado": 1, "candidato_retirado": 1, "candidato_nuevo": 1})


if __name__ == "__main__":
    unittest.main(verbosity=2)
