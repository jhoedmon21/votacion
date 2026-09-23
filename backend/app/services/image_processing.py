"""Procesamiento simple de imágenes de actas WhatsApp: carga → estandariza → comprime.
Sin OCR, sin IA. Solo normalización de imagen para almacenamiento/transmisión.
"""
from __future__ import annotations

import io
import logging
from pathlib import Path

from PIL import Image

logger = logging.getLogger(__name__)

# Configuración de estandarización
MAX_DIMENSION = 2048        # máximo ancho/alto en px
TARGET_DPI = 200            # DPI objetivo para impresión/visualización
JPEG_QUALITY = 85           # calidad JPEG (1-100)
MAX_FILE_SIZE_KB = 500      # tamaño máximo objetivo en KB
OUTPUT_FORMAT = "JPEG"      # formato de salida


def estandarizar_imagen(
    ruta_entrada: str | Path,
    ruta_salida: str | Path | None = None,
    max_dimension: int = MAX_DIMENSION,
    calidad: int = JPEG_QUALITY,
    max_kb: int = MAX_FILE_SIZE_KB,
) -> bytes:
    """
    Carga una imagen, la estandariza y devuelve los bytes listos para guardar.
    
    Operaciones:
    1. Convierte a RGB (elimina canal alfa, CMYK, etc.)
    2. Redimensiona manteniendo aspect ratio (max_dimension)
    3. Establece DPI objetivo
    4. Comprime JPEG con calidad objetivo
    5. Si supera max_kb, reduce calidad progresivamente
    
    Args:
        ruta_entrada: ruta al archivo de imagen origen
        ruta_salida: opcional, si se da guarda el archivo ahí
        max_dimension: máximo ancho/alto en píxeles
        calidad: calidad JPEG inicial (1-100)
        max_kb: tamaño máximo en KB
    
    Returns:
        bytes de la imagen estandarizada (JPEG)
    """
    # Leer archivo en memoria para evitar bloqueo en Windows
    with open(ruta_entrada, "rb") as f:
        datos = f.read()
    
    img = Image.open(io.BytesIO(datos))
    if img.mode != "RGB":
        img = img.convert("RGB")
    
    # 2. Redimensionar manteniendo aspect ratio
    ancho, alto = img.size
    if max(ancho, alto) > max_dimension:
        if ancho > alto:
            nuevo_ancho = max_dimension
            nuevo_alto = int(alto * max_dimension / ancho)
        else:
            nuevo_alto = max_dimension
            nuevo_ancho = int(ancho * max_dimension / alto)
        img = img.resize((nuevo_ancho, nuevo_alto), Image.Resampling.LANCZOS)
        logger.debug(f"Redimensionado: {ancho}x{alto} -> {nuevo_ancho}x{nuevo_alto}")
    
    # 3. Establecer DPI
    img.info["dpi"] = (TARGET_DPI, TARGET_DPI)
    
    # 4. Comprimir con calidad objetivo, ajustando si supera max_kb
    calidad_actual = calidad
    buffer = io.BytesIO()
    
    while calidad_actual >= 20:
        buffer.seek(0)
        buffer.truncate(0)
        img.save(buffer, format="JPEG", quality=calidad_actual, optimize=True, dpi=(TARGET_DPI, TARGET_DPI))
        tamaño_kb = buffer.tell() / 1024
        
        if tamaño_kb <= max_kb:
            logger.info(f"Imagen estandarizada: {tamaño_kb:.1f} KB, calidad {calidad_actual}, {img.size[0]}x{img.size[1]}")
            break
        
        calidad_actual -= 5
    else:
        # Si aún supera max_kb con calidad mínima, redimensionar más agresivamente
        logger.warning(f"Imagen aún > {max_kb} KB con calidad mínima; reduciendo dimensiones")
        factor = 0.8
        while buffer.tell() / 1024 > max_kb and factor > 0.2:
            nuevo_ancho = int(img.size[0] * factor)
            nuevo_alto = int(img.size[1] * factor)
            img = img.resize((nuevo_ancho, nuevo_alto), Image.Resampling.LANCZOS)
            buffer.seek(0)
            buffer.truncate(0)
            img.save(buffer, format="JPEG", quality=calidad_actual, optimize=True, dpi=(TARGET_DPI, TARGET_DPI))
            factor *= 0.9
        logger.info(f"Imagen reducida agresivamente: {buffer.tell()/1024:.1f} KB, {img.size[0]}x{img.size[1]}")
    
    resultado = buffer.getvalue()
    
    if ruta_salida:
        Path(ruta_salida).write_bytes(resultado)
        logger.info(f"Guardado en {ruta_salida} ({len(resultado)/1024:.1f} KB)")
    
    return resultado


def estandarizar_desde_bytes(
    datos: bytes,
    ruta_salida: str | Path | None = None,
    **kwargs
) -> bytes:
    """Estandariza una imagen desde bytes en memoria."""
    img = Image.open(io.BytesIO(datos))
    buffer_salida = io.BytesIO()
    
    # Guardar en buffer temporal para reutilizar la lógica
    img.save(buffer_salida, format="JPEG", quality=95)
    buffer_salida.seek(0)
    
    # Usar la función principal guardando en archivo temporal
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
        tmp.write(buffer_salida.getvalue())
        tmp.flush()
        resultado = estandarizar_imagen(tmp.name, ruta_salida, **kwargs)
    
    # Limpiar temp
    try:
        Path(tmp.name).unlink()
    except OSError:
        pass
    
    return resultado


def procesar_lote_whatsapp(
    directorio_entrada: str | Path,
    directorio_salida: str | Path,
    patron: str = "*.jpg",
) -> dict:
    """
    Procesa todas las imágenes de un directorio (ej. carpeta de WhatsApp).
    Retorna estadísticas del procesamiento.
    """
    entrada = Path(directorio_entrada)
    salida = Path(directorio_salida)
    salida.mkdir(parents=True, exist_ok=True)
    
    archivos = list(entrada.glob(patron))
    resultados = {"procesados": 0, "errores": 0, "bytes_originales": 0, "bytes_finales": 0}
    
    for archivo in archivos:
        try:
            tamaño_orig = archivo.stat().st_size
            salida_archivo = salida / f"{archivo.stem}_std.jpg"
            estandarizar_imagen(archivo, salida_archivo)
            tamaño_nuevo = salida_archivo.stat().st_size
            
            resultados["procesados"] += 1
            resultados["bytes_originales"] += tamaño_orig
            resultados["bytes_finales"] += tamaño_nuevo
            logger.info(f"OK: {archivo.name} ({tamaño_orig/1024:.1f}KB -> {tamaño_nuevo/1024:.1f}KB)")
        except Exception as e:
            resultados["errores"] += 1
            logger.error(f"Error procesando {archivo.name}: {e}")
    
    logger.info(f"Lote completado: {resultados}")
    return resultados