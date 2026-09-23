"""Tests de crawler_onpe.py (puros, sin red salvo las funciones que la usan).

Ejecución:
    cd onpe-scraper && python -m unittest tests.test_crawler_onpe -v
"""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import crawler_onpe as C  # noqa: E402

HTML_GRUPO = """
<h2 class="node-title"><a href="/dataset/foo-2022">Foo</a></h2>
<h2 class="node-title"><a href="/dataset/bar-2023">Bar</a></h2>
<h2 class="node-title"><a href="/dataset/foo-2022">Foo</a></h2>
"""


class TestSlugs(unittest.TestCase):
    def test_regex_fallback(self):
        with patch.dict(sys.modules, {"bs4": None}):
            # Fuerza el camino regex simulando ausencia de bs4.
            import importlib

            real_import = __import__

            def sin_bs4(nombre, *a, **k):
                if nombre == "bs4":
                    raise ImportError("sin bs4")
                return real_import(nombre, *a, **k)

            with patch("builtins.__import__", side_effect=sin_bs4):
                slugs = C._slugs_grupo(HTML_GRUPO)
        self.assertEqual(slugs, ["/dataset/bar-2023", "/dataset/foo-2022"])

    def test_bs4_si_disponible(self):
        try:
            import bs4  # noqa: F401
        except ImportError:
            self.skipTest("bs4 no instalado")
        self.assertEqual(C._slugs_grupo(HTML_GRUPO),
                         ["/dataset/bar-2023", "/dataset/foo-2022"])


class TestConfig(unittest.TestCase):
    def test_plantillas_env(self):
        with patch.dict(os.environ, {"ONPE_ENDPOINTS":
                                     "https://x?a={ubigeo}, https://y-sin-placeholder"}):
            self.assertEqual(C._plantillas_endpoints(), ["https://x?a={ubigeo}"])
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("ONPE_ENDPOINTS", None)
            self.assertEqual(C._plantillas_endpoints(), [])

    def test_ubigeos_arequipa(self):
        ubs = C._ubigeos_ambito("arequipa")
        self.assertEqual(len(ubs), 109)
        self.assertTrue(all(u.startswith("04") for u in ubs))
        self.assertIn("040201", ubs)

    def test_ubigeos_nacional_sin_filtro(self):
        self.assertEqual(C._ubigeos_ambito("nacional"), [])

    def test_pool_ua_reales(self):
        self.assertGreaterEqual(len(C.POOL_UA), 2)
        self.assertTrue(all(u.startswith("Mozilla/5.0") for u in C.POOL_UA))


if __name__ == "__main__":
    unittest.main(verbosity=2)
