"""Cliente HTTP del scraper: cabeceras reales, reintentos y rate-limiting.

La ONPE y datosabiertos.gob.pe sirven tras reverse proxy / WAF: sin
`User-Agent` de navegador y sin pausas, el scraper recibe 403. Este módulo
centraliza esas defensas para que ningún adaptador de fuente las reinvente.
"""
from __future__ import annotations

import logging
import time
from pathlib import Path
from typing import Any

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logger = logging.getLogger(__name__)


class FuenteBloqueada(RuntimeError):
    """403/429 persistente o challenge WAF: pausar y reintentar más tarde."""


class FuenteNoDisponible(RuntimeError):
    """La fuente no expone (aún) el recurso esperado (data no publicada)."""


class LimitadorRitmo:
    """Garantiza una pausa mínima entre peticiones (rate-limiting cooperativo)."""

    def __init__(self, pausa_seg: float = 1.5) -> None:
        self.pausa_seg = max(0.0, pausa_seg)
        self._ultima: float = 0.0

    def esperar(self) -> None:
        """Duerme lo necesario para respetar la pausa mínima."""
        ahora = time.monotonic()
        espera = self.pausa_seg - (ahora - self._ultima)
        if espera > 0:
            time.sleep(espera)
        self._ultima = time.monotonic()


def crear_sesion(
    user_agent: str,
    reintentos: int = 3,
    timeout_seg: int = 30,
    pausa_seg: float = 1.5,
) -> tuple[requests.Session, LimitadorRitmo]:
    """Sesión con cabeceras de navegador real + backoff en 429/5xx.

    Los 403 NO se reintentan (suelen ser WAF/bloqueo: reintentar agrava).
    """
    sesion = requests.Session()
    sesion.headers.update({
        "User-Agent": user_agent,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,"
                  "application/json;q=0.8,*/*;q=0.7",
        "Accept-Language": "es-PE,es;q=0.9",
        "Cache-Control": "no-cache",
    })
    reintento = Retry(
        total=max(0, reintentos),
        backoff_factor=2.0,                    # 2s, 4s, 8s...
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=("GET", "POST"),
        raise_on_status=False,
    )
    adaptador = HTTPAdapter(max_retries=reintento, pool_maxsize=4)
    sesion.mount("https://", adaptador)
    sesion.mount("http://", adaptador)
    # Timeout por defecto en cada petición (evita cuelgues eternos).
    _timeout = timeout_seg

    original_request = sesion.request

    def _con_timeout(metodo: str, url: str, **kwargs: Any):
        kwargs.setdefault("timeout", _timeout)
        return original_request(metodo, url, **kwargs)

    sesion.request = _con_timeout  # type: ignore[method-assign]
    return sesion, LimitadorRitmo(pausa_seg)


def obtener(
    sesion: requests.Session,
    limitador: LimitadorRitmo,
    url: str,
    *,
    params: dict | None = None,
) -> requests.Response:
    """GET con ritmo + manejo explícito de 403/WAF (lanza FuenteBloqueada)."""
    limitador.esperar()
    try:
        resp = sesion.get(url, params=params)
    except requests.RequestException as exc:
        raise FuenteNoDisponible(f"sin respuesta de {url}: {exc}") from exc
    if resp.status_code == 403:
        raise FuenteBloqueada(
            f"403 de {url}: el WAF bloqueó al scraper. "
            "Aumente HTTP_PAUSA_SEG, verifique el User-Agent o use --fuente archivo."
        )
    if resp.status_code == 429:
        raise FuenteBloqueada(
            f"429 de {url}: rate-limit del servidor. Aumente HTTP_PAUSA_SEG."
        )
    if resp.status_code >= 400:
        raise FuenteNoDisponible(f"HTTP {resp.status_code} en {url}")
    return resp


def descargar(
    sesion: requests.Session,
    limitador: LimitadorRitmo,
    url: str,
    destino: Path,
    *,
    params: dict | None = None,
) -> Path:
    """Descarga un recurso (ZIP/CSV) por streaming al disco."""
    limitador.esperar()
    destino.parent.mkdir(parents=True, exist_ok=True)
    try:
        with sesion.get(url, params=params, stream=True) as resp:
            if resp.status_code == 403:
                raise FuenteBloqueada(f"403 descargando {url}")
            resp.raise_for_status()
            with destino.open("wb") as fh:
                for bloque in resp.iter_content(chunk_size=1 << 20):
                    if bloque:
                        fh.write(bloque)
    except (FuenteBloqueada, FuenteNoDisponible):
        raise
    except requests.RequestException as exc:
        raise FuenteNoDisponible(f"descarga fallida de {url}: {exc}") from exc
    logger.info("descargado %s (%.1f MB)", destino, destino.stat().st_size / 1e6)
    return destino
