"""Generador de prompts para "Museo IA" (consumo del LLM).

Toma los datos consolidados tras la carga de actas (resumen nacional del
cómputo + top de organizaciones + avance por distrito + observadas) y
construye un prompt dinámico formateado en JSON, listo para
``POST /api/museo-ia/prompt`` → LLM (Muse Spark / GPT / Gemini).

El JSON de salida tiene forma estable::

    {
      "modelo_sugerido": "muse-spark",
      "system": "...",
      "user_prompt": "...",
      "contexto": {...},            # datos numéricos consolidados
      "formato_respuesta": {...},   # contrato JSON que debe devolver el LLM
      "metadatos": {...}            # trazabilidad: versión, actas, timestamp
    }
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any


class MuseoIaError(ValueError):
    """Error de construcción del prompt (p. ej. tipo de elección inválido)."""


TIPOS_VALIDOS = ("REGIONAL", "PROVINCIAL", "DISTRITAL")

TONOS = {
    "institucional": "Tono institucional, neutral y formal (comunicado oficial).",
    "periodistico": "Tono periodístico, claro y divulgativo para ciudadanía.",
    "tecnico": "Tono técnico-electoral, con precisión numérica y reglas ONPE.",
}


def _validar_entrada(tipo_eleccion: str, tono: str, top: int) -> tuple[str, str, int]:
    """Normaliza y valida los parámetros; lanza MuseoIaError (→ 422)."""
    tipo = (tipo_eleccion or "").upper()
    if tipo not in TIPOS_VALIDOS:
        raise MuseoIaError(f"tipo_eleccion inválido: {tipo_eleccion!r} (usa {TIPOS_VALIDOS})")
    tono_norm = (tono or "institucional").lower()
    if tono_norm not in TONOS:
        raise MuseoIaError(f"tono inválido: {tono!r} (usa {sorted(TONOS)})")
    if not 1 <= int(top) <= 50:
        raise MuseoIaError(f"top fuera de rango [1, 50]: {top!r}")
    return tipo, tono_norm, int(top)


def construir_prompt_consolidado(
    *,
    resumen: dict[str, Any],
    tipo_eleccion: str = "DISTRITAL",
    top: int = 10,
    tono: str = "institucional",
    incluir_observadas: bool = True,
    pregunta: str | None = None,
) -> dict[str, Any]:
    """Construye el prompt JSON del LLM a partir del consolidado de actas.

    :param resumen: dict del cómputo (forma de ``V1ResumenOut``: total_mesas,
        actas_normales/observadas, avance_pct, participación, votos_*,
        partidos[{organizacion, candidato, votos, porcentaje}], distritos,
        observadas).
    :param tipo_eleccion: REGIONAL | PROVINCIAL | DISTRITAL.
    :param top: n° de organizaciones a incluir en el contexto.
    :param tono: institucional | periodistico | tecnico.
    :param incluir_observadas: si False, omite la cola de observadas.
    :param pregunta: pregunta libre del operador (opcional).
    :raises MuseoIaError: ante parámetros inválidos.
    """
    tipo, tono_norm, top_n = _validar_entrada(tipo_eleccion, tono, top)

    partidos = list((resumen or {}).get("partidos") or [])[:top_n]
    distritos = list((resumen or {}).get("distritos") or [])[:15]
    observadas = list((resumen or {}).get("observadas") or [])[:20]

    total_mesas = int(resumen.get("total_mesas") or 0)
    actas_normales = int(resumen.get("actas_normales") or 0)
    actas_observadas = int(resumen.get("actas_observadas") or 0)

    contexto: dict[str, Any] = {
        "tipo_eleccion": tipo,
        "total_mesas": total_mesas,
        "actas_normales": actas_normales,
        "actas_observadas": actas_observadas,
        "avance_pct": resumen.get("avance_pct", 0.0),
        "participacion_pct": resumen.get("participacion_pct", 0.0),
        "electores_habiles": resumen.get("electores_habiles", 0),
        "votos_validos": resumen.get("votos_validos", 0),
        "votos_blancos": resumen.get("votos_blancos", 0),
        "votos_nulos": resumen.get("votos_nulos", 0),
        "votos_impugnados": resumen.get("votos_impugnados", 0),
        "votos_emitidos": resumen.get("votos_emitidos", 0),
        "ranking": [
            {
                "posicion": i + 1,
                "organizacion": p.get("organizacion"),
                "candidato": p.get("candidato", ""),
                "votos": p.get("votos", 0),
                "porcentaje": p.get("porcentaje", 0.0),
            }
            for i, p in enumerate(partidos)
        ],
        "distritos_rezagados": [
            {
                "ubigeo": d.get("ubigeo"),
                "distrito": d.get("distrito"),
                "avance_pct": d.get("avance_pct"),
                "actas": d.get("actas"),
                "mesas": d.get("mesas"),
            }
            for d in distritos
        ],
    }
    if incluir_observadas:
        contexto["observadas"] = [
            {
                "numero_mesa": o.get("numero_mesa"),
                "local": o.get("local", ""),
                "ubigeo": o.get("ubigeo", ""),
                "distrito": o.get("distrito", ""),
            }
            for o in observadas
        ]

    lider = contexto["ranking"][0] if contexto["ranking"] else None
    segundo = contexto["ranking"][1] if len(contexto["ranking"]) > 1 else None
    ventaja = (
        f"{lider['organizacion']} lidera con {lider['votos']} votos "
        f"({lider['porcentaje']}%), seguido de {segundo['organizacion']} "
        f"({segundo['votos']} votos)."
        if lider and segundo else
        (f"{lider['organizacion']} lidera el cómputo." if lider else
         "Aún sin votos contabilizados.")
    )

    system = (
        "Eres Museo IA, analista electoral del cómputo oficial. "
        "Respondes SÓLO con el JSON del contrato `formato_respuesta`, sin "
        "texto fuera del JSON. Cifras exactas del contexto; si un dato no "
        "está, usa null y explícalo en `advertencias`. Nunca inventes mesas, "
        "actas ni porcentajes. " + TONOS[tono_norm]
    )
    user_prompt = (
        f"Analiza el cómputo {tipo} con {actas_normales} actas normales y "
        f"{actas_observadas} observadas sobre {total_mesas} mesas "
        f"(avance {resumen.get('avance_pct', 0.0)}%, "
        f"participación {resumen.get('participacion_pct', 0.0)}%). {ventaja} "
        f"Identifica al probable ganador, la competitividad (margen entre los "
        f"dos primeros), los 3 distritos más rezagados y el riesgo de las "
        f"observadas. "
        + (f"Pregunta del operador: {pregunta.strip()} " if pregunta else "")
        + "Devuelve el JSON del contrato."
    )

    return {
        "modelo_sugerido": "muse-spark",
        "system": system,
        "user_prompt": user_prompt,
        "contexto": contexto,
        "formato_respuesta": {
            "tipo": "object",
            "propiedades": {
                "titular": "string: titular de 1 línea",
                "ganador_probable": "string | null",
                "margen_pp": "number | null: ventaja en puntos porcentuales",
                "competitividad": "string: ALTA | MEDIA | BAJA",
                "distritos_rezagados": "string[]: hasta 3 ubigeos",
                "riesgo_observadas": "string: 1-2 líneas",
                "advertencias": "string[]",
            },
            "requeridos": ["titular", "competitividad", "advertencias"],
        },
        "metadatos": {
            "generado_en": datetime.now(timezone.utc).isoformat(),
            "tipo_eleccion": tipo,
            "tono": tono_norm,
            "top": top_n,
            "actas_base": actas_normales + actas_observadas,
            "fuente": "computo nacional consolidado tras carga de actas",
        },
    }
