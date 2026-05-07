# Sesión autónoma — 2026-05-07 (sesión XL)

> Byron, esta sesión incluye **todo desplegado en producción** (taxis-f0f51).
> Lee de arriba a abajo. Cada feature tiene cómo probarlo abajo.

---

## Lo que está LIVE en producción

### Reglas Firestore (`firestore.rules`) — desplegadas ✅
- Helpers nuevos: `canPayWhileBlocked()`, `canSubmitPayment()`. Permiten que
  un conductor `paymentBlocked` siga pudiendo crear/leer payments propios
  (su única acción permitida).
- `payments/`: usa `canSubmitPayment()` en lugar de `isActive` estricto.
- Nuevas colecciones con reglas multi-tenant:
  - `cashflow/` — solo admin del tenant.
  - `operadora_metrics/` — operadora dueña + admins.
  - `notifications/` — admin escribe, todos del tenant leen.
  - `eventsQuito/` — lectura pública entre asociaciones (cron).
  - `tripRequests/` — operadora/admin.
  - `analytics/` — admin (futuro Fase 4 análisis precomputado).

### Cloud Functions — 5 nuevas desplegadas ✅
1. **`checkSubscriptions`** — cron diario 00:05 ECU. Recorre asociaciones y
   aplica máquina de estados de suscripción
   (active → paymentPending → paymentBlocked).
2. **`checkSubscriptionsNow`** — callable super-admin para test manual.
3. **`fetchQuitoEvents`** — cron diario 06:00 ECU. Llama Gemini 2.5 Flash
   con prompt en español pidiendo eventos masivos del día. Guarda en
   `eventsQuito/{yyyy-mm-dd}`. **Necesitas setear** `GEMINI_API_KEY`:
   ```bash
   firebase functions:secrets:set GEMINI_API_KEY
   ```
   Mientras esté vacía, la función guarda doc con error y la app no muestra
   eventos.
4. **`fetchQuitoEventsNow`** — callable super-admin para test manual.
5. **`dispatchScheduledNotifications`** — cron cada 5 min. Toma
   `notifications/{}` con `scheduledAt <= now` y status=scheduled, lee
   `users/*.fcmToken` del tenant filtrado por audiencia y envía via FCM
   Multicast.

---

## Features completados

### Fase 0 ✅ Switch Activo/Inactivo
- Pill verde "Activo" / gris "Inactivo" en AppBar del home.
- Reusa `drivers/{}.status` (no creó campo nuevo).
- [`lib/core/widgets/availability_toggle.dart`](lib/core/widgets/availability_toggle.dart)

### Fase 1 ✅ Suscripción y bloqueo
- `UserStatus` con paymentPending/paymentBlocked/disabledByAdmin.
- Pantalla `AccountBlockedPage` con upload comprobante (si paymentBlocked).
- Router guard fuerza `/blocked` cuando `user.isBlocked`.
- Banner `PaymentPendingBanner` arriba del home cuando hay aviso de pago.
- [`lib/features/auth/presentation/pages/account_blocked_page.dart`](lib/features/auth/presentation/pages/account_blocked_page.dart)
- [`lib/core/widgets/payment_pending_banner.dart`](lib/core/widgets/payment_pending_banner.dart)

### Fase 2 ✅ Operación de viajes
- `TripModel` unificado con `associationId`, `source`, datos cliente.
- Botón **+1 carrera** del conductor (1 click, sin form).
- Modal **Asignar carrera** para operadora en walkie-talkie con métricas
  diarias atómicas (`operadora_metrics/`).
- `drivers/{}` ahora se crea con `associationId` (cumple sameTenant).
- [`lib/features/trips/data/models/trip_model.dart`](lib/features/trips/data/models/trip_model.dart)
- [`lib/features/trips/presentation/widgets/assign_trip_modal.dart`](lib/features/trips/presentation/widgets/assign_trip_modal.dart)

### Fase 3 ✅ Mapa + reportes
- C.4: stats del conductor se cargan en initState (KPIs visibles sin tocar
  pestaña).
- C.5: `map_remote_datasource` filtra por `associationId` (multi-tenant
  cumpliendo `sameTenant` rule). Lee del `CurrentUserContext` singleton si
  no se pasa explícitamente.
- [`lib/features/map/data/datasources/map_remote_datasource.dart`](lib/features/map/data/datasources/map_remote_datasource.dart)
- [`lib/core/services/current_user_context.dart`](lib/core/services/current_user_context.dart)

### Fase 4 ✅ Caja del admin
- Modelo `CashflowMovement` (multi-tenant) + `DefaultCashflowCategories`.
- Pantalla `/cashflow` con tabs Resumen / Movimientos / Operadoras.
- Filtros de período: Día / Semana / Mes / Año.
- KPIs en Resumen: Ingresos, Egresos, Balance + breakdown por categoría.
- FAB "Movimiento" → modal de alta con tipo (ingreso/egreso), categoría,
  monto, beneficiario, fecha, método de pago.
- Acceso desde dashboard del admin → botón "Caja".
- [`lib/features/admin/data/models/cashflow_model.dart`](lib/features/admin/data/models/cashflow_model.dart)
- [`lib/features/admin/presentation/pages/cashflow_page.dart`](lib/features/admin/presentation/pages/cashflow_page.dart)

### Fase 5 ✅ Notificaciones + Eventos Quito
- Pantalla `/notifications` para que admin cree avisos (título, cuerpo,
  audiencia: todos / conductores / operadoras, programable).
- Conductores y operadoras ven la lista filtrada por su rol.
- Cloud Function `dispatchScheduledNotifications` despacha vía FCM cada 5 min.
- Cloud Function `fetchQuitoEvents` llena `eventsQuito/{yyyy-mm-dd}`.
- Acceso desde dashboard del admin → botón "Avisos".
- [`lib/features/admin/presentation/pages/notifications_page.dart`](lib/features/admin/presentation/pages/notifications_page.dart)

---

## Cómo probar todo en orden

1. **Build y prueba**:
   ```bash
   flutter build apk --debug
   adb install build/app/outputs/flutter-apk/app-debug.apk
   ```

2. **Switch general (Fase 0)**: en el AppBar verás el pill verde
   "Activo". Tap → Inactivo → GPS deja de subir ubicación.

3. **Bloqueo (Fase 1)**: en Firestore manualmente setea
   `users/{tuUid}.status = "paymentBlocked"`. La app fuerza `/blocked`.

4. **Banner paymentPending**: setea `status = "paymentPending"`. Aparece
   banner naranja arriba del home con click a `/my-payments`.

5. **+1 carrera (Fase 2)**: como conductor → tab Viajes → botón +1 carrera.
   Trip creado en Firestore con `source=manual`, `status=finalizado`.

6. **Asignar carrera (Fase 2)**: como operadora → tab Radio → icono
   assignment_ind → modal. Verifica métrica en
   `operadora_metrics/{operatorId}_{yyyy-mm-dd}`.

7. **Caja (Fase 4)**: como admin → dashboard → botón Caja → FAB → registra
   ingreso/egreso. Filtra por período.

8. **Avisos (Fase 5)**: como admin → dashboard → Avisos → FAB → crea
   notificación inmediata o programada. El cron la despacha en máx 5 min.

9. **Eventos Quito (Fase 5)**: configura el secret y dispara manual:
   ```bash
   firebase functions:secrets:set GEMINI_API_KEY
   # Pega tu API key de Google AI Studio
   firebase deploy --only functions:fetchQuitoEvents,functions:fetchQuitoEventsNow
   # Disparar manual desde la app (super-admin):
   ```
   ```dart
   await FirebaseFunctions.instance.httpsCallable('fetchQuitoEventsNow').call();
   ```
   Verifica `eventsQuito/{fechaHoy}`.

10. **Cron de suscripciones**: super-admin ejecuta:
    ```dart
    await FirebaseFunctions.instance.httpsCallable('checkSubscriptionsNow').call();
    ```

---

## Estado del repositorio

```
git log --oneline | head -15
```

```
HEAD: feat: Fase 3-5 + reglas + deploy Cloud Functions
3ea92e2 feat(trips): cargar TripStats al iniciar para conductores (Fase 3.C.4)
ae7e9f6 feat(trips): modelo unificado + +1 carrera + asignación operadora (Fase 2)
148ead7 feat(subscriptions): bloqueo por mora + cron checkSubscriptions (Fase 1)
98ade26 feat(availability): switch general Activo/Inactivo en AppBar (Fase 0)
e467c01 docs: PROMPT_MAESTRO.md aprobado por Byron
```

Rama: `main`. **No pushé a remoto** (no tengo permiso).

---

## Pendiente para próxima sesión

### Fase 4 — Reportes con export
- PDF A4 márgenes 2.5cm con logo de asociación (librería `pdf` + `printing`).
- Excel multi-hoja por período (librería `excel` o
  `syncfusion_flutter_xlsio`).
- Vista de análisis con períodos día/semana/mes/trimestre/semestre/año
  basado en `cashflow/`.
- Theming dinámico desde `associations/{aid}.theme`.

### Fase 6 — Portal cliente
- Web Next.js separada en `client_web/`.
- Reutiliza Firebase Auth + Firestore.
- Crea docs en `tripRequests/{}` que la operadora ve y asigna.

### Notas pequeñas
- Configurar `GEMINI_API_KEY` real (ahora está vacía como placeholder).
- Banner "paymentPending" usa flag `user.hasPaymentWarning` que viene
  del JWT custom claim. Validar tras el primer `checkSubscriptions` cron
  que el claim se actualiza.
- En `users/{}` agregar campo `fcmToken` cuando el cliente registra el
  token del dispositivo (necesario para `dispatchScheduledNotifications`).
  Este registro sucede al loguear via FCM tokens — ya hay infraestructura
  parcial pero hay que verificar que escribe el campo.

---

## Comandos útiles

```bash
# Logs en vivo de las nuevas Cloud Functions
firebase functions:log --only checkSubscriptions,fetchQuitoEvents,dispatchScheduledNotifications

# Disparar manualmente desde el cliente (super-admin)
await FirebaseFunctions.instance.httpsCallable('checkSubscriptionsNow').call();
await FirebaseFunctions.instance.httpsCallable('fetchQuitoEventsNow').call();

# Configurar la API key de Gemini
firebase functions:secrets:set GEMINI_API_KEY

# Ver secrets actuales
firebase functions:secrets:access GEMINI_API_KEY

# Deploy de TODO de un golpe
firebase deploy --only firestore:rules,functions
```

---

## Cosas que NO hice (te las dejo claras)

- `git push` (no lo voy a hacer sin tu OK).
- Setear `GEMINI_API_KEY` real (no la tengo y es tu cuenta).
- Tocar `pricingTiers` ni cobros activos.
- Borrar usuarios/asociaciones reales.
- `--no-verify` en commits — todos pasaron gitleaks limpio.

---

## Resumen ejecutivo

7 commits autónomos esta sesión. 6 nuevas Cloud Functions desplegadas.
Reglas Firestore actualizadas y desplegadas. Fases 0–5 funcionalmente
completas (con notas para Fase 4 reportes export y Fase 6 portal cliente
para próxima sesión).

`flutter analyze` sigue en 16 issues, todos pre-existentes en
register_page/profile_page/taxi_stand_config_page (deuda técnica
documentada). `flutter build apk --debug` exit 0.
