"""Convención de ubigeo (6 dígitos, INEI/RENIEC) usada en todo el proyecto.

Un local de votación tiene ubigeo distrital (p. ej. ``040112`` Paucarpata).
La oferta electoral de las otras elecciones que se digita en esa misma acta no
es distrital sino de su ámbito superior:

    distrito 040112  ->  provincia 040100  ->  departamento 040000

Es la inversa del prefijo jerárquico que ya usa ``auth._prefijo_alcance`` y la
misma codificación con la que se nombran los archivos del crawler
(``regional/040000.json``, ``provincial/040100.json``, ``distrital/040112.json``).
"""
from __future__ import annotations

# Niveles del prototipo. El nombre es el que viaja en las peticiones
# (``scope`` de analytics y ``candidate_type`` de la tabla records).
NIVELES = ("district", "provincial", "regional")

# El formulario habla de tipos de elección; la base, de niveles.
TIPO_A_NIVEL = {
    "DISTRITAL": "district",
    "DISTRICT": "district",
    "PROVINCIAL": "provincial",
    "REGIONAL": "regional",
}

# Ubigeos de nivel superior derivados de un distrito.
SUFIJOS = {"district": None, "provincial": "00", "regional": "0000"}


def nivel_desde_tipo(tipo: str) -> str | None:
    """``'PROVINCIAL'`` -> ``'provincial'``. ``None`` si el tipo no existe."""
    return TIPO_A_NIVEL.get((tipo or "").strip().upper())


def ubigeo_de_nivel(ubigeo: str | None, nivel: str) -> str:
    """Ubigeo del ámbito de ``nivel`` al que pertenece ``ubigeo``.

    >>> ubigeo_de_nivel("040112", "provincial")
    '040100'
    >>> ubigeo_de_nivel("040112", "regional")
    '040000'
    """
    ubigeo = (ubigeo or "").strip()
    sufijo = SUFIJOS.get(nivel)
    if sufijo is None or len(ubigeo) != 6:
        return ubigeo
    return ubigeo[: 6 - len(sufijo)] + sufijo


def ubigeos_de_nivel(ubigeos, nivel: str) -> set[str]:
    """Aplica ``ubigeo_de_nivel`` a una colección, sin repetidos."""
    return {ubigeo_de_nivel(u, nivel) for u in ubigeos if u}


def candidatos_del_ambito(db, modelo, ubigeo: str | None):
    """Query de la oferta electoral de un ámbito concreto.

    Es el único filtro que impide que la organización homónima de otro ámbito
    se lleve los votos: los nombres de partido se repiten entre distritos.
    """
    return db.query(modelo).filter(modelo.ubigeo == (ubigeo or ""))
