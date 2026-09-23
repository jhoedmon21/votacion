"""Loader del padrón: UPSERT idempotente con logs por provincia/distrito.

Claves de idempotencia (mismas del DDL):
  * locales: UNIQUE (ubigeo, codigo_local) → UPDATE si existe, INSERT si no.
  * mesas:   UNIQUE (local_id, numero_mesa) → actualiza electores/estado.

En PostgreSQL usa `ON CONFLICT DO UPDATE` nativo (una sentencia por lote);
en el resto (SQLite/MySQL-dev) usa el camino portable get-or-create. Re-correr
el scraper con la misma fuente deja los conteos intactos: actualiza, no duplica.
`total_mesas` del local se recalcula desde las mesas reales tras cada provincia.
"""
from __future__ import annotations

import logging
from collections import Counter
from dataclasses import dataclass, field

from sqlalchemy import func
from sqlalchemy.orm import Session

from .fuentes import RegistroLocal

logger = logging.getLogger(__name__)


@dataclass
class StatsCarga:
    """Contadores agregados de una carga (útil para tests y reportes)."""

    locales_nuevos: int = 0
    locales_actualizados: int = 0
    mesas_nuevas: int = 0
    mesas_actualizadas: int = 0
    por_provincia: Counter = field(default_factory=Counter)

    def resumen(self) -> str:
        return (
            f"locales +{self.locales_nuevos}/~{self.locales_actualizados} | "
            f"mesas +{self.mesas_nuevas}/~{self.mesas_actualizadas}"
        )


def _upsert_local_pg(conn, tabla, datos: dict) -> str:
    """UPSERT nativo PostgreSQL para un local. Retorna 'nuevo'/'actualizado'."""
    from sqlalchemy.dialects.postgresql import insert as pg_insert

    stmt = pg_insert(tabla).values(**datos)
    stmt = stmt.on_conflict_do_update(
        index_elements=["ubigeo", "codigo_local"],
        set_={k: stmt.excluded[k] for k in (
            "nombre_local", "direccion", "referencia", "latitud", "longitud",
            "provincia", "distrito", "fuente")},
    ).returning(tabla.c.id, tabla.c.created_at, tabla.c.updated_at)
    fila = conn.execute(stmt).one()
    # created_at == updated_at (a precisión de la transacción) => fue INSERT.
    return "nuevo" if fila.created_at == fila.updated_at else "actualizado"


def cargar_provincia(
    sesion: Session,
    provincia: str,
    locales: list[RegistroLocal],
    *,
    fuente: str = "ONPE",
    nativo_pg: bool = False,
) -> StatsCarga:
    """UPSERT de todos los locales/mesas de UNA provincia (un commit).

    El log por provincia/distrito sale aquí: INFO por provincia, DEBUG por
    distrito, para que `--solo-provincia X -v` sea el modo de depuración.
    """
    from .modelos import LocalVotacion, MesaVotacion

    stats = StatsCarga()
    distritos = sorted({l.distrito or "—" for l in locales})
    logger.info("[%s] upsert: %d locales en %d distritos: %s",
                provincia, len(locales), len(distritos),
                ", ".join(distritos[:8]) + ("..." if len(distritos) > 8 else ""))

    for local in locales:
        datos = {
            "ubigeo": local.ubigeo, "departamento": local.departamento,
            "provincia": local.provincia or provincia,
            "distrito": local.distrito, "codigo_local": local.codigo_local,
            "nombre_local": local.nombre_local, "direccion": local.direccion,
            "referencia": local.referencia,
            "latitud": local.latitud, "longitud": local.longitud,
            "fuente": fuente,
        }
        if nativo_pg:
            estado = _upsert_local_pg(sesion.connection(), LocalVotacion.__table__, datos)
            fila = (sesion.query(LocalVotacion)
                    .filter_by(ubigeo=local.ubigeo, codigo_local=local.codigo_local)
                    .one())
        else:
            fila = (sesion.query(LocalVotacion)
                    .filter_by(ubigeo=local.ubigeo, codigo_local=local.codigo_local)
                    .first())
            if fila is None:
                fila = LocalVotacion(**datos)
                sesion.add(fila)
                sesion.flush()
                estado = "nuevo"
            else:
                # Camino portable: no pisa con vacíos (un re-run con un archivo
                # más pobre no borra dirección/referencia ya cargadas).
                for k, v in datos.items():
                    if k not in ("ubigeo", "codigo_local") and v not in (None, ""):
                        setattr(fila, k, v)
                estado = "actualizado"
        if estado == "nuevo":
            stats.locales_nuevos += 1
        else:
            stats.locales_actualizados += 1

        for m in local.mesas:
            mesa = (sesion.query(MesaVotacion)
                    .filter_by(local_id=fila.id, numero_mesa=m.numero)
                    .first())
            if mesa is None:
                sesion.add(MesaVotacion(local_id=fila.id, numero_mesa=m.numero,
                                        electores_habiles=m.electores))
                stats.mesas_nuevas += 1
            else:
                if m.electores is not None and mesa.electores_habiles != m.electores:
                    mesa.electores_habiles = m.electores
                    stats.mesas_actualizadas += 1
        # La sesión usa autoflush=False: vaciar antes de contar para que el
        # total incluya las mesas recién añadidas de esta pasada.
        sesion.flush()
        fila.total_mesas = (sesion.query(func.count(MesaVotacion.id))
                            .filter_by(local_id=fila.id).scalar() or 0)
        logger.debug("[%s] %s/%s: %s (%d mesas)",
                     provincia, local.ubigeo, local.codigo_local,
                     local.nombre_local, fila.total_mesas)

    sesion.commit()
    stats.por_provincia[provincia] += len(locales)
    logger.info("[%s] commit: %s", provincia, stats.resumen())
    return stats
