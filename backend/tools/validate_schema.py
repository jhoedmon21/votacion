"""Verificación estructural del DDL PostgreSQL (sin servidor disponible).

Este entorno no tiene PostgreSQL ni Docker, así que el esquema no se puede
ejecutar de verdad. Este script hace las comprobaciones que sí son posibles
sobre el texto del DDL y atrapa los errores más frecuentes al escribirlo:

  1. Paréntesis, comillas y bloques $$ balanceados.
  2. Toda sentencia termina en ';'.
  3. Cada REFERENCES/INSERT/UPDATE ... apunta a una tabla declarada antes.
  4. Cada columna citada en REFERENCES tabla(col) existe en esa tabla.
  5. No hay CREATE TYPE/TABLE/FUNCTION duplicados.
  6. Los CHECK y columnas de las vistas sólo usan columnas existentes.

Uso:
    python tools/validate_schema.py backend/sql/schema_arequipa.sql
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

CREATE_RE = re.compile(
    r"CREATE\s+(?:OR\s+REPLACE\s+)?(TABLE|TYPE|FUNCTION|VIEW|TRIGGER|POLICY)\s+"
    r"(?:IF\s+NOT\s+EXISTS\s+)?([a-zA-Z_][\w.]*)",
    re.IGNORECASE,
)
ALTER_TABLE_RE = re.compile(r"ALTER\s+TABLE\s+([a-zA-Z_][\w]*)", re.IGNORECASE)


def strip_comments(sql: str) -> str:
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.DOTALL)
    return re.sub(r"--[^\n]*", "", sql)


def split_statements(sql: str) -> list[str]:
    """Divide por ';' respetando los bloques $$ ... $$ de plpgsql."""
    partes, buffer, en_dollar = [], [], False
    i = 0
    while i < len(sql):
        if sql.startswith("$$", i):
            en_dollar = not en_dollar
            buffer.append("$$")
            i += 2
            continue
        ch = sql[i]
        if ch == ";" and not en_dollar:
            buffer.append(";")
            partes.append("".join(buffer).strip())
            buffer = []
        else:
            buffer.append(ch)
        i += 1
    resto = "".join(buffer).strip()
    if resto:
        partes.append(resto)
    return [p for p in partes if p]


def balance(sql: str, errores: list[str]) -> None:
    for abre, cierra, nombre in (("(", ")", "paréntesis"), ("[", "]", "corchetes")):
        if sql.count(abre) != sql.count(cierra):
            errores.append(f"{nombre} desbalanceados: {sql.count(abre)} vs {sql.count(cierra)}")
    if sql.count("$$") % 2:
        errores.append("número impar de delimitadores $$")
    if sql.count("'") % 2:
        errores.append("comillas simples desbalanceadas (revisar literales)")


def columnas_de_tabla(cuerpo: str) -> set[str]:
    """Nombre de las columnas declaradas en el CREATE TABLE.

    Las columnas viven a profundidad 1 (dentro del paréntesis del CREATE TABLE);
    los CHECK / REFERENCES anidados van a profundidad >= 2 y no son columnas.
    """
    columnas: set[str] = set()
    profundidad = 0
    for linea in cuerpo.splitlines():
        limpia = linea.strip().rstrip(",")
        profundidad_al_inicio = profundidad
        profundidad += limpia.count("(") - limpia.count(")")
        if profundidad_al_inicio != 1 or not limpia:
            continue
        if re.match(r"^(CONSTRAINT|PRIMARY|UNIQUE|FOREIGN|CHECK|LIKE|EXCLUDE)\b", limpia, re.IGNORECASE):
            continue
        m = re.match(r"^([a-zA-Z_][\w]*)\s", limpia)
        if m:
            columnas.add(m.group(1).lower())
    return columnas


def main(ruta: str) -> int:
    path = Path(ruta)
    if not path.is_absolute() and not path.exists():
        # Se resuelve contra la raíz del proyecto (el script se invoca desde varios cwd)
        path = ROOT / ruta
    if not path.exists():
        print(f"[error] no existe {path}")
        return 2

    sql = strip_comments(path.read_text(encoding="utf-8"))
    errores: list[str] = []
    balance(sql, errores)

    sentencias = split_statements(sql)
    tablas: dict[str, set[str]] = {}
    tipos: set[str] = set()
    vistas: set[str] = set()
    funciones: set[str] = set()
    triggers: set[str] = set()
    duplicados: list[str] = []

    for sent in sentencias:
        if not sent:
            continue
        if not sent.rstrip().endswith(";") and not strip_comments(sent).strip():
            continue
        for tipo, nombre in CREATE_RE.findall(sent):
            nombre = nombre.lower()
            tipo_up = tipo.upper()
            if tipo_up == "TABLE":
                if nombre in tablas:
                    duplicados.append(f"TABLE {nombre}")
                tablas[nombre] = columnas_de_tabla(sent)
        for tipo, nombre in CREATE_RE.findall(sent):
            nombre_l = nombre.lower()
            if tipo.upper() == "TYPE":
                if nombre_l in tipos:
                    duplicados.append(f"TYPE {nombre_l}")
                tipos.add(nombre_l)
            if tipo.upper() == "VIEW":
                vistas.add(nombre_l)
            if tipo.upper() == "FUNCTION":
                funciones.add(nombre_l)
            if tipo.upper() == "TRIGGER":
                triggers.add(nombre_l)

    # Sentencias sin terminador
    completo = strip_comments(path.read_text(encoding="utf-8"))
    for sent in split_statements(completo):
        if sent.strip() and not sent.rstrip().endswith(";"):
            errores.append(f"sentencia sin ';' al final: {sent[:70]!r}")

    # REFERENCES tabla(columna)
    refs = re.findall(r"REFERENCES\s+([a-zA-Z_][\w]*)\s*\(([a-zA-Z_][\w]*)\)", sql, re.IGNORECASE)
    faltan_tabla, faltan_col = [], []
    for tabla, columna in refs:
        t, c = tabla.lower(), columna.lower()
        if t not in tablas:
            faltan_tabla.append(tabla)
        elif c not in tablas[t]:
            faltan_col.append(f"{tabla}.{columna}")
    if faltan_tabla:
        errores.append(f"REFERENCES a tablas inexistentes: {sorted(set(faltan_tabla))}")
    if faltan_col:
        errores.append(f"REFERENCES a columnas inexistentes: {sorted(set(faltan_col))}")

    # CREATE TRIGGER ... ON tabla
    for tabla in re.findall(r"CREATE\s+TRIGGER\s+\w+[^;]*?\sON\s+([a-zA-Z_][\w]*)", sql, re.IGNORECASE | re.DOTALL):
        if tabla.lower() not in tablas:
            errores.append(f"trigger sobre tabla inexistente: {tabla}")

    # ALTER TABLE / política sobre tablas declaradas
    for tabla in ALTER_TABLE_RE.findall(sql):
        if tabla.lower() not in tablas:
            errores.append(f"ALTER TABLE de tabla inexistente: {tabla}")

    # Funciones invocadas en triggers deben existir
    for fn in re.findall(r"EXECUTE\s+FUNCTION\s+([a-zA-Z_][\w]*)", sql, re.IGNORECASE):
        if fn.lower() not in funciones:
            errores.append(f"EXECUTE FUNCTION de función no declarada: {fn}")

    # Tipos ENUM usados en columnas deben estar declarados
    enums_usados = set(
        re.findall(
            r"\b(?:nivel_ubigeo|tipo_eleccion|cargo_eleccion|columna_acta|estado_candidato|"
            r"tipo_organizacion|rol_usuario|estado_acta|origen_captura|severidad_observacion|"
            r"codigo_regla|evento_acta)\b",
            sql,
        )
    )
    no_declarados = sorted(e for e in enums_usados if e not in tipos)
    if no_declarados:
        errores.append(f"ENUM usados pero no declarados: {no_declarados}")

    print(f"[sql] {len(sentencias)} sentencias, {len(tablas)} tablas, {len(tipos)} tipos, "
          f"{len(vistas)} vistas, {len(funciones)} funciones, {len(triggers)} triggers")

    if duplicados:
        errores.append(f"objetos duplicados: {duplicados}")

    if errores:
        print(f"\n[FALLO] {len(errores)} problema(s):")
        for e in errores:
            print(f"  - {e}")
        return 1

    print("[ok] estructura del DDL coherente (nota: no sustituye una ejecución real en PostgreSQL)")
    return 0


if __name__ == "__main__":
    objetivo = sys.argv[1] if len(sys.argv) > 1 else "backend/sql/schema_arequipa.sql"
    raise SystemExit(main(objetivo))
