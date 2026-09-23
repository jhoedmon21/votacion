"""Detección de cambios entre dos capturas del mismo ámbito del JNE.

Responde una pregunta distinta de «¿son idénticas?»:

    ¿qué candidato entró, cuál salió y a quién le cambió el estado?

La identidad de un candidato **no se puede resolver sólo por DNI**: cuando el
JNE retira o excluye a alguien le borra la foto, y con ella se va el DNI y el
nombre (en el archivo hay 26 candidatos así). Por eso el emparejamiento va por
pasos decrecientes de confianza:

    1. DNI, cuando ambas capturas lo traen
    2. posición en la lista
    3. nombre completo normalizado

Gracias a eso un candidato anonimizado se reporta como *datos cambiados* —que
es lo que ocurrió— en vez de como un retirado más un nuevo, que es lo que
reportaría una comparación por igualdad de campos.
"""
from __future__ import annotations

import json
import re
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

# Sólo quien está en carrera cuenta para el cómputo: una transición desde o
# hacia este estado es la que exige mirar.
EN_CARRERA = "INSCRITO"

NIVELES = ("regional", "provincial", "distrital")

TIPOS = (
    "ambito_nuevo",
    "ambito_retirado",
    "organizacion_nueva",
    "organizacion_retirada",
    "candidato_nuevo",
    "candidato_retirado",
    "estado_cambiado",
    "datos_cambiados",
)

TIPOS_DE_ORGANIZACION = ("organizacion_nueva", "organizacion_retirada")
TIPOS_DE_AMBITO = ("ambito_nuevo", "ambito_retirado")


@dataclass(frozen=True)
class Cambio:
    """Un cambio concreto, con lo suficiente para leerlo sin abrir los JSON."""

    tipo: str
    ambito: str  # "distrital:040119"
    organizacion: str = ""
    cargo: str | None = None
    anterior: str | None = None
    nuevo: str | None = None
    detalle: str = ""

    @property
    def critico(self) -> bool:
        """¿Cambia quién está en carrera? Es lo que hay que mirar el día D."""
        if self.tipo in TIPOS_DE_AMBITO:
            return True
        if self.tipo in TIPOS_DE_ORGANIZACION:
            return True
        if self.tipo == "candidato_nuevo":
            return (self.nuevo or "").upper() == EN_CARRERA
        if self.tipo == "candidato_retirado":
            return (self.anterior or "").upper() == EN_CARRERA
        if self.tipo == "estado_cambiado":
            return EN_CARRERA in ((self.anterior or "").upper(), (self.nuevo or "").upper())
        return False  # datos_cambiados: cambia cómo se ve, no quién compite

    def __str__(self) -> str:
        if self.tipo in TIPOS_DE_AMBITO:
            return f"{self.tipo}: {self.ambito}"
        cabeza = f"{self.tipo}: {self.organizacion}"
        if self.cargo:
            cabeza += f" · {self.cargo}"
        if self.tipo == "estado_cambiado":
            cabeza += f" · {self.anterior} -> {self.nuevo}"
        if self.detalle:
            cabeza += f" · {self.detalle}"
        marca = "!" if self.critico else "·"
        return f"{marca} {cabeza}"


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
def normalizar_nombre(texto: str | None) -> str:
    """Nombre comparable: sin acentos, sin puntuación, en mayúsculas."""
    plano = unicodedata.normalize("NFKD", texto or "")
    plano = "".join(c for c in plano if not unicodedata.combining(c))
    return " ".join(re.sub(r"[^A-Za-z0-9]+", " ", plano).upper().split())


def clave_ambito(datos: dict, nivel: str | None = None) -> str:
    return f"{datos.get('nivel') or nivel}:{datos.get('ubigeo')}"


def leer_captura(base: Path) -> dict[str, dict]:
    """Todas las capturas de un directorio, indexadas por `nivel:ubigeo`."""
    capturas: dict[str, dict] = {}
    for nivel in NIVELES:
        carpeta = base / nivel
        if not carpeta.exists():
            continue
        for archivo in sorted(carpeta.glob("*.json")):
            try:
                datos = json.loads(archivo.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                continue
            capturas[clave_ambito(datos, nivel)] = datos
    return capturas


def _posicion(candidato: dict):
    return candidato.get("posicion")


def _candidatos(organizacion: dict) -> list[dict]:
    return [c for c in (organizacion.get("candidatos") or []) if isinstance(c, dict)]


def describir(candidato: dict, con_estado: bool = True) -> str:
    """Etiqueta legible de un candidato, sin inventar lo que el JNE borró.

    ``con_estado=False`` cuando quien llama ya muestra el estado (p. ej. un
    cambio de estado, donde se lee «INSCRITO -> TACHADO»).
    """
    nombre = (candidato.get("nombre_completo") or "").strip() or "(sin nombre)"
    partes = [nombre]
    if con_estado and candidato.get("estado"):
        partes.append(str(candidato["estado"]))
    if (candidato.get("dni") or "").strip():
        partes.append(f"DNI {candidato['dni']}")
    if _posicion(candidato) is not None:
        partes.append(f"n.º {_posicion(candidato)}")
    return " · ".join(partes)


def _campos_cambiados(anterior: dict, nuevo: dict) -> str:
    """Diferencias de identidad (no de estado) entre dos capturas del mismo candidato."""
    cambios: list[str] = []
    for campo, etiqueta in (("dni", "DNI"), ("nombre_completo", "nombre"), ("posicion", "posición")):
        antes = anterior.get(campo)
        ahora = nuevo.get(campo)
        if (antes or "") == (ahora or ""):
            continue
        cambios.append(f"{etiqueta} {antes or '(vacío)'!r} -> {ahora or '(vacío)'!r}")
    return "; ".join(cambios)


# ---------------------------------------------------------------------------
# Emparejamiento
# ---------------------------------------------------------------------------
def emparejar(anteriores: list[dict], nuevos: list[dict]):
    """Empareja candidatos del mismo (organización, cargo).

    Devuelve `(parejas, sólo_anteriores, sólo_nuevos)`. El orden de los pasos
    importa: el DNI es el más fiable, pero desaparece justo cuando alguien sale
    de la carrera, así que la posición queda de respaldo.

    Ese respaldo por posición es deliberadamente estrecho: **sólo** empareja si a
    alguno de los dos le falta el nombre, que es la huella de un candidato
    anonimizado al salir de la carrera. Si ambos tienen nombre y no coincide, son
    personas distintas aunque compartan el número de lista, y ocultarlo sería
    tapar un cambio de candidato: se reportan como retirado y nuevo.

    Se empareja uno a uno, sin reutilizar candidatos: si dos capturas tienen el
    mismo nombre repetido en la misma lista, se consumen en orden.
    """
    parejas: list[tuple[dict, dict]] = []
    quedan_anteriores, quedan_nuevos = list(anteriores), list(nuevos)

    def consumir(coincide) -> None:
        for anterior in list(quedan_anteriores):
            for nuevo in list(quedan_nuevos):
                if coincide(anterior, nuevo):
                    parejas.append((anterior, nuevo))
                    quedan_anteriores.remove(anterior)
                    quedan_nuevos.remove(nuevo)
                    break

    def dni(valor: dict) -> str:
        return (valor.get("dni") or "").strip()

    def anonimo(valor: dict) -> bool:
        return not normalizar_nombre(valor.get("nombre_completo"))

    consumir(lambda a, b: bool(dni(a)) and dni(a) == dni(b))
    consumir(
        lambda a, b: _posicion(a) is not None
        and _posicion(a) == _posicion(b)
        and (anonimo(a) or anonimo(b))
    )
    consumir(
        lambda a, b: bool(normalizar_nombre(a.get("nombre_completo")))
        and normalizar_nombre(a.get("nombre_completo"))
        == normalizar_nombre(b.get("nombre_completo"))
    )
    return parejas, quedan_anteriores, quedan_nuevos


def comparar_ambito(anterior: dict, nuevo: dict) -> list[Cambio]:
    """Cambios de contenido de un ámbito (organizaciones y candidatos)."""
    ambito = clave_ambito(nuevo) or clave_ambito(anterior)
    salida: list[Cambio] = []

    organizaciones_anteriores = {
        o.get("organizacionPolitica"): o for o in anterior.get("organizaciones") or []
    }
    organizaciones_nuevas = {
        o.get("organizacionPolitica"): o for o in nuevo.get("organizaciones") or []
    }

    for nombre in sorted(set(organizaciones_anteriores) - set(organizaciones_nuevas)):
        cuantos = len(_candidatos(organizaciones_anteriores[nombre]))
        salida.append(Cambio(
            "organizacion_retirada", ambito, nombre,
            detalle=f"{cuantos} candidatos que ya no se publican",
        ))
    for nombre in sorted(set(organizaciones_nuevas) - set(organizaciones_anteriores)):
        cuantos = len(_candidatos(organizaciones_nuevas[nombre]))
        salida.append(Cambio(
            "organizacion_nueva", ambito, nombre,
            detalle=f"{cuantos} candidatos",
        ))

    for nombre in sorted(set(organizaciones_anteriores) & set(organizaciones_nuevas)):
        por_cargo_anteriores: dict = defaultdict(list)
        por_cargo_nuevos: dict = defaultdict(list)
        for candidato in _candidatos(organizaciones_anteriores[nombre]):
            por_cargo_anteriores[candidato.get("cargo")].append(candidato)
        for candidato in _candidatos(organizaciones_nuevas[nombre]):
            por_cargo_nuevos[candidato.get("cargo")].append(candidato)

        cargos = sorted(
            set(por_cargo_anteriores) | set(por_cargo_nuevos),
            key=lambda c: (c is None, c or ""),
        )
        for cargo in cargos:
            parejas, faltantes, agregados = emparejar(
                por_cargo_anteriores.get(cargo, []), por_cargo_nuevos.get(cargo, [])
            )
            for candidato in faltantes:
                salida.append(Cambio(
                    "candidato_retirado", ambito, nombre, cargo,
                    anterior=candidato.get("estado"), detalle=describir(candidato),
                ))
            for candidato in agregados:
                salida.append(Cambio(
                    "candidato_nuevo", ambito, nombre, cargo,
                    nuevo=candidato.get("estado"), detalle=describir(candidato),
                ))
            for antes, ahora in parejas:
                if (antes.get("estado") or "").upper() != (ahora.get("estado") or "").upper():
                    salida.append(Cambio(
                        "estado_cambiado", ambito, nombre, cargo,
                        anterior=antes.get("estado"), nuevo=ahora.get("estado"),
                        detalle=describir(ahora, con_estado=False),
                    ))
                    continue
                diferencia = _campos_cambiados(antes, ahora)
                if diferencia:
                    salida.append(Cambio(
                        "datos_cambiados", ambito, nombre, cargo,
                        anterior=antes.get("estado"), nuevo=ahora.get("estado"),
                        detalle=diferencia,
                    ))
    return salida


def comparar(anteriores: dict[str, dict], nuevos: dict[str, dict]) -> list[Cambio]:
    """Cambios entre dos capturas completas, ámbito por ámbito."""
    salida: list[Cambio] = []
    for clave in sorted(set(anteriores) - set(nuevos)):
        salida.append(Cambio("ambito_retirado", clave,
                             detalle=describir_ambito(anteriores[clave])))
    for clave in sorted(set(nuevos) - set(anteriores)):
        salida.append(Cambio("ambito_nuevo", clave,
                             detalle=describir_ambito(nuevos[clave])))
    for clave in sorted(set(anteriores) & set(nuevos)):
        salida.extend(comparar_ambito(anteriores[clave], nuevos[clave]))
    return salida


def describir_ambito(datos: dict) -> str:
    organizaciones = datos.get("organizaciones") or []
    candidatos = sum(len(_candidatos(o)) for o in organizaciones)
    etiqueta = datos.get("distrito") or datos.get("provincia") or "AREQUIPA"
    return f"{etiqueta}: {len(organizaciones)} organizaciones, {candidatos} candidatos"


def resumen(cambios: list[Cambio]) -> Counter:
    return Counter(c.tipo for c in cambios)


def formatear(cambios: list[Cambio], solo_criticos: bool = False) -> list[str]:
    """Líneas del informe, agrupadas por ámbito."""
    seleccionados = [c for c in cambios if c.critico or not solo_criticos]
    if not seleccionados:
        return []
    por_ambito: dict[str, list[Cambio]] = defaultdict(list)
    for cambio in seleccionados:
        por_ambito[cambio.ambito].append(cambio)

    lineas: list[str] = []
    for ambito in sorted(por_ambito):
        del_ambito = [c for c in por_ambito[ambito] if c.tipo in TIPOS_DE_AMBITO]
        if del_ambito:
            for cambio in del_ambito:
                lineas.append(f"  {cambio}")
            continue
        lineas.append(f"  {ambito}")
        for cambio in por_ambito[ambito]:
            lineas.append(f"      {cambio}")
    return lineas
