"""Pruebas del cierre de acta: origen único del pie + validación R1.

Cubre la refactorización del módulo de procesamiento de actas:

  * ``asignar_pie_acta`` / ``sincronizar_consolidado_pie`` — el pie por
    columna (norma ONPE) es el ÚNICO origen de verdad y el consolidado
    histórico (votos_blancos/nulos/impugnados) se RECONSTRUYE desde él:
    nunca se asigna dos veces desde el payload ni se suma por niveles.
  * ``validar_cierre_acta`` — la validación previa al commit: si la suma
    física (válidos + blancos + nulos + impugnados) difiere del total del
    papel, el acta se registra OBSERVADA con su nota de descuadre, sin
    duplicar contadores; si cuadra, queda contabilizada.
  * Flujo HTTP: registro descuadrado → 200 observada (antes 409),
    rectificación → contabilizada, R2 (padrón) sigue bloqueando.

Se ejecuta sin pytest (igual que los demás tests del backend):

    cd backend && python tests/test_cierre_acta.py
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# Base temporal ANTES de importar app (el engine se crea al importar).
_DIR_TMP = tempfile.mkdtemp(prefix="cierre_test_")
os.environ["DATABASE_URL"] = f"sqlite:///{_DIR_TMP}/test_cierre.db"

from fastapi.testclient import TestClient  # noqa: E402

from app.core.database import SessionLocal  # noqa: E402
from app.core.models import (ActaMetadata, DistrictCandidate,  # noqa: E402
                             Record, RegionalCandidate, Table, Venue)
from app.main import app  # noqa: E402
from app.services.processor import (asignar_pie_acta,  # noqa: E402
                                    obtener_metadata,
                                    sincronizar_consolidado_pie,
                                    validar_cierre_acta)

UBIGEO_LOCAL = "040112"  # Paucarpata


def _mesa(db, numero: str, habiles: int | None = 300) -> Table:
    venue = db.query(Venue).first()
    mesa = Table(venue_id=venue.id, numero_mesa=numero, electores_habiles=habiles)
    db.add(mesa)
    db.commit()
    db.refresh(mesa)
    return mesa


# ---------------------------------------------------------------------------
# validar_cierre_acta — validación de cierre previa al commit (sin DB)
# ---------------------------------------------------------------------------
class TestValidarCierreActa(unittest.TestCase):
    def _mesa_memoria(self, **kw) -> Table:
        return Table(numero_mesa="000001", venue_id=1, **kw)

    def test_cuadra_marca_contabilizada(self):
        mesa = self._mesa_memoria(processed=False, requires_review=True,
                                  status="requires_review")
        cierre = validar_cierre_acta(
            mesa,
            total_validos=100, votos_blancos=10, votos_nulos=5,
            votos_impugnados=2, total_papel=117,
        )
        self.assertTrue(cierre["cuadra"])
        self.assertEqual(cierre["suma_calculada"], 117)
        self.assertEqual(cierre["diferencia"], 0)
        self.assertTrue(mesa.processed)
        self.assertFalse(mesa.requires_review)
        self.assertEqual(mesa.status, "processed")
        self.assertIsNone(mesa.observacion)

    def test_descuadre_registra_observada_con_nota(self):
        """Spec R1: la nota documenta exactamente la diferencia del papel."""
        mesa = self._mesa_memoria()
        cierre = validar_cierre_acta(
            mesa,
            total_validos=100, votos_blancos=10, votos_nulos=5,
            votos_impugnados=2, total_papel=130,
        )
        self.assertFalse(cierre["cuadra"])
        self.assertEqual(cierre["suma_calculada"], 117)
        self.assertEqual(cierre["total_papel"], 130)
        self.assertEqual(cierre["diferencia"], 13)
        self.assertTrue(mesa.requires_review)
        self.assertFalse(mesa.processed)
        self.assertEqual(mesa.status, "requires_review")
        self.assertEqual(
            mesa.observacion,
            "Descuadre: Suma calculada (117) difiere del total del papel (130)",
        )

    def test_none_y_ceros_no_rompen_la_aritmetica(self):
        """payload.votos_blancos or 0: los None se tratan como cero."""
        mesa = self._mesa_memoria()
        cierre = validar_cierre_acta(
            mesa, total_validos=0, votos_blancos=None, votos_nulos=None,
            votos_impugnados=None, total_papel=None,
        )
        self.assertTrue(cierre["cuadra"])
        self.assertEqual(cierre["suma_calculada"], 0)

    def test_sin_marcar_procesada_conserva_el_estado_previo(self):
        """PUT sin verified (autoguardado): si cuadra, no promueve ni observa."""
        mesa = self._mesa_memoria(processed=False, requires_review=True,
                                  status="requires_review")
        cierre = validar_cierre_acta(
            mesa, total_validos=10, total_papel=10, marcar_procesada=False,
        )
        self.assertTrue(cierre["cuadra"])
        self.assertTrue(mesa.requires_review)          # sigue observada
        self.assertEqual(mesa.status, "requires_review")
        self.assertIsNone(mesa.observacion)

    def test_descuadre_observa_aun_sin_marcar_procesada(self):
        mesa = self._mesa_memoria(processed=True, requires_review=False,
                                  status="processed")
        validar_cierre_acta(mesa, total_validos=10, total_papel=12,
                            marcar_procesada=False)
        self.assertTrue(mesa.requires_review)
        self.assertFalse(mesa.processed)

    def test_cabecera_en_cero_con_votos_observa(self):
        """R7 unificado en el cierre: papel 0 con votos digitados descuadra."""
        mesa = self._mesa_memoria()
        cierre = validar_cierre_acta(
            mesa, total_validos=50, votos_blancos=5, total_papel=0,
        )
        self.assertFalse(cierre["cuadra"])
        self.assertTrue(mesa.requires_review)
        self.assertIn("total del papel (0)", mesa.observacion)

    def test_acta_multicolumna_cuadra_solo_si_todas_cuadran(self):
        """Acta regional: GOBERNADOR_VICE y CONSEJEROS cuadran por separado."""
        mesa = self._mesa_memoria()
        cierre = validar_cierre_acta(mesa, columnas=[
            {"nombre": "GOBERNADOR_VICE", "validos": 100, "blancos": 10,
             "nulos": 5, "impugnados": 2, "papel": 117},
            {"nombre": "CONSEJEROS", "validos": 90, "blancos": 10,
             "nulos": 5, "impugnados": 2, "papel": 107},
        ])
        self.assertTrue(cierre["cuadra"])
        self.assertEqual(cierre["descuadres"], [])

        mesa2 = self._mesa_memoria()
        cierre2 = validar_cierre_acta(mesa2, columnas=[
            {"nombre": "GOBERNADOR_VICE", "validos": 100, "blancos": 10,
             "nulos": 5, "impugnados": 2, "papel": 117},
            {"nombre": "CONSEJEROS", "validos": 90, "blancos": 10,
             "nulos": 5, "impugnados": 2, "papel": 999},
        ])
        self.assertFalse(cierre2["cuadra"])
        self.assertTrue(mesa2.requires_review)
        self.assertIn("CONSEJEROS", mesa2.observacion)
        self.assertIn("999", mesa2.observacion)


# ---------------------------------------------------------------------------
# asignar_pie_acta / sincronizar_consolidado_pie — origen único del pie
# ---------------------------------------------------------------------------
class TestPiePorColumna(unittest.TestCase):
    def test_pie_por_nivel_y_consolidado_derivado(self):
        """El consolidado replica el pie del nivel, NO se suma ni duplica."""
        db = SessionLocal()
        try:
            mesa = _mesa(db, "900101")
            meta = asignar_pie_acta(db, mesa.id, "distrital",
                                    blancos=7, nulos=3, impugnados=2)
            db.commit()
            db.refresh(meta)
            self.assertEqual((meta.blancos_distrital, meta.nulos_distrital,
                              meta.impugnados_distrital), (7, 3, 2))
            # Consolidado DERIVADO del nivel de referencia (una sola fuente).
            self.assertEqual((meta.votos_blancos, meta.votos_nulos,
                              meta.votos_impugnados), (7, 3, 2))
            # Los demás niveles no se contaminan (regresión del bug que
            # iteraba los caracteres del nivel y creaba columnas fantasma).
            self.assertEqual(meta.blancos_regional, 0)
            self.assertEqual(meta.nulos_provincial, 0)
        finally:
            db.close()

    def test_regional_dos_columnas_el_consolidado_sigue_a_la_principal(self):
        """GOBERNADOR_VICE → regional (principal); CONSEJEROS → consejero.

        El pie de la columna CONSEJEROS se persiste en su nivel propio (antes
        se perdía) sin mover el consolidado de la columna principal.
        """
        db = SessionLocal()
        try:
            mesa = _mesa(db, "900102")
            asignar_pie_acta(db, mesa.id, "regional",
                             blancos=4, nulos=1, impugnados=1)
            asignar_pie_acta(db, mesa.id, "consejero",
                             blancos=30, nulos=2, impugnados=0,
                             sincronizar=False)
            db.commit()
            meta = obtener_metadata(db, mesa.id)
            db.refresh(meta)
            self.assertEqual(meta.blancos_regional, 4)
            self.assertEqual(meta.blancos_consejero, 30)
            self.assertEqual(meta.votos_blancos, 4)   # consolidado: principal
        finally:
            db.close()

    def test_consolidado_multinivel_sigue_a_la_columna_mayor(self):
        db = SessionLocal()
        try:
            mesa = _mesa(db, "900103")
            dist = DistrictCandidate(name="A", party="Partido A",
                                     ubigeo=UBIGEO_LOCAL, sort_order=1)
            reg = RegionalCandidate(name="R", party="Partido R",
                                    ubigeo="040000", sort_order=1)
            db.add_all([dist, reg])
            db.commit()
            db.add_all([
                Record(table_id=mesa.id, candidate_type="district",
                       candidate_id=dist.id, votes=10),
                Record(table_id=mesa.id, candidate_type="regional",
                       candidate_id=reg.id, votes=500),
            ])
            db.commit()
            asignar_pie_acta(db, mesa.id, "distrital",
                             blancos=1, nulos=1, impugnados=1,
                             sincronizar=False)
            asignar_pie_acta(db, mesa.id, "regional",
                             blancos=20, nulos=5, impugnados=5,
                             sincronizar=False)
            sincronizar_consolidado_pie(db, obtener_metadata(db, mesa.id))
            db.commit()
            meta = obtener_metadata(db, mesa.id)
            db.refresh(meta)
            # Columna mayor (regional, 500 votos) resume la cabecera.
            self.assertEqual(meta.votos_blancos, 20)
            self.assertEqual(meta.votos_nulos, 5)
            self.assertEqual(meta.votos_impugnados, 5)
        finally:
            db.close()

    def test_consolidado_legacy_se_conserva_sin_pie_por_columna(self):
        """Acta histórica con sólo el consolidado: no se borra ni se pisa."""
        db = SessionLocal()
        try:
            mesa = _mesa(db, "900104")
            meta = ActaMetadata(table_id=mesa.id, votos_blancos=9,
                                votos_nulos=4, votos_impugnados=1)
            db.add(meta)
            db.commit()
            sincronizar_consolidado_pie(db, meta)
            self.assertEqual((meta.votos_blancos, meta.votos_nulos,
                              meta.votos_impugnados), (9, 4, 1))
        finally:
            db.close()

    def test_none_se_normaliza_a_cero(self):
        db = SessionLocal()
        try:
            mesa = _mesa(db, "900105")
            meta = asignar_pie_acta(db, mesa.id, "provincial",
                                    blancos=None, nulos=None, impugnados=None)
            db.commit()
            db.refresh(meta)
            self.assertEqual((meta.blancos_provincial, meta.nulos_provincial,
                              meta.impugnados_provincial), (0, 0, 0))
        finally:
            db.close()

    def test_nivel_invalido_se_rechaza(self):
        db = SessionLocal()
        try:
            mesa = _mesa(db, "900106")
            with self.assertRaises(ValueError):
                asignar_pie_acta(db, mesa.id, "nacional", blancos=1, nulos=0,
                                 impugnados=0)
            db.rollback()
        finally:
            db.close()


# ---------------------------------------------------------------------------
# Flujo HTTP: POST /api/actas y PUT /api/actas/{id}
# ---------------------------------------------------------------------------
VOTOS = ({"candidate_id": 1, "votes": 100}, {"candidate_id": 2, "votes": 60})
PIE = {"votos_blancos": 10, "votos_nulos": 5, "votos_impugnados": 2}


class TestFlujoRegistro(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        db = SessionLocal()
        db.add(Venue(name="IE Cierre", sector="S1", address="Av 1",
                     latitude=-16.4, longitude=-71.5,
                     ubigeo=UBIGEO_LOCAL, total_tables=10))
        db.commit()
        db.add_all([
            DistrictCandidate(name="Cand A", party="Partido A",
                               ubigeo=UBIGEO_LOCAL, sort_order=1),
            DistrictCandidate(name="Cand B", party="Partido B",
                               ubigeo=UBIGEO_LOCAL, sort_order=2),
        ])
        db.commit()
        db.close()

        with TestClient(app) as c:
            r = c.post("/api/auth/login", json={
                "email": "digitador.global@computoarequipa.gob.pe",
                "contrasena": "Digitador.Global2026",
            })
            assert r.status_code == 200, r.text
            cls.headers = {"Authorization": f"Bearer {r.json()['token']}"}

    def _post(self, mesa: str, total_votantes: int, **extra) -> dict:
        payload = {
            "numero_mesa": mesa,
            "votos_distrital": list(VOTOS),
            "ocr_confidence": 0.95,
            "image_url": f"http://localhost/storage/{mesa}.webp",
            "total_votantes": total_votantes,
            **PIE, **extra,
        }
        with TestClient(app) as c:
            r = c.post("/api/actas", json=payload, headers=self.headers)
        return r

    def test_registro_descuadrado_se_guarda_observado(self):
        """Σ 160 + pie 17 = 177 ≠ papel 230 → 200 (antes 409) + OBSERVADA."""
        r = self._post("100001", total_votantes=230)
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        self.assertTrue(body["requires_review"])
        self.assertEqual(body["status"], "requires_review")
        self.assertIn("Suma calculada (177)", body["observacion"])
        self.assertIn("total del papel (230)", body["observacion"])

        # Persistido UNA sola vez: pie por nivel == consolidado derivado
        # (nunca sumados ni duplicados), sin columnas fantasma.
        db = SessionLocal()
        try:
            meta = (db.query(ActaMetadata)
                    .filter(ActaMetadata.table_id == body["id"]).one())
            self.assertEqual(meta.blancos_distrital, 10)
            self.assertEqual(meta.nulos_distrital, 5)
            self.assertEqual(meta.impugnados_distrital, 2)
            self.assertEqual(meta.votos_blancos, 10)
            self.assertEqual(meta.votos_nulos, 5)
            self.assertEqual(meta.votos_impugnados, 2)
            self.assertEqual(meta.total_votantes, 230)
            self.assertEqual(meta.blancos_regional, 0)
        finally:
            db.close()

    def test_rectificacion_cuadrada_contabiliza(self):
        """Observada → PUT con el total corregido + verified → procesada."""
        r = self._post("100002", total_votantes=230)
        self.assertEqual(r.status_code, 200, r.text)
        acta_id = r.json()["id"]

        with TestClient(app) as c:
            r2 = c.put(f"/api/actas/{acta_id}", json={
                "votos_distrital": list(VOTOS),
                "blancos_distrital": PIE["votos_blancos"],
                "nulos_distrital": PIE["votos_nulos"],
                "impugnados_distrital": PIE["votos_impugnados"],
                "total_votantes": 177,
                "verified": True,
                "motivo": "Cotejo contra el acta física",
            }, headers=self.headers)
        self.assertEqual(r2.status_code, 200, r2.text)
        body = r2.json()
        self.assertFalse(body["requires_review"])
        self.assertEqual(body["status"], "processed")
        self.assertIsNone(body["observacion"])
        self.assertEqual(body["blancos_distrital"], 10)
        self.assertEqual(body["votos_blancos"], 10)

    def test_registro_cuadrado_contabiliza_directo(self):
        r = self._post("100003", total_votantes=177)
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        self.assertFalse(body["requires_review"])
        self.assertEqual(body["status"], "processed")
        self.assertIsNone(body["observacion"])

    def test_r2_exceso_de_padron_sigue_bloqueando(self):
        db = SessionLocal()
        try:
            _mesa(db, "100004", habiles=100)
        finally:
            db.close()
        r = self._post("100004", total_votantes=200)
        self.assertEqual(r.status_code, 409, r.text)
        self.assertEqual(r.json()["detail"]["regla"], "R2_TOPE_ELECTORES")

    def test_autoguardado_parcial_no_pisa_el_pie(self):
        """PUT sin verified: corrige el pie, cuadra, y no altera el estado."""
        r = self._post("100005", total_votantes=177)
        self.assertEqual(r.status_code, 200, r.text)
        acta_id = r.json()["id"]

        with TestClient(app) as c:
            r2 = c.put(f"/api/actas/{acta_id}", json={
                "votos_distrital": list(VOTOS),
                "blancos_distrital": 11,
                "nulos_distrital": 4,
                "impugnados_distrital": 2,
                "total_votantes": 177,
                "verified": False,
            }, headers=self.headers)
        self.assertEqual(r2.status_code, 200, r2.text)
        body = r2.json()
        self.assertEqual(body["status"], "processed")   # estado intacto
        self.assertEqual((body["blancos_distrital"],
                          body["nulos_distrital"]), (11, 4))
        self.assertEqual((body["votos_blancos"], body["votos_nulos"]),
                         (11, 4))  # consolidado reconstruido


def main() -> int:
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    resultado = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if resultado.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
