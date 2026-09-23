"""Pruebas de autenticación, RBAC y alcance territorial.

Se ejecutan sin pytest:

    cd backend && python tests/test_auth.py

Usan una base SQLite temporal (no toca votopaucarpata.db ni el PostgreSQL de
prueba) y arrancan la app FastAPI con TestClient, sin red.
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
_DIR_TMP = tempfile.mkdtemp(prefix="auth_test_")
os.environ["DATABASE_URL"] = f"sqlite:///{_DIR_TMP}/test_auth.db"

from fastapi.testclient import TestClient  # noqa: E402

from app.core.models import (ROLES_SISTEMA, AccesoLog, Sesion,  # noqa: E402
                             Usuario, UsuarioAlcance, Venue)
from app.core.security import hash_token, verificar_password  # noqa: E402
from app.main import app  # noqa: E402
from app.core.database import SessionLocal, engine  # noqa: E402

CLAVES = {
    "admin@computoarequipa.gob.pe": "Admin.Arequipa2026",
    "coord.arequipa@computoarequipa.gob.pe": "Coord.Arequipa2026",
    "coord.caylloma@computoarequipa.gob.pe": "Coord.Caylloma2026",
    "resp.paucarpata@computoarequipa.gob.pe": "Distrital.Paucarpata2026",
    "personero.paucarpata@computoarequipa.gob.pe": "Personero.Paucarpata2026",
}


def _cliente() -> TestClient:
    return TestClient(app)


class TestCrypto(unittest.TestCase):
    """El núcleo criptográfico cumple las reglas del sistema."""

    def test_hash_bcrypt_y_verificacion(self):
        h = hash_password_ok()
        self.assertTrue(h.startswith(("$2a$", "$2b$")))
        self.assertTrue(verificar_password("Clave.Segura2026", h))
        self.assertFalse(verificar_password("otra", h))
        # Contraseña corta se rechaza en el hash, nunca se guarda débil
        from app.core.security import hash_password
        with self.assertRaises(ValueError):
            hash_password("corta")

    def test_token_y_hash(self):
        from app.core.security import generar_token, hash_token
        t = generar_token()
        self.assertGreaterEqual(len(t), 40)
        self.assertEqual(hash_token(t), hash_token(t))
        self.assertNotEqual(hash_token(t), hash_token(t + "x"))

    def test_roles_del_sistema(self):
        self.assertEqual(
            set(ROLES_SISTEMA),
            {
                "SUPER_ADMIN",
                "DIGITADOR_GLOBAL",
                "COORD_PROVINCIAL",
                "RESPONSABLE_DISTRITAL",
                "COORD_LOCAL",
                "DELEGADO_MESA",
                "PERSONERO",
            },
        )


def hash_password_ok() -> str:
    from app.core.security import hash_password
    return hash_password("Clave.Segura2026")


class TestLoginYRoles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # La app ya corrió su seed al importar: los venues deben tener ubigeo
        db = SessionLocal()
        cls.venue_id = db.query(Venue).first().id
        db.close()

    def test_login_correcto_devuelve_token_y_usuario(self):
        with _cliente() as c:
            r = c.post("/api/auth/login", json={
                "email": "admin@computoarequipa.gob.pe",
                "contrasena": CLAVES["admin@computoarequipa.gob.pe"],
            })
            self.assertEqual(r.status_code, 200, r.text)
            data = r.json()
            self.assertGreaterEqual(len(data["token"]), 40)
            self.assertEqual(data["usuario"]["rol"], "SUPER_ADMIN")
            self.assertEqual(data["usuario"]["alcance_ubigeos"], [])

    def test_login_clave_mala_401(self):
        with _cliente() as c:
            r = c.post("/api/auth/login", json={
                "email": "admin@computoarequipa.gob.pe", "contrasena": "equivocada",
            })
            self.assertEqual(r.status_code, 401)

    def test_login_email_desconocido_401(self):
        with _cliente() as c:
            r = c.post("/api/auth/login", json={
                "email": "nadie@computoarequipa.gob.pe", "contrasena": "loquesea.123",
            })
            self.assertEqual(r.status_code, 401)

    def test_endpoints_protegidos_sin_token_401(self):
        with _cliente() as c:
            for ruta in ("/api/actas/review", "/api/analytics/summary", "/api/auth/me"):
                self.assertEqual(c.get(ruta).status_code, 401, ruta)

    def test_token_invalido_401(self):
        with _cliente() as c:
            r = c.get("/api/actas/review", headers={"Authorization": "Bearer NOEXISTE"})
            self.assertEqual(r.status_code, 401)

    def test_me_devuelve_alcance_del_personero(self):
        with _cliente() as c:
            tok = self._login(c, "personero.paucarpata@computoarequipa.gob.pe")
            r = c.get("/api/auth/me", headers=self._auth(tok))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.json()["rol"], "PERSONERO")
            self.assertEqual(r.json()["alcance_ubigeos"], ["040112"])

    def test_solo_super_admin_lee_usuarios(self):
        # Visibilidad por rol (router /api/auth/usuarios): SUPER_ADMIN y
        # DIGITADOR_GLOBAL ven todo; coordinadores ven a su equipo; el resto
        # sólo se ve a sí mismo (200 con 1 fila, sin hashes).
        with _cliente() as c:
            tok_pers = self._login(c, "personero.paucarpata@computoarequipa.gob.pe")
            tok_admin = self._login(c, "admin@computoarequipa.gob.pe")
            r_pers = c.get("/api/auth/usuarios", headers=self._auth(tok_pers))
            self.assertEqual(r_pers.status_code, 200)
            self.assertTrue(all(u["email"] == "personero.paucarpata@computoarequipa.gob.pe"
                                for u in r_pers.json()))
            r = c.get("/api/auth/usuarios", headers=self._auth(tok_admin))
            self.assertEqual(r.status_code, 200)
            # Los hashes nunca salen por la API
            self.assertTrue(all("password" not in u for u in r.json()))

    def test_logout_revoca(self):
        with _cliente() as c:
            tok = self._login(c, "resp.paucarpata@computoarequipa.gob.pe")
            h = self._auth(tok)
            self.assertEqual(c.post("/api/auth/logout", headers=h).status_code, 200)
            self.assertEqual(c.get("/api/auth/me", headers=h).status_code, 401)

    def test_refresh_rota_el_token(self):
        with _cliente() as c:
            tok = self._login(c, "resp.paucarpata@computoarequipa.gob.pe")
            h = self._auth(tok)
            r = c.post("/api/auth/refresh", headers=h)
            self.assertEqual(r.status_code, 200)
            nuevo = r.json()["token"]
            self.assertNotEqual(nuevo, tok)
            self.assertEqual(c.get("/api/auth/me", headers=h).status_code, 401)
            self.assertEqual(
                c.get("/api/auth/me", headers=self._auth(nuevo)).status_code, 200
            )

    def test_bloqueo_por_fuerza_bruta(self):
        with _cliente() as c:
            email = "resp.yanahuara@computoarequipa.gob.pe"
            for _ in range(5):
                r = c.post("/api/auth/login", json={"email": email, "contrasena": "malamala"})
                self.assertEqual(r.status_code, 401)
            # El 6to, incluso con la clave correcta, está bloqueado
            r = c.post("/api/auth/login", json={
                "email": email,
                "contrasena": "Distrital.Yanahuara2026",
            })
            self.assertEqual(r.status_code, 423)

    # -- utilidades ---------------------------------------------------------

    @staticmethod
    def _auth(token: str) -> dict:
        return {"Authorization": f"Bearer {token}"}

    @staticmethod
    def _login(c: TestClient, email: str) -> str:
        r = c.post("/api/auth/login", json={"email": email, "contrasena": CLAVES[email]})
        assert r.status_code == 200, r.text
        return r.json()["token"]


class TestAlcanceTerritorial(unittest.TestCase):
    """El alcance territorial filtra locales, actas y rankings."""

    @classmethod
    def setUpClass(cls):
        cls.venue_pauc = cls._crear_venue("040112", "LOCAL PAUC TEST")
        cls.venue_yura = cls._crear_venue("040130", "LOCAL YURA TEST")

    @staticmethod
    def _crear_venue(ubigeo: str, nombre: str) -> int:
        db = SessionLocal()
        v = Venue(name=nombre, sector="TEST", address="x",
                  latitude=-16.4, longitude=-71.5, total_tables=10, ubigeo=ubigeo)
        db.add(v)
        db.commit()
        db.refresh(v)
        venue_id = v.id
        db.close()
        return venue_id

    @staticmethod
    def _auth(token: str) -> dict:
        return {"Authorization": f"Bearer {token}"}

    def test_coordinador_caylloma_no_ve_paucarpata(self):
        with _cliente() as c:
            tok = self._login_cliente(c, "coord.caylloma@computoarequipa.gob.pe")
            r = c.get(f"/api/actas/{self.venue_pauc}", headers=self._auth(tok))
            # El acta del venue de Paucarpata no existe, pero el alcance debe
            # rechazar ANTES que el 404: usamos el detalle del error
            r2 = c.get("/api/analytics/map", headers=self._auth(tok))
            nombres = [v["name"] for v in r2.json()]
            self.assertNotIn("LOCAL PAUC TEST", nombres)
            self.assertNotIn("LOCAL YURA TEST", nombres)  # 040130 es Arequipa, no Caylloma

    def test_coordinador_arequipa_ve_ambos_venues_de_su_provincia(self):
        with _cliente() as c:
            tok = self._login_cliente(c, "coord.arequipa@computoarequipa.gob.pe")
            r = c.get("/api/analytics/map", headers=self._auth(tok))
            nombres = [v["name"] for v in r.json()]
            self.assertIn("LOCAL PAUC TEST", nombres)
            self.assertIn("LOCAL YURA TEST", nombres)

    def test_admin_ve_todos(self):
        with _cliente() as c:
            tok = self._login_cliente(c, "admin@computoarequipa.gob.pe")
            r = c.get("/api/analytics/map", headers=self._auth(tok))
            nombres = [v["name"] for v in r.json()]
            self.assertIn("LOCAL PAUC TEST", nombres)
            self.assertIn("LOCAL YURA TEST", nombres)

    def test_personero_lee_pero_no_corrije_actas(self):
        with _cliente() as c:
            tok = self._login_cliente(c, "personero.paucarpata@computoarequipa.gob.pe")
            r = c.put(f"/api/actas/{self.venue_pauc}", json={}, headers=self._auth(tok))
            self.assertEqual(r.status_code, 403)

    def test_responsable_paucarpata_ve_su_venue_y_no_yura(self):
        with _cliente() as c:
            tok = self._login_cliente(c, "resp.paucarpata@computoarequipa.gob.pe")
            r = c.get("/api/analytics/map", headers=self._auth(tok))
            nombres = [v["name"] for v in r.json()]
            self.assertIn("LOCAL PAUC TEST", nombres)
            self.assertNotIn("LOCAL YURA TEST", nombres)

    @staticmethod
    def _login_cliente(c: TestClient, email: str) -> str:
        r = c.post("/api/auth/login", json={"email": email, "contrasena": CLAVES[email]})
        assert r.status_code == 200, r.text
        return r.json()["token"]


class TestAuditoria(unittest.TestCase):
    def test_accesos_quedan_en_bitacora(self):
        with _cliente() as c:
            c.post("/api/auth/login", json={
                "email": "admin@computoarequipa.gob.pe",
                "contrasena": "Admin.Arequipa2026",
            })
            c.post("/api/auth/login", json={
                "email": "admin@computoarequipa.gob.pe", "contrasena": "mala",
            })
        db = SessionLocal()
        logs = (
            db.query(AccesoLog)
            .filter(AccesoLog.email == "admin@computoarequipa.gob.pe")
            .order_by(AccesoLog.id.desc())
            .limit(2)
            .all()
        )
        db.close()
        self.assertEqual(len(logs), 2)
        self.assertTrue(any(l.exitoso for l in logs))
        self.assertTrue(any(not l.exitoso for l in logs))

    def test_sesiones_se_guardan_solo_con_hash(self):
        with _cliente() as c:
            r = c.post("/api/auth/login", json={
                "email": "admin@computoarequipa.gob.pe",
                "contrasena": "Admin.Arequipa2026",
            })
            token = r.json()["token"]
        db = SessionLocal()
        sesion = (
            db.query(Sesion).filter(Sesion.token_hash == hash_token(token)).first()
        )
        db.close()
        self.assertIsNotNone(sesion)
        # El token en claro no está en ninguna columna
        self.assertNotEqual(sesion.token_hash, token)


def main() -> int:
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    suite.addTests(loader.loadTestsFromModule(sys.modules[__name__]))
    resultado = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if resultado.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
