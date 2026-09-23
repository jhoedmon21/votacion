"""Orden oficial de las organizaciones políticas en la cédula de sufragio 2026.

La cédula no lista a los partidos por orden alfabético —que es como los
devuelve el JNE en su API— sino en el orden que la ONPE sorteó el **10 de
junio de 2026** con un bolillero (Resolución Jefatural n.° 000116-2026-JN/ONPE):

* **Bloque superior**: los 41 partidos políticos y 5 alianzas electorales
  nacionales, en un orden único para todo el país (son 46 entradas y no 44
  porque cada alianza cuenta aparte).
* **Bloque inferior**: los movimientos regionales, sorteados en la ODPE de cada
  capital de departamento. Para Arequipa ese sorteo puso a ``YO AREQUIPA``,
  ``AREQUIPA AVANCEMOS``, ``AREQUIPA TRADICION Y FUTURO`` y
  ``FUERZA AREQUIPEÑA`` en ese orden (es el bloque que se ve al pie de la
  cédula regional de Arequipa).

Fuente del bloque nacional y de la regla de bloques:
https://www.tvperu.gob.pe/noticias/politica/erm-2026-asi-quedaron-ubicadas-las-organizaciones-politicas-en-la-cedula-de-sufragio

Por qué importa en este sistema
-------------------------------
``sort_order`` es la posición de la organización **en la columna del acta**
(ver ``docs/schemas/plantilla-acta-v1.schema.json`` y ``load_jne_data``), y los
votos digitados viajan identificados por esa posición. Por eso ``sort_order`` y
el índice del arreglo ``organizaciones`` de los JSON de oferta tienen que ser el
mismo número: si se compactara o se reordenara sólo uno de los dos, el voto
digitado se guardaría contra el partido vecino.

Uso::

    from app.core.orden_cedula import ordenar_organizaciones, clave_orden

    ordenar_organizaciones(data["organizaciones"])   # ordena in place
    sorted(orgs, key=lambda o: clave_orden(o["organizacionPolitica"]))
"""
from __future__ import annotations

import re
import unicodedata
from typing import Iterable, Mapping

# --- bloque nacional: sorteo ONPE del 10-jun-2026 ---------------------------
# Transcripción literal de la lista publicada por la ONPE, en su orden.
ORDEN_NACIONAL_2026: tuple[str, ...] = (
    "Alianza para el Progreso",
    "Partido Político Nacional Perú Libre",
    "Partido por el Entendimiento, Recuperación y Unificación del Perú",
    "Salvemos al Perú",
    "Juntos por el Perú",
    "Partido Político Integridad Democrática",
    "Partido Frente de la Esperanza 2021",
    "Acción Popular",
    "Cooperación, Verdad y Honradez",
    "Partido Cívico Obras",
    "Partido Político Todo con el Pueblo",
    "Coalición Transformadora Tierra Verde",
    "Renovación Popular Perú",
    "Fe en el Perú",
    "Partido Demócrata Verde",
    "Alianza Regional por el Perú",
    "Partido Político PRIN",
    "Un Camino Diferente",
    "Partido Popular Cristiano - PPC",
    "Visión Perú",
    "Frente Popular Agrícola FIA del Perú",
    "Fuerza Popular",
    "Avanza País - Partido de Integración Social",
    "Libertad Popular",
    "Partido de los Trabajadores y Emprendedores PTE Perú - Comunidad Política Inka Perú",
    "Partido Político Perú Primero",
    "Partido Demócrata Unido Perú",
    "Partido Patriótico del Perú",
    "Fuerza Ciudadana",
    "Partido Unidad y Paz",
    "Batalla Perú",
    "Partido País para Todos",
    "Ahora Nación - AN",
    "Primero la Gente - Comunidad, Ecología, Libertad y Progreso",
    "Progresemos",
    "Partido del Buen Gobierno",
    "Partido Político Pueblo Consciente",
    "Partido Político Perú Acción",
    "Partido Democrático Somos Perú",
    "Partido Aprista Peruano",
    "Podemos Perú",
    "Alianza Electoral Venceremos",
    "Partido Morado",
    "Perú Moderno",
    "Partido SICREO",
    "Partido Político ADP",
)

# --- bloque inferior: sorteo de la ODPE Arequipa (movimientos regionales) ----
# Cada entrada es la forma oficial seguida de las variantes con que el JNE
# publica la misma organización (el nombre del JNE llega con prefijo
# "MOVIMIENTO REGIONAL" o con la coma que la ONPE omite).
MOVIMIENTOS_AREQUIPA_2026: tuple[tuple[str, ...], ...] = (
    ("Yo Arequipa", "Movimiento Regional Yo Arequipa"),
    ("Arequipa Avancemos", "Movimiento Regional Arequipa Avancemos",
     "Movimiento Regional Arequipa Avancemos - MRA"),
    ("Arequipa Tradición y Futuro", "Arequipa, Tradición y Futuro",
     "Movimiento Regional Arequipa Tradición y Futuro"),
    ("Fuerza Arequipeña", "Movimiento Regional Fuerza Arequipeña",
     "Partido Político Regional Fuerza Arequipeña"),
)

# Alias sueltos del bloque nacional: cómo lo publica el JNE frente a la ONPE.
# Las tres últimas entradas son los nombres cortos del mock
# ``candidatos_arequipa.json``, que usa la marca en lugar de la razón social.
ALIAS_NACIONAL: Mapping[str, str] = {
    "PERU LIBRE": "Partido Político Nacional Perú Libre",
    "RENOVACION POPULAR": "Renovación Popular Perú",
    "SOMOS PERU": "Partido Democrático Somos Perú",
    "PARTIDO DEMOCRATICO SOMOS PERU": "Partido Democrático Somos Perú",
    "FRENTE POPULAR AGRICOLA FIA DEL PERU": "Frente Popular Agrícola FIA del Perú",
    "ALIANZA ELECTORAL VENCEREMOS": "Alianza Electoral Venceremos",
    "PARTIDO POLITICO NACIONAL PERU LIBRE": "Partido Político Nacional Perú Libre",
    "PARTIDO POLITICO PERU PRIMERO": "Partido Político Perú Primero",
    "PARTIDO POLITICO PUEBLO CONSCIENTE": "Partido Político Pueblo Consciente",
    "PARTIDO POLITICO INTEGRIDAD DEMOCRATICA": "Partido Político Integridad Democrática",
    "AVANZA PAIS - PARTIDO DE INTEGRACION SOCIAL": "Avanza País - Partido de Integración Social",
    "PARTIDO DE LOS TRABAJADORES Y EMPRENDEDORES PTE PERU - COMUNIDAD POLITICA INKA PERU":
        "Partido de los Trabajadores y Emprendedores PTE Perú - Comunidad Política Inka Perú",
}

# Bloques de la cédula, en su orden físico de arriba hacia abajo.
BLOQUE_NACIONAL = 0
BLOQUE_REGIONAL = 1
BLOQUE_DESCONOCIDO = 2


def normalizar(nombre: str) -> str:
    """Forma canónica para comparar nombres de organizaciones.

    Mayúsculas, sin tildes ni signos: ``Ahora Nación – AN`` y ``AHORA NACION -
    AN`` son la misma organización, y ``Arequipa, Tradición y Futuro`` también
    se compara contra la variante con prefijo ``MOVIMIENTO REGIONAL``.
    """
    base = unicodedata.normalize("NFKD", nombre or "")
    base = "".join(c for c in base if not unicodedata.combining(c))
    base = base.upper().replace("–", "-").replace("—", "-")
    base = re.sub(r"[^A-Z0-9]+", " ", base)
    return " ".join(base.split())


# Posición oficial en el bloque nacional (por nombre oficial de la ONPE).
SORTEO: dict[str, int] = {
    normalizar(nombre): posicion
    for posicion, nombre in enumerate(ORDEN_NACIONAL_2026, start=1)
}

_MOVIMIENTOS: dict[str, int] = {
    normalizar(nombre): posicion
    for posicion, variantes in enumerate(MOVIMIENTOS_AREQUIPA_2026, start=1)
    for nombre in variantes
}

_CANONICO_ALIAS: dict[str, str] = {
    normalizar(variante): normalizar(oficial)
    for variante, oficial in ALIAS_NACIONAL.items()
}


def bloque_y_posicion(nombre: str) -> tuple[int, int, str]:
    """Clave de orden: ``(bloque, posición, nombre normalizado)``.

    Lo que no se reconoce —una organización local que no pasó por ninguno de los
    dos sorteos— cae al final en orden alfabético: mejor una cola visible que
    mezclarla en un bloque oficial que no le corresponde.
    """
    clave = normalizar(nombre)
    clave = _CANONICO_ALIAS.get(clave, clave)

    posicion = SORTEO.get(clave)
    if posicion is not None:
        return BLOQUE_NACIONAL, posicion, clave

    posicion = _MOVIMIENTOS.get(clave)
    if posicion is not None:
        return BLOQUE_REGIONAL, posicion, clave

    return BLOQUE_DESCONOCIDO, 0, clave


def clave_orden(nombre: str) -> tuple[int, int, str]:
    """Atajo de ``bloque_y_posicion`` para usar como ``key=`` de ``sorted``."""
    return bloque_y_posicion(nombre)


def posicion_en_cedula(nombre: str) -> int | None:
    """Posición de la organización en su bloque oficial (``None`` si no está).

    Se expone separada de ``clave_orden`` porque sirve para mostrar en pantalla
    "casita 21 de la cédula", no para ordenar (el orden dentro de un ámbito lo
    fija el índice del acta, que omite a quien no está en carrera).
    """
    bloque, posicion, _ = bloque_y_posicion(nombre)
    return None if bloque == BLOQUE_DESCONOCIDO else posicion


def ordenar_organizaciones(
    organizaciones: list, campo: str = "organizacionPolitica"
) -> list:
    """Ordena la lista de organizaciones de un ámbito **in place**.

    Es un orden estable: dos entradas equivalentes (sólo puede pasar entre
    organizaciones no reconocidas) conservan el orden relativo que traían.
    """
    organizaciones.sort(key=lambda o: clave_orden((o or {}).get(campo) or ""))
    return organizaciones


def esta_ordenada(organizaciones: Iterable, campo: str = "organizacionPolitica") -> bool:
    """``True`` si la lista ya viene en orden de cédula."""
    claves = [clave_orden((o or {}).get(campo) or "") for o in organizaciones]
    return all(a <= b for a, b in zip(claves, claves[1:]))


def no_reconocidas(organizaciones: Iterable, campo: str = "organizacionPolitica") -> list[str]:
    """Nombres que no aparecen en ninguno de los dos sorteos (para reportar)."""
    vistas = {
        (o or {}).get(campo) or ""
        for o in organizaciones
    }
    return sorted(n for n in vistas if bloque_y_posicion(n)[0] == BLOQUE_DESCONOCIDO and n)
