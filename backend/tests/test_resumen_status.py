"""Pruebas del panel Gestión de Actas: GET /api/v1/actas/resumen-status.

Se ejecutan sin pytest:

    cd backend && python tests/test_resumen_status.py

Base SQLite temporal + TestClient, sin red. Cubre: agregados COUNT/SUM/CASE,
cascada departamento→provincia→distrito→local, filtro de estado, búsqueda
exacta de mesa, paginación, 422 de parámetros inválidos y alcance
(DIGITADOR_GLOBAL sin restricciones vs RESPONSABLE_DISTRITAL acotado).
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# Base temporal ANTES de importar app (el engine se crea al importar)
_DIR_TMP = tempfile.mkdtemp(prefix="status_test_")
os.environ["DATABASE_URL"] = f"sqlite:///{_DIR_TMP}/test_status.db"

from fastapi.testclient import TestClient  # noqa: E402

from app.core.database import SessionLocal  # noqa: E402
from app.core.models import Table, Venue  # noqa: E402
from app.main import app  # noqa: E402


def _cliente() -> TestClient:
    return TestClient(app)


def _login(c: TestClient, email: str, clave: str) -> dict:
    r = c.post("/api/auth/login", json={"email": email, "contrasena": clave})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


class TestResumenStatus(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        db = SessionLocal()
        v1 = Venue(name="IE Test A", sector="S1", address="Av 1",
                   latitude=-16.4, longitude=-71.5,
                   ubigeo="040112", total_tables=3)
        v2 = Venue(name="IE Test B", sector="S2", address="Av 2",
                   latitude=-16.5, longitude=-71.6,
                   ubigeo="040201", total_tables=2)
        db.add_all([v1, v2])
        db.commit()
        cls.local_pauc = v1.id
        db.add_all([
            Table(venue_id=v1.id, numero_mesa="100001", processed=True,
                  requires_review=False, status="processed"),
            Table(venue_id=v1.id, numero_mesa="100002", processed=False,
                  requires_review=True, status="requires_review"),
            Table(venue_id=v1.id, numero_mesa="100003", processed=False,
                  requires_review=False, status="pending"),
            Table(venue_id=v2.id, numero_mesa="200001", processed=True,
                  requires_review=False, status="processed"),
            Table(venue_id=v2.id, numero_mesa="200002", processed=False,
                  requires_review=False, status="pending"),
        ])
        db.commit()
        db.close()

        c = _cliente()
        cls.h_dig = _login(c, "digitador.global@computoarequipa.gob.pe",
                           "Digitador.Global2026")
        cls.h_resp = _login(c, "resp.paucarpata@computoarequipa.gob.pe",
                            "Distrital.Paucarpata2026")

    def test_agregado_base_single_query_shape(self):
        with _cliente() as c:
            r = c.get("/api/v1/actas/resumen-status", headers=self.h_dig)
            self.assertEqual(r.status_code, 200, r.text)
            body = r.json()
            self.assertEqual(body["totales"],
                             {"total": 5, "registradas": 2, "pendientes": 2,
                              "observadas": 1, "avance_pct": 40.0})
            self.assertEqual(body["total_filas"], 5)
            self.assertIn("filtros", body)

    def test_cascada_provincia_nombre_y_prefijo(self):
        with _cliente() as c:
            for prov in ("CAMANA", "camana", "0402"):
                r = c.get("/api/v1/actas/resumen-status", headers=self.h_dig,
                          params={"provincia": prov})
                self.assertEqual(r.status_code, 200, (prov, r.text))
                self.assertEqual(r.json()["totales"]["total"], 2)
                mesas = [f["numero_mesa"] for f in r.json()["filas"]]
                self.assertTrue(all(m.startswith("200") for m in mesas))

    def test_cascada_distrito_mas_estado(self):
        with _cliente() as c:
            r = c.get("/api/v1/actas/resumen-status", headers=self.h_dig,
                      params={"distrito": "040112", "estado": "pendientes"})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertEqual([f["numero_mesa"] for f in r.json()["filas"]],
                             ["100003"])
            self.assertEqual(r.json()["filas"][0]["estado"], "PENDIENTE")
            # Los totales ignoran el filtro de estado (son del ámbito).
            self.assertEqual(r.json()["totales"]["total"], 3)

    def test_busqueda_mesa_exacta(self):
        with _cliente() as c:
            r = c.get("/api/v1/actas/resumen-status", headers=self.h_dig,
                      params={"mesa": "100002"})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertEqual(r.json()["total_filas"], 1)
            fila = r.json()["filas"][0]
            self.assertEqual((fila["numero_mesa"], fila["estado"],
                              fila["distrito"], fila["provincia"]),
                             ("100002", "OBSERVADA", "PAUCARPATA", "AREQUIPA"))

    def test_paginacion(self):
        with _cliente() as c:
            r = c.get("/api/v1/actas/resumen-status", headers=self.h_dig,
                      params={"page_size": 2, "pagina": 2})
            self.assertEqual(r.status_code, 200, r.text)
            body = r.json()
            self.assertEqual((body["pagina"], body["total_paginas"],
                              [f["numero_mesa"] for f in body["filas"]]),
                             (2, 3, ["100003", "200001"]))

    def test_filtro_local(self):
        with _cliente() as c:
            r = c.get("/api/v1/actas/resumen-status", headers=self.h_dig,
                      params={"local_id": self.local_pauc})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertEqual(r.json()["totales"]["total"], 3)
            r = c.get("/api/v1/actas/resumen-status", headers=self.h_dig,
                      params={"local_id": 999999})
            self.assertEqual(r.status_code, 404)

    def test_parametros_invalidos_422(self):
        with _cliente() as c:
            for params in ({"estado": "mal"}, {"provincia": "LIMA"},
                           {"departamento": "CUSCO"}, {"distrito": "999999"}):
                r = c.get("/api/v1/actas/resumen-status", headers=self.h_dig,
                          params=params)
                self.assertEqual(r.status_code, 422, (params, r.text))

    def test_alcance_rol_no_global(self):
        with _cliente() as c:
            r = c.get("/api/v1/actas/resumen-status", headers=self.h_resp)
            self.assertEqual(r.status_code, 200, r.text)
            self.assertEqual(r.json()["totales"]["total"], 3)  # sólo Paucarpata
            r = c.get("/api/v1/actas/resumen-status", headers=self.h_resp,
                      params={"provincia": "CAMANA"})
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.json()["totales"]["total"], 0)

    def test_locales_por_distrito(self):
        with _cliente() as c:
            r = c.get("/api/v1/ubigeo/locales", headers=self.h_dig,
                      params={"ubigeo": "040112"})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertEqual(r.json(),
                             [{"id": self.local_pauc, "nombre": "IE Test A",
                               "ubigeo": "040112", "mesas": 3}])
            r = c.get("/api/v1/ubigeo/locales", headers=self.h_resp,
                      params={"ubigeo": "040201"})
            self.assertEqual(r.status_code, 403)


def main() -> int:
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    resultado = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if resultado.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
