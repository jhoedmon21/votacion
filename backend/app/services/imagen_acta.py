"""Procesamiento de imágenes de actas antes de almacenarlas.

Objetivo: que la foto del acta subida desde el campo llegue al servidor,
se NORMALICE (orientación EXIF, tamaño máximo, nitidez suave) y se
GUARDE en un formato moderno de peso reducido **manteniendo calidad de
lectura** — el acta debe seguir siendo legible para el cotejo visual y
para el OCR.

Parámetros elegidos para actas electorales (texto pequeño sobre papel):
  * Lado mayor máximo 1600 px (suficiente para OCR y zoom de verificación).
  * WebP calidad 82: ~3-6× más liviano que el JPEG original con la misma
    legibilidad; los teléfonos suben fotos de 3-6 MB que quedan en ~150-400 KB.
  * Si Pillow no compila WebP (raro), cae a JPEG calidad 85.
"""
from __future__ import annotations

import logging
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageOps

# HEIC/HEIF (fotos de iPhone): si el plugin está instalado, registrar el opener
# hace que Pillow las abra como cualquier otra imagen. Sin él, el bloque de
# respaldo del caller guarda el original sin bloquear la evidencia.
try:
    from pillow_heif import register_heif_opener
    register_heif_opener()
except ImportError:  # noqa: BLE001 — build sin pillow-heif: cae al respaldo
    pass

logger = logging.getLogger(__name__)

LADO_MAYOR_MAX = 1600
CALIDAD_WEBP = 82
CALIDAD_JPEG = 85

# Tipos que aceptamos del usuario (se convierten todos al formato final)
FORMATOS_ACEPTADOS = {"image/jpeg", "image/png", "image/webp", "image/heic",
                      "image/heif", "image/bmp", "image/tiff", "image/avif"}


def procesar_acta(origen: str | Path) -> tuple[Path, dict]:
    """Normaliza la imagen de un acta y devuelve (ruta_final, métricas).

    La ruta final tiene extensión .webp (o .jpeg como fallback) y está lista
    para `storage_service.upload()`. Nunca modifica el archivo original.
    """
    origen_path = Path(origen)
    img = Image.open(origen_path)

    # 1) EXIF: los celulares guardan la rotación en metadatos; si no se
    #    aplica, el acta se ve girada en el navegador.
    img = ImageOps.exif_transpose(img)

    # 2) RGB: los PNG con transparencia y los CMYK rompen la compresión WebP.
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")

    # 3) Reducción a la resolución de trabajo (sólo baja, nunca agranda).
    ancho, alto = img.size
    mayor = max(ancho, alto)
    escala = LADO_MAYOR_MAX / mayor if mayor > LADO_MAYOR_MAX else 1.0
    if escala < 1.0:
        img = img.resize(
            (round(ancho * escala), round(alto * escala)),
            Image.LANCZOS,  # el mejor compromiso nitidez/peso para texto
        )

    # 4) Compresión con calidad controlada.
    salida = BytesIO()
    formato_final = "WEBP"
    try:
        img.save(salida, format="WEBP", quality=CALIDAD_WEBP, method=6)
    except Exception:  # noqa: BLE001 — build sin WebP
        salida = BytesIO()
        formato_final = "JPEG"
        img.save(salida, format="JPEG", quality=CALIDAD_JPEG, optimize=True)
    salida.seek(0)

    ext = ".webp" if formato_final == "WEBP" else ".jpeg"
    destino = origen_path.with_suffix(ext)
    destino.write_bytes(salida.getvalue())

    peso_original = origen_path.stat().st_size
    peso_final = destino.stat().st_size
    metricas = {
        "formato": formato_final.lower(),
        "ancho": img.size[0],
        "alto": img.size[1],
        "peso_original_kb": round(peso_original / 1024, 1),
        "peso_final_kb": round(peso_final / 1024, 1),
        "reduccion_pct": (
            round(100 * (1 - peso_final / peso_original), 1)
            if peso_original else 0.0
        ),
    }
    logger.info(
        "Imagen de acta procesada: %s KB -> %s KB (%s) %sx%s",
        metricas["peso_original_kb"], metricas["peso_final_kb"],
        metricas["formato"], metricas["ancho"], metricas["alto"],
    )
    return destino, metricas
