"""Validador de actas con las reglas matemáticas de la ONPE.

Este módulo es la autoridad del sistema sobre si un acta "cuadra". Lo usan:

  * el endpoint ``POST /api/actas/validar`` (lo llama la PWA móvil antes de
    enviar), y
  * el backend PostgreSQL, que replica las mismas reglas en el trigger
    ``fn_validar_contabilizacion`` como última línea de defensa.

Reglas implementadas
--------------------
R1_SUMA_VOTOS            Σ votos por organización + blancos + nulos + impugnados
                         == total de votantes impreso en el acta.
R2_TOPE_ELECTORES        total de votantes <= electores hábiles de la mesa.
R3_COLUMNAS_INCOHERENTES Las columnas del acta (alcalde vs regidores,
                         gobernador/vice vs consejeros) no cuadran entre sí.
R4_ACTA_DUPLICADA        La mesa + tipo de elección ya tiene acta registrada, o la
                         fotografía ya fue usada (misma evidencia, dos actas).
R5_FOTO_AUSENTE          No se adjuntó la foto del acta física.
R6_ILEGIBLE              El digitador declaró campos ilegibles.
R7_FIRMA_FALTANTE        Faltan firmas de personeros en el acta física.
R8_DIFERENCIA_MANUAL     Diferencia detectada al cotejar con el papel.

Distinción clave de negocio: el sistema **guarda** el acta tal como está escrita
en el papel aunque no cuadre (queda OBSERVADA), pero **no la contabiliza** hasta
que la suma cuadre y las observaciones bloqueantes estén resueltas.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Literal

Severidad = Literal["BLOQUEANTE", "ADVERTENCIA", "INFO"]

# Columnas del acta física según la elección. CONSEJERO = Consejo Regional
# elegido POR PROVINCIA: en el sistema es un nivel propio (candidate_type
# ``consejero``), no la columna secundaria del acta regional.
COLUMNA_PRINCIPAL = {
    "REGIONAL": "GOBERNADOR_VICE",
    "CONSEJERO": "CONSEJEROS",
    "PROVINCIAL": "ALCALDE",
    "DISTRITAL": "ALCALDE",
}
COLUMNAS_POR_ELECCION = {
    "REGIONAL": ("GOBERNADOR_VICE", "CONSEJEROS"),
    "CONSEJERO": ("CONSEJEROS",),
    "PROVINCIAL": ("ALCALDE", "REGIDORES"),
    "DISTRITAL": ("ALCALDE", "REGIDORES"),
}


@dataclass(frozen=True)
class ColumnaActa:
    """Una columna del acta (bloque A o B del papel)."""

    columna: str
    votos: dict[str, int] = field(default_factory=dict)  # id/posición -> votos
    votos_blancos: int = 0
    votos_nulos: int = 0
    votos_impugnados: int = 0
    total_votantes: int = 0

    @property
    def suma_votos(self) -> int:
        return sum(self.votos.values())

    @property
    def suma_total(self) -> int:
        """Σ votos por organización + blancos + nulos + impugnados."""
        return self.suma_votos + self.votos_blancos + self.votos_nulos + self.votos_impugnados

    @property
    def diferencia(self) -> int:
        return self.total_votantes - self.suma_total


@dataclass
class Hallazgo:
    """Observación generada por una regla."""

    regla: str
    severidad: Severidad
    mensaje: str
    diferencia: int | None = None
    columna: str | None = None

    def to_dict(self) -> dict:
        return {
            "regla": self.regla,
            "severidad": self.severidad,
            "mensaje": self.mensaje,
            "diferencia": self.diferencia,
            "columna": self.columna,
        }


@dataclass
class ResultadoValidacion:
    consistente: bool
    estado_sugerido: str
    columna_principal: str
    total_votantes: int
    electores_habiles: int
    suma_votos: int
    diferencia: int
    participacion_pct: float
    hallazgos: list[Hallazgo] = field(default_factory=list)
    # Columnas que no cuadran: [{"columna", "total_votantes", "suma", "diferencia"}]
    descuadres: list[dict] = field(default_factory=list)

    @property
    def bloqueantes(self) -> list[Hallazgo]:
        return [h for h in self.hallazgos if h.severidad == "BLOQUEANTE"]

    @property
    def puede_enviar(self) -> bool:
        """El formulario móvil sólo se habilita cuando no hay bloqueantes."""
        return not self.bloqueantes

    def to_dict(self) -> dict:
        return {
            "consistente": self.consistente,
            "estado_sugerido": self.estado_sugerido,
            "columna_principal": self.columna_principal,
            "total_votantes": self.total_votantes,
            "electores_habiles": self.electores_habiles,
            "suma_votos": self.suma_votos,
            "diferencia": self.diferencia,
            "participacion_pct": self.participacion_pct,
            "puede_enviar": self.puede_enviar,
            "descuadres": self.descuadres,
            "hallazgos": [h.to_dict() for h in self.hallazgos],
        }


def columnas_de(tipo_eleccion: str) -> tuple[str, str]:
    return COLUMNAS_POR_ELECCION.get(tipo_eleccion.upper(), ("ALCALDE", "REGIDORES"))


def validar_acta(
    tipo_eleccion: str,
    electores_habiles: int,
    columnas: Iterable[ColumnaActa],
    *,
    foto_presente: bool = True,
    acta_ya_registrada: bool = False,
    foto_repetida: bool = False,
    ilegible: bool = False,
    firmas_completas: bool = True,
    diferencia_manual: int | None = None,
) -> ResultadoValidacion:
    """Evalúa todas las reglas y devuelve el veredicto + los hallazgos.

    ``consistente`` es TRUE sólo si **todas** las columnas del acta cuadran, no
    únicamente la principal: el papel trae dos cómputos independientes (alcalde
    y regidores, o gobernador/vice y consejeros) y la regla R1 se aplica a cada
    uno. Un descuadre en cualquiera de los dos impediría contabilizar el acta
    también en la base de datos, así que la API no debe autorizarla.

    ``diferencia`` sigue siendo la de la columna principal, que es la que
    resume la cabecera del acta; el detalle por columna va en ``descuadres``.
    """
    tipo = (tipo_eleccion or "").upper()
    principal = COLUMNA_PRINCIPAL.get(tipo, "ALCALDE")
    por_nombre = {c.columna: c for c in columnas}
    col_principal = por_nombre.get(principal)
    hallazgos: list[Hallazgo] = []

    # ---- R4: duplicidad (se evalúa primero: es la regla más costosa de corregir)
    if acta_ya_registrada:
        hallazgos.append(
            Hallazgo(
                "R4_ACTA_DUPLICADA",
                "BLOQUEANTE",
                "Esta mesa ya tiene un acta registrada para este tipo de elección. "
                "Sólo un COORD_PROVINCIAL puede reemplazarla.",
            )
        )
    if foto_repetida:
        hallazgos.append(
            Hallazgo(
                "R4_ACTA_DUPLICADA",
                "BLOQUEANTE",
                "La fotografía ya fue usada en otra acta (misma evidencia, distinta mesa).",
            )
        )

    if col_principal is None:
        raise ValueError(f"Falta la columna principal '{principal}' para la elección {tipo}")

    # ---- Votos negativos (guarda contra errores de digitación del formulario)
    for columna in por_nombre.values():
        negativos = {k: v for k, v in columna.votos.items() if v < 0}
        if negativos or min(columna.votos_blancos, columna.votos_nulos, columna.votos_impugnados) < 0:
            hallazgos.append(
                Hallazgo(
                    "R1_SUMA_VOTOS",
                    "BLOQUEANTE",
                    f"La columna {columna.columna} tiene votos negativos: {negativos or 'metadatos'}.",
                    columna=columna.columna,
                )
            )

    # ---- R1: consistencia de la suma, por cada columna
    for columna in por_nombre.values():
        if columna.diferencia != 0:
            severidad: Severidad = "BLOQUEANTE"
            hallazgos.append(
                Hallazgo(
                    "R1_SUMA_VOTOS",
                    severidad,
                    (
                        f"La columna {columna.columna} no cuadra: "
                        f"total de votantes {columna.total_votantes} vs "
                        f"suma {columna.suma_total} "
                        f"(Σ votos {columna.suma_votos} + blancos {columna.votos_blancos} "
                        f"+ nulos {columna.votos_nulos} + impugnados {columna.votos_impugnados}). "
                        f"Diferencia: {columna.diferencia:+d}."
                    ),
                    diferencia=columna.diferencia,
                    columna=columna.columna,
                )
            )

    # ---- R2: tope del padrón (sobre la columna principal)
    if col_principal.total_votantes > electores_habiles:
        hallazgos.append(
            Hallazgo(
                "R2_TOPE_ELECTORES",
                "BLOQUEANTE",
                (
                    f"El acta registra {col_principal.total_votantes} votantes sobre "
                    f"{electores_habiles} electores hábiles de la mesa "
                    f"(exceso de {col_principal.total_votantes - electores_habiles})."
                ),
                diferencia=col_principal.total_votantes - electores_habiles,
                columna=col_principal.columna,
            )
        )

    # ---- R3: coherencia entre columnas del mismo acta
    # Es posible (y legal) que un elector vote válido para alcalde y anule la
    # columna de regidores, así que una diferencia entre columnas es una
    # ADVERTENCIA para revisión, no un bloqueo.
    for nombre, columna in por_nombre.items():
        if nombre == col_principal.columna:
            continue
        if columna.total_votantes != col_principal.total_votantes:
            hallazgos.append(
                Hallazgo(
                    "R3_COLUMNAS_INCOHERENTES",
                    "ADVERTENCIA",
                    (
                        f"La columna {nombre} declara {columna.total_votantes} votantes y la "
                        f"columna {col_principal.columna} declara {col_principal.total_votantes}. "
                        "El total del acta se toma de la columna principal; verifique el papel."
                    ),
                    diferencia=columna.total_votantes - col_principal.total_votantes,
                    columna=nombre,
                )
            )

    # ---- Evidencia y forma del acta
    if not foto_presente:
        hallazgos.append(
            Hallazgo(
                "R5_FOTO_AUSENTE",
                "ADVERTENCIA",
                "No se adjuntó la fotografía del acta. El PERSONERO debe subirla desde el local.",
            )
        )
    if not firmas_completas:
        hallazgos.append(
            Hallazgo(
                "R7_FIRMA_FALTANTE",
                "ADVERTENCIA",
                "El acta no tiene todas las firmas de los personeros.",
            )
        )
    if ilegible:
        hallazgos.append(
            Hallazgo(
                "R6_ILEGIBLE",
                "BLOQUEANTE",
                "El digitador declaró campos ilegibles: el acta no puede contabilizarse sin cotejo previo.",
            )
        )
    if diferencia_manual:
        hallazgos.append(
            Hallazgo(
                "R8_DIFERENCIA_MANUAL",
                "ADVERTENCIA",
                f"Diferencia de {diferencia_manual:+d} votos declarada al cotejar con el papel.",
                diferencia=diferencia_manual,
            )
        )

    # ---- Señales de alerta (no bloquean, pero ayudan a cazar errores gruesos)
    if col_principal.suma_total == 0 and col_principal.total_votantes == 0:
        hallazgos.append(
            Hallazgo(
                "R1_SUMA_VOTOS",
                "ADVERTENCIA",
                "El acta está completamente en cero: confirme que no sea un formulario sin llenar.",
                columna=col_principal.columna,
            )
        )
    elif electores_habiles and col_principal.total_votantes == electores_habiles:
        hallazgos.append(
            Hallazgo(
                "R2_TOPE_ELECTORES",
                "INFO",
                "Participación del 100%: es posible, pero conviene verificar la lectura del padrón.",
                columna=col_principal.columna,
            )
        )

    # R1 es por columna: basta que una descuadre para que el acta no sea
    # consistente, aunque la principal (la que resume la cabecera) cuadre.
    columnas_malas = [c for c in por_nombre.values() if c.diferencia != 0]
    descuadres = [
        {
            "columna": c.columna,
            "total_votantes": c.total_votantes,
            "suma": c.suma_total,
            "diferencia": c.diferencia,
        }
        for c in sorted(columnas_malas, key=lambda c: c.columna)
    ]
    consistente = not columnas_malas
    hay_bloqueante = any(h.severidad == "BLOQUEANTE" for h in hallazgos)
    estado = "OBSERVADA" if (hay_bloqueante or not consistente) else "DIGITADA"
    participacion = (
        round(100.0 * col_principal.total_votantes / electores_habiles, 2)
        if electores_habiles
        else 0.0
    )

    return ResultadoValidacion(
        consistente=consistente,
        estado_sugerido=estado,
        columna_principal=col_principal.columna,
        total_votantes=col_principal.total_votantes,
        electores_habiles=electores_habiles,
        suma_votos=col_principal.suma_votos,
        diferencia=col_principal.diferencia,
        participacion_pct=participacion,
        hallazgos=hallazgos,
        descuadres=descuadres,
    )


# ---------------------------------------------------------------------------
# Resolución de actas observadas
# ---------------------------------------------------------------------------
def puede_contabilizar(resultado: ResultadoValidacion, bloqueantes_abiertos: int = 0) -> tuple[bool, str]:
    """Decide si un acta puede pasar a CONTABILIZADA.

    Devuelve (permitido, motivo). Un acta con diferencia matemática sólo se
    contabiliza después de una resolución documentada (``resolucion_final``),
    que es exactamente lo que hace el backend al resolver la observación.

    Un descuadre en cualquier columna bloquea aquí igual que en el trigger
    ``fn_validar_contabilizacion``: las dos capas deben coincidir para que la
    API no intente algo que la base va a rechazar.
    """
    if not resultado.consistente:
        detalle = "; ".join(
            f"{d['columna']} (diferencia {d['diferencia']:+d})" for d in resultado.descuadres
        )
        return False, (
            f"El acta no cuadra en {detalle or f'la columna {resultado.columna_principal}'}"
            f" ({resultado.diferencia:+d} en la principal); "
            "requiere resolución sustentada antes de contabilizar."
        )
    if bloqueantes_abiertos > 0:
        return False, f"Tiene {bloqueantes_abiertos} observación(es) bloqueante(s) sin resolver."
    return True, "Acta consistente: puede contabilizarse."
