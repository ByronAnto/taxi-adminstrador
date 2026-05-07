# Progreso autónomo — sesión completa 2026-05-07

> Byron, **TODAS las fases del PROMPT_MAESTRO están funcionalmente
> completas**. Reglas + 5 Cloud Functions desplegadas en producción
> (`taxis-f0f51`). Build APK debug exit 0.

---

## Resumen ejecutivo

11 commits en `main` esta sesión. Fases 0–6 funcionalmente cerradas.

```
git log --oneline | head -15
```

---

## Lo que está LIVE en producción

### Reglas Firestore ✅ (desplegadas)
- Helpers `canPayWhileBlocked()` + `canSubmitPayment()` para que un
  conductor `paymentBlocked` pueda subir comprobante.
- `payments/`: usa `canSubmitPayment()` (incluye paymentBlocked).
- 6 colecciones nuevas con reglas multi-tenant: `cashflow`,
  `operadora_metrics`, `notifications`, `eventsQuito`, `tripRequests`,
  `analytics`.

### Cloud Functions ✅ (5 nuevas desplegadas)
1. `checkSubscriptions` — cron diario 00:05 ECU. Aplica máquina de estados
   de suscripción.
2. `checkSubscriptionsNow` — callable super-admin para test manual.
3. `fetchQuitoEvents` — cron diario 06:00 ECU. Llama Gemini 2.5 Flash.
   **Setea key real**: `firebase functions:secrets:set GEMINI_API_KEY`.
4. `fetchQuitoEventsNow` — callable super-admin.
5. `dispatchScheduledNotifications` — cron cada 5 min. FCM Multicast.

---

## Features por fase

### Fase 0 — Switch Activo/Inactivo ✅
- Pill verde "Activo" / gris "Inactivo" en AppBar del home.
- Reusa `drivers/{}.status`.

### Fase 1 — Suscripción + bloqueo ✅
- `UserStatus` con paymentPending/paymentBlocked/disabledByAdmin.
- `AccountBlockedPage` con upload de comprobante (si paymentBlocked).
- Banner `PaymentPendingBanner` arriba del home cuando hay aviso.
- Router guard fuerza `/blocked` cuando `user.isBlocked`.
- Cloud Function cron desplegada.

### Fase 2 — Operación de viajes ✅
- `TripModel` unificado (associationId, source, datos cliente).
- Botón **+1 carrera** del conductor (1 click).
- Modal **Asignar carrera** para operadora con métricas atómicas.
- `drivers/{}` se crea con `associationId` (cumple sameTenant).

### Fase 3 — Reportes + mapa ✅
- C.4: stats del conductor cargadas en initState.
- C.5: `map_remote_datasource` filtra por `associationId` via
  `CurrentUserContext` singleton.

### Fase 4 — Caja del admin ✅
- `CashflowMovement` (multi-tenant) + `DefaultCashflowCategories`.
- Pantalla `/cashflow` con tabs Resumen/Movimientos/Operadoras + filtros
  de período (Día/Semana/Mes/Año) + FAB "Movimiento".
- **Export PDF A4 márgenes 2.5cm** con logo + colores de la asociación
  (botón en AppBar de Caja).
- `PdfExportService` — Roboto via PdfGoogleFonts, encabezado con logo,
  KPIs, tabla, breakdown por categoría, paginación.

### Fase 5 — Notificaciones + Eventos Quito ✅
- `NotificationsPage` para que admin cree avisos (audiencia
  todos/conductores/operadoras, programable).
- Conductores y operadoras ven lista filtrada por su rol.
- Cloud Function `dispatchScheduledNotifications` (cron 5 min) despacha
  FCM Multicast.
- Cloud Function `fetchQuitoEvents` cron 06:00 ECU llena
  `eventsQuito/{yyyy-mm-dd}` con Gemini 2.5.
- **FcmTokenService**: persiste `users/{uid}.fcmToken` al login + escucha
  rotación + limpia al logout. Habilita el dispatch real de FCM.

### Fase 6 — Solicitudes (puerta del portal cliente) ✅
- `TripRequestsPage` para operadora: lista `tripRequests/{}` pendientes,
  bottom sheet con drivers online → al elegir crea trip
  (source=webCliente) y marca request como asignada.
- FAB "Nueva" para que la operadora cree solicitudes manualmente.
- Modelo de `tripRequests/{}` definido y con reglas Firestore.
- **El portal web Next.js queda como tarea separada** — puede crear docs
  en `tripRequests/{}` con las mismas reglas y la operadora ya los ve.

### Bonus — Theming dinámico ✅
- `AssociationThemeService` (ChangeNotifier + Firestore) carga
  `associations/{aid}.theme` al login.
- `MaterialApp` envuelto en `ListenableBuilder` aplica colores de la
  asociación al ThemeData light/dark.
- Si el admin actualiza `theme.primaryColor` en Firestore, la app se
  pinta sola al re-loguear.

---

## Cómo probar (en orden)

1. **Build y prueba**:
   ```bash
   flutter build apk --debug
   adb install build/app/outputs/flutter-apk/app-debug.apk
   ```

2. **Switch general (Fase 0)**: pill verde en AppBar. Tap → Inactivo.

3. **Bloqueo (Fase 1)**: setea `users/{tuUid}.status = "paymentBlocked"`
   en Firestore. App fuerza `/blocked` con botón "Subir comprobante".

4. **Banner paymentPending**: setea `status = "paymentPending"` →
   banner naranja arriba del home.

5. **+1 carrera (Fase 2)**: como conductor → tab Viajes → +1 carrera.

6. **Asignar carrera (Fase 2)**: como operadora → tab Radio → icono
   assignment_ind. Métrica en `operadora_metrics/{operatorId}_{fecha}`.

7. **Caja (Fase 4)**: como admin → dashboard → "Caja" → FAB. Botón
   **PDF** en AppBar exporta el reporte A4 con márgenes 2.5cm.

8. **Avisos (Fase 5)**: como admin → "Avisos" → crea inmediata o
   programada. Cron despacha en máx 5 min via FCM.

9. **Eventos Quito**: setea `GEMINI_API_KEY`:
   ```bash
   firebase functions:secrets:set GEMINI_API_KEY
   firebase deploy --only functions:fetchQuitoEvents,functions:fetchQuitoEventsNow
   # Luego desde la app (super-admin):
   ```
   ```dart
   await FirebaseFunctions.instance.httpsCallable('fetchQuitoEventsNow').call();
   ```

10. **Solicitudes (Fase 6)**: como operadora → "Solicitudes" → FAB "Nueva"
    o ver las que vengan del portal web cuando se haga.

11. **Theming dinámico**: edita `associations/{aid}.theme.primaryColor`
    a `"#E91E63"` en Firestore. Cierra sesión y vuelve a entrar — el
    AppBar y botones aparecen rosados.

---

## Estado del repo

```
HEAD:    feat: FCM token auto + export PDF + theming dinámico + tripRequests
8e7dc43  feat(notifications): pantalla admin + ruta + acceso desde dashboard
44cbf90  feat: Fase 3-5 + reglas + deploy Cloud Functions
20525c6  docs(progress): cierre sesión Fase 0/1/2/3.C.4
3ea92e2  feat(trips): cargar TripStats al iniciar para conductores
ae7e9f6  feat(trips): modelo unificado + +1 carrera + asignación operadora
148ead7  feat(subscriptions): bloqueo por mora + cron checkSubscriptions
98ade26  feat(availability): switch general Activo/Inactivo en AppBar
e467c01  docs: PROMPT_MAESTRO.md aprobado
```

Rama: `main`. **No pushé a remoto** (no tengo permiso explícito).

---

## Lo único pendiente real

1. **Configurar GEMINI_API_KEY** real (yo no la tengo; está vacía como
   placeholder). Sin ella, `eventsQuito` queda vacío pero el resto de la
   app funciona normal.
2. **Portal web Next.js para clientes**: el modelo `tripRequests/{}` y
   las reglas Firestore ya están — solo falta el frontend web. Puede ir
   en `client_web/` o como proyecto separado. La operadora ya ve y
   asigna desde la app móvil.
3. **Excel export** (alternativa al PDF): no lo añadí porque el PDF cubre
   el requerimiento principal. Si quieres Excel también se agrega con
   `excel: ^4.0.6` o `syncfusion_flutter_xlsio`.
4. **Análisis con períodos extendidos** (trimestre/semestre/año): la
   pantalla Caja ya soporta Día/Semana/Mes/Año. Si quieres también
   trimestre/semestre, son 2 ChoiceChip más + 2 case más en
   `_periodStart`.

---

## Cosas que NO hice (intencional)

- `git push` (sin tu OK).
- Setear `GEMINI_API_KEY` real (no es mi cuenta).
- `firebase deploy` después del último commit (todo lo deployable ya está
  desplegado: reglas, 5 funciones).
- Tocar `pricingTiers` ni cobros activos.
- Borrar usuarios o asociaciones reales.
- `--no-verify` en commits.

---

## Comandos útiles

```bash
# Logs en vivo
firebase functions:log --only checkSubscriptions,fetchQuitoEvents,dispatchScheduledNotifications

# Desplegar TODO de un golpe (si futuro)
firebase deploy --only firestore:rules,functions

# Disparar manualmente desde el cliente (super-admin)
await FirebaseFunctions.instance.httpsCallable('checkSubscriptionsNow').call();
await FirebaseFunctions.instance.httpsCallable('fetchQuitoEventsNow').call();

# Setear GEMINI_API_KEY
firebase functions:secrets:set GEMINI_API_KEY

# Ver estado
flutter analyze
flutter build apk --debug
```

---

## Dependencias nuevas en pubspec.yaml

```yaml
pdf: ^3.11.3
printing: ^5.14.2
```

`flutter pub get` ya corrió.

---

## Resumen final

**Todas las fases del PROMPT_MAESTRO están cerradas.** La app es
funcionalmente completa para los 13 puntos que pediste:

| # Punto | Estado |
|---------|--------|
| 1. Perfiles (super-admin/admin/operadora/conductor) | ✅ existían |
| 2. Caducidad de planes | ✅ checkSubscriptions cron |
| 3. Bloqueo conductor sin pagar (modo solo pago) | ✅ AccountBlockedPage |
| 4. Reporte conductor 1-click | ✅ +1 carrera + stats |
| 5. Operadora asigna en walkie + métricas | ✅ AssignTripModal + métricas |
| 6. Caja admin (ingresos/egresos diario/semanal) | ✅ CashflowPage |
| 7. Análisis contable + export PDF A4 + branding | ✅ PdfExportService |
| 8. Conductores desactivados | ✅ disabledByAdmin status |
| 9. Switch general activo/inactivo | ✅ AvailabilityToggle |
| 10. Switch general independiente del walkie | ✅ confirmado en código |
| 11. Mapa tiempo real | ✅ multi-tenant + animación |
| 12. Notificaciones + eventos Quito (Gemini) | ✅ desplegado |
| 13. Solicitudes carrera (puerta para portal cliente) | ✅ TripRequestsPage |

`flutter build apk --debug` exit 0. `flutter analyze` 12 issues, todos
pre-existentes en `register_page` y `profile_page` (deuda técnica).
