"""Credenciales de personeros — QR firmado + PDF fotocheck (Fuerza Arequipeña).

QR: ``FA-AREQUIPA|{dni}|{mesa}|{firma}`` con firma = HMAC-SHA256(secret,
``"{dni}|{mesa}"``)[:12]. Los 3 primeros segmentos respetan el formato
estructurado del requerimiento; la firma permite al Digitador Global validar
autenticidad sin confiar solo en lo impreso (ver POST /verificar-qr).

PDF: fotocheck 90×140 mm retrato (escala CR80 del requerimiento) con
reportlab a 300 DPI efectivos (QR en alta resolución, texto vectorial).
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import io
import logging
from datetime import datetime, timezone

from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.models import AsignacionPersonero, Table, Usuario, Venue

logger = logging.getLogger(__name__)

QR_PREFIJO = "FA-AREQUIPA"
PARTIDO = "FUERZA AREQUIPEÑA"
PROCESO = "Elecciones Regionales y Municipales · Arequipa 2026"

# Identidad visual.
ROJO_CARMESI = (0xB9 / 255, 0x1C / 255, 0x1C / 255)  # #b91c1c
AZUL_AREQUIPA = (0x0B / 255, 0x2C / 255, 0x6B / 255)  # azul arequipeño profundo
BLANCO = (1, 1, 1)

_SECRET_DEFECTO = "dev-fuerza-arequipena-cambiar"


def _secreto() -> str:
    if settings.credencial_qr_secret == _SECRET_DEFECTO:
        logger.warning("CREDENCIAL_QR_SECRET en valor dev: cambie en producción (.env)")
    return settings.credencial_qr_secret or _SECRET_DEFECTO


def firmar_qr(dni: str, mesa: str) -> str:
    """Firma HMAC-SHA256 truncada (12 hex mayúsculas) de 'dni|mesa'."""
    mac = hmac.new(_secreto().encode(), f"{dni}|{mesa}".encode(),
                   hashlib.sha256).hexdigest()[:12].upper()
    return mac


def construir_qr(dni: str, mesa: str) -> str:
    """Contenido del QR: FA-AREQUIPA|DNI|MESA|firma."""
    return f"{QR_PREFIJO}|{dni}|{mesa}|{firmar_qr(dni, mesa)}"


def verificar_qr(qr: str) -> tuple[bool, str | None, str | None, str]:
    """Valida formato y firma. Retorna (ok, dni, mesa, motivo)."""
    partes = (qr or "").strip().split("|")
    if len(partes) != 4 or partes[0] != QR_PREFIJO:
        return False, None, None, "formato inválido (esperado FA-AREQUIPA|DNI|MESA|firma)"
    _, dni, mesa, firma = partes
    if not (dni.isdigit() and len(dni) == 8):
        return False, None, None, "DNI inválido en el QR"
    if not (mesa.isdigit() and len(mesa) == 6):
        return False, None, None, "mesa inválida en el QR"
    if not hmac.compare_digest(firma.upper(), firmar_qr(dni, mesa)):
        return False, dni, mesa, "firma inválida: credencial apócrifa"
    return True, dni, mesa, "firma válida"


def iniciales(nombres: str, apellidos: str) -> str:
    """Monograma para la foto (la base no guarda foto del personero)."""
    ini = ((nombres or "").strip()[:1] + (apellidos or "").strip()[:1]).upper()
    return ini or "FA"


def qr_imagen_dataurl(texto: str, escala: int = 10) -> str:
    """QR en alta resolución como data URL PNG (lista para <img> e impresión)."""
    import qrcode

    img = qrcode.make(texto, box_size=escala, border=2).convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    b64 = base64.b64encode(buf.getvalue()).decode()
    return f"data:image/png;base64,{b64}"


def _jerarquia(ubigeo: str) -> tuple[str, str]:
    from app.core.ubigeo_catalogo import (DISTRITOS_POR_PROVINCIA,
                                           UBIGEO_DISTRITO)

    distrito = UBIGEO_DISTRITO.get(ubigeo, ubigeo)
    provincia = next((p for p, ds in DISTRITOS_POR_PROVINCIA.items()
                      if any(u == ubigeo for u, _ in ds)), "")
    return provincia, distrito


def datos_credencial(db: Session, usuario_id: int,
                     mesa: str | None = None) -> dict:
    """Ficha completa de credencial (la mesa se elige o es la TITULAR vigente).

    Lanza LookupError si el usuario no es personero/delegado o no tiene mesa.
    """
    persona = db.get(Usuario, usuario_id)
    if persona is None or persona.rol not in ("PERSONERO", "DELEGADO_MESA"):
        raise LookupError(f"Personero {usuario_id} no existe")
    q = (db.query(AsignacionPersonero)
         .filter(AsignacionPersonero.usuario_id == persona.id))
    if mesa:
        q = q.filter(AsignacionPersonero.mesa_id == db.query(Table.id)
                     .filter(Table.numero_mesa == mesa).scalar_subquery())
    asignacion = (q.order_by(AsignacionPersonero.created_at.desc()).first())
    if asignacion is None:
        raise LookupError(f"{persona.nombre_completo} no tiene mesa asignada")
    table = db.get(Table, asignacion.mesa_id)
    venue = db.get(Venue, table.venue_id) if table else None
    if table is None or venue is None:
        raise LookupError("Asignación sin mesa/local en el padrón")
    provincia, distrito = _jerarquia(venue.ubigeo or "")
    qr = construir_qr(persona.dni, table.numero_mesa)
    return {
        "personero_id": persona.id,
        "nombres": persona.nombres,
        "apellidos": persona.apellidos,
        "dni": persona.dni,
        "rol": persona.rol,
        "telefono": persona.telefono,
        "partido": settings.credencial_partido or PARTIDO,
        "proceso": PROCESO,
        "foto_iniciales": iniciales(persona.nombres, persona.apellidos),
        "asignacion": {
            "mesa": table.numero_mesa,
            "tipo": asignacion.tipo,
            "estado": asignacion.estado,
            "local": venue.name,
            "direccion": venue.address,
            "distrito": distrito,
            "provincia": provincia,
            "ubigeo": venue.ubigeo or "",
        },
        "qr": qr,
        "qr_imagen": qr_imagen_dataurl(qr),
        "emitida_en": datetime.now(timezone.utc).isoformat(),
    }


# ---------------------------------------------------------------------------
# PDF (reportlab, 90×140 mm, texto vectorial + QR 300 DPI)
# ---------------------------------------------------------------------------
def _pagina_credencial(c, datos: dict, ancho: float, alto: float) -> None:
    from reportlab.lib.units import mm
    from reportlab.lib.utils import ImageReader

    rojo, azul, blanco = ROJO_CARMESI, AZUL_AREQUIPA, BLANCO
    # Cabecera carmesí del partido.
    c.setFillColor(rojo)
    c.rect(0, alto - 30 * mm, ancho, 30 * mm, stroke=0, fill=1)
    c.setFillColor(blanco)
    c.setFont("Helvetica-Bold", 13)
    c.drawCentredString(ancho / 2, alto - 13 * mm, datos["partido"])
    c.setFont("Helvetica-Bold", 6.2)
    c.drawCentredString(ancho / 2, alto - 19.5 * mm, "ELECCIONES REGIONALES Y MUNICIPALES")
    c.setFont("Helvetica", 6)
    c.drawCentredString(ancho / 2, alto - 24 * mm, "AREQUIPA 2026 · CREDENCIAL DE PERSONERO")
    # Franja azul arequipeña.
    c.setFillColor(azul)
    c.rect(0, alto - 33 * mm, ancho, 3 * mm, stroke=0, fill=1)

    y = alto - 38 * mm
    # Foto con recuadro + badge.
    c.setStrokeColor(azul)
    c.setLineWidth(1.2)
    c.rect(8 * mm, y - 34 * mm, 28 * mm, 34 * mm, stroke=1, fill=0)
    c.setFillColor(azul)
    c.setFont("Helvetica-Bold", 22)
    c.drawCentredString(22 * mm, y - 21 * mm, datos["foto_iniciales"])
    c.setFillColor(rojo)
    c.circle(33 * mm, y - 5 * mm, 6 * mm, stroke=0, fill=1)
    c.setFillColor(blanco)
    c.setFont("Helvetica-Bold", 7)
    c.drawCentredString(33 * mm, y - 3.2 * mm, "FA")
    # Identidad.
    c.setFillColor((0.1, 0.1, 0.1))
    c.setFont("Helvetica", 6)
    c.drawString(40 * mm, y - 6 * mm, "NOMBRES Y APELLIDOS")
    c.setFont("Helvetica-Bold", 10.5)
    for i, linea in enumerate([datos["nombres"], datos["apellidos"]]):
        c.drawString(40 * mm, y - (12 + i * 6) * mm, (linea or "")[:26])
    c.setFont("Helvetica", 6)
    c.drawString(40 * mm, y - 27 * mm, "DNI")
    c.setFont("Helvetica-Bold", 12)
    c.drawString(40 * mm, y - 33 * mm, datos["dni"])
    # Asignación.
    a = datos["asignacion"]
    y2 = y - 40 * mm
    c.setFillColor(azul)
    c.setFont("Helvetica-Bold", 6.5)
    c.drawString(8 * mm, y2, "DISTRITO")
    c.setFillColor((0.1, 0.1, 0.1))
    c.setFont("Helvetica-Bold", 9)
    c.drawString(8 * mm, y2 - 5 * mm, a["distrito"][:32])
    c.setFillColor(azul)
    c.setFont("Helvetica-Bold", 6.5)
    c.drawString(8 * mm, y2 - 11 * mm, "LOCAL DE VOTACIÓN")
    c.setFillColor((0.1, 0.1, 0.1))
    c.setFont("Helvetica-Bold", 9)
    c.drawString(8 * mm, y2 - 16 * mm, a["local"][:34])
    c.setFont("Helvetica", 6.5)
    c.drawString(8 * mm, y2 - 21 * mm, (a["direccion"] or "")[:44])
    # Mesa destacada.
    c.setFillColor(rojo)
    c.setFont("Helvetica-Bold", 7)
    c.drawString(8 * mm, y2 - 28 * mm, "N° DE MESA")
    c.setFont("Helvetica-Bold", 20)
    c.drawString(8 * mm, y2 - 37 * mm, a["mesa"])
    c.setFont("Helvetica", 6.5)
    c.setFillColor((0.3, 0.3, 0.3))
    c.drawString(48 * mm, y2 - 33 * mm, f"{a['tipo']} · {a['estado']}")
    c.drawString(48 * mm, y2 - 37 * mm, a["ubigeo"])
    # QR + firma.
    qr_b64 = datos["qr_imagen"].split(",", 1)[1]
    qr_img = ImageReader(io.BytesIO(base64.b64decode(qr_b64)))
    c.drawImage(qr_img, 8 * mm, 24 * mm, width=28 * mm, height=28 * mm,
                preserveAspectRatio=True)
    c.setFillColor((0.3, 0.3, 0.3))
    c.setFont("Helvetica", 5.5)
    c.drawString(8 * mm, 20.5 * mm, "Escanee para verificar")
    c.drawString(8 * mm, 17.5 * mm, datos["qr"][:27] + "…")
    c.setStrokeColor((0.2, 0.2, 0.2))
    c.setLineWidth(0.6)
    c.line(42 * mm, 26 * mm, 82 * mm, 26 * mm)
    c.setFont("Helvetica", 6)
    c.drawCentredString(62 * mm, 22 * mm, "Firma Personero Legal")
    c.drawCentredString(62 * mm, 19 * mm, PARTIDO.title())
    # Pie azul.
    c.setFillColor(azul)
    c.rect(0, 0, ancho, 12 * mm, stroke=0, fill=1)
    c.setFillColor(blanco)
    c.setFont("Helvetica", 5.5)
    c.drawCentredString(ancho / 2, 7 * mm, "Válida solo con QR verificable en el sistema")
    c.setFont("Helvetica-Bold", 5.5)
    c.drawCentredString(ancho / 2, 3.8 * mm, datos["qr"])


def pdf_credencial(datos: dict) -> bytes:
    """PDF de una credencial (90×140 mm)."""
    from reportlab.lib.units import mm
    from reportlab.pdfgen import canvas

    buf = io.BytesIO()
    ancho, alto = 90 * mm, 140 * mm
    c = canvas.Canvas(buf, pagesize=(ancho, alto))
    c.setTitle(f"Credencial {datos['dni']} mesa {datos['asignacion']['mesa']}")
    _pagina_credencial(c, datos, ancho, alto)
    c.showPage()
    c.save()
    return buf.getvalue()


def pdf_credenciales_bulk(credenciales: list[dict]) -> bytes:
    """PDF multipágina (una credencial por página, 90×140 mm)."""
    from reportlab.lib.units import mm
    from reportlab.pdfgen import canvas

    if not credenciales:
        raise ValueError("sin credenciales para el bulk")
    buf = io.BytesIO()
    ancho, alto = 90 * mm, 140 * mm
    c = canvas.Canvas(buf, pagesize=(ancho, alto))
    c.setTitle(f"Credenciales {PARTIDO} ({len(credenciales)})")
    for datos in credenciales:
        _pagina_credencial(c, datos, ancho, alto)
        c.showPage()
    c.save()
    return buf.getvalue()
