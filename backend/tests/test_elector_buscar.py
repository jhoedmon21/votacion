"""Pruebas de la consulta ONPE: GET /api/v1/elector/buscar.

Se ejecutan sin pytest:

    cd backend && python tests/test_elector_buscar.py

Base SQLite temporal + TestClient, sin red. Cubre: ficha por mesa (jerarquía,
orden derivado, estado), ficha por DNI (identidad + asignación operativa),
DNI sin mesa, 404 honestos, 422 de parámetros y alcance territorial
(DIGITADOR_GLOBAL global vs RESPONSABLE_DISTRITAL acotado).
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
_DIR_TMP = tempfile.mkdtemp(prefix="elector_test_")
os.environ["DATABASE_URL"] = f"sqlite:///{_DIR_TMP}/test_elector.db"

from fastapi.testclient import TestClient  # noqa: E402

from app.core.database import SessionLocal  # noqa: E402
from app.core.models import AsignacionPersonero, Table, Usuario, Venue  # noqa: E402
from app.main import app  # noqa: E402


def _cliente() -> TestClient:
    return TestClient(app)


def _login(c: TestClient, email: str, clave: str) -> dict:
    r = c.post("/api/auth/login", json={"email": email, "contrasena": clave})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


class TestElectorBuscar(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        db = SessionLocal()
        v = Venue(name="IE Test Franco", sector="Cercado",
                  address="AV SAMUEL PASTOR 1301",
                  latitude=-16.4, longitude=-71.5,
                  ubigeo="040208", total_tables=2)
        db.add(v)
        db.commit()
        db.add_all([
            Table(venue_id=v.id, numero_mesa="008824", electores_habiles=250,
                  processed=True, status="processed"),
            Table(venue_id=v.id, numero_mesa="008825", electores_habiles=250,
                  processed=False, status="pending"),
        ])
        db.commit()
        t = db.query(Table).filter_by(numero_mesa="008824").one()
        pers = db.query(Usuario).filter_by(
            email="personero.paucarpata@computoarequipa.gob.pe").one()
        db.add(AsignacionPersonero(usuario_id=pers.id, mesa_id=t.id,
                                   tipo="TITULAR", estado="PRESENTE"))
        db.commit()
        db.close()

        c = _cliente()
        cls.h_dig = _login(c, "digitador.global@computoarequipa.gob.pe",
                           "Digitador.Global2026")
        cls.h_resp = _login(c, "resp.paucarpata@computoarequipa.gob.pe",
                            "Distrital.Paucarpata2026")

    def test_ficha_por_mesa(self):
        with _cliente() as c:
            r = c.get("/api/v1/elector/buscar", headers=self.h_dig,
                      params={"mesa": "008824"})
            self.assertEqual(r.status_code, 200, r.text)
            f = r.json()
            self.assertEqual(
                (f["modo"], f["ubigeo"], f["provincia"], f["distrito"],
                 f["local"]["nombre"], f["local"]["direccion"],
                 f["numeroMesa"], f["numeroOrden"], f["estadoActa"]),
                ("mesa", "040208", "CAMANA", "SAMUEL PASTOR",
                 "IE Test Franco", "AV SAMUEL PASTOR 1301",
                 "008824", 1, "REGISTRADA"))

    def test_orden_derivado_segunda_mesa(self):
        with _cliente() as c:
            r = c.get("/api/v1/elector/buscar", headers=self.h_dig,
                      params={"mesa": "008825"})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertEqual((r.json()["numeroOrden"], r.json()["estadoActa"]),
                             (2, "PENDIENTE"))

    def test_ficha_por_dni_con_asignacion(self):
        with _cliente() as c:
            r = c.get("/api/v1/elector/buscar", headers=self.h_dig,
                      params={"dni": "40000006"})
            self.assertEqual(r.status_code, 200, r.text)
            f = r.json()
            self.assertEqual((f["modo"], f["nombres"], f["esMiembroMesa"]),
                             ("dni", "Abel", True))
            self.assertEqual(f["asignacion"]["mesa"], "008824")
            self.assertEqual(f["numeroMesa"], "008824")

    def test_dni_registrado_sin_mesa(self):
        with _cliente() as c:
            r = c.get("/api/v1/elector/buscar", headers=self.h_dig,
                      params={"dni": "40000001"})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertEqual((r.json()["esMiembroMesa"],
                              r.json()["numeroMesa"]),
                             (False, ""))

    def test_no_inventa_padron(self):
        with _cliente() as c:
            r = c.get("/api/v1/elector/buscar", headers=self.h_dig,
                      params={"dni": "99999999"})
            self.assertEqual(r.status_code, 404)
            r = c.get("/api/v1/elector/buscar", headers=self.h_dig,
                      params={"mesa": "000000"})
            self.assertEqual(r.status_code, 404)
            r = c.get("/api/v1/elector/buscar", headers=self.h_dig)
            self.assertEqual(r.status_code, 422)

    def test_alcance_no_global(self):
        with _cliente() as c:
            r = c.get("/api/v1/elector/buscar", headers=self.h_resp,
                      params={"mesa": "008824"})
            # Camaná fuera del alcance de Paucarpata.
            self.assertEqual(r.status_code, 403)


def main() -> int:
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    resultado = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if resultado.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
