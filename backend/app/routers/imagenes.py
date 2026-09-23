"""Endpoints de procesamiento de imágenes actas (sin OCR, solo estandarización)."""
from __future__ import annotations

import io
import logging
import tempfile
from pathlib import Path

from fastapi import APIRouter, File, HTTPException, UploadFile
from fastapi.responses import StreamingResponse

from app.services.image_processing import estandarizar_imagen

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/imagenes", tags=["imagenes"])


@router.post("/estandarizar")
async def estandarizar_acta(
    file: UploadFile = File(...),
    max_dimension: int = 2048,
    calidad: int = 85,
    max_kb: int = 500,
):
    """
    Recibe una imagen (acta de WhatsApp), la estandariza y devuelve el JPEG optimizado.
    
    - Redimensiona a max 2048px manteniendo aspect ratio
    - Convierte a RGB (JPEG)
    - Comprime a max 500 KB (ajustando calidad)
    - Establece 200 DPI
    - Devuelve JPEG listo para almacenar/reenviar
    """
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(400, "El archivo debe ser una imagen")
    
    # Guardar temporalmente - cerrar el archivo antes de procesar (Windows)
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
            contenido = await file.read()
            tmp.write(contenido)
            tmp_path = tmp.name
        
        # Procesar (el archivo ya está cerrado)
        resultado = estandarizar_imagen(
            tmp_path,
            max_dimension=2048,
            calidad=85,
            max_kb=500,
        )
        
        # Generar nombre de salida
        nombre_salida = f"{Path(file.filename).stem}_std.jpg"
        
        return StreamingResponse(
            io.BytesIO(resultado),
            media_type="image/jpeg",
            headers={
                "Content-Disposition": f'attachment; filename="{nombre_salida}"',
                "X-Original-Size": str(len(contenido)),
                "X-Processed-Size": str(len(resultado)),
            },
        )
    finally:
        # Limpiar temp
        try:
            if tmp_path:
                Path(tmp_path).unlink(missing_ok=True)
        except OSError:
            pass


@router.post("/procesar-lote")
async def procesar_lote(
    files: list[UploadFile] = File(...),
    max_dimension: int = 2048,
    calidad: int = 85,
    max_kb: int = 500,
):
    """Procesa múltiples imágenes y devuelve ZIP con todas estandarizadas."""
    import zipfile
    import io
    
    if len(files) > 50:
        raise HTTPException(400, "Máximo 50 imágenes por lote")
    
    buffer_zip = io.BytesIO()
    with zipfile.ZipFile(buffer_zip, "w", zipfile.ZIP_DEFLATED) as zf:
        for file in files:
            if not file.content_type or not file.content_type.startswith("image/"):
                continue
            tmp_path = None
            try:
                with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
                    tmp.write(await file.read())
                    tmp_path = tmp.name
                
                resultado = estandarizar_imagen(tmp_path)
                nombre = f"{Path(file.filename).stem}_std.jpg"
                zf.writestr(nombre, resultado)
            finally:
                try:
                    if tmp_path:
                        Path(tmp_path).unlink(missing_ok=True)
                except OSError:
                    pass
    
    buffer_zip.seek(0)
    return StreamingResponse(
        io.BytesIO(buffer_zip.getvalue()),
        media_type="application/zip",
        headers={"Content-Disposition": 'attachment; filename="actas_estandarizadas.zip"'},
    )