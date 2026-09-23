"""
Script para actualizar la base de datos con candidatos extraídos del JNE.
Lee el archivo JSON generado por scraper_jne_multinivel.py y actualiza 
las tablas de candidatos distritales, provinciales y regionales.
"""

import json
import os
import sys
from pathlib import Path
from sqlalchemy.orm import Session

# El paquete `app` vive en backend/; sin esto el script muere al importar y ni
# siquiera alcanza a explicar que quedó obsoleto.
sys.path.insert(0, str(Path(__file__).resolve().parent / "backend"))

from app.core.database import SessionLocal, engine
from app.core.models import Base, DistrictCandidate, ProvincialCandidate, RegionalCandidate

def cargar_candidatos_desde_json(json_path: str):
    """Carga candidatos desde el archivo JSON generado por el scraper."""
    with open(json_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    return data

def sincronizar_candidatos(db: Session, candidatos_data: dict):
    """Sincroniza los candidatos en la base de datos con los datos del JSON."""
    
    # Mapeo de niveles a modelos
    modelos = {
        "DISTRITAL": DistrictCandidate,
        "PROVINCIAL": ProvincialCandidate, 
        "REGIONAL": RegionalCandidate
    }
    
    nombres_modelos = {
        "DISTRITAL": "distritales",
        "PROVINCIAL": "provinciales",
        "REGIONAL": "regionales"
    }
    
    # Para cada nivel
    for nivel_nombre, nivel_data in candidatos_data.get("niveles", {}).items():
        if nivel_nombre not in modelos:
            continue
            
        Modelo = modelos[nivel_nombre]
        print(f"\nSincronizando candidatos {nombres_modelos[nivel_nombre]}...")
        
        # Obtener candidatos existentes
        existentes = {c.nombre: c for c in db.query(Modelo).all()}
        print(f"  Candidatos existentes: {len(existentes)}")
        
        # Procesar cada organización
        actualizados = 0
        nuevos = 0
        
        for org in nivel_data.get("organizaciones", []):
            nombre_partido = org.get("organizacionPolitica", "")
            
            # Determinar qué cargo procesar según el nivel
            cargos = []
            if nivel_nombre == "REGIONAL":
                # Para regional: gobernador y vicegobernador
                if org.get("gobernador"):
                    cargos.append(("GOBERNADOR", org["gobernador"]))
                if org.get("vicegobernador"):
                    cargos.append(("VICE GOBERNADOR", org["vicegobernador"]))
            else:
                # Para distrital y provincial: alcalde y regidores
                if org.get("alcalde"):
                    cargos.append(("ALCALDE", org["alcalde"]))
                for regidor in org.get("regidores", []):
                    cargos.append(("REGIDOR", regidor))
            
            # Procesar cada cargo
            for cargo, candidato in cargos:
                if not candidato:
                    continue
                    
                nombre_completo = f"{candidato.get('nombres', '')} {candidato.get('apellidoPaterno', '')} {candidato.get('apellidoMaterno', '')}".strip()
                if not nombre_completo:
                    nombre_completo = candidato.get('nombres', '').strip()
                
                # Usar el número como sort_order, o asignar uno basado en el orden de aparición
                sort_order = candidato.get('numero') or len(existentes) + actualizados + nuevos + 1
                
                # Preparar datos del candidato
                datos_candidato = {
                    "nombre": nombre_completo,
                    "partido": nombre_partido,
                    "color": candidatos_data.get("colores", {}).get(nombre_partido, "#6b7280"),  # Gris por defecto
                    "symbol": org.get("logo_url"),  # URL del logo del partido
                    "photo_url": candidato.get("foto"),  # URL de la foto del candidato
                    "sort_order": sort_order
                }
                
                # Verificar si ya existe (por nombre y partido)
                clave_existente = f"{nombre_completo}|{nombre_partido}"
                existente = None
                for nombre_existente, candidato_existente in existentes.items():
                    if (candidato_existente.nombre == nombre_completo and 
                        candidato_existente.party == nombre_partido):
                        existente = candidato_existente
                        break
                
                if existente:
                    # Actualizar existente
                    for key, value in datos_candidato.items():
                        setattr(existente, key, value)
                    actualizados += 1
                else:
                    # Crear nuevo
                    nuevo_candidato = Modelo(**datos_candidato)
                    db.add(nuevo_candidato)
                    existentes[clave_existente] = nuevo_candidato  # Para evitar duplicados en este lote
                    nuevos += 1
        
        print(f"  Actualizados: {actualizados}")
        print(f"  Nuevos: {nuevos}")
    
    # Commit todos los cambios
    db.commit()
    print("\n✅ Sincronización completada")

def _cargador_legado_sin_ubigeo():
    """Carga candidatos ignorando la dimensión territorial.

    Obsoleto: sin `ubigeo` sus filas no aparecen en ningún ranking y, al no
    acotar por ámbito, los votos se atribuirían al partido homónimo de otro
    distrito. Se conserva como referencia del formato JSON antiguo.
    """
    # Ruta al archivo JSON generado por el scraper
    json_path = Path(__file__).parent / "jne-scraper" / "candidatos_completo.json"
    
    if not json_path.exists():
        print(f"❌ Error: No se encontró el archivo {json_path}")
        print("   Primero ejete el scraper: python jne-scraper/scraper_jne_multinivel.py")
        return
    
    print(f"📂 Cargando datos desde: {json_path}")
    candidatos_data = cargar_candidatos_desde_json(str(json_path))
    
    # Crear sesión de base de datos
    db = SessionLocal()
    try:
        # Asegurar que las tablas existan
        Base.metadata.create_all(bind=engine)
        
        # Sincronizar candidatos
        sincronizar_candidatos(db, candidatos_data)
        
    except Exception as e:
        print(f"❌ Error durante la sincronización: {e}")
        db.rollback()
    finally:
        db.close()


def main():
    """Cargador obsoleto: se niega a correr para no ensuciar el dashboard."""
    print(
        "Este script está obsoleto: no asigna `ubigeo`, así que sus filas no\n"
        "aparecerían en ningún ranking. Usa el cargador vigente:\n\n"
        "    cd backend && python -m app.load_jne_data --dry-run\n\n"
        "Escribe candidatos para los 110 ámbitos con su dimensión territorial,\n"
        "hace upsert preservando los votos ya registrados y copia fotos y logos.\n"
    )


if __name__ == "__main__":
    main()