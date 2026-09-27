"""API v1 — Registro, OCR y Cómputo Electoral (contrato OpenAPI estable).

Endpoints:
  * ``POST /api/v1/actas/registrar`` — recibe el JSON del formulario réplica
    ONPE, valida la suma contra ``electores_habiles`` y persiste:
    NORMAL (cuadra, entra al cómputo) u OBSERVADA/IMPUGNADA (no contabiliza,
    queda para revisión del coordinador con sus hallazgos R1-R8).
  * ``POST /api/v1/actas/ocr-preview`` — previsualización OCR sin guardar:
    OpenCV (grayscale + Otsu) y dígitos con PyTesseract.
  * ``GET /api/v1/resultados/resumen`` — KPIs consolidados del cómputo.

Implementa el DDL productivo ``backend/sql/schema.sql`` sobre el prototipo:
los estados NORMAL/OBSERVADA/IMPUGNADA y la regla "se guarda, no se cuenta
hasta resolver" son los mismos del esquema UUID.
"""
from __future__ import annotations

import logging
from pathlib import Path
from uuid import uuid4

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.core.auth import (alcance_ubigeos, es_rol_global, requerir_rol,
                            usuario_actual, validar_alcance_venue,
                            venues_en_alcance)
from app.core.database import SessionLocal, get_db
from app.core.models import (ActaMetadata, ActaRechazo, ConsejeroCandidate,
                              DistrictCandidate, ProvincialCandidate, Record,
                              RegionalCandidate, Table, Usuario, Venue)
from app.core.schemas import (V1ActaStatusFila, V1ActaStatusTotales,
                               V1ConsejeroProvincia, V1GanadorDistrito,
                               V1InconsistenciaActa, V1LocalOpt,
                               V1OcrPreviewOut, V1RegistrarIn, V1RegistrarOut,
                               V1ResumenOut, V1ResumenStatusOut)
from app.core.ubigeo import candidatos_del_ambito, nivel_desde_tipo
from app.core.ubigeo import ubigeo_de_nivel
from app.core.ubigeo_catalogo import PROVINCIA_NOMBRE, UBIGEO_PROVINCIA
from app.services.acta_validator import (COLUMNA_PRINCIPAL, ColumnaActa,
                                          validar_acta)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1", tags=["v1"])

MODELOS = {
    "district": DistrictCandidate,
    "provincial": ProvincialCandidate,
    "consejero": ConsejeroCandidate,
    "regional": RegionalCandidate,
}

ROLES_REGISTRO = ("SUPER_ADMIN", "DIGITADOR_GLOBAL", "RESPONSABLE_DISTRITAL", "COORD_PROVINCIAL",
                  "COORD_LOCAL", "DELEGADO_MESA", "PERSONERO")


def _oferta(db: Session, venue_ubigeo: str, clave: str):
    modelo = MODELOS[clave]
    filas = list(candidatos_del_ambito(
        db, modelo, ubigeo_de_nivel(venue_ubigeo, clave)).all())
    por_nombre = {c.party: c for c in filas if c.party}
    por_orden = {str(c.sort_order): c for c in filas}
    return filas, por_nombre, por_orden


@router.post("/actas/foto")
async def subir_foto_acta(file: UploadFile = File(...),
                          usuario: Usuario = Depends(requerir_rol(*ROLES_REGISTRO))):
    """Sube la imagen del acta y devuelve su URL pública.

    No registra nada: el formulario la asocia vía ``image_url`` al momento de
    ``POST /actas/registrar`` (así la foto puede subirse antes de digitar).
    """
    tipo = (file.content_type or "").lower()
    if not tipo.startswith("image/"):
        raise HTTPException(status_code=422, detail="Sólo se aceptan imágenes del acta")
    from app.services.storage import storage_service
    tmp_dir = Path("./tmp")
    tmp_dir.mkdir(exist_ok=True)
    suffix = Path(file.filename or "acta.jpg").suffix or ".jpg"
    tmp_path = tmp_dir / f"foto_acta_{uuid4().hex}{suffix}"
    try:
        tmp_path.write_bytes(await file.read())
        # La foto se NORMALIZA antes de almacenarse: orientación EXIF,
        # máx. 1600 px y WebP de alta calidad — el acta sigue legible para el
        # cotejo/OCR pero pesa una fracción del original del celular.
        # FOTO SIEMPRE ACEPTADA: si el procesamiento falla (formato exótico,
        # imagen corrupta) se guarda el ORIGINAL tal cual — la evidencia
        # nunca se rechaza por no poder comprimirse.
        metricas: dict = {}
        try:
            from app.services.imagen_acta import procesar_acta
            tmp_path, metricas = procesar_acta(tmp_path)
        except Exception:  # noqa: BLE001 — formato exótico/corrupta: respaldo
            logger.warning("Foto sin procesar (se guarda original): %s", file.filename)
            metricas = {}
        url = storage_service.upload(
            str(tmp_path),
            filename=f"actas/{uuid4().hex}{tmp_path.suffix or '.webp'}",
        )
    finally:
        tmp_path.unlink(missing_ok=True)
    return {"url": url, "procesamiento": metricas}


@router.get("/almacenamiento/estadisticas")
def estadisticas_almacenamiento(db: Session = Depends(get_db),
                                usuario: Usuario = Depends(usuario_actual)):
    """Estadísticas de almacenamiento de las fotos de actas (tarjeta del panel).

    * Con foto / sin foto: cobertura de evidencia fotográfica sobre el total
      de mesas del padrón.
    * Espacio: suma de pesos finales guardados vs. los pesos originales que
      habría ocupado la misma foto sin el procesamiento WebP en servidor.
    """
    _ = usuario
    total_mesas = db.query(func.count(Table.id)).scalar() or 0
    con_foto = (
        db.query(func.count(Table.id))
        .filter(Table.image_url.isnot(None), Table.image_url != "")
        .scalar() or 0
    )
    pesos = (
        db.query(
            func.coalesce(func.sum(ActaMetadata.image_peso_original_kb), 0.0),
            func.coalesce(func.sum(ActaMetadata.image_peso_final_kb), 0.0),
        )
        .filter(ActaMetadata.image_peso_final_kb > 0)
        .one()
    )
    original_kb = float(pesos[0] or 0)
    final_kb = float(pesos[1] or 0)
    ahorro_kb = max(0.0, original_kb - final_kb)
    return {
        "total_mesas": total_mesas,
        "con_foto": con_foto,
        "sin_foto": max(0, total_mesas - con_foto),
        "cobertura_foto_pct": round(100 * con_foto / total_mesas, 2) if total_mesas else 0.0,
        "imagenes_procesadas": (
            db.query(func.count(ActaMetadata.id))
            .filter(ActaMetadata.image_peso_final_kb > 0)
            .scalar() or 0
        ),
        "peso_original_kb": round(original_kb, 1),
        "peso_final_kb": round(final_kb, 1),
        "ahorro_kb": round(ahorro_kb, 1),
        "ahorro_pct": round(100 * ahorro_kb / original_kb, 1) if original_kb else 0.0,
        # Contador de actas vacías detectadas y rechazadas (regla R0) y
        # de los demás rechazos de integridad (R1/R2), del log acta_rechazos.
        "actas_vacias_rechazadas": (
            db.query(func.count(ActaRechazo.id))
            .filter(ActaRechazo.regla == "R0_ACTA_VACIA")
            .scalar() or 0
        ),
        "rechazos_integridad": (
            db.query(func.count(ActaRechazo.id))
            .filter(ActaRechazo.regla != "R0_ACTA_VACIA")
            .scalar() or 0
        ),
    }


@router.post("/actas/registrar", response_model=V1RegistrarOut)
def registrar(payload: V1RegistrarIn, db: Session = Depends(get_db),
              usuario: Usuario = Depends(requerir_rol(*ROLES_REGISTRO))):
    """Registra el acta digitada con validación matemática ONPE.

    * Mesa fuera del padrón → 404. Fuera del alcance → 403.
    * Matemática inconsistente o padrón superado → estado OBSERVADA (409 con
      hallazgos si además hay duplicidad; si no, 200 con estado OBSERVADA).
    * ``impugnada=true`` → estado IMPUGNADA.
    * Sólo NORMAL crea votos contabilizados (``records``); OBSERVADA/IMPUGNADA
      guarda el consolidado en metadata y marca la mesa para revisión.
    """
    tipo = (payload.tipo_eleccion or "").upper()
    clave = nivel_desde_tipo(tipo)
    if clave is None:
        raise HTTPException(status_code=422, detail=f"Tipo de elección inválido: {payload.tipo_eleccion}")

    table = db.query(Table).filter(Table.numero_mesa == payload.numero_mesa).first()
    if table is None:
        raise HTTPException(
            status_code=404,
            detail=f"Mesa {payload.numero_mesa} no está en el padrón de locales",
        )
    venue = validar_alcance_venue(db, usuario, table.venue_id)
    # Presencia + asignación: el personero registra sólo sus mesas con
    # check-in GPS válido en el local.
    from app.routers.campo import exigir_asignacion, exigir_presencia
    exigir_asignacion(db, usuario, table.id, payload.numero_mesa)
    exigir_presencia(db, usuario, venue.id)
    habiles = table.electores_habiles or 0
    if habiles <= 0:
        raise HTTPException(
            status_code=422,
            detail=f"Mesa {payload.numero_mesa} sin padrón de electores hábiles",
        )
    # R5 estricta: el acta FÍSICA es la evidencia del registro — sin su
    # fotografía el dato no es verificable y NO se registra.
    if not payload.image_url:
        raise HTTPException(
            status_code=422,
            detail="FALTA CARGAR ACTA: adjunte la fotografía del acta física antes de registrar. Es obligatoria como evidencia.",
        )

    _, por_nombre, por_orden = _oferta(db, venue.ubigeo or "", clave)
    no_mapeados = [k for k in payload.votos
                   if k not in por_nombre and str(k) not in por_orden]
    if no_mapeados:
        raise HTTPException(
            status_code=422,
            detail=f"Organizaciones desconocidas en el acta: {', '.join(sorted(no_mapeados))}",
        )

    # Caracteres/casillas inválidas: el esquema ya rechaza decimales y
    # letras (422 de Pydantic); aquí se corta explícitamente el negativo.
    _negativos = {k: v for k, v in payload.votos.items() if int(v) < 0}
    if _negativos:
        raise HTTPException(
            status_code=422,
            detail=("CASILLAS INVÁLIDAS: no se permiten valores negativos "
                    f"({', '.join(sorted(_negativos))}). Verifique contra el "
                    "acta física."),
        )

    columna = ColumnaActa(
        columna=COLUMNA_PRINCIPAL.get(tipo, "ALCALDE"),
        votos={str(k): int(v) for k, v in payload.votos.items()},
        votos_blancos=payload.votos_blancos,
        votos_nulos=payload.votos_nulos,
        votos_impugnados=payload.votos_impugnados,
        total_votantes=payload.total_emitidos,
    )
    ya_registrada = (
        db.query(Record.id).filter(
            Record.table_id == table.id, Record.candidate_type == clave).first()
        is not None
    )
    res = validar_acta(
        tipo_eleccion=tipo,
        electores_habiles=habiles,
        columnas=[columna],
        foto_presente=True,
        acta_ya_registrada=ya_registrada,
    )

    # Regla de negocio del cliente: la suma digitada DEBE cuadrar con el
    # total emitido antes de guardar. Un descuadre (o superar el padrón) no
    # se registra: se rechaza con 409 y el formulario muestra el mensaje
    # interactivo para corregir los números.
    # R6 — Concentración atípica (advertencia con doble confirmación): una
    # organización con >90% de los votos válidos de la mesa es estadísticamente
    # inusual (fraude o error de digitación). NO bloquea: exige que el
    # digitador reconfirme contra el acta física (confirmado_atipico=true).
    # Cero votos preferenciales en la lista ganadora con voto agrupado alto
    # se menciona en la misma advertencia (casilla aplicable del acta).
    votos_validos = sum(int(v) for v in payload.votos.values())
    if (not payload.impugnada and not payload.confirmado_atipico
            and not payload.forzar_revision and votos_validos > 0):
        _ganador = max(payload.votos.items(), key=lambda kv: kv[1])
        if _ganador[1] > 0.9 * votos_validos:
            _cand = por_nombre.get(_ganador[0]) or por_orden.get(str(_ganador[0]))
            _nombre = getattr(_cand, "party", None) or _ganador[0]
            raise HTTPException(
                status_code=409,
                detail={
                    "mensaje": (
                        f"VOTOS INUSUALES: {_nombre} concentra {_ganador[1]} de "
                        f"{votos_validos} votos válidos "
                        f"({round(100 * _ganador[1] / votos_validos, 1)}%). "
                        "Verifique contra el acta física y confirme la digitación."
                    ),
                    "regla": "R6_CONCENTRACION",
                    "requiere_confirmacion": True,
                    "hallazgos": [],
                },
            )

    # R1 conocido — Control de calidad: si el digitador no puede corregir el
    # descuadre (papel ilegible/dañado), puede enviar el acta a Revisión /
    # Acta Observada en lugar de guardarla como contabilizada.
    if payload.forzar_revision and not payload.impugnada:
        table.processed = False
        table.requires_review = True
        table.status = "requires_review"
        meta_prev = db.query(ActaMetadata).filter(
            ActaMetadata.table_id == table.id).first()
        if meta_prev is None:
            meta_prev = ActaMetadata(table_id=table.id)
            db.add(meta_prev)
        meta_prev.votos_blancos = payload.votos_blancos
        meta_prev.votos_nulos = payload.votos_nulos
        meta_prev.votos_impugnados = payload.votos_impugnados
        meta_prev.total_electores = habiles
        meta_prev.total_votantes = payload.total_emitidos
        _pie_nivel_rev = {
            "REGIONAL": "regional", "CONSEJERO": "consejero",
            "PROVINCIAL": "provincial", "DISTRITAL": "distrital",
        }.get(tipo)
        if _pie_nivel_rev:
            setattr(meta_prev, f"blancos_{_pie_nivel_rev}", payload.votos_blancos)
            setattr(meta_prev, f"nulos_{_pie_nivel_rev}", payload.votos_nulos)
            setattr(meta_prev, f"impugnados_{_pie_nivel_rev}", payload.votos_impugnados)
        try:
            with SessionLocal() as log_db:
                log_db.add(ActaRechazo(
                    numero_mesa=payload.numero_mesa, tipo_eleccion=tipo,
                    regla="R1_ENVIADA_REVISION",
                    mensaje=("Digitador envía el acta a Revisión / Acta "
                             "Observada (descuadre reconocido).")[:400],
                    usuario_email=usuario.email,
                ))
                log_db.commit()
        except Exception:  # noqa: BLE001
            pass
        db.commit()
        db.refresh(table)
        return {
            "acta_id": table.id,
            "numero_mesa": table.numero_mesa,
            "estado": "OBSERVADA",
            "hallazgos": [{
                "regla": "R1_ENVIADA_REVISION", "severidad": "ADVERTENCIA",
                "mensaje": "Acta enviada a Revisión / Acta Observada por el "
                           "digitador (descuadre reconocido contra la cabecera).",
                "diferencia": res.diferencia,
            }],
        }

    if not payload.impugnada and (not res.consistente or res.bloqueantes):
        bloqueantes = res.bloqueantes or [h for h in res.hallazgos if h.severidad == "BLOQUEANTE"]
        mensaje = (
            bloqueantes[0].mensaje
            if bloqueantes
            else "NO COINCIDEN LOS DATOS: la suma de votos no cuadra con el "
                 "total de votos emitidos. Corrige los números antes de guardar."
        )
        try:  # log de rechazos para el contador del panel (nunca rompe el flujo)
            db.add(ActaRechazo(
                numero_mesa=payload.numero_mesa, tipo_eleccion=tipo,
                regla=(bloqueantes[0].regla if bloqueantes else "R1_SUMA_VOTOS"),
                mensaje=mensaje[:400], usuario_email=usuario.email,
            ))
            db.commit()
        except Exception:  # noqa: BLE001
            db.rollback()
        raise HTTPException(
            status_code=409,
            detail={
                "mensaje": mensaje,
                "diferencia": res.diferencia,
                "hallazgos": [h.to_dict() for h in res.hallazgos],
            },
        )

    if payload.impugnada:
        estado = "IMPUGNADA"
    elif not res.consistente or res.bloqueantes:
        estado = "OBSERVADA"
    else:
        estado = "NORMAL"

    contabilizada = estado == "NORMAL"
    if contabilizada:
        for k, v in payload.votos.items():
            cand = por_nombre.get(k) or por_orden.get(str(k))
            reg = db.query(Record).filter(
                Record.table_id == table.id,
                Record.candidate_type == clave,
                Record.candidate_id == cand.id).first()
            if reg is None:
                db.add(Record(table_id=table.id, candidate_type=clave,
                              candidate_id=cand.id, votes=int(v), verified=True))
            else:
                reg.votes = int(v)
                reg.verified = True
        table.processed = True
        table.requires_review = False
        table.status = "processed"
    else:
        table.processed = False
        table.requires_review = True
        table.status = "requires_review"

    meta = db.query(ActaMetadata).filter(ActaMetadata.table_id == table.id).first()
    if meta is None:
        meta = ActaMetadata(table_id=table.id)
        db.add(meta)
    meta.votos_blancos = payload.votos_blancos
    meta.votos_nulos = payload.votos_nulos
    meta.votos_impugnados = payload.votos_impugnados
    meta.total_electores = habiles
    # Pie POR COLUMNA (norma ONPE): el registro trae el pie del nivel
    # digitado y se persiste en las columnas de ese nivel.
    _pie_nivel = {
        "REGIONAL": "regional", "CONSEJERO": "consejero",
        "PROVINCIAL": "provincial", "DISTRITAL": "distrital",
    }.get(tipo)
    if _pie_nivel:
        setattr(meta, f"blancos_{_pie_nivel}", payload.votos_blancos)
        setattr(meta, f"nulos_{_pie_nivel}", payload.votos_nulos)
        setattr(meta, f"impugnados_{_pie_nivel}", payload.votos_impugnados)
    # Votantes que sufragaron (cabecera): el PUT de rectificación lo necesita
    # para verificar el cuadre con los valores efectivos.
    meta.total_votantes = payload.total_emitidos
    if payload.image_url:
        table.image_url = payload.image_url
    # Métricas del procesamiento WebP (las entrega POST /v1/actas/foto).
    if payload.image_peso_original_kb is not None:
        meta.image_peso_original_kb = payload.image_peso_original_kb
    if payload.image_peso_final_kb is not None:
        meta.image_peso_final_kb = payload.image_peso_final_kb
    db.commit()
    db.refresh(table)

    logger.info("v1/registrar mesa %s %s -> %s (por %s)",
                payload.numero_mesa, tipo, estado, usuario.email)
    return V1RegistrarOut(
        acta_id=table.id,
        numero_mesa=table.numero_mesa,
        tipo_eleccion=tipo,
        estado=estado,
        total_emitidos=payload.total_emitidos,
        suma_partes=columna.suma_total,
        diferencia=res.diferencia,
        participacion_pct=res.participacion_pct,
        contabilizada=contabilizada,
        hallazgos=[
            {"regla": h.regla, "severidad": h.severidad, "mensaje": h.mensaje,
             "diferencia": h.diferencia}
            for h in res.hallazgos
        ],
    )


@router.post("/actas/ocr-preview", response_model=V1OcrPreviewOut)
async def ocr_preview(file: UploadFile = File(...),
                      usuario: Usuario = Depends(usuario_actual)):
    """OCR de previsualización (no guarda nada).

    Pipeline: grayscale → escalado ×2 → blur → umbral Otsu → Tesseract
    (sólo dígitos). Devuelve el N° de mesa probable y los números leídos
    para prellenar el formulario. 503 si falta OpenCV/Tesseract en el host.
    """
    _ = usuario
    tmp = Path("./tmp")
    tmp.mkdir(exist_ok=True)
    suffix = Path(file.filename or "acta.jpg").suffix or ".jpg"
    ruta = tmp / f"preview_{uuid4().hex}{suffix}"
    try:
        ruta.write_bytes(await file.read())
        return _ocr_otsu(str(ruta))
    finally:
        ruta.unlink(missing_ok=True)


def _ocr_otsu(ruta: str) -> V1OcrPreviewOut:
    try:
        import cv2
        import pytesseract
    except ImportError as exc:
        raise HTTPException(
            status_code=503,
            detail=f"OCR local no instalado en el servidor: {exc}") from exc

    img = cv2.imread(ruta, cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise HTTPException(status_code=422, detail="No se pudo leer la imagen")
    img = cv2.resize(img, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)
    img = cv2.GaussianBlur(img, (3, 3), 0)
    umbral, otsu = cv2.threshold(img, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)

    try:
        texto = pytesseract.image_to_string(
            otsu, config="--psm 6 -c tessedit_char_whitelist=0123456789")
    except Exception as exc:  # noqa: BLE001  (binario tesseract ausente, etc.)
        raise HTTPException(
            status_code=503, detail=f"Motor Tesseract no disponible: {exc}") from exc

    import re
    digitos = [int(n) for n in re.findall(r"\d{1,6}", texto or "")]
    m6 = re.search(r"\b(\d{6})\b", texto or "")
    return V1OcrPreviewOut(
        numero_mesa=m6.group(1) if m6 else None,
        digitos=digitos,
        total_campos=len(digitos),
        umbral_otsu=round(float(umbral), 2),
        confianza=0.55 if digitos else 0.0,
        advertencia=(None if digitos
                     else "No se leyeron dígitos: verifica la foto y digita manual"),
    )


@router.get("/ubigeo/provincias")
def provincias_region(db: Session = Depends(get_db),
                      usuario: Usuario = Depends(usuario_actual)):
    """Las 8 provincias de Arequipa con sus mesas en padrón, acotadas al
    alcance del usuario."""
    from app.core.ubigeo_catalogo import (DISTRITOS_POR_PROVINCIA,
                                           PROVINCIA_NOMBRE)
    _ = db
    if es_rol_global(usuario):
        visibles = sorted(DISTRITOS_POR_PROVINCIA)
    else:
        prefijos = sorted({(u or "").rstrip("0") or u
                           for u in alcance_ubigeos(usuario)})
        visibles = sorted(
            p for p, ds in DISTRITOS_POR_PROVINCIA.items()
            if any(u.startswith(pf) for u, _ in ds for pf in prefijos))
    salida = []
    for prov in visibles:
        ubigeos = [u for u, _ in DISTRITOS_POR_PROVINCIA[prov]]
        n_mesas = (db.query(Table).join(Venue, Venue.id == Table.venue_id)
                   .filter(Venue.ubigeo.in_(ubigeos)).count())
        n_locales = (db.query(Venue).filter(Venue.ubigeo.in_(ubigeos)).count())
        salida.append({"provincia": prov,
                       "nombre": PROVINCIA_NOMBRE.get(prov, prov),
                       "distritos": len(ubigeos), "locales": n_locales,
                       "mesas": n_mesas})
    return salida


@router.get("/ubigeo/distritos")
def distritos_region(provincia: str | None = Query(default=None),
                     db: Session = Depends(get_db),
                     usuario: Usuario = Depends(usuario_actual)):
    """Los 109 distritos con sus mesas en padrón (fuente de los selectores),
    opcionalmente filtrados por provincia. Acotado al alcance del usuario."""
    from app.core.ubigeo_catalogo import (DISTRITOS, DISTRITOS_POR_PROVINCIA,
                                           PROVINCIA_NOMBRE)
    if provincia is not None:
        prov = (provincia or "").strip().upper()
        if prov.isdigit():
            # Ubigeo de provincia (040700): filtra por prefijo territorial.
            pref = prov.rstrip("0") or prov
            base = [(u, p, n) for u, p, n in DISTRITOS if u.startswith(pref)]
        else:
            base = [(u, prov, n)
                    for u, n in DISTRITOS_POR_PROVINCIA.get(prov, [])]
    else:
        base = list(DISTRITOS)
    if es_rol_global(usuario):
        visibles = base
    else:
        prefijos = sorted({(u or "").rstrip("0") or u
                           for u in alcance_ubigeos(usuario)})
        visibles = [(u, p, n) for u, p, n in base
                    if any(u.startswith(pf) for pf in prefijos)]
    # Conteo de mesas en una sola consulta.
    conteo = dict(
        db.query(Venue.ubigeo, func.count(Table.id))
        .join(Table, Table.venue_id == Venue.id)
        .filter(Venue.ubigeo.in_([u for u, _, _ in visibles] or [""]))
        .group_by(Venue.ubigeo).all()
    ) if visibles else {}
    return [{"ubigeo": u, "provincia": p,
             "provincia_nombre": PROVINCIA_NOMBRE.get(p, p),
             "distrito": n, "mesas": conteo.get(u, 0)}
            for u, p, n in visibles]


@router.get("/mesas")
def mesas_por_ubigeo(ubigeo: str = Query(..., min_length=6, max_length=6),
                     db: Session = Depends(get_db),
                     usuario: Usuario = Depends(usuario_actual)):
    """Mesas del padrón de un distrito (para elegir mesa sin digitar)."""
    if not es_rol_global(usuario):
        prefijos = sorted({(u or "").rstrip("0") or u
                           for u in alcance_ubigeos(usuario)})
        if not any((ubigeo or "").startswith(p) for p in prefijos):
            raise HTTPException(status_code=403, detail="Distrito fuera de tu alcance")
    filas = (
        db.query(Table, Venue)
        .join(Venue, Venue.id == Table.venue_id)
        .filter(Venue.ubigeo == ubigeo)
        .order_by(Table.numero_mesa)
        .limit(500)
        .all()
    )
    return [{"numero_mesa": t.numero_mesa, "local": v.name,
             "electores_habiles": t.electores_habiles,
             "estado": t.status} for t, v in filas]


@router.get("/resultados/resumen", response_model=V1ResumenOut)
def resumen(tipo_eleccion: str = Query("DISTRITAL"),
            top: int = Query(10, ge=1, le=50),
            ubigeo: str = Query("", description="Foca el cómputo a un distrito (6d) o provincia (4d)"),
            db: Session = Depends(get_db),
            usuario: Usuario = Depends(usuario_actual)):
    """KPIs consolidados del cómputo: actas, avance, participación y partidos."""
    from app.core.ubigeo import NIVELES
    from app.services.processor import ensure_seed_data

    ensure_seed_data(db)
    clave = nivel_desde_tipo(tipo_eleccion) or "district"
    if clave not in NIVELES:
        clave = "district"

    venues = db.query(Venue)
    if not es_rol_global(usuario):
        ubigeos = alcance_ubigeos(usuario)
        prefijos = sorted({(u or "").rstrip("0") or u for u in ubigeos})
        venues = venues.filter(Venue.ubigeo.like(prefijos[0] + "%")) if prefijos else venues.filter(Venue.id < 0)
    # Foco geográfico del cómputo (clic en el mapa o filtro del tablero):
    # 6 dígitos = distrito exacto; 4 = toda la provincia.
    if ubigeo:
        if len(ubigeo) <= 4:
            venues = venues.filter(Venue.ubigeo.like(ubigeo + "%"))
        else:
            venues = venues.filter(Venue.ubigeo == ubigeo)
    venues = venues.all()
    vids = [v.id for v in venues]

    mesas = db.query(Table).filter(Table.venue_id.in_(vids)).all() if vids else []
    procesadas = [t for t in mesas if t.processed and not t.requires_review]
    observadas = [t for t in mesas if t.requires_review]
    pids = [t.id for t in procesadas]

    habiles = sum(t.electores_habiles or 0 for t in procesadas)
    # Sólo contabilizadas: los votos de OBSERVADA/IMPUGNADA no entran.
    votos_org = (db.query(func.coalesce(func.sum(Record.votes), 0))
                 .filter(Record.candidate_type == clave,
                         Record.table_id.in_(pids)).scalar() if pids else 0) or 0
    meta = (db.query(func.coalesce(func.sum(ActaMetadata.votos_blancos), 0),
                     func.coalesce(func.sum(ActaMetadata.votos_nulos), 0),
                     func.coalesce(func.sum(ActaMetadata.votos_impugnados), 0))
            .filter(ActaMetadata.table_id.in_(pids)).first()
            if pids else (0, 0, 0))
    blancos, nulos, impug = (int(x or 0) for x in meta)
    emitidos = int(votos_org) + blancos + nulos + impug

    modelo = MODELOS[clave]
    ambitos = sorted({ubigeo_de_nivel(v.ubigeo or "", clave) for v in venues})
    oferta = (db.query(modelo).filter(modelo.ubigeo.in_(ambitos)).all()
              if ambitos else [])
    totales = dict(
        db.query(Record.candidate_id, func.sum(Record.votes))
        .filter(Record.candidate_type == clave, Record.table_id.in_(pids))
        .group_by(Record.candidate_id).all()) if pids else {}
    filas = sorted(
        ({"organizacion": c.party or c.name, "candidato": c.name,
          "color": c.color or "#6b7280",
          "votos": int(totales.get(c.id, 0) or 0)} for c in oferta),
        key=lambda r: r["votos"], reverse=True)[:top]
    total_v = sum(r["votos"] for r in filas) or 1
    partidos = [{**r, "porcentaje": round(100.0 * r["votos"] / total_v, 2)} for r in filas]

    # Avance por distrito (ordenado: más atrasados primero).
    from app.core.ubigeo_catalogo import UBIGEO_DISTRITO
    por_ubigeo: dict[str, dict] = {}
    for v in venues:
        u = v.ubigeo or ""
        d = por_ubigeo.setdefault(u, {"mesas": 0, "actas": 0, "obs": 0})
        tm = [t for t in mesas if t.venue_id == v.id]
        d["mesas"] += len(tm)
        d["actas"] += sum(1 for t in tm if t.processed and not t.requires_review)
        d["obs"] += sum(1 for t in tm if t.requires_review)
    distritos = sorted(
        ({"ubigeo": u,
          "distrito": UBIGEO_DISTRITO.get(u, u),
          "mesas": d["mesas"], "actas": d["actas"], "observadas": d["obs"],
          "avance_pct": round(100.0 * d["actas"] / d["mesas"], 1) if d["mesas"] else 0.0}
         for u, d in por_ubigeo.items() if u),
        key=lambda r: (r["avance_pct"], -r["mesas"]))

    venue_por_id = {v.id: v for v in venues}

    # Control de integridad macro: cada acta contabilizada debe cumplir
    #   Σ votos digitados == total de VOTANTES de su cabecera
    # y los votantes no pueden superar los electores hábiles del padrón.
    # Lo que no cuadra son DATOS ERRÓNEOS: se listan para revisión y el
    # dashboard muestra la alerta.
    inconsistencias: list[V1InconsistenciaActa] = []
    total_votantes_actas = 0
    if pids:
        from app.core.ubigeo_catalogo import UBIGEO_DISTRITO as _UD

        # Regla ONPE por columna: la suma a comparar con los votantes es la
        # COLUMNA MAYOR del acta + blancos/nulos/impugnados, NO la suma de
        # todos los niveles (el mismo elector vota en cada columna del papel;
        # sumarlas daba falsos "DATOS ERRÓNEOS" con diferencia +N×niveles).
        sumas_nivel = (
            db.query(Record.table_id, Record.candidate_type, func.sum(Record.votes))
            .filter(Record.table_id.in_(pids))
            .group_by(Record.table_id, Record.candidate_type).all())
        sumas: dict[int, int] = {}
        for (tid, _nivel, s) in sumas_nivel:
            sumas[tid] = max(sumas.get(tid, 0), int(s or 0))
        metas = {m.table_id: m for m in (
            db.query(ActaMetadata)
            .filter(ActaMetadata.table_id.in_(pids)).all())}
        for t in procesadas:
            m = metas.get(t.id)
            blancos_a = m.votos_blancos if m else 0
            nulos_a = m.votos_nulos if m else 0
            impug_a = m.votos_impugnados if m else 0
            suma = int(sumas.get(t.id, 0) or 0) + blancos_a + nulos_a + impug_a
            votantes = int(m.total_votantes or 0) if m else 0
            total_votantes_actas += votantes
            vinfo = venue_por_id.get(t.venue_id)
            base = {
                "acta_id": t.id, "numero_mesa": t.numero_mesa,
                "local": vinfo.name if vinfo else "",
                "distrito": _UD.get((vinfo.ubigeo if vinfo else "") or "", ""),
                "suma_votos": suma, "total_votantes": votantes,
                "electores_habiles": t.electores_habiles or 0,
            }
            hab = t.electores_habiles or 0
            if hab and votantes > hab:
                # Imposible físico: lo más grave, se alerta primero.
                inconsistencias.append(V1InconsistenciaActa(
                    **base, diferencia=votantes - hab,
                    tipo="EXCEDE_PADRON",
                    mensaje=(
                        f"La mesa {t.numero_mesa} declara {votantes} votantes, "
                        "más que sus "
                        f"{hab} electores hábiles. IMPOSIBLE: revise el acta."
                    )))
            elif votantes == 0:
                # Sin cabecera de votantes no hay contra qué cuadrar.
                if suma > 0:
                    inconsistencias.append(V1InconsistenciaActa(
                        **base, diferencia=suma,
                        tipo="SIN_VOTANTES",
                        mensaje=(
                            f"La mesa {t.numero_mesa} registra {suma} votos pero "
                            "no tiene el total de VOTANTES que sufragaron. "
                            "Complete la cabecera del acta."
                        )))
            elif suma != votantes:
                inconsistencias.append(V1InconsistenciaActa(
                    **base, diferencia=suma - votantes,
                    tipo="DESCUADRE",
                    mensaje=(
                        f"La mesa {t.numero_mesa} registra {suma} votos emitidos "
                        f"pero su cabecera declara {votantes} votantes "
                        f"(diferencia {suma - votantes:+d}). DATOS ERRÓNEOS: "
                        "corrija el acta o verifique el papel."
                    )))

    # Ganador (organización más votada) por distrito para el mapa de resultados:
    # sólo mesas contabilizadas, empate -> primera alfabéticamente (determinista).
    ganadores: dict[str, V1GanadorDistrito] = {}
    if pids:
        filas_g = (
            db.query(Venue.ubigeo, modelo.party, modelo.color,
                     func.sum(Record.votes))
            .join(Table, Table.venue_id == Venue.id)
            .join(Record, (Record.table_id == Table.id)
                  & (Record.candidate_type == clave))
            .join(modelo, modelo.id == Record.candidate_id)
            .filter(Table.id.in_(pids), Venue.ubigeo != None)  # noqa: E711
            .group_by(Venue.ubigeo, modelo.party, modelo.color).all()
        )
        mejor: dict[str, tuple[int, str, str]] = {}
        for ubigeo, org, color, votos in filas_g:
            if not org:
                continue
            v = int(votos or 0)
            actual = mejor.get(ubigeo)
            if actual is None or v > actual[0] or (v == actual[0] and org < actual[1]):
                mejor[ubigeo] = (v, org, color or "#6b7280")
        for ubigeo, (v, org, color) in mejor.items():
            ganadores[ubigeo] = V1GanadorDistrito(
                organizacion=org, color=color, votos=v)

    # Consejo Regional POR PROVINCIA (sólo nivel ``consejero``): mismo cálculo
    # que el panel (app/services/consejeros.py) — curules oficiales, ganador
    # y reparto d'Hondt con electos por orden de lista. NO es resultado oficial.
    consejeros: list = []
    if clave == "consejero":
        from app.services.consejeros import resultado_por_provincia
        for p in resultado_por_provincia(db, pids):
            ganador = None
            if p.ganador:
                ganador = V1GanadorDistrito(
                    organizacion=p.ganador.organizacion,
                    color=p.ganador.color, votos=p.ganador.votos,
                    electos=p.ganador.electos,
                    foto=p.ganador.foto, logo=p.ganador.logo)
            escanos = [
                V1GanadorDistrito(
                    organizacion=e.organizacion, color=e.color, votos=e.votos,
                    electos=e.electos, foto=e.foto, logo=e.logo,
                    curules_ganados=e.curules_ganados)
                for e in p.escanos
            ]
            consejeros.append(V1ConsejeroProvincia(
                provincia=p.provincia, ubigeo=p.ubigeo,
                ganador=ganador, escanos=escanos, curules=p.curules))

    obs_lista = sorted( 
        ({"numero_mesa": t.numero_mesa,
          "acta_id": t.id,
          "local": venue_por_id.get(t.venue_id).name
          if venue_por_id.get(t.venue_id) else "",
          "ubigeo": venue_por_id.get(t.venue_id).ubigeo
          if venue_por_id.get(t.venue_id) else "",
          "distrito": UBIGEO_DISTRITO.get(
              venue_por_id.get(t.venue_id).ubigeo
              if venue_por_id.get(t.venue_id) else "", "")}
         for t in observadas),
        key=lambda r: r["numero_mesa"])[:100]

    total_mesas = len(mesas)
    return V1ResumenOut(
        total_mesas=total_mesas,
        total_actas=len(procesadas) + len(observadas),
        actas_normales=len(procesadas),
        actas_observadas=len(observadas),
        avance_pct=round(100.0 * len(procesadas) / total_mesas, 2) if total_mesas else 0.0,
        participacion_pct=round(100.0 * emitidos / habiles, 2) if habiles else 0.0,
        tipo_eleccion=tipo_eleccion.upper(),
        electores_habiles=habiles,
        votos_validos=int(votos_org),
        votos_blancos=blancos,
        votos_nulos=nulos,
        votos_impugnados=impug,
        votos_emitidos=emitidos,
        total_votantes_actas=total_votantes_actas,
        inconsistencias=inconsistencias,
        partidos=partidos,
        distritos=distritos,
        observadas=obs_lista,
        ganadores=ganadores,
        consejeros=consejeros,
    )


# ---------------------------------------------------------------------------
# Gestión de Actas — resumen de estado con filtros en cascada
# ---------------------------------------------------------------------------

# Estados del filtro `estado` (lo que ve el Digitador en el panel).
ESTADOS_STATUS = ("todas", "registradas", "pendientes", "observadas")


def _norm_texto(valor: str | None) -> str:
    """Mayúsculas sin acentos ni espacios extra (para comparar provincias)."""
    import unicodedata

    base = unicodedata.normalize("NFKD", (valor or "").strip().upper())
    base = "".join(c for c in base if not unicodedata.combining(c))
    return " ".join(base.split())


def _ubigeos_de_provincia(provincia: str) -> list[str]:
    """Ubigeos de una provincia (acepta nombre 'CAMANA' o prefijo '0402')."""
    from app.core.ubigeo_catalogo import DISTRITOS_POR_PROVINCIA

    clave = _norm_texto(provincia)
    if not clave:
        return []
    por_nombre = {_norm_texto(k): k for k in DISTRITOS_POR_PROVINCIA}
    if clave in por_nombre:
        return [u for u, _ in DISTRITOS_POR_PROVINCIA[por_nombre[clave]]]
    prefijo = clave.rstrip("0") or clave
    if prefijo.isdigit() and len(prefijo) >= 2:
        return [u for ds in DISTRITOS_POR_PROVINCIA.values()
                for u, _ in ds if u.startswith(prefijo)]
    return []


def _condicion_estado(estado: str):
    """Condición SQL del filtro de estado sobre Table."""
    from sqlalchemy import and_

    if estado == "registradas":
        return and_(Table.processed == True, Table.requires_review == False)  # noqa: E712
    if estado == "pendientes":
        return and_(Table.processed == False, Table.requires_review == False)  # noqa: E712
    if estado == "observadas":
        return Table.requires_review == True  # noqa: E712
    return None


def _estado_de_fila(t: Table) -> str:
    """Estado de una mesa para el badge del panel."""
    if t.requires_review:
        return "OBSERVADA"
    if t.processed:
        return "REGISTRADA"
    return "PENDIENTE"


@router.get("/ubigeo/locales", response_model=list[V1LocalOpt])
def locales_por_ubigeo(ubigeo: str = Query(..., min_length=6, max_length=6),
                       db: Session = Depends(get_db),
                       usuario: Usuario = Depends(usuario_actual)):
    """Locales de votación de un distrito con su n° de mesas (cascada).

    Acotado al alcance territorial salvo rol global (SUPER_ADMIN /
    DIGITADOR_GLOBAL, que consultan cualquier distrito).
    """
    if not es_rol_global(usuario):
        prefijos = sorted({(u or "").rstrip("0") or u
                           for u in alcance_ubigeos(usuario)})
        if not any((ubigeo or "").startswith(p) for p in prefijos):
            raise HTTPException(status_code=403, detail="Distrito fuera de tu alcance")
    venues = (db.query(Venue).filter(Venue.ubigeo == ubigeo)
              .order_by(Venue.name).all())
    conteo = dict(
        db.query(Table.venue_id, func.count(Table.id))
        .filter(Table.venue_id.in_([v.id for v in venues] or [-1]))
        .group_by(Table.venue_id).all()
    ) if venues else {}
    return [V1LocalOpt(id=v.id, nombre=v.name, ubigeo=v.ubigeo or "",
                       mesas=conteo.get(v.id, 0)) for v in venues]


@router.get("/actas/resumen-status", response_model=V1ResumenStatusOut)
def resumen_status(
    departamento: str = Query(default="AREQUIPA"),
    provincia: str | None = Query(default=None),
    distrito: str | None = Query(default=None, min_length=6, max_length=6),
    local_id: int | None = Query(default=None),
    estado: str = Query(default="todas"),
    mesa: str | None = Query(default=None, min_length=6, max_length=6),
    busqueda: str | None = Query(default=None, min_length=2, max_length=40),
    pagina: int = Query(default=1, ge=1),
    page_size: int = Query(default=15, ge=1, le=100),
    db: Session = Depends(get_db),
    usuario: Usuario = Depends(usuario_actual),
):
    """KPIs + lista paginada de actas bajo el filtro en cascada.

    Una sola llamada HTTP, dos consultas SQL optimizadas:
      1. Agregado con ``COUNT`` + ``SUM(CASE WHEN ...)`` sobre el join
         mesas↔locales (totales del filtro, sin importar `estado` ni `mesa`).
      2. Lista paginada (``LIMIT/OFFSET``) con el filtro de estado y la
         búsqueda exacta de mesa aplicados.
    El rol global (SUPER_ADMIN / DIGITADOR_GLOBAL) consulta cualquier
    combinación sin restricciones; el resto queda acotado a su alcance.
    """
    from sqlalchemy import case

    from app.core.ubigeo_catalogo import UBIGEO_DISTRITO

    estado_norm = (estado or "todas").lower()
    if estado_norm not in ESTADOS_STATUS:
        raise HTTPException(
            status_code=422,
            detail=f"estado inválido: {estado!r} (usa {list(ESTADOS_STATUS)})")
    if _norm_texto(departamento) != "AREQUIPA":
        raise HTTPException(status_code=422,
                            detail="departamento inválido: el sistema cubre AREQUIPA")
    if mesa is not None and not mesa.isdigit():
        raise HTTPException(status_code=422, detail="mesa: 6 dígitos exactos")

    # ---- Filtro territorial: parte del alcance y se estrecha por cascada.
    venues_q = venues_en_alcance(db, usuario)
    if provincia:
        ubigeos_prov = _ubigeos_de_provincia(provincia)
        if not ubigeos_prov:
            raise HTTPException(status_code=422,
                                detail=f"provincia desconocida: {provincia!r}")
        venues_q = venues_q.filter(Venue.ubigeo.in_(ubigeos_prov))
    if distrito:
        if distrito not in UBIGEO_DISTRITO:
            raise HTTPException(status_code=422,
                                detail=f"distrito desconocido: {distrito!r}")
        venues_q = venues_q.filter(Venue.ubigeo == distrito)
    if local_id is not None:
        venues_q = venues_q.filter(Venue.id == local_id)
    venues = venues_q.all()
    if local_id is not None and not venues:
        # Distingue "local inexistente" (404) de "fuera de alcance" (403).
        existe = db.query(Venue.id).filter(Venue.id == local_id).first()
        raise HTTPException(
            status_code=404 if existe is None else 403,
            detail=(f"Local {local_id} no existe" if existe is None
                    else "Local fuera de tu alcance territorial"))
    vids = [v.id for v in venues]
    venue_por_id = {v.id: v for v in venues}

    # ---- 1) Agregado en SQL (COUNT + SUM/CASE WHEN, una sola consulta).
    cond_base = [Table.venue_id.in_(vids)] if vids else [Table.id < 0]
    es_reg = (Table.processed == True) & (Table.requires_review == False)  # noqa: E712
    es_obs = (Table.requires_review == True)  # noqa: E712
    es_pen = (Table.processed == False) & (Table.requires_review == False)  # noqa: E712
    reg = case((es_reg, 1), else_=0)
    obs = case((es_obs, 1), else_=0)
    pen = case((es_pen, 1), else_=0)
    total, registradas, observadas, pendientes = (
        db.query(func.count(Table.id),
                 func.coalesce(func.sum(reg), 0),
                 func.coalesce(func.sum(obs), 0),
                 func.coalesce(func.sum(pen), 0))
        .filter(*cond_base).one()
    )
    total, registradas = int(total), int(registradas)
    observadas, pendientes = int(observadas), int(pendientes)

    # ---- 2) Lista paginada con estado + búsqueda exacta de mesa.
    lista_q = db.query(Table).filter(*cond_base)
    cond_estado = _condicion_estado(estado_norm)
    if cond_estado is not None:
        lista_q = lista_q.filter(cond_estado)
    if mesa is not None:
        lista_q = lista_q.filter(Table.numero_mesa == mesa)
    if busqueda:
        # Búsqueda de texto que el digitador usa para "encontrar el acta":
        # número de mesa (prefijo, así sirve con 4 dígitos), nombre del local o
        # nombre del distrito. El filtro `mesa` sigue siendo el exacto.
        from sqlalchemy import or_

        texto = busqueda.strip().upper()
        condiciones = []
        if texto.isdigit():
            condiciones.append(Table.numero_mesa.like(f"{texto}%"))
        por_local = [v.id for v in venues if texto in (v.name or "").upper()]
        if por_local:
            condiciones.append(Table.venue_id.in_(por_local))
        ubigeos_texto = {u for u, d in UBIGEO_DISTRITO.items() if texto in d}
        por_distrito = [v.id for v in venues if (v.ubigeo or "") in ubigeos_texto]
        if por_distrito:
            condiciones.append(Table.venue_id.in_(por_distrito))
        lista_q = (lista_q.filter(or_(*condiciones)) if condiciones
                   else lista_q.filter(Table.id < 0))
    total_filas = lista_q.count()
    total_paginas = max(1, -(-total_filas // page_size))
    pagina = min(pagina, total_paginas)
    filas_db = (lista_q.order_by(Table.numero_mesa)
                .offset((pagina - 1) * page_size).limit(page_size).all())

    # Digitador asignado (TITULAR más reciente por mesa, una sola consulta).
    ids = [t.id for t in filas_db]
    digitador_por_mesa: dict[int, str | None] = {}
    if ids:
        from app.core.models import AsignacionPersonero

        asigs = (
            db.query(AsignacionPersonero)
            .filter(AsignacionPersonero.mesa_id.in_(ids),
                    AsignacionPersonero.tipo == "TITULAR")
            .order_by(AsignacionPersonero.mesa_id,
                      AsignacionPersonero.created_at.desc()).all()
        )
        vistos: set[int] = set()
        titular_usuario: dict[int, int] = {}
        for a in asigs:
            if a.mesa_id not in vistos:
                vistos.add(a.mesa_id)
                titular_usuario[a.mesa_id] = a.usuario_id
        if titular_usuario:
            nombres = dict(
                db.query(Usuario.id, Usuario.nombres)
                .filter(Usuario.id.in_(set(titular_usuario.values()))).all())
            apellidos = dict(
                db.query(Usuario.id, Usuario.apellidos)
                .filter(Usuario.id.in_(set(titular_usuario.values()))).all())
            for mesa_id, uid in titular_usuario.items():
                digitador_por_mesa[mesa_id] = (
                    f"{nombres.get(uid, '')} {apellidos.get(uid, '')}".strip() or None)

    filas = []
    for t in filas_db:
        v = venue_por_id.get(t.venue_id)
        ub = v.ubigeo if v else ""
        filas.append(V1ActaStatusFila(
            acta_id=t.id, numero_mesa=t.numero_mesa, ubigeo=ub,
            distrito=UBIGEO_DISTRITO.get(ub, ub),
            provincia="",
            local_id=t.venue_id, local=v.name if v else "",
            estado=_estado_de_fila(t),
            digitador=digitador_por_mesa.get(t.id),
            actualizada_en=t.updated_at.isoformat() if t.updated_at else None,
            tiene_foto=bool(t.image_url),
        ))
    # Provincia legible por fila (nombre oficial del catálogo).
    from app.core.ubigeo_catalogo import DISTRITOS_POR_PROVINCIA

    ubigeo_a_prov: dict[str, str] = {}
    for prov, ds in DISTRITOS_POR_PROVINCIA.items():
        for u, _ in ds:
            ubigeo_a_prov[u] = prov
    for f in filas:
        f.provincia = ubigeo_a_prov.get(f.ubigeo, "")

    return V1ResumenStatusOut(
        filtros={"departamento": "AREQUIPA", "provincia": provincia,
                 "distrito": distrito,
                 "local_id": str(local_id) if local_id is not None else None,
                 "estado": estado_norm, "mesa": mesa, "busqueda": busqueda},
        totales=V1ActaStatusTotales(
            total=total, registradas=registradas, pendientes=pendientes,
            observadas=observadas,
            avance_pct=round(100.0 * registradas / total, 1) if total else 0.0),
        pagina=pagina, page_size=page_size,
        total_filas=total_filas, total_paginas=total_paginas, filas=filas,
    )
