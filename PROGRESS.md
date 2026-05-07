# Progreso autónomo — 2026-05-07 (sesión continuada)

> Byron, esto resume TODO lo hecho en la sesión autónoma.
> 6 commits desde el OK del PROMPT_MAESTRO. Cada commit pasa
> `flutter analyze` (en archivos tocados) y `flutter build apk --debug`.

---

## Comandos rápidos para retomar

```bash
git log --oneline e467c01..HEAD   # ver SOLO los commits de esta sesión
git log --oneline | head -10      # ver historial completo
flutter analyze                   # 16 issues — TODOS pre-existentes en
                                  # register_page/profile_page (deuda técnica)
flutter build apk --debug         # validado al final de cada fase
```

---

## Fases completadas (Fase 0, Fase 1, Fase 2)

### Fase 0 — Switch general Activo/Inactivo (commit `98ade26`)

Pill verde "Activo" / gris "Inactivo" en el AppBar. Tap alterna
`DriverLocationService` entre online/offline. Independiente del toggle
del walkie-talkie.

**Decisión que tomé**: NO creé `users/{uid}.isAvailable` nuevo.
Reusé `drivers/{driverId}.status` (ya tenía `desconectado` como valor).
Documentado en el commit; fácil de revertir.

### Fase 1 — Suscripción y bloqueo (commit `148ead7`)

Máquina de estados completa. `UserStatus` extendido con
`paymentPending`, `paymentBlocked`, `disabledByAdmin`. Pantalla
`AccountBlockedPage` con upload de comprobante. Router guard.
Cloud Function `checkSubscriptions` (cron diario 00:05 ECU) +
`checkSubscriptionsNow` (callable super-admin).

**Pendiente para mañana**:
- Desplegar la Cloud Function (no toco producción sin tu OK).
- Banner `paymentPending` arriba del home.
- Reglas Firestore para bloqueados (sólo lectura propia + write payments).

### Fase 2 — Operación de viajes (commit `ae7e9f6`)

**TripModel unificado** (todas las fuentes en un solo schema):
- Campos nuevos: `associationId`, `driverName`, `operatorName`,
  `clienteNombre`, `clienteTelefono`, `source`, `updatedAt`.
- `TripStatus`: solicitado/asignado/enRuta/finalizado/cancelado +
  legacy aliases (en_progreso/completado).
- `TripSource`: manual/apkOperadora/walkieTalkie/webCliente.
- Backward-compat: viajes legacy siguen funcionando.

**Botón "+1 carrera"** del conductor:
- Visible sólo para rol conductor, prominente arriba del TabBar de viajes.
- Un click crea trip con: driverId, driverName, GPS actual,
  status=finalizado, source=manual.
- Sin formulario.

**Modal "Asignar carrera"** para operadora:
- Botón en el walkie-talkie (icono assignment_ind), sólo rol operadora.
- Stream de `drivers/{}` filtrado por `associationId` + `status != desconectado`.
- Form: dropdown conductor, dirección recogida, nombre/teléfono cliente,
  notas.
- Crea trip con `source=apkOperadora`, `status=asignado`.
- Métrica diaria atómica en
  `operadora_metrics/{operatorId}_{yyyy-mm-dd}.tripsAssigned`
  (FieldValue.increment(1) — idempotente).

**Bonus arreglado**: `drivers/{}` ahora se crea con `associationId`
(antes faltaba; las reglas Firestore lo requerían). Migración soft:
los docs viejos sin `associationId` se rellenan al re-loguear.

### Fase 3.C.4 — Stats del conductor (commit `3ea92e2`)

**Mejora pequeña pero útil**: la pestaña "Estadísticas" ya tenía la UI
armada con KPIs hoy/semana, pero `TripStatsLoadRequested` no se
disparaba. Ahora se dispara en initState de TripsPage si el rol es
conductor.

**Pendiente Fase 3 (próxima sesión)**:
- Tabs Hoy/Semana/Mes en lugar de KPIs sueltos.
- Exportable a PDF (depende de Fase 4: librería `pdf` + branding).
- **Mapa estilo Uber (C.5)** — animación de markers con Tween.

---

## Decisiones que asumí (recomendaciones del PROMPT_MAESTRO sin tu marca)

| # | Decisión | Asumido | Estado |
|---|----------|---------|--------|
| D-1 | Cliente: app o web | Web Next.js separada | Pendiente Fase 6 |
| D-2 | Caducidad: cron + client-side | Ambos | ✅ Implementado |
| D-3 | Eventos Quito: Gemini | Gemini 2.5 con web-search | Pendiente Fase 5 |
| D-4 | Mapa real-time backend | Firestore + throttle | Pendiente C.5 |
| D-5 | Categorías cashflow | Plantilla base + extensible | Pendiente Fase 4 |
| D-6 | Bloqueado puede subir comprobante | Sí | ✅ Implementado |
| D-7 | Período de gracia | 3 días (constante) | ✅ Implementado |
| D-8 | Notificaciones programadas | Sí, scheduledAt + cron | Pendiente Fase 5 |
| D-9 | Theming dinámico | Validar antes de tocar | Pendiente Fase 4 |

Si alguna no te gusta, dímelo y la cambio. Todo en commits aislados,
fácil de revertir.

---

## Cómo probar lo de hoy

### Switch Activo/Inactivo (Fase 0)
1. Login como conductor.
2. Ver pill verde "Activo" en el AppBar.
3. Tap → "Inactivo" gris. Verifica `drivers/{driverId}.status =
   desconectado` en Firestore.
4. Confirmar que el toggle del radio NO afecta al switch general.

### Bloqueo por mora (Fase 1)
1. Setear manualmente `users/{tuUid}.status = "paymentBlocked"`.
2. La app fuerza `/blocked` con botón "Subir comprobante".
3. Botón → `/my-payments`.
4. Cambiar a `"disabledByAdmin"` → misma pantalla sin botón de pago.
5. Volver a `"active"` → app se desbloquea sola.

### +1 carrera (Fase 2)
1. Login como conductor, tab Viajes.
2. Botón "+1 carrera" arriba.
3. Tap → carrera creada en `trips/{}` con `source=manual`,
   `status=finalizado`. Aparece en Historial.

### Asignar carrera operadora (Fase 2)
1. Login como operadora, tab Radio.
2. Botón con icono "assignment_ind" en la fila inferior del walkie.
3. Modal: elige conductor (sólo aparecen los `drivers.status != desconectado`
   de tu asociación), captura datos, "Asignar".
4. Verifica `trips/{}` con `source=apkOperadora`, `status=asignado`.
5. Verifica métrica en `operadora_metrics/{tuUid}_{fecha}`.

### Stats del conductor (Fase 3.C.4)
1. Login como conductor con algunas carreras.
2. Tab Viajes → Estadísticas.
3. KPIs Hoy/Semana/Cancelado deberían aparecer (ya no necesitan toques).

### Cron de suscripciones (Fase 1)
Después de desplegar las funciones (`firebase deploy --only
functions:checkSubscriptions,functions:checkSubscriptionsNow`):
```dart
await FirebaseFunctions.instance.httpsCallable('checkSubscriptionsNow').call();
```
Revisa `users/*.status` antes y después.

---

## Estado del repositorio

```
3ea92e2 feat(trips): cargar TripStats al iniciar para conductores (Fase 3.C.4)
ae7e9f6 feat(trips): modelo unificado + +1 carrera + asignación operadora (Fase 2)
5e531ba docs(progress): cierre de sesión autónoma con Fase 0 + Fase 1
148ead7 feat(subscriptions): bloqueo por mora + cron checkSubscriptions (Fase 1)
98ade26 feat(availability): switch general Activo/Inactivo en AppBar (Fase 0)
e467c01 docs: PROMPT_MAESTRO.md aprobado por Byron
975cd29 docs: PROGRESS.md con resumen completo de la sesión [walkie-talkie]
024b33c fix(payments): compara PaymentStatus por enum, no por string
2050c7b feat(walkie-talkie): toggle ON/OFF para liberar mic cuando no se usa
4eccad4 chore: baseline inicial del proyecto antes de arreglar walkie-talkie
```

Rama: `main`. **No pushé a remoto** (no tengo permiso explícito tuyo).

---

## Por qué paro aquí

Respeto el contrato del PROMPT_MAESTRO sección 6: paso al ~90% de tokens
con todo documentado y commiteado. Cuando reanudes, este archivo + los
commits son contrato suficiente.

**Próxima sesión (continuar Fase 3 + Fase 4):**

1. **Fase 3.C.4 — completar reportes conductor**:
   - Tabs Hoy/Semana/Mes con totales y promedio.
   - Exportable a PDF (necesita librería `pdf` + `printing`).

2. **Fase 3.C.5 — Mapa estilo Uber**:
   - Suscripción a `drivers/{}` filtrado por `associationId` + `status !=
     desconectado`.
   - Marker animado con Tween entre updates (interpolación 1-2s).
   - Throttle a 5s/update en `driver_location_service` para controlar costos.

3. **Fase 4 — Contabilidad y reportes admin** (E):
   - Modelo `cashflow/{}` (multi-tenant).
   - Pantalla "Caja" del admin con tabs Resumen/Movimientos/Pagos a operadoras.
   - Categorías editables en `associations/{aid}.cashflowCategories`.
   - Análisis con períodos día/semana/mes/trimestre/semestre/año.
   - Export Excel + PDF (A4 márgenes 2.5cm) con logo y nombre de la asociación.
   - Theming dinámico (validar antes de tocar).

Estimado: 2-3 sesiones más para terminar Fase 3 y Fase 4.

---

## Deudas técnicas detectadas (no urgentes)

`flutter analyze` reporta 16 warnings/info pre-existentes:
- `register_page.dart`: campos `_fotoVehiculo`, `_fotoLicenciaFrontal`,
  `_fotoLicenciaTrasera` declarados pero no usados — flow de subida de
  fotos está deshabilitado. NO tocar sin saber si lo van a re-habilitar.
- `register_page.dart:483`: RadioListTile usa `value:` deprecated.
- `my_payments_page.dart:220`: `_photoUploadedUrl` no usado.
- 5x `unnecessary_underscores` (info de estilo).

---

## Recordatorios

- `git push` lo haces vos cuando estés conforme.
- `firebase deploy` lo haces vos. Yo dejé el código de Cloud Functions
  listo para deploy.
- Si una decisión asumida no te gusta, está aislada en un commit y se
  puede revertir con `git revert <hash>` sin tocar el resto.
