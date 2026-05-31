# Reportería y Analítica de Carreras — Diseño y Plan de Trabajo

**Fecha:** 2026-05-30
**Proyecto:** taxi_jipijapa (Flutter + Firebase)
**Autor:** Byron Realpe + Claude (rol analista de datos)
**Estado:** Diseño aprobado (análisis) → pendiente revisión del spec antes de implementar

---

## 1. Objetivo

Convertir los datos de carreras en **reportería accionable para la toma de decisiones**, en cuatro cadencias: **diario, semanal, mensual y anual**, para dos audiencias:

- **Base (admin / operadora):** decisiones de operación — turnos, cobertura, días/horas a reforzar, tendencia del negocio.
- **Conductor:** su desempeño — sus carreras, sus horas pico, su estimado, su rating.

---

## 2. Datos existentes (cimiento)

| Fuente | Grano | Campos clave |
|---|---|---|
| `tripStatsDaily/{asoc}_{YYYY-MM-DD}` | diario por base | `tripsByHour {hora:n}`, `totalTrips`, `estimatedRevenue`, `date`, `dateTs` (Timestamp, 00:00 EC = 05:00 UTC) |
| `trips/{id}` | crudo por carrera | `associationId`, `driverId`, `status`, `source`, `createdAt`, pickup `lat/lng`, `clienteNombre`, `rating` |
| `tripRequests/{id}` | solicitud web | `estado` (pendiente/asignada/cancelada/finalizada), `associationId`, `driverId` |
| `drivers/{id}` | acumulado conductor | `totalTrips`, `ratingSum`, `ratingCount`, `rating`, `vehicleNumber` |
| `associations/{id}` | acumulado base | `totalTrips` |
| `lib/tripStats.js` `fareForHour(h)` | función pura | $1.45 diurna (06:00–18:59) / $1.75 nocturna (19:00–05:59) |

**Principio rector:** el **agregado diario es el átomo**. Semana/mes/año se obtienen **sumando los diarios** por rango de `dateTs`; el **heatmap día‑de‑semana × hora** se obtiene **agrupando `tripsByHour` por el día de semana** de cada diario. → La mayoría de vistas se **calculan al leer**, sin guardar datos nuevos.

**Único hueco:** el agregado diario es **por base**, no por conductor con detalle horario. Para que el conductor vea sus horas pico se añade `driverStatsDaily`.

---

## 3. Marco de métricas (qué medir y por qué)

### 3.1 Base (admin/operadora)
| Métrica | Decisión que habilita | Cadencia |
|---|---|---|
| Volumen de carreras | tamaño del negocio | D/S/M/A |
| Demanda por hora (horas pico) | turnos y cobertura | D/S |
| Demanda por día de semana | qué días reforzar | S/M |
| **Heatmap DoW × hora** | cuándo+qué día hay demanda (la más accionable) | S/M |
| Tendencia WoW / MoM (↑/↓ %) | ¿crece o cae el negocio? | S/M/A |
| Mismo‑día vs mismo‑día (lunes vs lunes) | estacionalidad semanal sin ruido de calendario | S |
| Carreras por conductor activo (prom.) | productividad de la flota | S/M |
| Conductores activos / día | cobertura real | D/S |
| Embudo solicitudes web (recibidas→asignadas→finalizadas→canceladas) | calidad de servicio | S/M |
| Rating promedio de la base | calidad percibida | M |
| Ingreso **estimado** | proxy de demanda (NO finanzas) | D/S/M/A |

### 3.2 Conductor
| Métrica | Cadencia |
|---|---|
| Mis carreras | D/S/M |
| Mis horas pico (cuándo conviene conectarse) | S |
| Mi ingreso estimado | D/S/M |
| Mi rating | M |
| Mi posición vs la base (percentil, opcional/motivacional) | S/M |

---

## 4. Visualizaciones

1. **Heatmap día‑de‑semana × hora** (intensidad por color) — vista estrella para decisiones.
2. **Curva por hora** del día (barras) — diario.
3. **Línea de tendencia** semanal/mensual + **% vs período anterior**.
4. **Barras comparativas** (lunes vs lunes, etc.).
5. **Tarjetas KPI** (total, estimado $, carreras/conductor, rating).

---

## 5. Advertencias de analista (la info debe ser honesta)

1. **"Ingreso estimado" ≠ ingreso real** (`conteo × tarifa mínima`). Rotular SIEMPRE como estimado; usar como proxy de demanda/tendencia, no para finanzas.
2. **Solo cuenta lo que pasa por la app** (carreras finalizadas / cola / web). Carreras de calle no registradas → un "día bajo" puede ser **sub‑registro**, no baja demanda.
3. **Pocas semanas = ruido.** Comparativas (WoW, lunes‑vs‑lunes) recién confiables con ~4–6 semanas. Mostrar aviso "datos insuficientes" hasta entonces.

---

## 6. Modelo de datos — cambios propuestos

### 6.1 Nuevo: `driverStatsDaily/{driverId}_{YYYY-MM-DD}`
Análogo a `tripStatsDaily` pero por conductor. Se escribe en el MISMO trigger `onTripFinalized` (un `set merge` extra).
```
{ driverId, associationId, date, dateTs,
  tripsByHour: { "<hora>": n }, totalTrips, estimatedRevenue, updatedAt }
```

### 6.2 Enriquecer `tripStatsDaily` (y driverStatsDaily)
- Añadir `dayOfWeek` (0–6) calculado del `date` EC → simplifica el heatmap y el lunes‑vs‑lunes sin recalcular en cliente.

### 6.3 Embudo web (Fase 4): `tripRequestStatsDaily/{asoc}_{date}`
Contadores por estado (recibidas/asignadas/finalizadas/canceladas) desde triggers de `tripRequests`. (Fase posterior.)

### 6.4 Backfill (opcional)
Función `onCall` (superadmin) que recorre `trips` finalizados históricos y reconstruye `tripStatsDaily` + `driverStatsDaily`. Útil para tener historia desde el día 1. Idempotente (set, no increment, o borrar+reconstruir).

---

## 7. Capa de cálculo (lectura)

Servicio Dart (o repos) que, dado un rango:
- **Rango diario/semana/mes/año:** range query sobre `dateTs` y suma de `totalTrips` / `estimatedRevenue` / `tripsByHour`.
- **Heatmap:** agrupar `tripsByHour` de los diarios del rango por `dayOfWeek` → matriz 7×24.
- **Comparativas:** dos rangos (actual vs anterior) → % de cambio; mismo‑día = filtrar por `dayOfWeek`.
- **Conductor:** igual, contra `driverStatsDaily`.

Sin pre‑agregar semana/mes/año (los diarios son pocos docs por rango → barato). Si el volumen crece mucho, se añade rollup semanal/mensual después.

---

## 8. Plan de trabajo por fases

### Fase 0 — Definición ✅ (este documento)
Métricas y modelo cerrados; revisión del usuario.

### Fase 1 — Backend agregados
- [ ] Añadir `driverStatsDaily` en `onTripFinalized` (set merge con `tripsByHour`/`totalTrips`/`estimatedRevenue`).
- [ ] Añadir `dayOfWeek` en `tripStatsDaily` y `driverStatsDaily`.
- [ ] Índices Firestore necesarios (`dateTs` range + `associationId`/`driverId`).
- [ ] (Opcional) Backfill `onCall` desde `trips` históricos.
- [ ] Reglas de seguridad: lectura de `driverStatsDaily` por dueño y por admin/operadora de la asoc.

### Fase 2 — Capa de lectura
- [ ] Servicio de métricas: rangos D/S/M/A, rollups, matriz heatmap, comparativas.
- [ ] Tests de la lógica pura de agregación.

### Fase 3 — UI Reportes
- [ ] **Base:** heatmap DoW×hora + horas pico + KPIs + tendencia. (PRIMERO — más accionable.)
- [ ] **Conductor:** sus carreras/horas/estimado/rating.
- [ ] Selector de cadencia (diario/semana/mes/año) y de rango.
- [ ] Aviso "datos insuficientes" cuando aplique.

### Fase 4 — Refinos
- [ ] Embudo de solicitudes web (calidad de servicio).
- [ ] % WoW / MoM y comparativa mismo‑día.
- [ ] Rating promedio de base; posición del conductor.
- [ ] Exportar (CSV/PDF) — si se requiere.

---

## 9. Decisiones por defecto (ajustables)

1. **Orden de UI:** se arranca por **base (heatmap + horas pico)** por ser lo más accionable; conductor después.
2. **Embudo web:** Fase 4 (no bloquea el core).
3. **Anual:** la estructura lo soporta desde ya (suma de diarios); se mostrará cuando haya meses suficientes.
4. **Sin pre‑agregado semanal/mensual** al inicio (compute‑on‑read); se añade si el volumen lo exige.

---

## 10. Pendientes / preguntas abiertas
- ¿Exportación (CSV/PDF) es requerida o solo visualización en app?
- ¿La "posición del conductor vs la base" (ranking) se quiere, o puede generar fricción entre conductores?
- ¿Backfill histórico ahora, o arrancamos midiendo desde la fecha de despliegue?
