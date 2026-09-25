"""Vision AI OCR engine — GPT-4o-mini with Gemini Flash fallback."""
import base64
import json
import logging
from pathlib import Path

from app.core.config import settings
from app.core.schemas import ActaParseResult

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """\
Eres un motor OCR especializado en actas electorales de la ONPE (Perú).
Analiza la imagen y extrae EXACTAMENTE los siguientes datos en JSON válido:

{
  "numero_mesa": "6 dígitos del número de mesa (string de 6 caracteres, rellena con ceros a la izquierda si hace falta)",
  "votos_distrital": [ {"candidate_index": 0, "votes": int}, ... ],  // votos por candidato a la Alcaldía de Paucarpata, en orden de aparición
  "votos_provincial": [ {"candidate_index": 0, "votes": int}, ... ], // votos por candidato a la Alcaldía Provincial de Arequipa, en orden de aparición
  "votos_consejero": [ {"candidate_index": 0, "votes": int}, ... ],  // votos por lista de Consejeros Regionales de la provincia del local
  "votos_regional": [ {"candidate_index": 0, "votes": int}, ... ],   // votos por candidato a Gobernador Regional de Arequipa
  "votos_blancos": int,
  "votos_nulos": int,
  "votos_impugnados": int,
  "ocr_confidence": float entre 0.0 y 1.0 (tu confianza en la lectura)
}

Reglas:
- Devuelve SOLO JSON, sin texto adicional, sin markdown.
- Si un dígito es ambiguo, marca ocr_confidence más bajo.
- Si no puedes leer un campo, pon 0 pero baja ocr_confidence.
"""


def _encode_image(path: str) -> str:
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("utf-8")


def _parse_openai(image_path: str) -> dict:
    from openai import OpenAI

    client = OpenAI(api_key=settings.openai_api_key)
    b64 = _encode_image(image_path)

    resp = client.chat.completions.create(
        model=settings.openai_vision_model,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Extrae los datos de esta acta electoral:"},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{b64}"},
                    },
                ],
            },
        ],
        response_format={"type": "json_object"},
    )
    content = resp.choices[0].message.content
    return json.loads(content)


def _parse_gemini(image_path: str) -> dict:
    import httpx

    b64 = _encode_image(image_path)
    url = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        f"{settings.gemini_vision_model}:generateContent?key={settings.gemini_api_key}"
    )
    payload = {
        "system_instruction": {"parts": [{"text": SYSTEM_PROMPT}]},
        "contents": [
            {
                "parts": [
                    {"text": "Extrae los datos de esta acta electoral:"},
                    {"inline_data": {"mime_type": "image/jpeg", "data": b64}},
                ]
            }
        ],
    }
    resp = httpx.post(url, json=payload)
    resp.raise_for_status()
    data = resp.json()
    text = data["candidates"][0]["content"]["parts"][0]["text"]
    # strip markdown fences if present
    text = text.strip().removeprefix("```json").removesuffix("```").strip()
    return json.loads(text)


def _parse_tesseract(image_path: str) -> dict:
    """Local OCR fallback using Tesseract + OpenCV pre-processing.

    Extracts mesa number and numeric vote tallies from a cleaned image.
    Heuristic by nature: assigned a low confidence so results route to review.
    """
    import cv2
    import numpy as np
    import pytesseract
    from PIL import Image

    if settings.tesseract_cmd:
        pytesseract.pytesseract.tesseract_cmd = settings.tesseract_cmd

    # Load and pre-process: grayscale -> upscale -> threshold
    img = cv2.imread(image_path, cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise RuntimeError("OpenCV could not read image")

    img = cv2.resize(img, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)
    img = cv2.GaussianBlur(img, (3, 3), 0)
    img = cv2.adaptiveThreshold(
        img, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 31, 11
    )

    text = pytesseract.image_to_string(img, config="--psm 6")
    text = text.strip()
    if not text:
        raise RuntimeError("Tesseract returned empty text")

    # Extract the 6-digit mesa number (look for standalone 6-digit token)
    import re

    mesa_match = re.search(r"\b(\d{6})\b", text)
    numero_mesa = mesa_match.group(1) if mesa_match else "000000"

    # Collect all integer vote tallies; heuristic: single/two/three digit numbers
    numbers = [int(n) for n in re.findall(r"\b\d{1,4}\b", text)]
    numbers = [n for n in numbers if n != int(numero_mesa or 0)]

    # Naive mapping: assign the first N numbers to district candidates in order
    distrital = [{"candidate_index": i, "votes": v} for i, v in enumerate(numbers)]

    return {
        "numero_mesa": numero_mesa,
        "votos_distrital": distrital,
        "votos_consejero": [],
        "votos_regional": [],
        "votos_blancos": 0,
        "votos_nulos": 0,
        "votos_impugnados": 0,
        "ocr_confidence": 0.4,
    }


def parse_acta(image_path: str) -> ActaParseResult:
    """Parse an acta image and return a normalized result.

    Priority:
      1. OpenAI vision (highest quality)
      2. Gemini vision (fallback)
      3. Local Tesseract OCR (offline fallback, low confidence)
    """
    errors = []
    if settings.openai_api_key:
        try:
            raw = _parse_openai(image_path)
            return _normalize(raw)
        except Exception as e:  # noqa: BLE001
            logger.warning("OpenAI vision failed: %s", e)
            errors.append(e)

    if settings.gemini_api_key:
        try:
            raw = _parse_gemini(image_path)
            return _normalize(raw)
        except Exception as e:  # noqa: BLE001
            logger.warning("Gemini vision failed: %s", e)
            errors.append(e)

    if settings.local_ocr_enabled:
        try:
            raw = _parse_tesseract(image_path)
            logger.info("Using local Tesseract OCR fallback")
            return _normalize(raw)
        except Exception as e:  # noqa: BLE001
            logger.warning("Local OCR failed: %s", e)
            errors.append(e)

    raise RuntimeError(f"Vision OCR failed: {errors}")


def _normalize(raw: dict) -> ActaParseResult:
    numero_mesa = str(raw.get("numero_mesa", "")).strip().zfill(6)[:6]

    def to_votes(items) -> list:
        result = []
        if isinstance(items, list):
            for i, it in enumerate(items):
                if isinstance(it, dict):
                    result.append({
                        "candidate_id": int(it.get("candidate_index", it.get("candidate_id", i))),
                        "votes": int(it.get("votes", 0) or 0),
                    })
        return result

    confidence = float(raw.get("ocr_confidence", 0.5))
    confidence = max(0.0, min(1.0, confidence))

    return ActaParseResult(
        numero_mesa=numero_mesa,
        votos_distrital=to_votes(raw.get("votos_distrital", [])),
        votos_provincial=to_votes(raw.get("votos_provincial", [])),
        votos_consejero=to_votes(raw.get("votos_consejero", [])),
        votos_regional=to_votes(raw.get("votos_regional", [])),
        votos_blancos=int(raw.get("votos_blancos", 0) or 0),
        votos_nulos=int(raw.get("votos_nulos", 0) or 0),
        votos_impugnados=int(raw.get("votos_impugnados", 0) or 0),
        ocr_confidence=confidence,
    )