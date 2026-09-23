# Arquitectura Cloud y Alta Disponibilidad — Día D (Elecciones Regionales y Municipales · Arequipa 2026)

> Complemento de `docs/ARQUITECTURA_AREQUIPA.md` §8. Aquí se concreta el plan de
> infraestructura cloud (AWS como referencia primaria; equivalencias GCP/VPS al
> final), el dimensionamiento con el perfil de carga real y el runbook de
> operación. **Principio rector heredado:** el riesgo del día D no es el
> throughput (~30–40 escrituras/s sobre ~10.000 actas), es la disponibilidad, la
> pérdida de datos y la cola humana de revisión. Toda decisión optimiza esas
> tres cosas.

---

## 1. Perfil de carga (dimensionamiento honesto)

| Magnitud | Valor | Nota |
|---|---|---|
| Electores hábiles región | ~1,1 M | Padrón ONPE Arequipa |
| Mesas | ~3.400 | 6 electores/mesa aprox. |
| Actas totales (3 elecciones × mesa) | ~10.000 | regional + provincial + distrital |
| Ventana pico | 16:00–22:00 | cierre de votación + cómputo |
| Escrituras en pico | 30–40/s | actas + check-ins + incidencias |
| Lecturas en pico | ~500/s | 50 coordinadores + paneles públicos refrescando |
| Fotos de actas | ~10.000 × 1–2 MB | subidas en ráfagas al cierre |
| Concurrencia de sesiones | ~4.000 personeros + 200 coordinadores | autenticados con token opaco |

Conclusión: **una instancia PostgreSQL mediana basta para las escrituras.** El
diseño se juega en: separar lecturas de escrituras, absorber ráfagas de fotos,
cola offline en cliente y no perder escrituras confirmadas.

---

## 2. Topología objetivo (AWS)

```
                      Route 53 (DNS, health checks)
                              │
                      CloudFront (fotos estáticas + PWA)
                              │
                        ALB (multi-AZ)
                 ┌────────────┴────────────┐
                 │                         │
        ASG API (FastAPI)          ASG API (FastAPI)     ← 2–4 tareas, 2 AZ
        eu-central-... wait: pe-east-1a            pe-east-1c (us-east-1 como análogo)
                 │                         │
                 └────────────┬────────────┘
                              │
                     PgBouncer (transaction pool)
                              │
              ┌───────────────┴────────────────┐
              │                                │
     PostgreSQL 15 primario            Réplica de lectura
     (multi-AZ, sync replica)          (analytics y dashboards)
              │
        S3 / Object Storage
        (fotos de actas e incidencias, versionado ON)
              │
        CloudWatch + alarms (p95, 5xx, cola observadas)
```

### Componentes y por qué

| Capa | Servicio (AWS) | Alternativa GCP / VPS | Decisión y motivo |
|---|---|---|---|
| DNS + health check | Route 53 | Cloud DNS / Cloudflare | Failover automático entre ALB sano/no sano |
| CDN + WAF | CloudFront + WAF | Cloud CDN | Cachea la PWA y el CSS/JS; WAF filtra ráfagas maliciosas |
| Balanceo | ALB multi-AZ | HTTPS LB | Termina TLS, health checks por instancia |
| API | ECS Fargate, ASG con meta de CPU 40 % | Cloud Run / systemd+nginx | Escala horizontal sin estado: toda la sesión vive en DB/cookie |
| Pool de conexiones | PgBouncer `transaction` | — | Obligatorio: FastAPI con `--reload`-like workers abre muchas conexiones cortas |
| Base de datos | RDS PostgreSQL 15 multi-AZ, `db.m7g.large` | Cloud SQL HA / VM + Patroni | Failover automático ~60–120 s; `synchronous_commit=on` |
| Réplica de lectura | RDS read replica | Cloud SQL read replica | `/api/analytics/*` y el dashboard golpean la réplica |
| Fotos | S3 versionado + lifecycle IA | GCS / MinIO | Ya implementado en `app/services/storage.py`; la base guarda URL+hash |
| Observabilidad | CloudWatch + SNS | Cloud Monitoring | Alarmas de las 4 señales doradas + métrica de negocio (§5) |

**Zona horaria/región:** una sola región (el sistema es regional); multi-AZ da
la tolerancia a fallo de datacenter que el evento exige, multi-región sería
complejidad injustificada para 10k actas.

---

## 3. Decisiones de resistencia (qué protege cada una)

1. **Toda escritura es idempotente.** `UNIQUE (mesa_id, tipo_eleccion)` en
   PostgreSQL + hash SHA-256 de la foto en el cliente: un reintento de la cola
   offline devuelve el acta existente (409 controlado), nunca duplica. Sin esto,
   cada retry de red duplicaría votos.
2. **Cola offline en el cliente (ya implementada).** Un local sin señal no es un
   acta perdida: la PWA guarda el payload y reintenta con backoff. Es la medida
   #1 de continuidad.
3. **Backpressure explícito.** Ante saturación, la API responde `503` +
   `Retry-After: 30`, nunca un timeout opaco: el cliente reintenta con la cola;
   el personero no redigita.
4. **`synchronous_commit = on`** en el primario: perder una escritura confirmada
   de un acta es inaceptable en un cómputo oficial. La latencia extra (~1 ms)
   es irrelevante a 40 writes/s.
5. **Lecturas desde la réplica.** El dashboard y `/api/analytics/*` se sirven de
   la read replica (staleness tolerado ≤ 5 s en cómputo paralelo). Las
   escrituras y la validación transaccional nunca compiten con 500 lecturas/s.
6. **Fotos fuera del proceso API.** Subida directa a S3 con URLs prefirmadas
   (opción recomendada de paso 2): el API nunca transporta megabytes; valida el
   hash y guarda la URL.
7. **Sin microservicios, sin particionado, sin caché de resultados.** La
   justificación completa está en `ARQUITECTURA_AREQUIPA.md` §8.3: dos artefactos
   (API + DB) minimizan modos de falla en el momento de máxima presión.

---

## 4. Plan de escala y contingencia día D

### 4.1 T-scale por fase de la jornada

| Fase | Horario | Instancias API | Nota |
|---|---|---|---|
| Instalación de mesas | 06:00–10:00 | 2 | Check-ins GPS en ráfaga al abrir (pico corto ~10× base) |
| Votación | 10:00–16:00 | 2 | Tráfico bajo; incidencias puntuales |
| **Cierre + cómputo** | **16:00–22:00** | **4** (auto) | Pico de actas + fotos; ASG escala por CPU>40 % 3 min sostenidos |
| Verificación | 22:00–24:00 | 2 | Resolución de observadas; tráfico de consultas |

### 4.2 Contingencias (falla → acción)

| Falla | Acción | Tiempo objetivo |
|---|---|---|
| Una instancia API muere | ALB la saca; ASG reemplaza | Automático, < 3 min |
| Failover de PostgreSQL | RDS promueve la réplica síncrona | Automático, 60–120 s; la cola offline absorbe el corte |
| Réplica de lectura lenta | Failover de endpoints analytics al primario (feature flag) | Manual < 5 min |
| Pico sobrepasa dimensionamiento | 503 + Retry-After; cola offline reintenta | Automático |
| CDN cae | PWA ya descargada funciona offline; escrituras en cola | Sin impacto |
| Región entera indisponible (no esperado) | Restaurar snapshot RDS en región secundaria; RPO ≤ 5 min (WAL continuo a S3), RTO ~30 min | Runbook §6 |

### 4.3 Presupuesto orientativo (día D, 72 h de ventana)

| Recurso | Spec | Costo aprox. (USD) |
|---|---|---|
| RDS multi-AZ db.m7g.large + réplica | 2 vCPU/8 GB cada una | ~$450 |
| ECS Fargate 4×1 vCPU/2 GB pico | escalado por horas | ~$60 |
| ALB + CloudFront + transferencia | ~40 GB fotos + tráfico | ~$90 |
| S3 10k fotos (~20 GB) + WAL | lifecycle a IA | ~$10 |
| **Total evento** | | **~$610** + infraestructura base preexistente |

---

## 5. Métricas y alarmas (lo que se vigila a las 16:00)

**Señales técnicas** (CloudWatch, alarma → SNS → Telegram/SMS del centro de cómputo):

| Métrica | Umbral | Acción |
|---|---|---|
| API p95 latency | > 800 ms 5 min | Verificar pooler/DB; escalar |
| API 5xx rate | > 1 % 5 min | Rollback de task definition si hubo deploy |
| DB CPU | > 70 % 10 min | Escalar instancia (vertical, es lo más rápido) |
| Conexiones DB | > 80 % del límite | Confirmar PgBouncer; subit max_connections |
| Cola DLQ / errores de storage | > 0 | Revisar permisos S3 |

**Métricas de negocio** (lo que de verdad importa, consultas a vistas existentes):

| Métrica | Fuente | Umbral de alarma |
|---|---|---|
| % actas contabilizadas vs. hora esperada | `v_avance_distrito` | Curva por debajo del plan |
| Actas observadas sin resolver | `v_alertas_integridad` | > 30 o antigüedad > 45 min |
| Incidencias CRITICAS abiertas | `v_incidencias_abiertas` | > 0 en las 2 provincias con más electores |
| Locales en ROJO (sin personero) | `v_cobertura_locales` | > 5 % del total |
| Check-ins fallidos (fuera de radio) | `checkins_personero` | Tasa > 20 % en un local (GPS mal configurado) |

---

## 6. Runbook del día D (resumen operativo)

**T-7 días**
- Ensayo de carga con el payload real de un acta (k6/locust) sobre staging
  idéntico: valida el dimensionamiento, no lo suponga.
- Verificar backups: snapshot diario + WAL continuo; restaurar en staging una
  vez (un backup no probado no existe).
- Congelar deploys del backend; sólo hotfixes aprobados por el líder.

**T-1 día**
- Snapshot manual RDS; verificar espacio en disco (×2 del uso actual).
- Encender la réplica de lectura si estuvo apagada (calentar cache).
- Smoke test completo: login personero → check-in GPS → plantilla → acta →
  dashboard. Los 4 flujos en verde o no se abre.
- Revisar credenciales de emergencia del centro de cómputo y probar el canal
  SNS/Telegram de alarmas.

**Día D**
- 05:30: dashboards de CloudWatch en pantalla; check de las alarmas en verde.
- 08:00: confirmar check-ins fluyendo (`v_cobertura_locales` moviéndose).
- 16:00–22:00: el líder vigila **sólo** métricas de negocio (§5); los técnicos
  quedan en alarma automática.
- Ante cualquier anomalia: registrar hora, métrica y acción en el log del
  centro de cómputo (auditoría posterior del proceso electoral).

**T+1 día**
- Snapshot final; export de los reportes oficiales; apagar la réplica si no
  seguirá en uso; revisión post-mortem de incidencias de plataforma.
