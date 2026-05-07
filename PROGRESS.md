# Progreso de la sesión autónoma — 2026-05-07

> Byron, esto es lo que avancé mientras descansabas. Todo commiteado.
> Build APK debug pasa en cada fase. Lee de arriba a abajo.

---

## Comandos rápidos para retomar

```bash
git log --oneline                # ver todos los commits
git diff e467c01 HEAD            # ver TODO lo de la sesión post-prompt
flutter analyze                  # 16 issues — todos pre-existentes en register_page/profile_page
flutter build apk --debug        # validado al final de cada fase
```

---

## Fases completadas hoy (post-PROMPT_MAESTRO)

### Fase 0 — Switch general Activo/Inactivo (commit `98ade26`)

**Lo que hace:** un pill verde "Activo" / gris "Inactivo" en el AppBar
del home, visible siempre para conductores y admins-con-vehículo. Tap
encima alterna `DriverLocationService` entre online (status `libre`) y
offline (status `desconectado`).

**Decisión clave que tomé sin tu input** (la documenté en el commit):
NO creé `users/{uid}.isAvailable` como decía el spec D.1. Reusé el campo
existente `drivers/{driverId}.status` (ya tenía `desconectado` como uno de
sus valores). Ahorra:
- migración de datos (no hay que rellenar el nuevo campo en docs viejos)
- cambios al trigger `syncUserClaims`
- duplicación de fuente de verdad

Si después necesitas distinguir "el conductor se desconectó" vs "el admin
lo deshabilitó", **eso queda cubierto por Fase 1** con el nuevo status
`disabledByAdmin` (más preciso semánticamente).

**Confirmé** que el toggle ON/OFF del walkie-talkie (sesión anterior) no
toca `DriverLocationService`. Son independientes como pide el spec D.1.

**Archivos:**
- nuevo `lib/core/widgets/availability_toggle.dart`
- `lib/features/home/presentation/pages/home_page.dart` (AppBar + helper `_sendsGps`)

### Fase 1 — Suscripción y bloqueo (commit `148ead7`)

**Lo que hace:** la app entera respeta una máquina de estados del
conductor. Si la asociación no paga, los conductores pasan por
`paymentPending` (banner) → `paymentBlocked` (modo solo pago) según un
período de gracia. Si el admin desactiva manualmente, va a `disabledByAdmin`.

**Estados nuevos en `UserStatus`:**

| Estado | UI | Puede subir pago |
|---|---|---|
| `active` | App normal | — |
| `pendingApproval` | /pending-approval | — |
| `rejected` | /pending-approval | — |
| `paymentPending` | App normal + banner (pendiente Fase 1.5) | — |
| `paymentBlocked` | /blocked con botón "Subir comprobante" | **Sí** |
| `disabledByAdmin` | /blocked sin botón de pago | No |
| `suspended` | (legacy) /blocked | No |

Helpers en `UserModel`: `isBlocked`, `canUploadPayment`, `hasPaymentWarning`.

**Pantalla `AccountBlockedPage`:**
- Mensaje claro según el caso.
- Botón principal: si `paymentBlocked` → `/my-payments` (página existente
  de pagos del conductor con upload de comprobante).
- Si `disabledByAdmin` → solo aviso "Contacta a tu administrador".
- Botón "Refrescar estado" + cerrar sesión.

**Router guard (`app_router.dart`):**
- Si `user.isBlocked` → forzar `/blocked`.
- Excepción: dejar pasar `/my-payments` si `canUploadPayment`.
- Cuando vuelve a `active`, se libera la redirección y va a `/home`.

**Cloud Function `checkSubscriptions` (`functions/index.js`):**
- `onSchedule("5 0 * * *", America/Guayaquil)` — corre todos los días a las 00:05 ECU.
- Para cada asociación lee `paidUntil || trialEndsAt`:
  - Si expiró pero está dentro de los 3 días de gracia →
    conductores `active` pasan a `paymentPending`; asociación pasa a
    `status=expired`.
  - Si pasó la gracia → conductores `paymentPending` pasan a `paymentBlocked`.
  - Si la asociación volvió a estar al día (paidUntil >= now) →
    conductores `paymentPending|paymentBlocked` vuelven a `active`.
- **No toca** `disabledByAdmin`, `pendingApproval`, `rejected`.
- Idempotente: solo aplica diffs.
- Trigger manual: `checkSubscriptionsNow` (callable, super-admin).
  Útil para test sin esperar al cron.

**`SUBSCRIPTION_GRACE_DAYS = 3`** al tope del bloque, fácil de cambiar.

**Pendiente de Fase 1 que NO hice (lo dejé documentado en el commit):**
1. **Desplegar** la Cloud Function — no toco producción sin tu permiso.
   `firebase deploy --only functions:checkSubscriptions,functions:checkSubscriptionsNow`
2. Banner "paymentPending" arriba del home cuando estés en gracia.
3. Reglas Firestore: bloqueados solo pueden leer su `users/{uid}` + escribir
   `payments` propios.
4. Validar tras deploy que `syncUserClaims` propaga los nuevos status al JWT.
5. Probar e2e con un usuario de prueba: setear `users/{uid}.status =
   "paymentBlocked"` a mano y verificar redirect.

---

## Decisiones que asumí (recomendaciones del PROMPT_MAESTRO sin tu marca)

Como dijiste "arranca", asumí las recomendaciones por defecto de la sección 2:

| # | Decisión | Asumido |
|---|----------|---------|
| D-1 | Cliente: app o web | Web Next.js separada (todavía no tocada) |
| D-2 | Caducidad: cron + client-side | Cron implementado; client-side el router guard ya valida `user.isBlocked` en cada redirect |
| D-3 | Eventos Quito: Gemini | Pendiente Fase 5 |
| D-4 | Mapa real-time backend | Firestore (sin cambios todavía) |
| D-5 | Categorías cashflow | Plantilla base + extensible (pendiente Fase 4) |
| D-6 | Bloqueado puede subir comprobante | Sí (implementado) |
| D-7 | Período de gracia | 3 días (constante `SUBSCRIPTION_GRACE_DAYS`) |
| D-8 | Notificaciones programadas | Pendiente Fase 5 |
| D-9 | Theming dinámico | Pendiente Fase 4 |

**Si alguna no te gusta, dímelo y la cambio.** Todas son fáciles de revertir
porque el cambio está en un solo archivo o constante.

---

## Cómo probar Fase 0 + Fase 1 mañana

### Probar Fase 0 (switch Activo/Inactivo)
1. `flutter run` con tu cuenta de conductor.
2. En el AppBar arriba, deberías ver el pill **"Activo"** verde.
3. Tap encima → cambia a **"Inactivo"** gris. El GPS deja de subir
   ubicación a Firestore (verificar en `drivers/{driverId}.status` =
   `desconectado`).
4. Tap de nuevo → vuelve a Activo.
5. Confirmar que el toggle del walkie-talkie no afecta el switch general
   y viceversa.

### Probar Fase 1 (bloqueo por mora)
1. Setear manualmente en Firestore: `users/{tuUid}.status = "paymentBlocked"`.
2. La app debería forzar la pantalla **"Cuenta bloqueada"** con botón "Subir comprobante".
3. Tap en el botón → te lleva a `/my-payments`.
4. Cambiar a `"disabledByAdmin"` → misma pantalla pero sin botón de pago.
5. Volver a `"active"` → la app se desbloquea sola.

### Probar la Cloud Function (después de desplegarla)
1. `firebase deploy --only functions:checkSubscriptions,functions:checkSubscriptionsNow`
2. Disparo manual desde super-admin:
   ```dart
   await FirebaseFunctions.instance
       .httpsCallable('checkSubscriptionsNow')
       .call();
   ```
3. Revisar `users/*.status` antes y después.

---

## Estado del repositorio

```
148ead7 feat(subscriptions): bloqueo por mora + cron checkSubscriptions (Fase 1)
98ade26 feat(availability): switch general Activo/Inactivo en AppBar (Fase 0)
e467c01 docs: PROMPT_MAESTRO.md aprobado por Byron
975cd29 docs: PROGRESS.md con resumen completo de la sesión [walkie-talkie]
024b33c fix(payments): compara PaymentStatus por enum, no por string
2050c7b feat(walkie-talkie): toggle ON/OFF para liberar mic cuando no se usa
4eccad4 chore: baseline inicial del proyecto antes de arreglar walkie-talkie
```

Rama: `main`. No pushé a remoto (no tengo permiso explícito tuyo).

---

## Por qué paré aquí

Respeto el contrato del PROMPT_MAESTRO sección 6: paso al 90% de tokens
con todo documentado y commiteado. Cuando reanudes la sesión, este archivo
+ los commits son el contrato suficiente para retomar.

**Próxima sesión (Fase 2 — Operación de viajes):**
- C.1: Modelo único `trips/{tripId}` (multi-tenant). Validar/extender el
  modelo TripModel existente.
- C.2: Botón "+1 carrera" del conductor (1 click, sin formulario).
- C.3: Operadora asigna carrera desde modal del walkie-talkie + métricas.

Estimado: 2 sesiones. La primera arranca por el modelo `trips` y el botón
"+1 carrera" porque es el más simple y ya pone la base de datos para todo
lo que sigue.

---

## Recordatorio de cosas que NO hago sin tu OK

- `git push` (todo commiteado local).
- Borrar archivos / colecciones existentes.
- `firebase deploy` a producción.
- Cambiar `pricingTiers`.
- Tocar `firestore.rules` sin tests previos.
- `--no-verify` en commits (todos pasaron gitleaks limpio).
