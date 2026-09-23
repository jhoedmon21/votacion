"""Pruebas de las reglas ONPE del validador de actas.

Se ejecutan sin dependencias extra (no hay pytest instalado en este entorno):

    cd backend && python tests/test_acta_validator.py

También son compatibles con pytest si se instala más adelante.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.services.acta_validator import (  # noqa: E402
    ColumnaActa,
    puede_contabilizar,
    validar_acta,
)


def acta_distrital_consistente() -> tuple:
    alcalde = ColumnaActa(
        columna="ALCALDE",
        votos={"0": 100, "1": 60, "2": 40},
        votos_blancos=10,
        votos_nulos=5,
        votos_impugnados=2,
        total_votantes=217,
    )
    # La columna de regidores reparte distinto (voto preferencial / voto nulo
    # sólo en regidores) pero coincide en el total de votantes: caso normal.
    regidores = ColumnaActa(
        columna="REGIDORES",
        votos={"0": 90, "1": 70, "2": 35},
        votos_blancos=12,
        votos_nulos=8,
        votos_impugnados=2,
        total_votantes=217,
    )
    return alcalde, regidores


# ---------------------------------------------------------------------------
# Reglas matemáticas básicas
# ---------------------------------------------------------------------------
def test_acta_consistente():
    alcalde, regidores = acta_distrital_consistente()
    resultado = validar_acta("DISTRITAL", 250, [alcalde, regidores])

    assert resultado.consistente is True, resultado.to_dict()
    assert resultado.estado_sugerido == "DIGITADA"
    assert resultado.puede_enviar is True
    assert resultado.diferencia == 0
    assert resultado.total_votantes == 217
    assert resultado.suma_votos == 200
    assert resultado.participacion_pct == 86.8
    assert resultado.columna_principal == "ALCALDE"
    assert resultado.hallazgos == [], [h.to_dict() for h in resultado.hallazgos]


def test_r1_suma_no_cuadra():
    alcalde = ColumnaActa(
        columna="ALCALDE",
        votos={"0": 100, "1": 60, "2": 40},
        votos_blancos=10,
        votos_nulos=5,
        votos_impugnados=2,
        total_votantes=230,          # el papel dice 230 pero la suma es 217
    )
    resultado = validar_acta("DISTRITAL", 250, [alcalde])

    assert resultado.consistente is False
    assert resultado.estado_sugerido == "OBSERVADA"
    assert resultado.puede_enviar is False
    assert resultado.diferencia == 13
    reglas = [h.regla for h in resultado.bloqueantes]
    assert "R1_SUMA_VOTOS" in reglas


def test_r1_descuadre_en_columna_secundaria_bloquea():
    """Regresión: la regla R1 se evalúa POR COLUMNA del acta.

    El papel es un único documento con dos cómputos independientes (alcalde y
    regidores). Antes, un acta con la columna de alcalde cuadrada y la de
    regidores descuadrada se daba por consistente y `puede_contabilizar`
    autorizaba el envío; la base la habría terminado rechazando en el trigger.
    """
    alcalde = ColumnaActa(
        columna="ALCALDE",
        votos={"0": 100, "1": 60},
        total_votantes=160,
    )
    regidores = ColumnaActa(
        columna="REGIDORES",
        votos={"0": 40},
        total_votantes=200,          # el papel dice 200, las casillas suman 40
    )
    resultado = validar_acta("DISTRITAL", 250, [alcalde, regidores])

    assert resultado.diferencia == 0, "la columna principal sí cuadra"
    assert resultado.consistente is False, "basta que una columna descuadre"
    assert resultado.estado_sugerido == "OBSERVADA"
    assert resultado.puede_enviar is False
    assert resultado.descuadres == [
        {"columna": "REGIDORES", "total_votantes": 200, "suma": 40, "diferencia": 160}
    ], resultado.descuadres

    permitido, motivo = puede_contabilizar(resultado)
    assert permitido is False
    assert "REGIDORES" in motivo
    assert "+160" in motivo


def test_r2_tope_electores():
    alcalde = ColumnaActa(
        columna="ALCALDE",
        votos={"0": 200, "1": 50},
        votos_blancos=5,
        votos_nulos=3,
        votos_impugnados=2,
        total_votantes=260,          # la mesa sólo tiene 250 electores hábiles
    )
    resultado = validar_acta("DISTRITAL", 250, [alcalde])

    assert resultado.consistente is True       # la suma sí cuadra
    assert resultado.puede_enviar is False     # pero excede el padrón
    assert resultado.estado_sugerido == "OBSERVADA"
    assert any(h.regla == "R2_TOPE_ELECTORES" for h in resultado.bloqueantes)


def test_r3_columnas_incoherentes_es_advertencia():
    alcalde, regidores = acta_distrital_consistente()
    # Columna internamente consistente (193 + 12 + 8 + 2 = 215) pero con 2
    # votantes menos que la de alcalde: caso real cuando alguien anula su voto
    # de regidores pero vota válido para alcalde.
    regidores_incoherente = ColumnaActa(
        columna="REGIDORES",
        votos={"0": 88, "1": 70, "2": 35},
        votos_blancos=12,
        votos_nulos=8,
        votos_impugnados=2,
        total_votantes=215,
    )
    resultado = validar_acta("DISTRITAL", 250, [alcalde, regidores_incoherente])

    assert resultado.consistente is True
    assert resultado.puede_enviar is True      # no bloquea, sólo avisa
    assert any(
        h.regla == "R3_COLUMNAS_INCOHERENTES" and h.severidad == "ADVERTENCIA"
        for h in resultado.hallazgos
    )
    assert any("REGIDORES" == h.columna for h in resultado.hallazgos)


def test_votos_negativos_bloquean():
    alcalde = ColumnaActa(
        columna="ALCALDE",
        votos={"0": -5, "1": 100},
        total_votantes=95,
    )
    resultado = validar_acta("DISTRITAL", 250, [alcalde])
    assert resultado.puede_enviar is False
    assert any(h.regla == "R1_SUMA_VOTOS" for h in resultado.bloqueantes)


# ---------------------------------------------------------------------------
# Evidencia, duplicidad y estado del acta
# ---------------------------------------------------------------------------
def test_foto_ausente_avisa_pero_no_bloquea():
    alcalde, regidores = acta_distrital_consistente()
    resultado = validar_acta("DISTRITAL", 250, [alcalde, regidores], foto_presente=False)

    assert resultado.puede_enviar is True
    assert resultado.estado_sugerido == "DIGITADA"
    assert any(h.regla == "R5_FOTO_AUSENTE" for h in resultado.hallazgos)


def test_acta_duplicada_bloquea():
    alcalde, regidores = acta_distrital_consistente()
    resultado = validar_acta("DISTRITAL", 250, [alcalde, regidores], acta_ya_registrada=True)

    assert resultado.puede_enviar is False
    assert resultado.estado_sugerido == "OBSERVADA"
    assert any(h.regla == "R4_ACTA_DUPLICADA" for h in resultado.bloqueantes)


def test_foto_repetida_bloquea():
    alcalde, regidores = acta_distrital_consistente()
    resultado = validar_acta("DISTRITAL", 250, [alcalde, regidores], foto_repetida=True)
    assert any(h.regla == "R4_ACTA_DUPLICADA" for h in resultado.bloqueantes)


def test_acta_en_cero_avisa():
    alcalde = ColumnaActa(columna="ALCALDE", votos={"0": 0}, total_votantes=0)
    resultado = validar_acta("DISTRITAL", 250, [alcalde])
    assert resultado.consistente is True
    assert any(h.severidad == "ADVERTENCIA" for h in resultado.hallazgos)


def test_ilegible_bloquea():
    alcalde, regidores = acta_distrital_consistente()
    resultado = validar_acta("DISTRITAL", 250, [alcalde, regidores], ilegible=True)
    assert resultado.puede_enviar is False
    assert any(h.regla == "R6_ILEGIBLE" for h in resultado.bloqueantes)


# ---------------------------------------------------------------------------
# Elección regional: la columna principal es GOBERNADOR_VICE
# ---------------------------------------------------------------------------
def test_regional_usa_columna_gobernador():
    gobernador = ColumnaActa(
        columna="GOBERNADOR_VICE",
        votos={"0": 120, "1": 80},
        votos_blancos=10,
        votos_nulos=5,
        votos_impugnados=3,
        total_votantes=218,
    )
    consejeros = ColumnaActa(
        columna="CONSEJEROS",
        votos={"0": 110, "1": 90},
        votos_blancos=10,
        votos_nulos=5,
        votos_impugnados=3,
        total_votantes=218,
    )
    resultado = validar_acta("REGIONAL", 250, [gobernador, consejeros])
    assert resultado.columna_principal == "GOBERNADOR_VICE"
    assert resultado.consistente is True
    assert resultado.total_votantes == 218


def test_falta_columna_principal_es_error():
    consejeros = ColumnaActa(columna="CONSEJEROS", total_votantes=0)
    try:
        validar_acta("REGIONAL", 250, [consejeros])
    except ValueError as exc:
        assert "GOBERNADOR_VICE" in str(exc)
    else:  # pragma: no cover
        raise AssertionError("se esperaba ValueError por falta de columna principal")


# ---------------------------------------------------------------------------
# Resolución de actas observadas
# ---------------------------------------------------------------------------
def test_puede_contabilizar():
    alcalde, regidores = acta_distrital_consistente()
    ok = validar_acta("DISTRITAL", 250, [alcalde, regidores])
    permitido, _ = puede_contabilizar(ok)
    assert permitido is True

    inconsistente = validar_acta(
        "DISTRITAL",
        250,
        [ColumnaActa(columna="ALCALDE", votos={"0": 10}, total_votantes=99)],
    )
    permitido, motivo = puede_contabilizar(inconsistente)
    assert permitido is False
    assert "no cuadra" in motivo

    permitido, motivo = puede_contabilizar(ok, bloqueantes_abiertos=1)
    assert permitido is False
    assert "bloqueante" in motivo


def main() -> int:
    pruebas = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    fallidas = 0
    for prueba in pruebas:
        try:
            prueba()
            print(f"  [ok]    {prueba.__name__}")
        except AssertionError as exc:
            fallidas += 1
            print(f"  [FALLO] {prueba.__name__}: {exc}")
        except Exception as exc:  # noqa: BLE001
            fallidas += 1
            print(f"  [ERROR] {prueba.__name__}: {type(exc).__name__}: {exc}")

    print(f"\n{len(pruebas) - fallidas}/{len(pruebas)} pruebas OK")
    return 1 if fallidas else 0


if __name__ == "__main__":
    raise SystemExit(main())
