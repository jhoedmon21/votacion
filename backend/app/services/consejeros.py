"""Consejo Regional POR PROVINCIA — cómputo compartido.

Cada provincia es una circunscripción con su propia columna de CONSEJEROS en
el acta y sus propios curules (Res. JNE para ERM 2026: Arequipa 6; Castilla,
Caylloma y La Unión 2; Camaná, Caravelí, Condesuyos e Islay 1 — 16 en total).
El voto es por lista cerrada, sin voto preferencial: los escaños se reparten
por **cifra repartidora (d'Hondt)** cuando la provincia elige 2+ y entran los
primeros candidatos de cada lista según su orden de registro.

``resultado_por_provincia`` alimenta tanto al cómputo v1
(``/v1/resultados/resumen``) como al resumen del panel
(``/analytics/summary?scope=consejero``): mismo reparto en ambas vistas.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from sqlalchemy import func
from sqlalchemy.orm import Session

from app.core.models import ConsejeroCandidate, Record, Table
from app.core.ubigeo_catalogo import PROVINCIA_NOMBRE, UBIGEO_PROVINCIA

# Curules por provincia (ubigeo provincial -> escaños a renovar).
CURULES_POR_PROVINCIA: dict[str, int] = {
    "040100": 6,  # Arequipa
    "040400": 2,  # Castilla
    "040500": 2,  # Caylloma
    "040800": 2,  # La Unión
    "040200": 1,  # Camaná
    "040300": 1,  # Caravelí
    "040600": 1,  # Condesuyos
    "040700": 1,  # Islay
}


@dataclass
class ListaEscano:
    organizacion: str
    color: str
    votos: int
    curules_ganados: int = 0
    electos: list[str] = field(default_factory=list)
    # Foto y logo del candidato cabecera (mismo tratamiento visual que el Top 2).
    foto: str | None = None
    logo: str | None = None


@dataclass
class ProvinciaResultado:
    provincia: str
    ubigeo: str
    curules: int
    ganador: ListaEscano | None
    escanos: list[ListaEscano]


def _dhondt(votos: dict[str, int], curules: int) -> dict[str, int]:
    """Cifra repartidora: curules por organización (desempate alfabético)."""
    cocientes: list[tuple[float, str]] = []
    for org, v in votos.items():
        for i in range(1, curules + 1):
            cocientes.append((v / i, org))
    cocientes.sort(key=lambda t: (-t[0], t[1]))
    reparto: dict[str, int] = {}
    for _, org in cocientes[:curules]:
        reparto[org] = reparto.get(org, 0) + 1
    return reparto


def _nombre_provincia(ubigeo_prov: str) -> str:
    """Nombre de la provincia desde el catálogo (distrito -> provincia)."""
    return next(
        (PROVINCIA_NOMBRE.get(nom, nom)
         for u, nom in UBIGEO_PROVINCIA.items()
         if u.startswith(ubigeo_prov[:4])),
        ubigeo_prov,
    )


def resultado_por_provincia(db: Session, mesas_ids: list[int]) -> list[ProvinciaResultado]:
    """Resultado de consejeros por provincia sobre las mesas dadas.

    ``mesas_ids`` son las mesas contabilizadas del alcance actual; sin mesas,
    se listan las 8 provincias con sus curules y sin ganador.
    """
    votos_prov: dict[str, dict[str, tuple[int, str]]] = {}
    if mesas_ids:
        filas = (
            db.query(ConsejeroCandidate.ubigeo, ConsejeroCandidate.party,
                     ConsejeroCandidate.color, func.sum(Record.votes))
            .join(Record, (Record.candidate_id == ConsejeroCandidate.id)
                  & (Record.candidate_type == "consejero"))
            .filter(Record.table_id.in_(mesas_ids))
            .group_by(ConsejeroCandidate.ubigeo, ConsejeroCandidate.party,
                      ConsejeroCandidate.color).all()
        )
        for ubigeo_p, org, color, votos in filas:
            if not org:
                continue
            d = votos_prov.setdefault(ubigeo_p, {})
            v = int(votos or 0)
            if org not in d or v > d[org][0]:
                d[org] = (v, color or "#6b7280")

    cabezas: dict[tuple[str, str], list[str]] = {}
    # Foto/logo del candidato cabecera de cada (provincia, organización):
    # el de menor sort_order encabeza la lista.
    medios: dict[tuple[str, str], tuple[str | None, str | None, int]] = {}
    for c in db.query(ConsejeroCandidate).filter(
            ConsejeroCandidate.ubigeo.in_(CURULES_POR_PROVINCIA)).all():
        if not c.party:
            continue
        cabezas.setdefault((c.ubigeo, c.party), []).append(c.name or "")
        clave = (c.ubigeo, c.party)
        actual = medios.get(clave)
        if actual is None or (c.sort_order or 999) < actual[2]:
            medios[clave] = (c.photo_url, c.symbol, c.sort_order or 999)
    for nombres in cabezas.values():
        nombres.sort()

    salida: list[ProvinciaResultado] = []
    for ubigeo_p in sorted(CURULES_POR_PROVINCIA):
        curules = CURULES_POR_PROVINCIA[ubigeo_p]
        votos_org = {org: v for org, (v, _) in votos_prov.get(ubigeo_p, {}).items()}
        colores = {org: c for org, (_, c) in votos_prov.get(ubigeo_p, {}).items()}

        listas: list[ListaEscano] = []
        if votos_org:
            reparto = _dhondt(votos_org, curules)
            for org in sorted(reparto, key=lambda o: (-reparto[o], -votos_org[o])):
                ganados = reparto[org]
                electos = [n for n in cabezas.get((ubigeo_p, org), []) if n][:ganados]
                foto, logo, _orden = medios.get((ubigeo_p, org), (None, None, 0))
                listas.append(ListaEscano(
                    organizacion=org, color=colores.get(org, "#6b7280"),
                    votos=votos_org[org], curules_ganados=ganados, electos=electos,
                    foto=foto, logo=logo))

        ganador = max(listas, key=lambda l: l.votos) if listas else None
        salida.append(ProvinciaResultado(
            provincia=_nombre_provincia(ubigeo_p), ubigeo=ubigeo_p,
            curules=curules, ganador=ganador, escanos=listas))
    return salida
