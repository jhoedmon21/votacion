"""Pruebas del editor de padrón: POST /api/digitador/mesas/padron.

Se ejecutan sin pytest:

    cd backend && python tests/test_padron_mesa.py

Base SQLite temporal + TestClient, sin red. Cubre el flujo completo de la
ventana de edición de electores hábiles: el cliente manda el N° de mesa, el
endpoint resuelve su id en `tables` y en una transacción aplica

    UPDATE tables SET electores_habiles=:n, processed=0,
           requires_review=0, status='pending' WHERE id=:id;
    DELETE FROM acta_metadata WHERE table_id=:id;
    DELETE FROM records        WHERE table_id=:id;

más la huella de auditoría. También: 404 de mesa inexistente, 403 de rol no
global, 422 de payload inválido e idempotencia (re-editar una mesa ya
resetada no falla).
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
_DIR_TMP = tempfile.mkdtemp(prefix="padron_test_")
os.environ["DATABASE_URL"] = f"sqlite:///{_DIR_TMP}/test_padron.db"

from fastapi.testclient import TestClient  # noqa: E402

from app.core.database import SessionLocal  # noqa: E402
from app.core.models import (ActaAuditoriaGlobal, ActaMetadata, Record,  # noqa: E402
                              Table, Venue)
from app.main import app  # noqa: E402


def _cliente() -> TestClient:
    return TestClient(app)


def _login(c: TestClient, email: str, clave: str) -> dict:
    r = c.post("/api/auth/login", json={"email": email, "contrasena": clave})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


class TestPadronMesa(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        db = SessionLocal()
        v = Venue(name="IE Padron Test", sector="S1", address="Av 1",
                  latitude=-16.4, longitude=-71.5,
                  ubigeo="040112", total_tables=2)
        db.add(v)
        db.commit()
        # Mesa con acta "contaminada": processed, observada, con votos y
        # metadatos — el reset debe limpiar todo.
        t1 = Table(venue_id=v.id, numero_mesa="010203", electores_habiles=250,
                   processed=True, requires_review=True,
                   status="requires_review")
        t2 = Table(venue_id=v.id, numero_mesa="010204", electores_habiles=180,
                   processed=False, requires_review=False, status="pending")
        db.add_all([t1, t2])
        db.commit()
        db.add_all([
            Record(table_id=t1.id, candidate_type="district",
                   candidate_id=1, votes=120, verified=True),
            Record(table_id=t1.id, candidate_type="regional",
                   candidate_id=2, votes=80, verified=True),
            ActaMetadata(table_id=t1.id, votos_blancos=4, votos_nulos=6,
                         total_electores=250),
        ])
        db.commit()
        cls.mesa_con_acta = t1.id
        cls.mesa_pendiente = t2.id
        db.close()

        c = _cliente()
        cls.h_admin = _login(c, "admin@computoarequipa.gob.pe",
                             "Admin.Arequipa2026")
        cls.h_dig = _login(c, "digitador.global@computoarequipa.gob.pe",
                           "Digitador.Global2026")
        cls.h_pers = _login(c, "personero.paucarpata@computoarequipa.gob.pe",
                            "Personero.Paucarpata2026")

    def _mesa(self, numero: str) -> Table:
        db = SessionLocal()
        try:
            return db.query(Table).filter(Table.numero_mesa == numero).one()
        finally:
            db.close()

    def _contaminar(self, numero: str):
        """Deja la mesa con acta 'sucia' (2 votos + metadata) para el reset.

        Se llama al inicio de cada test que borra: los tests de unittest
        corren en orden alfabético, así que el estado no puede depender del
        orden de escritura.
        """
        db = SessionLocal()
        try:
            t = db.query(Table).filter(Table.numero_mesa == numero).one()
            db.query(Record).filter(Record.table_id == t.id).delete()
            db.query(ActaMetadata).filter(
                ActaMetadata.table_id == t.id).delete()
            t.electores_habiles = 250
            t.processed = True
            t.requires_review = True
            t.status = "requires_review"
            db.add_all([
                Record(table_id=t.id, candidate_type="district",
                       candidate_id=1, votes=120, verified=True),
                Record(table_id=t.id, candidate_type="regional",
                       candidate_id=2, votes=80, verified=True),
                ActaMetadata(table_id=t.id, votos_blancos=4, votos_nulos=6,
                             total_electores=250),
            ])
            db.commit()
        finally:
            db.close()

    def test_reset_por_numero_mesa(self):
        """El SQL pedido, disparado por N° de mesa con rol DIGITADOR_GLOBAL."""
        self._contaminar("010203")
        with _cliente() as c:
            r = c.post("/api/digitador/mesas/padron",
                       headers=self.h_dig,
                       json={"numero_mesa": "010203",
                             "electores_habiles": 300,
                             "motivo": "corrección del padrón ONPE"})
            self.assertEqual(r.status_code, 200, r.text)
            body = r.json()
            self.assertEqual(body["mesa"]["numero_mesa"], "010203")
            self.assertEqual(body["mesa"]["id"], self.mesa_con_acta)
            self.assertEqual(body["mesa"]["electores_habiles"], 300)
            self.assertFalse(body["mesa"]["processed"])
            self.assertFalse(body["mesa"]["requires_review"])
            self.assertEqual(body["mesa"]["status"], "pending")
            self.assertEqual(body["eliminados"],
                             {"records": 2, "acta_metadata": 1})
            self.assertIn("auditoria_id", body)

        db = SessionLocal()
        try:
            t = db.query(Table).filter(Table.numero_mesa == "010203").one()
            self.assertEqual(t.electores_habiles, 300)
            self.assertFalse(t.processed)
            self.assertFalse(t.requires_review)
            self.assertEqual(t.status, "pending")
            self.assertEqual(db.query(Record).filter(
                Record.table_id == t.id).count(), 0)
            self.assertEqual(db.query(ActaMetadata).filter(
                ActaMetadata.table_id == t.id).count(), 0)
            aud = db.query(ActaAuditoriaGlobal).filter(
                ActaAuditoriaGlobal.acta_id == t.id).order_by(
                ActaAuditoriaGlobal.id.desc()).all()
            self.assertGreaterEqual(len(aud), 1)
            self.assertEqual(aud[0].accion, "MODIFICAR")
            self.assertEqual(aud[0].numero_mesa, "010203")
            self.assertIn("electores_habiles", aud[0].valores_anteriores)
        finally:
            db.close()

    def test_super_admin_tambien_puede(self):
        with _cliente() as c:
            r = c.post("/api/digitador/mesas/padron",
                       headers=self.h_admin,
                       json={"numero_mesa": "010204",
                             "electores_habiles": 200})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertEqual(r.json()["mesa"]["electores_habiles"], 200)
        self.assertEqual(self._mesa("010204").electores_habiles, 200)

    def test_mesa_inexistente_404(self):
        with _cliente() as c:
            r = c.post("/api/digitador/mesas/padron",
                       headers=self.h_dig,
                       json={"numero_mesa": "999999",
                             "electores_habiles": 300})
            self.assertEqual(r.status_code, 404, r.text)
            self.assertIn("padrón", r.json()["detail"])

    def test_rol_no_global_403(self):
        with _cliente() as c:
            r = c.post("/api/digitador/mesas/padron",
                       headers=self.h_pers,
                       json={"numero_mesa": "010203",
                             "electores_habiles": 300})
            self.assertEqual(r.status_code, 403, r.text)

    def test_payload_invalido_422(self):
        with _cliente() as c:
            for malo in ({"numero_mesa": "0102", "electores_habiles": 10},
                         {"numero_mesa": "010203", "electores_habiles": 0},
                         {"numero_mesa": "010203"}):
                r = c.post("/api/digitador/mesas/padron",
                           headers=self.h_dig, json=malo)
                self.assertEqual(r.status_code, 422, (malo, r.text))

    def test_reeditar_mesa_ya_resetada(self):
        """El editor es idempotente: re-editar no falla ni inventa filas."""
        self._contaminar("010203")
        with _cliente() as c:
            r1 = c.post("/api/digitador/mesas/padron",
                        headers=self.h_dig,
                        json={"numero_mesa": "010203",
                              "electores_habiles": 300})
            self.assertEqual(r1.status_code, 200, r1.text)
            r2 = c.post("/api/digitador/mesas/padron",
                        headers=self.h_dig,
                        json={"numero_mesa": "010203",
                              "electores_habiles": 350})
            self.assertEqual(r2.status_code, 200, r2.text)
            self.assertEqual(r2.json()["eliminados"],
                             {"records": 0, "acta_metadata": 0})
        self.assertEqual(self._mesa("010203").electores_habiles, 350)


if __name__ == "__main__":
    unittest.main(verbosity=2)
