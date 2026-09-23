"""Pruebas de credenciales FA: data, PDF, bulk distrital y verificación QR.

Se ejecutan sin pytest:

    cd backend && python tests/test_credenciales.py

Base SQLite temporal + TestClient, sin red. Cubre: formato QR
FA-AREQUIPA|DNI|MESA|firma, PDF válido (%PDF-), bulk por distrito, QR
forjado rechazado y alcance (rol no global fuera de jurisdicción → 403).
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
_DIR_TMP = tempfile.mkdtemp(prefix="cred_test_")
os.environ["DATABASE_URL"] = f"sqlite:///{_DIR_TMP}/test_cred.db"

from fastapi.testclient import TestClient  # noqa: E402

from app.core.database import SessionLocal  # noqa: E402
from app.core.models import AsignacionPersonero, Table, Usuario, Venue  # noqa: E402
from app.main import app  # noqa: E402
from app.services import credenciales as SVC  # noqa: E402


def _cliente() -> TestClient:
    return TestClient(app)


def _login(c: TestClient, email: str, clave: str) -> dict:
    r = c.post("/api/auth/login", json={"email": email, "contrasena": clave})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


class TestQr(unittest.TestCase):
    def test_formato_estructurado(self):
        qr = SVC.construir_qr("40000006", "008824")
        partes = qr.split("|")
        self.assertEqual(partes[:3], ["FA-AREQUIPA", "40000006", "008824"])
        self.assertEqual(len(partes), 4)
        ok, dni, mesa, _ = SVC.verificar_qr(qr)
        self.assertEqual((ok, dni, mesa), (True, "40000006", "008824"))

    def test_forjado_y_malformado(self):
        qr = SVC.construir_qr("40000006", "008824")
        ok, _, _, motivo = SVC.verificar_qr(qr[:-2] + "FF")
        self.assertFalse(ok)
        self.assertIn("firma", motivo)
        for malo in ("FA-AREQUIPA|1|2", "OTRO|40000006|008824|ABCDEF123456",
                     "", "FA-AREQUIPA|abc|008824|ABCDEF123456"):
            ok, _, _, _ = SVC.verificar_qr(malo)
            self.assertFalse(ok, malo)


class TestEndpoints(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        db = SessionLocal()
        v = Venue(name="IE Test Franco", sector="Cercado",
                  address="AV SAMUEL PASTOR 1301",
                  latitude=-16.4, longitude=-71.5,
                  ubigeo="040208", total_tables=1)
        db.add(v)
        db.commit()
        db.add(Table(venue_id=v.id, numero_mesa="008824", electores_habiles=250,
                     processed=True, status="processed"))
        db.commit()
        t = db.query(Table).filter_by(numero_mesa="008824").one()
        pers = db.query(Usuario).filter_by(
            email="personero.paucarpata@computoarequipa.gob.pe").one()
        cls.pid = pers.id
        db.add(AsignacionPersonero(usuario_id=pers.id, mesa_id=t.id,
                                   tipo="TITULAR", estado="PRESENTE"))
        db.commit()
        # Personero fuera del alcance de Paucarpata (para el 403).
        from app.core.security import hash_password

        yan = Usuario(email="pers.cobertura@computoarequipa.gob.pe", dni="40000077",
                      nombres="Test", apellidos="Cobertura", rol="PERSONERO",
                      password_hash=hash_password("Clave.Test2026"))
        db.add(yan)
        db.commit()
        from app.core.models import UsuarioAlcance

        db.add(UsuarioAlcance(usuario_id=yan.id, ubigeo="040208"))
        db.commit()
        cls.pid_fuera = yan.id
        db.close()

        c = _cliente()
        cls.h_dig = _login(c, "digitador.global@computoarequipa.gob.pe",
                           "Digitador.Global2026")
        cls.h_resp = _login(c, "resp.paucarpata@computoarequipa.gob.pe",
                            "Distrital.Paucarpata2026")

    def test_data_y_pdf(self):
        with _cliente() as c:
            r = c.get(f"/api/v1/personeros/{self.pid}/credencial-data",
                      headers=self.h_dig)
            self.assertEqual(r.status_code, 200, r.text)
            ficha = r.json()
            self.assertEqual(ficha["asignacion"]["local"], "IE Test Franco")
            self.assertTrue(ficha["qr_imagen"].startswith("data:image/png;base64,"))
            r = c.get(f"/api/v1/personeros/{self.pid}/credencial.pdf",
                      headers=self.h_dig)
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers["content-type"], "application/pdf")
            self.assertTrue(r.content.startswith(b"%PDF-"))

    def test_verificar_ok_y_forjado(self):
        with _cliente() as c:
            qr = c.get(f"/api/v1/personeros/{self.pid}/credencial-data",
                       headers=self.h_dig).json()["qr"]
            r = c.post("/api/v1/personeros/verificar-qr", headers=self.h_dig,
                       json={"qr": qr})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertTrue(r.json()["valida"])
            self.assertEqual(r.json()["distrito"], "SAMUEL PASTOR")
            r = c.post("/api/v1/personeros/verificar-qr", headers=self.h_dig,
                       json={"qr": qr[:-2] + "FF"})
            self.assertFalse(r.json()["valida"])

    def test_bulk_distrito(self):
        with _cliente() as c:
            r = c.get("/api/v1/personeros/credencial/distrito",
                      headers=self.h_dig, params={"ubigeo": "040208"})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertGreaterEqual(r.json()["total"], 1)
            r = c.get("/api/v1/personeros/credencial/distrito.pdf",
                      headers=self.h_dig, params={"ubigeo": "040208"})
            self.assertEqual(r.status_code, 200)
            self.assertTrue(r.content.startswith(b"%PDF-"))
            r = c.get("/api/v1/personeros/credencial/distrito.pdf",
                      headers=self.h_dig, params={"ubigeo": "040101"})
            self.assertEqual(r.status_code, 404)

    def test_alcance_403(self):
        with _cliente() as c:
            r = c.get(f"/api/v1/personeros/{self.pid_fuera}/credencial-data",
                      headers=self.h_resp)
            self.assertEqual(r.status_code, 403, r.text)

    def test_sin_asignacion_404(self):
        with _cliente() as c:
            admin = c.post("/api/auth/login", json={
                "email": "admin@computoarequipa.gob.pe",
                "contrasena": "Admin.Arequipa2026"}).json()
            h = {"Authorization": "Bearer " + admin["token"]}
            r = c.get("/api/v1/personeros/1/credencial-data", headers=h)
            self.assertEqual(r.status_code, 404)


def main() -> int:
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    resultado = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if resultado.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
