# brag-plan.md — Intro del Sistema de Cómputo Electoral (español)

Implementación inspirada en el skill `/brag` (latent-spaces/brag): 15–25 s,
hook en los primeros 2 s, mostrar el producto real, cero lenguaje SaaS genérico.

## Ficha
- **Tono**: `cinematic` adaptado a Fuerza Arequipeña (rojo #E02020, blanco, negro).
- **Formato**: landscape 16:9 (1600×900, autoescalado).
- **Duración**: ~19.5 s (dentro del rango 15–25).
- **Música/voz**: no incluidas en esta implementación web (skill original usa Hyperframes + Kokoro).
- **Ley creativa**: hook numérico específico del producto; cada escena muestra
  UI real recreada (acta, mapa de ganadores, check-in GPS); sin "streamline".

## Storyboard
| # | Tiempo | Escena | Contenido |
|---|--------|--------|-----------|
| 1 | 0.0–2.5 | **HOOK** | Números pop: "4,194 ACTAS · 109 DISTRITOS" → "UNA SOLA NOCHE." |
| 2 | 2.5–5.5 | **REVEAL** | Marca FA (rojo) + "SISTEMA DE CÓMPUTO ELECTORAL — AREQUIPA 2026" + subtítulo con los 3 pilares. |
| 3 | 5.5–9.0 | **Highlight 1 — Actas** | Card de acta (mesa 023001) con contadores animados; línea de validación R1 "347 = 347 ✓" en verde. |
| 4 | 9.0–13.0 | **Highlight 2 — Mapa** | Cuadrícula de 109 distritos que se vuelca color por color (ganador distrital); leyenda FA. |
| 5 | 13.0–16.5 | **Highlight 3 — Cobertura** | Check-in GPS del personero (Local 2210 · 12 m ✓) + semáforo verde/amarillo/rojo encendiéndose. |
| 6 | 16.5–19.5 | **OUTRO** | Marca FA + "FUERZA AREQUIPEÑA · Cómputo en vivo" + repo `jhoedmon21/votacion`. |

## Gate
- `docs/brag/index.html` autocontenida (sin dependencias), timeline JS reiniciable.
- Render: grabación del Preview → `docs/brag/brag.webm` + `share-copy.txt`.
