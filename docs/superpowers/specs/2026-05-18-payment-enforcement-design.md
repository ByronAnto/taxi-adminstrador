# Payment Enforcement — Design Spec

**Fecha:** 2026-05-18
**Autor:** Byron Realpe (asistido por Claude)
**Estado:** Aprobado para implementación
**Subsistema:** A — Bloqueos por mora (asociación + socio), anulación de pagos

## Contexto y motivación

Hoy el SaaS multi-tenant tiene los campos `paidUntil` (asociación) y `billingConfig` (cuota del socio), pero **no hay enforcement automático**: nadie revisa vencimientos, los usuarios pueden seguir operando aunque la asociación o el socio estén en mora.

Este spec define el ciclo completo de bloqueo y reactivación:

1. **Asociación vencida** (`paidUntil < now` o `trialEndsAt < now` con `status='trial'`) → suspende toda la cooperativa.
2. **Socio vencido** (cuota personal no pagada al día) → bloquea solo a ese conductor.
3. **Anulación de pago validado** (banco devuelve, fraude, error) → el admin lo anula y el conductor cae a `paymentBlocked` inmediatamente.
4. **Reactivación** automática al validar el pago correspondiente.

## Decisiones tomadas (alineadas con Byron)

| # | Decisión | Valor |
|---|---|---|
| 1 | Período de gracia | **Ninguno** — bloqueo inmediato a las 00:00 del día de vencer |
| 2 | Banner pre-aviso | **Solo el día calendario del vencimiento**, mensaje configurable por super-admin |
| 3 | Anular pago validado | **Solo admin** puede; bloqueo inmediato + FCM al conductor con motivo |
| 4 | Membresía asociación → super-admin | **Manual** — super-admin recibe transferencia y marca `paidUntil`. Admin puede subir comprobante para validación. |
| 5 | Asociación bloqueada | Todos los usuarios ven `/blocked`. Solo el admin tiene botón "Subir comprobante de membresía". |
| 6 | Primera cuota del conductor nuevo | **Prorrateada** desde su fecha de aprobación hasta el próximo `dueDay` del calendario (`(cuota/diasPeriodo) × diasFaltantes`) |
| 7 | Arquitectura del enforcement | **Cron diario centralizado** a las 00:00 timezone `America/Guayaquil`. No lazy check. |

## Modelo de datos

### `associations/{aid}` — campos nuevos

```yaml
paidUntil: Timestamp          # ya existe — hasta cuándo está al día con super-admin
trialEndsAt: Timestamp        # ya existe — si plan='trial'
status: 'active' | 'trial' | 'suspended' | 'cancelled'
suspendedAt: Timestamp?       # NUEVO — momento del bloqueo
suspendedReason: string?      # NUEVO — 'expired_paid_until' | 'expired_trial' | 'manual'
```

### `users/{uid}` — sin cambios estructurales

Se reusan los campos existentes:

```yaml
status: UserStatus   # active | paymentBlocked | disabledByAdmin | ...
approvedAt: Timestamp   # fecha de ingreso a la asoc (base para primera cuota prorrateada)
blockedAt: Timestamp?   # NUEVO — momento del bloqueo
blockReason: string?    # NUEVO — 'cuota_vencida' | 'pago_anulado' | 'admin_manual'
```

### `payments/{paymentId}` — campos nuevos para anulación

```yaml
# campos existentes:
status: 'pending' | 'validated' | 'rejected'
driverId, associationId, amount, concept,
reportedAt, validatedAt, validatedBy

# NUEVOS:
voidedAt: Timestamp?     # admin anuló este pago validado
voidedBy: string?        # uid del admin que anuló
voidReason: string?      # motivo obligatorio (min 10 chars)
targetSuperAdmin: bool   # true si es pago de membresía de asoc al super-admin
                         #   (en ese caso driverId = admin.uid del que lo reporta)
```

**Concept nuevo soportado:** `'membresia_asociacion'`.

**Regla de cómputo:** si `voidedAt != null`, el pago **no cuenta** en `computeNextDueDate()`. Es como si nunca hubiera existido.

### `app_config/global` — doc nuevo (super-admin lo edita)

```yaml
dueDateBannerMessage: string
  # plantilla con placeholders {amount} y {dueDate}
  # ej: "Recuerde pagar {amount} antes de las 00:00 del {dueDate} para evitar el bloqueo."
```

## Arquitectura — Cron diario `enforcePayments`

**Trigger:** `onSchedule('every day 00:00', { timeZone: 'America/Guayaquil' })`
**Recursos:** 512 MiB, 540 s timeout (mismo perfil que `purgeExpiredProofs`).

### Pase A — Asociaciones vencidas

```pseudocode
for each association where status in ['active', 'trial']:
    expiryDate = status === 'trial' ? trialEndsAt : paidUntil
    if expiryDate <= now:
        association.status = 'suspended'
        association.suspendedAt = now
        association.suspendedReason = status === 'trial'
                                     ? 'expired_trial'
                                     : 'expired_paid_until'
        await sendFcmToAdmin(aid, "Tu cooperativa fue suspendida. ...")
```

### Pase B — Socios en mora

```pseudocode
for each association where status === 'active':
    cfg = association.billingConfig
    if !cfg || cfg.amount <= 0: continue  // asoc sin cobro → saltar

    for each user in this asoc
        where role in ['conductor','admin'] AND status === 'active':
        nextDue = computeNextDueDate(user, cfg)
        if nextDue <= now:
            // Permiso activo cubriendo esta fecha? Saltar.
            if await hasActivePermit(user.uid, nextDue): continue

            user.status = 'paymentBlocked'
            user.blockedAt = now
            user.blockReason = 'cuota_vencida'
            await sendFcm(user.uid, blockMessage)
```

### Pase C — Re-activación (red de seguridad)

```pseudocode
for each user where status === 'paymentBlocked' AND blockReason === 'cuota_vencida':
    cfg = association.billingConfig
    nextDue = computeNextDueDate(user, cfg)
    if nextDue > now:
        // Ya hay pago validado que cubre hasta fecha futura
        user.status = 'active'
        user.blockedAt = null
        user.blockReason = null
        await sendFcm(user.uid, "Tu cuenta fue reactivada")
```

> Pase C existe como fallback. La reactivación principal ocurre en `validatePayment` (inmediata al aprobar), así no se espera 24 h.

### `computeNextDueDate(user, cfg)` — función pura

```pseudocode
last = lastValidatedPayment(user.uid)   // status='validated' AND voidedAt is null
base = last ? last.validatedAt : user.approvedAt
period = cfg.period  // { every: int, unit: 'day'|'week'|'month'|'year' }
nextDue = base + (every × unit)
nextDue = alignToDueDay(nextDue, cfg.dueDay, period.unit)
return nextDue
```

**Caso de primera cuota prorrateada (ej. Miércoles → próximo Lunes):**

- `user.approvedAt = Wed 2026-05-13`
- `cfg = { period: { every: 1, unit: 'week' }, dueDay: 'monday', amount: 10 }`
- `nextDue = alignToDueDay(approvedAt, 'monday', 'week') = Mon 2026-05-18`
- Monto a pagar = `(10/7) × diasDesdeAprobacion` = `(10/7) × 5 = $7.14`
- El dashboard del conductor muestra "$7.14" en la tarjeta "Próxima cuota".
- El dialog de reportar pago pre-llena este monto.

## Pantallas y flujos cliente

### Banner del día del vencimiento

**Widget nuevo:** `lib/features/payments/presentation/widgets/due_date_banner.dart`

**Cuándo aparece:**
- Solo entre 00:00 y 23:59 del día calendario del `nextDueDate`.
- Solo si el usuario no tiene pago validado cubriendo ese período.

**Dónde:**
- Conductor → tope del Home (sobre `DashboardKpis`).
- Admin → mismo, leyendo `associations/{aid}.paidUntil` para banner de membresía.

**Diseño:** card amarillo/naranja con ícono ⚠️, texto del `dueDateBannerMessage` con placeholders sustituidos, botón "Pagar ahora →" que navega a `/my-payments` con dialog pre-llenado.

### `AccountBlockedPage` — extender

Ya existe en `lib/features/auth/presentation/pages/account_blocked_page.dart`. Agregar 3 variantes:

**Conductor con `status = paymentBlocked`:**
- Header rojo "Tu cuenta está bloqueada por mora"
- Subtítulo: monto + fecha de vencimiento
- Botón grande "Subir comprobante de pago" → abre `_ReportPaymentDialog` (ya existe)
- Historial de últimos 3 pagos (validados + anulados) para contexto
- Botón "Cerrar sesión"

**Admin con `association.status = suspended`:**
- Header rojo "Tu cooperativa fue suspendida"
- Subtítulo: "Membresía vencida desde DD-MM"
- Botón grande "Pagar membresía" → abre `_ReportAssociationPaymentDialog` (nuevo)
- Botón "Cerrar sesión"

**Conductor/operadora (no admin) de asoc suspended:**
- Header rojo "Tu cooperativa fue suspendida"
- Subtítulo: "El administrador debe pagar la membresía. Mientras tanto no puedes operar."
- **NO** hay botón de pago — solo "Cerrar sesión"

### `_ReportAssociationPaymentDialog` — nuevo widget

**Ubicación:** `lib/features/payments/presentation/widgets/report_association_payment_dialog.dart`

**Form:**
- Monto
- Fecha del depósito/transferencia
- Banco origen
- Número de comprobante
- Foto opcional (sube a `payment_proofs/{adminUid}/membership_{ts}.jpg`)

**Submit:** llama Cloud Function `reportAssociationPayment`.

### Validación de pagos de membresía (super-admin)

Reutilizar `payment_approvals_page.dart` con un filtro nuevo:

- Filtro "Membresías de asociación" — solo visible para super-admin
- Cada tile muestra: nombre de asociación + admin que reportó + monto
- Al aprobar → llama `validateAssociationPayment`

### Botón "Anular pago" en `_PaymentDetailDialog`

**Ubicación:** `lib/features/payments/presentation/pages/payment_approvals_page.dart`

**Condiciones de aparición:**
- `payment.status === 'validated'`
- `payment.voidedAt === null` (no se puede re-anular)
- Caller es `admin` del tenant

**Flujo:**
1. Botón rojo "Anular pago" debajo de los botones verdes Aprobar/Rechazar
2. Tap → confirmación: "Esto bloqueará al conductor inmediatamente. ¿Continuar?"
3. Si confirma → dialog con textfield "Motivo (mín 10 chars)" obligatorio
4. Llama Cloud Function `voidPayment({ paymentId, reason })`

### Config del mensaje del banner (super-admin)

**Ubicación:** Panel SaaS (`/super`), sección nueva "Configuración global".

**Campo:** TextField multiline para `app_config/global.dueDateBannerMessage`.

**Placeholders soportados:**
- `{amount}` → monto a pagar formateado (`$7.14`)
- `{dueDate}` → fecha legible (`Lun 18-may`)

## Reglas Firestore

### `payments/{paymentId}` — agregar permiso de anulación

```firestore
allow update: if sameTenant(resource.data) && (
  (canSubmitPayment() && isOwner(resource.data.driverId))
  || isOperatorOrAdmin()
  || (isAdmin() && _isVoidUpdate())
);

function _isVoidUpdate() {
  return resource.data.status == 'validated'
    && request.resource.data.diff(resource.data).affectedKeys()
        .hasOnly(['voidedAt', 'voidedBy', 'voidReason'])
    && request.resource.data.voidReason is string
    && request.resource.data.voidReason.size() >= 10;
}
```

> Nota: el flujo real escribe vía Cloud Function (`voidPayment`) con Admin SDK, que bypasea reglas. Esta regla es defensa en profundidad por si alguien intenta anular desde el cliente directamente.

### `associations/{aid}` — sin cambios

`myAssociationId()` viene del JWT y no se vacía al suspender — el admin sigue pudiendo leer su asoc desde `/blocked` para ver el motivo.

### `app_config/global` — sin cambios

Cae bajo la regla existente: lectura para autenticados, escritura solo super-admin.

## Cloud Functions

### Nuevas

| Function | Trigger | Permisos | Resumen |
|---|---|---|---|
| `enforcePayments` | `onSchedule('every day 00:00')` TZ Guayaquil | Sistema | Cron principal — Pases A, B, C |
| `voidPayment` | `onCall` | `isAdmin()` mismo tenant | Anula payment validado + bloquea conductor + FCM |
| `validateAssociationPayment` | `onCall` | `isSuperAdmin()` | Aprueba pago de membresía, extiende `paidUntil`, reactiva asoc, FCM a todos |
| `reportAssociationPayment` | `onCall` | `isAdmin()` con asoc suspended | Admin sube comprobante de membresía → crea `payments` con `concept='membresia_asociacion'` |
| `extendPaidUntil` | `onCall` | `isSuperAdmin()` | Manual: super-admin extiende `paidUntil` sin que haya comprobante (caso transferencia directa fuera de la app) |

### Modificadas

**`validatePayment` (existente):**
Después de aprobar, si `user.status === 'paymentBlocked' AND blockReason === 'cuota_vencida'` → marcar `active` + FCM "Tu cuenta fue reactivada". Esto reactiva al instante sin esperar al cron.

**`reportPayment` (existente):**
Sin cambios reales — ya permite reportar con `paymentBlocked` vía `canSubmitPayment()` en reglas.

## Notificaciones FCM

| Evento | Destinatario | Mensaje |
|---|---|---|
| Cron bloquea conductor por mora | Conductor | "Tu cuenta fue bloqueada por mora. Sube tu comprobante para reactivarte." |
| Cron suspende asociación | Admin de la asoc | "Tu cooperativa fue suspendida. Paga la membresía para reactivarla." |
| Admin anula pago | Conductor | "Un pago tuyo fue anulado. Motivo: {reason}. Tu cuenta está bloqueada." |
| Super-admin aprueba membresía | Todos los users de la asoc | "Cooperativa reactivada. Ya puedes operar normalmente." |
| `validatePayment` reactiva conductor | Conductor | "Tu cuenta fue reactivada. Bienvenido de vuelta." |

## Deploy

```bash
firebase deploy --only firestore:rules

firebase deploy --only \
  functions:enforcePayments,\
  functions:voidPayment,\
  functions:validateAssociationPayment,\
  functions:reportAssociationPayment,\
  functions:extendPaidUntil,\
  functions:validatePayment

# IAM público para los callables nuevos:
for f in voidpayment validateassociationpayment reportassociationpayment extendpaiduntil; do
  gcloud run services add-iam-policy-binding $f \
    --region=us-central1 \
    --member=allUsers \
    --role=roles/run.invoker \
    --quiet
done

# Crear doc Firestore manual:
# app_config/global { dueDateBannerMessage: "Recuerde pagar {amount} antes de las 00:00 del {dueDate}." }
```

## Testing manual

1. **Conductor en mora:** crear conductor de prueba, aprobarlo, forzar `payments` vacíos, ejecutar `enforcePayments` manualmente → verificar `paymentBlocked` + FCM recibido.
2. **Anular pago:** validar un pago, después usar el botón "Anular pago" como admin → verificar `voidedAt` + bloqueo del conductor + FCM.
3. **Reactivación inmediata:** subir comprobante desde `/blocked`, validarlo como admin → verificar que el conductor pasa a `active` sin esperar al cron.
4. **Asociación suspendida:** forzar `paidUntil = now - 1h`, correr cron → todos los users de la asoc ven `/blocked`. Solo el admin ve botón "Pagar membresía".
5. **Super-admin valida membresía:** admin sube comprobante, super-admin valida → todos los users reactivados, asoc vuelve a `active`.
6. **Primera cuota prorrateada:** conductor nuevo aprobado Miércoles, `cfg = weekly dueDay=monday $10` → dashboard muestra "$7.14 hasta lunes".

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Cron falla un día → bloqueos atrasados 24 h | Monitoring en Cloud Functions logs + alerta si no corrió |
| Admin anula pago por error | Confirmación con motivo obligatorio (mín 10 chars); auditoría queda en doc |
| Conductor en permiso pero el cron lo bloquea | Pase B verifica `hasActivePermit()` antes de bloquear |
| Asoc cobra cuota diferente cada periodo | `computeNextDueDate` lee `cfg` cada vez — admin puede cambiarlo sin migrar |
| Pago validado de período viejo se anula y queda con varias mensualidades atrasadas | `computeNextDueDate` siempre devuelve la fecha del SIGUIENTE pago no cubierto; si está vencida, bloqueo |

## Fuera de scope (próximos specs)

- **Subsistema B**: Cambio de unidad con doble aprobación (admin + operadora).
- **Subsistema C**: Mapa privado para conductores + fotos del vehículo en tap (admin/operadora).
- Pasarela de pago PayPhone integrada (cuando haya 5+ asociaciones).
- Reportes de mora histórica (cuántos bloqueos hubo, tiempo promedio hasta reactivación).
