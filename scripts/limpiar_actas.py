"""Limpieza TOTAL de actas del sistema de computo electoral.

Deja el sistema en estado pre-jornada:
  * Vacia las tablas de digitacion (votos, metadata, auditoria, rechazos,
    adjuntos, eventos, observaciones, columnas/detalle, incidencias de campo
    y log de accesos).
  * Reinicia las 4194 mesas del padron ONPE a PENDIENTE (processed=false,
    status='pending', sin foto ni OCR).
  * NO toca padron ni catalogos: venues, ubigeo, usuarios, organizaciones,
    candidatos, sesiones y asignaciones de personeros quedan intactos.

Seguridad:
  * Hace backup CSV de cada tabla afectada en backend/backups/ antes de
    borrar (salvo --sin-backup).
  * Exige --si para ejecutar; sin el flag solo imprime el plan (dry-run).

Uso (desde backend/):
  Windows:  venv\Scripts\python.exe ..\scripts\limpiar_actas.py --si
  Linux:    venv/bin/python3 ../scripts/limpiar_actas.py --si
Toma la conexion de DATABASE_URL en backend/.env (o la local por defecto).
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from datetime import datetime
from pathlib import Path

import psycopg2


def _conexion() -> dict:
    """Lee DATABASE_URL de backend/.env (server); si no existe, usa la
    conexion local por defecto de la maquina de desarrollo."""
    env = Path(__file__).resolve().parent.parent / "backend" / ".env"
    if env.exists():
        for linea in env.read_text(encoding="utf-8").splitlines():
            if linea.strip().startswith("DATABASE_URL="):
                url = linea.split("=", 1)[1].strip()
                m = re.match(
                    r"postgres(?:ql)?(?:\+\w+)?://([^:]+):([^@]*)@([^:/]+):?(\d+)?/(\w+)",
                    url,
                )
                if m:
                    u, p, h, port, db = m.groups()
                    return dict(host=h or "localhost", port=int(port or 5432),
                                dbname=db, user=u, password=p)
    return dict(host="localhost", dbname="computo_arequipa", user="postgres",
                password="Areq2026!pg")


DB = _conexion()

# Tablas de digitacion que se vacian por completo.
TRUNCAR = [
    "records",
    "acta_metadata",
    "acta_auditoria_global",
    "acta_rechazos",
    "acta_adjuntos",
    "acta_eventos",
    "acta_observaciones",
    "acta_columnas",
    "detalle_votos_acta",
    "incidencia_adjuntos",
    "incidencia_seguimiento",
    "incidencias_campo",
    "accesos_log",
]

# Columnas de la mesa que se reinician (la mesa misma NUNCA se borra:
# es el padron ONPE de 4194 mesas).
RESET_MESA = """
UPDATE tables
SET processed = FALSE,
    requires_review = FALSE,
    status = 'pending',
    ocr_confidence = NULL,
    image_url = NULL,
    updated_at = NOW()
"""

BACKUP_DIR = Path(__file__).resolve().parent.parent / "backend" / "backups"


def conteos(cur, tablas):
    out = {}
    for t in tablas:
        try:
            cur.execute(f"SELECT COUNT(*) FROM {t}")
            out[t] = cur.fetchone()[0]
        except Exception:
            cur.connection.rollback()
            out[t] = None
    return out


def backup(cur, destino: Path) -> list[str]:
    """Copia cada tabla no vacia a CSV. Devuelve las que respaldó."""
    hechos = []
    destino.mkdir(parents=True, exist_ok=True)
    for t in TRUNCAR:
        try:
            cur.execute(f"SELECT COUNT(*) FROM {t}")
            n = cur.fetchone()[0]
        except Exception:
            cur.connection.rollback()
            continue
        if n == 0:
            continue
        ruta = destino / f"{t}.csv"
        with ruta.open("w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            cur.execute(f"SELECT * FROM {t}")
            w.writerow([d[0] for d in cur.description])
            for fila in cur:
                w.writerow(fila)
        hechos.append(f"{t} ({n} filas)")
    return hechos


def main() -> int:
    ap = argparse.ArgumentParser(description="Limpieza total de actas")
    ap.add_argument("--si", action="store_true", help="ejecutar de verdad")
    ap.add_argument("--sin-backup", action="store_true",
                    help="no respaldar a CSV antes de borrar")
    args = ap.parse_args()

    conn = psycopg2.connect(**DB)
    cur = conn.cursor()

    antes = conteos(cur, TRUNCAR + ["tables"])
    cur.execute("SELECT COUNT(*) FROM tables WHERE processed = TRUE OR status <> 'pending'")
    mesas_con_datos = cur.fetchone()[0]

    print("=== PLAN DE LIMPIEZA ===")
    for t, n in antes.items():
        print(f"  {t}: {n}")
    print(f"  mesas con acta/procesadas: {mesas_con_datos}")
    print("  catalogos intactos: venues, ubigeo, usuarios, organizaciones, candidatos, sesiones")

    if not args.si:
        print("\nDRY-RUN: no se borro nada. Agrega --si para ejecutar.")
        conn.close()
        return 0

    if not args.sin_backup:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        hechos = backup(cur, BACKUP_DIR / f"limpieza_{ts}")
        print(f"\nBackup CSV en {BACKUP_DIR / f'limpieza_{ts}'}")
        for h in hechos:
            print(f"  + {h}")
        if not hechos:
            print("  (nada que respaldar)")

    print("\nTruncando tablas de digitacion...")
    cur.execute(f"TRUNCATE TABLE {', '.join(TRUNCAR)} RESTART IDENTITY CASCADE")
    print("Reiniciando 4194 mesas a PENDIENTE...")
    cur.execute(RESET_MESA)
    conn.commit()

    despues = conteos(cur, TRUNCAR)
    cur.execute("SELECT COUNT(*) FROM tables WHERE processed = FALSE AND status = 'pending'")
    pendientes = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM tables")
    total = cur.fetchone()[0]

    print("\n=== RESULTADO ===")
    for t, n in despues.items():
        print(f"  {t}: {n}")
    print(f"  mesas pendientes: {pendientes}/{total}")

    ok = all(n == 0 for n in despues.values()) and pendientes == total == 4194
    print("\nLIMPIEZA COMPLETA" if ok else "\nATENCION: verificar resultado")
    conn.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
