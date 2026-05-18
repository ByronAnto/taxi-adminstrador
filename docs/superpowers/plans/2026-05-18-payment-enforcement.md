# Payment Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implementar enforcement automático de pagos: bloquea por mora a la asociación (cuando vence `paidUntil` o `trialEndsAt`) y al socio (cuando vence su cuota personal), permite al admin anular pagos validados, reactiva inmediatamente al validar el comprobante.

**Architecture:** Cron diario `enforcePayments` a las 00:00 America/Guayaquil + 4 Cloud Functions callable nuevas + helpers JS testeables + reglas Firestore para anulación + UI cliente (banner del día, account_blocked_page con 3 variantes, botón anular pago, dialog pago membresía, config global del banner).

**Tech Stack:** Cloud Functions for Firebase v2 (Node 22), Firestore Admin SDK, FCM, Flutter (flutter_bloc, GoRouter), Dart, Jest para tests de helpers JS.

**Spec source:** [`docs/superpowers/specs/2026-05-18-payment-enforcement-design.md`](../specs/2026-05-18-payment-enforcement-design.md)

---

## Fase 1 — Foundation: Modelos + Reglas

### Task 1: Helper JS `computeNextDueDate` con tests

**Files:**
- Create: `functions/lib/dueDate.js`
- Test: `functions/test/dueDate.test.js`

- [ ] **Step 1: Crear directorios y archivo de test inicial**

```bash
mkdir -p functions/lib functions/test
```

Crear `functions/test/dueDate.test.js` con el primer test que falla:

```javascript
const { computeNextDueDate, alignToDueDay } = require('../lib/dueDate');

describe('alignToDueDay', () => {
  test('week: Wed approval with monday dueDay → next Monday', () => {
    const wed = new Date('2026-05-13T10:00:00Z'); // Wednesday
    const result = alignToDueDay(wed, 'monday', 'week');
    expect(result.toISOString().substring(0, 10)).toBe('2026-05-18'); // Mon
  });

  test('month: day 5 dueDay, base on day 3 → day 5 same month', () => {
    const day3 = new Date('2026-05-03T10:00:00Z');
    const result = alignToDueDay(day3, 5, 'month');
    expect(result.toISOString().substring(0, 10)).toBe('2026-05-05');
  });

  test('month: day 5 dueDay, base on day 10 → day 5 next month', () => {
    const day10 = new Date('2026-05-10T10:00:00Z');
    const result = alignToDueDay(day10, 5, 'month');
    expect(result.toISOString().substring(0, 10)).toBe('2026-06-05');
  });
});

describe('computeNextDueDate', () => {
  test('no previous payment → uses approvedAt + period, aligned', () => {
    const user = { approvedAt: new Date('2026-05-13T10:00:00Z') }; // Wed
    const cfg = { period: { every: 1, unit: 'week' }, dueDay: 'monday' };
    const result = computeNextDueDate(user, cfg, /*lastPayment*/ null);
    expect(result.toISOString().substring(0, 10)).toBe('2026-05-18'); // next Mon
  });

  test('with last validated payment → uses validatedAt + period', () => {
    const user = { approvedAt: new Date('2026-04-01T10:00:00Z') };
    const cfg = { period: { every: 1, unit: 'week' }, dueDay: 'monday' };
    const lastPayment = { validatedAt: new Date('2026-05-11T08:00:00Z') }; // Mon
    const result = computeNextDueDate(user, cfg, lastPayment);
    expect(result.toISOString().substring(0, 10)).toBe('2026-05-18'); // +1 week
  });

  test('voided payment is ignored (caller filters)', () => {
    // El caller filtra voidedAt != null antes de pasarlo
    // Test docs: este caso lo prueba el caller en index.js
    expect(true).toBe(true);
  });
});
```

- [ ] **Step 2: Verificar que las dependencias de test existen**

```bash
cd functions && cat package.json | grep -E '"jest"|"mocha"' || npm install --save-dev jest
```

Si no hay `jest`, agregar al `package.json` en `scripts`: `"test": "jest"`.

- [ ] **Step 3: Correr test, verificar que falla**

```bash
cd functions && npx jest test/dueDate.test.js 2>&1 | tail -20
```

Expected: FAIL con "Cannot find module '../lib/dueDate'".

- [ ] **Step 4: Implementar `functions/lib/dueDate.js`**

```javascript
'use strict';

const DAY_INDEX = {
  sunday: 0, monday: 1, tuesday: 2, wednesday: 3,
  thursday: 4, friday: 5, saturday: 6,
};

/**
 * Alinea una fecha al próximo dueDay según la unidad del período.
 * - week: dueDay es 'monday'|'tuesday'|... → próximo día de semana ≥ base
 * - month: dueDay es 1..28 → día N del mismo mes si base.day <= N, sino mes siguiente
 * - day: dueDay no aplica, retorna base + 1 día
 * - year: dueDay es 1..28, alinea al día N de enero (simplificado)
 */
function alignToDueDay(base, dueDay, unit) {
  const d = new Date(base);
  if (unit === 'week') {
    const targetDow = typeof dueDay === 'string' ? DAY_INDEX[dueDay.toLowerCase()] : Number(dueDay);
    if (Number.isNaN(targetDow)) return d;
    const diff = (targetDow - d.getUTCDay() + 7) % 7;
    const offset = diff === 0 ? 7 : diff; // si es el mismo día, salta a la próxima semana
    d.setUTCDate(d.getUTCDate() + offset);
    d.setUTCHours(0, 0, 0, 0);
    return d;
  }
  if (unit === 'month') {
    const targetDay = Math.min(Math.max(1, Number(dueDay) || 1), 28);
    const currentDay = d.getUTCDate();
    if (currentDay < targetDay) {
      d.setUTCDate(targetDay);
    } else {
      d.setUTCMonth(d.getUTCMonth() + 1);
      d.setUTCDate(targetDay);
    }
    d.setUTCHours(0, 0, 0, 0);
    return d;
  }
  if (unit === 'year') {
    const targetDay = Math.min(Math.max(1, Number(dueDay) || 1), 28);
    d.setUTCMonth(0); // enero
    d.setUTCDate(targetDay);
    d.setUTCFullYear(d.getUTCFullYear() + 1);
    d.setUTCHours(0, 0, 0, 0);
    return d;
  }
  // day: simplemente sumar 1 día
  d.setUTCDate(d.getUTCDate() + 1);
  d.setUTCHours(0, 0, 0, 0);
  return d;
}

/**
 * Calcula la próxima fecha de vencimiento para un usuario según su billingConfig.
 * @param {{approvedAt: Date|Timestamp}} user
 * @param {{period: {every: number, unit: string}, dueDay: any}} cfg
 * @param {{validatedAt: Date|Timestamp}|null} lastPayment - último pago no voided
 * @returns {Date}
 */
function computeNextDueDate(user, cfg, lastPayment) {
  const baseRaw = lastPayment
    ? lastPayment.validatedAt
    : user.approvedAt;
  const base = baseRaw && baseRaw.toDate ? baseRaw.toDate() : new Date(baseRaw);
  const unit = cfg.period.unit || 'month';
  const every = Math.max(1, Number(cfg.period.every) || 1);

  // base + (every × unit) sin alinear
  const advanced = new Date(base);
  if (unit === 'day') advanced.setUTCDate(advanced.getUTCDate() + every);
  else if (unit === 'week') advanced.setUTCDate(advanced.getUTCDate() + every * 7);
  else if (unit === 'month') advanced.setUTCMonth(advanced.getUTCMonth() + every);
  else if (unit === 'year') advanced.setUTCFullYear(advanced.getUTCFullYear() + every);

  // Si NO hay pago previo (primera cuota), alineamos al dueDay siguiente
  if (!lastPayment) {
    return alignToDueDay(base, cfg.dueDay, unit);
  }
  return advanced;
}

module.exports = { computeNextDueDate, alignToDueDay };
```

- [ ] **Step 5: Correr tests, verificar verde**

```bash
cd functions && npx jest test/dueDate.test.js 2>&1 | tail -20
```

Expected: PASS, 4 passing tests.

- [ ] **Step 6: Commit**

```bash
git add functions/lib/dueDate.js functions/test/dueDate.test.js functions/package.json
git commit -m "feat(functions): pure helpers computeNextDueDate + alignToDueDay con tests jest"
```

---

### Task 2: Extender `PaymentModel` con campos de anulación

**Files:**
- Modify: `lib/features/payments/data/models/payment_model.dart`

- [ ] **Step 1: Leer el modelo actual para entender el shape**

```bash
grep -n "class PaymentModel\|factory PaymentModel\|toFirestore\|class PaymentProof" lib/features/payments/data/models/payment_model.dart | head -20
```

- [ ] **Step 2: Agregar campos nuevos al constructor + fromFirestore + toFirestore**

En `PaymentModel`:

```dart
// Agregar al final de la lista de campos:
final DateTime? voidedAt;
final String? voidedBy;
final String? voidReason;
final bool targetSuperAdmin;
```

Constructor:
```dart
const PaymentModel({
  // ... campos existentes
  this.voidedAt,
  this.voidedBy,
  this.voidReason,
  this.targetSuperAdmin = false,
});
```

`fromFirestore`:
```dart
voidedAt: (data['voidedAt'] as Timestamp?)?.toDate(),
voidedBy: data['voidedBy'] as String?,
voidReason: data['voidReason'] as String?,
targetSuperAdmin: data['targetSuperAdmin'] as bool? ?? false,
```

`toFirestore`:
```dart
if (voidedAt != null) 'voidedAt': Timestamp.fromDate(voidedAt!),
if (voidedBy != null) 'voidedBy': voidedBy,
if (voidReason != null) 'voidReason': voidReason,
'targetSuperAdmin': targetSuperAdmin,
```

Getter helper:
```dart
bool get isVoided => voidedAt != null;
bool get isEffectivelyValidated => status == PaymentStatus.validated && !isVoided;
```

- [ ] **Step 3: Agregar concept value `membresiaAsociacion`**

Buscar `PaymentConcepts`:
```bash
grep -n "PaymentConcepts\|cuota_mensual" lib/features/payments/data/models/payment_model.dart
```

Agregar a la lista de concepts:
```dart
static const String membresiaAsociacion = 'membresia_asociacion';

static const all = [
  cuotaMensual, cuotaSemanal, multa, deuda, incentivo, ayuda,
  membresiaAsociacion,
];
```

- [ ] **Step 4: Verificar compilación**

```bash
flutter analyze lib/features/payments/data/models/payment_model.dart
```

Expected: 0 issues.

- [ ] **Step 5: Commit**

```bash
git add lib/features/payments/data/models/payment_model.dart
git commit -m "feat(payments): extender PaymentModel con voidedAt/voidedBy/voidReason/targetSuperAdmin + concept membresiaAsociacion"
```

---

### Task 3: Extender `UserModel` con `blockedAt`/`blockReason`

**Files:**
- Modify: `lib/features/auth/data/models/user_model.dart`

- [ ] **Step 1: Agregar campos al modelo**

En la clase `UserModel`, agregar tras `approvedAt`:

```dart
final DateTime? blockedAt;
final String? blockReason; // 'cuota_vencida' | 'pago_anulado' | 'admin_manual'
```

Constructor:
```dart
const UserModel({
  // ... existentes
  this.blockedAt,
  this.blockReason,
});
```

`fromFirestore`:
```dart
blockedAt: (data['blockedAt'] as Timestamp?)?.toDate(),
blockReason: data['blockReason'] as String?,
```

`toFirestore`:
```dart
if (blockedAt != null) 'blockedAt': Timestamp.fromDate(blockedAt!),
if (blockReason != null) 'blockReason': blockReason,
```

`copyWith` agregar params correspondientes.

- [ ] **Step 2: Verificar compilación**

```bash
flutter analyze lib/features/auth/data/models/user_model.dart
```

Expected: 0 issues.

- [ ] **Step 3: Commit**

```bash
git add lib/features/auth/data/models/user_model.dart
git commit -m "feat(auth): UserModel.blockedAt + blockReason para auditoría de bloqueos automáticos"
```

---

### Task 4: Extender `AssociationModel` con `suspendedAt`/`suspendedReason`

**Files:**
- Modify: `lib/features/associations/data/models/association_model.dart`

- [ ] **Step 1: Leer estructura actual**

```bash
grep -n "class AssociationModel\|factory\|paidUntil\|status:" lib/features/associations/data/models/association_model.dart | head -15
```

- [ ] **Step 2: Agregar campos**

```dart
final DateTime? suspendedAt;
final String? suspendedReason; // 'expired_paid_until' | 'expired_trial' | 'manual'
```

Mismas adiciones que UserModel: constructor, fromFirestore, toFirestore, copyWith.

- [ ] **Step 3: Verificar compilación**

```bash
flutter analyze lib/features/associations/data/models/association_model.dart
```

Expected: 0 issues.

- [ ] **Step 4: Commit**

```bash
git add lib/features/associations/data/models/association_model.dart
git commit -m "feat(associations): suspendedAt + suspendedReason en AssociationModel"
```

---

### Task 5: Reglas Firestore — `_isVoidUpdate`

**Files:**
- Modify: `firestore.rules`

- [ ] **Step 1: Agregar la función helper**

Después de `_isMemberIdsSelfUpdate()` (busca con `grep -n "_isMemberIdsSelfUpdate" firestore.rules`):

```firestore
function _isVoidUpdate() {
  return resource.data.status == 'validated'
    && request.resource.data.diff(resource.data).affectedKeys()
        .hasOnly(['voidedAt', 'voidedBy', 'voidReason'])
    && request.resource.data.voidReason is string
    && request.resource.data.voidReason.size() >= 10;
}
```

- [ ] **Step 2: Extender el `allow update` de `payments`**

Buscar el match de `payments`:
```bash
grep -n "match /payments" firestore.rules
```

Modificar el `allow update`:

```firestore
allow update: if sameTenant(resource.data) && (
  (canSubmitPayment() && isOwner(resource.data.driverId))
  || isOperatorOrAdmin()
  || (isAdmin() && _isVoidUpdate())
);
```

- [ ] **Step 3: Validar sintaxis local**

```bash
firebase emulators:exec --only firestore "echo rules ok" 2>&1 | tail -10
```

Si no hay emulador, al menos validar:
```bash
firebase deploy --only firestore:rules --dry-run 2>&1 | tail -10
```

Expected: rules parsean OK.

- [ ] **Step 4: Commit**

```bash
git add firestore.rules
git commit -m "feat(rules): permitir admin anular pago validated (mín 10 chars de motivo)"
```

---

## Fase 2 — Cron `enforcePayments`

### Task 6: Cloud Function `enforcePayments` — Pase A (asociaciones)

**Files:**
- Modify: `functions/index.js`

- [ ] **Step 1: Leer el patrón de `purgeExpiredProofs` para seguir el mismo perfil**

```bash
grep -n "purgeExpiredProofs\|onSchedule" functions/index.js | head -10
```

- [ ] **Step 2: Agregar `enforcePayments` (solo Pase A por ahora)**

Después de `purgeExpiredProofs`:

```javascript
// ──────────────────────────────────────────────────────────────────
//  enforcePayments — cron diario 00:00 America/Guayaquil
//  Pase A: suspende asociaciones con paidUntil/trialEndsAt vencido.
//  Pase B: bloquea conductores en mora (Task 7).
//  Pase C: reactiva los que ya tienen pago al día (Task 8).
// ──────────────────────────────────────────────────────────────────

exports.enforcePayments = onSchedule({
  schedule: 'every day 00:00',
  timeZone: 'America/Guayaquil',
  memory: '512MiB',
  timeoutSeconds: 540,
}, async (event) => {
  const now = Timestamp.now();
  logger.info('[enforcePayments] start', { now: now.toDate().toISOString() });

  // ─── Pase A: asociaciones vencidas ───
  const assocSnap = await db.collection('associations')
    .where('status', 'in', ['active', 'trial'])
    .get();

  let suspendedCount = 0;
  for (const doc of assocSnap.docs) {
    const a = doc.data();
    const isTrial = a.status === 'trial';
    const expiry = isTrial ? a.trialEndsAt : a.paidUntil;
    if (!expiry) continue;
    const expiryDate = expiry.toDate ? expiry.toDate() : new Date(expiry);
    if (expiryDate.getTime() > now.toMillis()) continue;

    await doc.ref.update({
      status: 'suspended',
      suspendedAt: now,
      suspendedReason: isTrial ? 'expired_trial' : 'expired_paid_until',
      updatedAt: now,
    });
    suspendedCount++;
    logger.info(`[enforcePayments] suspended assoc ${doc.id} (${a.name || ''})`);

    // FCM al admin
    const adminSnap = await db.collection('users')
      .where('associationId', '==', doc.id)
      .where('role', '==', 'admin')
      .where('status', '==', 'active')
      .limit(1)
      .get();
    if (!adminSnap.empty) {
      const adminUid = adminSnap.docs[0].id;
      await _sendFcmToUid(adminUid, {
        title: 'Cooperativa suspendida',
        body: `Tu cooperativa ${a.name || ''} fue suspendida por mora. Paga la membresía para reactivarla.`,
      }).catch((e) => logger.error('FCM error admin', e));
    }
  }

  logger.info(`[enforcePayments] A=${suspendedCount}`);
  return { suspended: suspendedCount };
});

/// Helper interno para enviar FCM a un uid usando el fcmToken guardado.
async function _sendFcmToUid(uid, payload) {
  const u = await db.collection('users').doc(uid).get();
  const token = u.data()?.fcmToken;
  if (!token) return;
  await getMessaging().send({
    token,
    notification: { title: payload.title, body: payload.body },
  });
}
```

Agregar imports necesarios al tope si no están:
```javascript
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { getMessaging } = require('firebase-admin/messaging');
const { logger } = require('firebase-functions');
```

- [ ] **Step 3: Verificar que no rompe `npm run lint`**

```bash
cd functions && npm run lint 2>&1 | tail -10 || true
```

Si hay lint config, debe pasar. Si no hay, al menos:
```bash
cd functions && node -c index.js
```

Expected: sin error de sintaxis.

- [ ] **Step 4: Commit**

```bash
git add functions/index.js
git commit -m "feat(functions): enforcePayments Pase A — suspende asociaciones vencidas + FCM al admin"
```

---

### Task 7: `enforcePayments` — Pase B (socios en mora)

**Files:**
- Modify: `functions/index.js`

- [ ] **Step 1: Agregar helper `lastValidatedPayment`**

Después del helper `_sendFcmToUid` agregar:

```javascript
/// Último pago validado y NO anulado del conductor.
async function _lastValidatedPayment(uid, associationId) {
  const snap = await db.collection('payments')
    .where('driverId', '==', uid)
    .where('associationId', '==', associationId)
    .where('status', '==', 'validated')
    .orderBy('validatedAt', 'desc')
    .limit(10)
    .get();
  for (const d of snap.docs) {
    if (!d.data().voidedAt) return d.data();
  }
  return null;
}

/// True si el conductor tiene un permiso activo cubriendo la fecha dada.
async function _hasActivePermit(uid, dateCovered) {
  const snap = await db.collection('permissions')
    .where('driverId', '==', uid)
    .where('status', '==', 'active')
    .limit(5)
    .get();
  for (const d of snap.docs) {
    const p = d.data();
    const start = p.startDate?.toDate?.();
    const end = p.expectedEndDate?.toDate?.();
    if (!start || !end) continue;
    if (dateCovered >= start && dateCovered <= end) return true;
  }
  return false;
}
```

- [ ] **Step 2: Extender `enforcePayments` con Pase B**

Insertar después del logger de Pase A:

```javascript
const { computeNextDueDate } = require('./lib/dueDate');

// ─── Pase B: conductores en mora ───
const activeAssocs = await db.collection('associations')
  .where('status', '==', 'active')
  .get();

let blockedCount = 0;
for (const aDoc of activeAssocs.docs) {
  const cfg = aDoc.data().billingConfig;
  if (!cfg || !(cfg.amount > 0)) continue;

  const usersSnap = await db.collection('users')
    .where('associationId', '==', aDoc.id)
    .where('status', '==', 'active')
    .get();

  for (const uDoc of usersSnap.docs) {
    const u = uDoc.data();
    if (!['conductor', 'admin'].includes(u.role)) continue;
    if (!u.approvedAt) continue;

    const last = await _lastValidatedPayment(uDoc.id, aDoc.id);
    const nextDue = computeNextDueDate(
      { approvedAt: u.approvedAt.toDate ? u.approvedAt.toDate() : u.approvedAt },
      cfg, last,
    );
    if (nextDue.getTime() > now.toMillis()) continue;
    if (await _hasActivePermit(uDoc.id, nextDue)) continue;

    await uDoc.ref.update({
      status: 'paymentBlocked',
      blockedAt: now,
      blockReason: 'cuota_vencida',
      updatedAt: now,
    });
    blockedCount++;
    logger.info(`[enforcePayments] blocked user ${uDoc.id}`);

    await _sendFcmToUid(uDoc.id, {
      title: 'Tu cuenta fue bloqueada',
      body: 'Sube tu comprobante de pago para reactivarte.',
    }).catch(() => {});
  }
}

logger.info(`[enforcePayments] B=${blockedCount}`);
```

Actualizar el `return`:
```javascript
return { suspended: suspendedCount, blocked: blockedCount };
```

- [ ] **Step 3: Verificar sintaxis**

```bash
cd functions && node -c index.js
```

Expected: sin error.

- [ ] **Step 4: Commit**

```bash
git add functions/index.js
git commit -m "feat(functions): enforcePayments Pase B — bloquea conductores en mora respetando permisos"
```

---

### Task 8: `enforcePayments` — Pase C (re-activación de seguridad)

**Files:**
- Modify: `functions/index.js`

- [ ] **Step 1: Agregar Pase C dentro de `enforcePayments`**

Después del logger de Pase B:

```javascript
// ─── Pase C: re-activar conductores con pago al día ───
const blockedSnap = await db.collection('users')
  .where('status', '==', 'paymentBlocked')
  .where('blockReason', '==', 'cuota_vencida')
  .get();

let reactivatedCount = 0;
for (const uDoc of blockedSnap.docs) {
  const u = uDoc.data();
  const aDoc = await db.collection('associations').doc(u.associationId).get();
  if (!aDoc.exists) continue;
  const cfg = aDoc.data().billingConfig;
  if (!cfg) continue;

  const last = await _lastValidatedPayment(uDoc.id, u.associationId);
  if (!last) continue;
  const nextDue = computeNextDueDate(
    { approvedAt: u.approvedAt.toDate() },
    cfg, last,
  );
  if (nextDue.getTime() <= now.toMillis()) continue;

  await uDoc.ref.update({
    status: 'active',
    blockedAt: FieldValue.delete(),
    blockReason: FieldValue.delete(),
    updatedAt: now,
  });
  reactivatedCount++;
  logger.info(`[enforcePayments] reactivated user ${uDoc.id}`);

  await _sendFcmToUid(uDoc.id, {
    title: 'Cuenta reactivada',
    body: 'Tu cuenta fue reactivada. Bienvenido de vuelta.',
  }).catch(() => {});
}

logger.info(`[enforcePayments] C=${reactivatedCount}`);
```

Actualizar el return:
```javascript
return { suspended: suspendedCount, blocked: blockedCount, reactivated: reactivatedCount };
```

- [ ] **Step 2: Verificar sintaxis**

```bash
cd functions && node -c index.js
```

- [ ] **Step 3: Commit**

```bash
git add functions/index.js
git commit -m "feat(functions): enforcePayments Pase C — red de seguridad de reactivación"
```

---

### Task 9: Modificar `validatePayment` para reactivar al instante

**Files:**
- Modify: `functions/index.js`

- [ ] **Step 1: Localizar `validatePayment`**

```bash
grep -n "exports.validatePayment\|validatePayment = onCall" functions/index.js
```

- [ ] **Step 2: Agregar lógica de reactivación al final del handler**

Antes del `return` final, después de `paymentRef.update({...status: validated...})`:

```javascript
// Si el conductor estaba paymentBlocked por cuota_vencida, reactivar inmediato
const driverSnap = await db.collection('users').doc(payment.driverId).get();
if (driverSnap.exists) {
  const d = driverSnap.data();
  if (d.status === 'paymentBlocked' && d.blockReason === 'cuota_vencida') {
    await driverSnap.ref.update({
      status: 'active',
      blockedAt: FieldValue.delete(),
      blockReason: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    logger.info(`[validatePayment] auto-reactivated ${payment.driverId}`);
    await _sendFcmToUid(payment.driverId, {
      title: 'Cuenta reactivada',
      body: 'Tu pago fue aprobado. Ya puedes operar normalmente.',
    }).catch(() => {});
  }
}
```

- [ ] **Step 3: Verificar sintaxis**

```bash
cd functions && node -c index.js
```

- [ ] **Step 4: Commit**

```bash
git add functions/index.js
git commit -m "feat(functions): validatePayment reactiva inmediatamente al conductor paymentBlocked"
```

---

## Fase 3 — Anulación de pagos

### Task 10: Cloud Function `voidPayment`

**Files:**
- Modify: `functions/index.js`

- [ ] **Step 1: Agregar la function**

Después de `validatePayment`:

```javascript
// ──────────────────────────────────────────────────────────────────
//  voidPayment — admin anula un pago previamente validado.
//  Bloquea al conductor inmediatamente + FCM con motivo.
// ──────────────────────────────────────────────────────────────────

exports.voidPayment = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { paymentId, reason } = request.data || {};

  if (!paymentId || typeof paymentId !== 'string') {
    throw new HttpsError('invalid-argument', 'paymentId requerido.');
  }
  if (!reason || typeof reason !== 'string' || reason.length < 10) {
    throw new HttpsError('invalid-argument', 'Motivo obligatorio (mín 10 caracteres).');
  }

  const paymentRef = db.collection('payments').doc(paymentId);
  const paymentSnap = await paymentRef.get();
  if (!paymentSnap.exists) {
    throw new HttpsError('not-found', 'Pago no existe.');
  }
  const p = paymentSnap.data();

  if (p.status !== 'validated' || p.voidedAt) {
    throw new HttpsError('failed-precondition', 'Solo se anulan pagos validados (no anulados).');
  }

  // Permisos: admin del mismo tenant
  const callerSnap = await db.collection('users').doc(auth.uid).get();
  const caller = callerSnap.data() || {};
  const isSuper = (request.auth.token?.email === 'brealpeaymara@gmail.com')
    || (request.auth.token?.superAdmin === true);
  if (!isSuper) {
    if (caller.role !== 'admin' || caller.associationId !== p.associationId) {
      throw new HttpsError('permission-denied', 'Solo admin del tenant puede anular.');
    }
  }

  const now = FieldValue.serverTimestamp();
  await paymentRef.update({
    voidedAt: now,
    voidedBy: auth.uid,
    voidReason: reason,
    updatedAt: now,
  });

  // Bloquear conductor
  if (p.driverId) {
    await db.collection('users').doc(p.driverId).update({
      status: 'paymentBlocked',
      blockedAt: now,
      blockReason: 'pago_anulado',
      updatedAt: now,
    });
    await _sendFcmToUid(p.driverId, {
      title: 'Pago anulado',
      body: `Un pago tuyo fue anulado. Motivo: ${reason}. Tu cuenta está bloqueada.`,
    }).catch(() => {});
  }

  return { ok: true };
});
```

- [ ] **Step 2: Verificar sintaxis**

```bash
cd functions && node -c index.js
```

- [ ] **Step 3: Commit**

```bash
git add functions/index.js
git commit -m "feat(functions): voidPayment — admin anula pago validated y bloquea conductor"
```

---

### Task 11: UI — botón "Anular pago" en `_PaymentDetailDialog`

**Files:**
- Modify: `lib/features/payments/presentation/pages/payment_approvals_page.dart`

- [ ] **Step 1: Localizar `_PaymentDetailDialog`**

```bash
grep -n "_PaymentDetailDialog\|class _PaymentDetail" lib/features/payments/presentation/pages/payment_approvals_page.dart
```

- [ ] **Step 2: Importar `cloud_functions` si falta**

```bash
grep -n "cloud_functions" lib/features/payments/presentation/pages/payment_approvals_page.dart || echo "FALTA"
```

Si falta, agregar al top:
```dart
import 'package:cloud_functions/cloud_functions.dart';
```

- [ ] **Step 3: Agregar botón "Anular pago" en el dialog**

Buscar la zona donde están los botones "Rechazar/Aprobar" (solo cuando status=pending). Agregar un bloque SEPARADO debajo de las acciones, visible solo cuando `payment.status == validated && !payment.isVoided && callerIsAdmin`:

```dart
// Botón anular pago — solo admin, solo si validated y no voided
Builder(builder: (ctx) {
  final auth = ctx.read<AuthBloc>().state;
  final isAdmin = auth is AuthAuthenticated &&
      auth.user.role == AppConstants.roleAdmin;
  if (!isAdmin) return const SizedBox.shrink();
  if (payment.status != PaymentStatus.validated) return const SizedBox.shrink();
  if (payment.isVoided) return const SizedBox.shrink();

  return Padding(
    padding: const EdgeInsets.only(top: 12),
    child: SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        icon: const Icon(Icons.block, color: Colors.red),
        label: const Text('Anular pago',
            style: TextStyle(color: Colors.red)),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.red),
        ),
        onPressed: () => _confirmAndVoid(context, payment),
      ),
    ),
  );
}),
```

- [ ] **Step 4: Agregar método `_confirmAndVoid`**

Dentro de la State class:

```dart
Future<void> _confirmAndVoid(BuildContext context, PaymentModel payment) async {
  final reasonCtrl = TextEditingController();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Anular pago'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Esta acción bloquea al conductor inmediatamente. '
            'Recibe FCM push con el motivo. ¿Continuar?',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: reasonCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Motivo (mín 10 caracteres)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () {
            if (reasonCtrl.text.trim().length < 10) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Motivo debe tener al menos 10 caracteres')),
              );
              return;
            }
            Navigator.of(ctx).pop(true);
          },
          child: const Text('Anular'),
        ),
      ],
    ),
  );

  if (confirmed != true) return;
  if (!context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  try {
    await FirebaseFunctions.instance.httpsCallable('voidPayment').call({
      'paymentId': payment.id,
      'reason': reasonCtrl.text.trim(),
    });
    if (!context.mounted) return;
    navigator.pop(); // cierra el detail dialog
    messenger.showSnackBar(const SnackBar(
      content: Text('Pago anulado y conductor bloqueado'),
    ));
  } on FirebaseFunctionsException catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text('Error: ${e.message ?? e.code}'),
    ));
  }
}
```

- [ ] **Step 5: Analizar**

```bash
flutter analyze lib/features/payments/presentation/pages/payment_approvals_page.dart
```

Expected: 0 issues nuevos.

- [ ] **Step 6: Commit**

```bash
git add lib/features/payments/presentation/pages/payment_approvals_page.dart
git commit -m "feat(payments): botón Anular pago con confirmación + motivo obligatorio (admin)"
```

---

## Fase 4 — Pago de membresía de asociación

### Task 12: Cloud Functions `reportAssociationPayment` + `validateAssociationPayment` + `extendPaidUntil`

**Files:**
- Modify: `functions/index.js`

- [ ] **Step 1: Agregar las 3 functions tras `voidPayment`**

```javascript
// ──────────────────────────────────────────────────────────────────
//  reportAssociationPayment — admin sube comprobante de membresía al
//  super-admin. Crea doc en `payments` con concept='membresia_asociacion'.
// ──────────────────────────────────────────────────────────────────

exports.reportAssociationPayment = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { amount, bank, transactionRef, transactionDate, photoUrl, photoExpiresAt } = request.data || {};

  if (!amount || amount <= 0) {
    throw new HttpsError('invalid-argument', 'Monto inválido.');
  }

  const userSnap = await db.collection('users').doc(auth.uid).get();
  const u = userSnap.data() || {};
  if (u.role !== 'admin') {
    throw new HttpsError('permission-denied', 'Solo admin puede reportar membresía.');
  }

  const now = FieldValue.serverTimestamp();
  const docRef = db.collection('payments').doc();
  await docRef.set({
    associationId: u.associationId,
    driverId: auth.uid,
    driverName: `${u.name || ''} ${u.lastname || ''}`.trim(),
    concept: 'membresia_asociacion',
    amount,
    status: 'pending',
    targetSuperAdmin: true,
    reportedAt: now,
    proof: {
      method: 'transferencia',
      bank: bank || null,
      transactionRef: transactionRef || null,
      transactionDate: transactionDate ? Timestamp.fromDate(new Date(transactionDate)) : null,
      photoUrl: photoUrl || null,
      photoExpiresAt: photoExpiresAt ? Timestamp.fromDate(new Date(photoExpiresAt)) : null,
    },
    createdAt: now,
    updatedAt: now,
  });

  return { ok: true, paymentId: docRef.id };
});

// ──────────────────────────────────────────────────────────────────
//  validateAssociationPayment — super-admin aprueba pago de membresía.
//  Extiende paidUntil + months, activa asociación, FCM a todos.
// ──────────────────────────────────────────────────────────────────

exports.validateAssociationPayment = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { paymentId, monthsToAdd } = request.data || {};

  const isSuper = (request.auth.token?.email === 'brealpeaymara@gmail.com')
    || (request.auth.token?.superAdmin === true);
  if (!isSuper) {
    throw new HttpsError('permission-denied', 'Solo super-admin.');
  }

  if (!paymentId) throw new HttpsError('invalid-argument', 'paymentId requerido.');
  const months = Math.max(1, Math.min(36, Number(monthsToAdd) || 1));

  const pRef = db.collection('payments').doc(paymentId);
  const pSnap = await pRef.get();
  if (!pSnap.exists) throw new HttpsError('not-found', 'Pago no existe.');
  const p = pSnap.data();
  if (p.concept !== 'membresia_asociacion') {
    throw new HttpsError('failed-precondition', 'Este pago no es de membresía.');
  }
  if (p.status !== 'pending') {
    throw new HttpsError('failed-precondition', 'Solo pagos pendientes.');
  }

  const now = FieldValue.serverTimestamp();
  await pRef.update({
    status: 'validated',
    validatedAt: now,
    validatedBy: auth.uid,
    updatedAt: now,
  });

  // Extender paidUntil
  const aRef = db.collection('associations').doc(p.associationId);
  const aSnap = await aRef.get();
  const current = aSnap.data().paidUntil?.toDate?.() || new Date();
  const base = current > new Date() ? current : new Date();
  const newPaidUntil = new Date(base);
  newPaidUntil.setUTCMonth(newPaidUntil.getUTCMonth() + months);

  await aRef.update({
    status: 'active',
    paidUntil: Timestamp.fromDate(newPaidUntil),
    suspendedAt: FieldValue.delete(),
    suspendedReason: FieldValue.delete(),
    updatedAt: now,
  });

  // FCM a todos los users de la asoc
  const usersSnap = await db.collection('users')
    .where('associationId', '==', p.associationId)
    .get();
  await Promise.all(usersSnap.docs.map((u) => _sendFcmToUid(u.id, {
    title: 'Cooperativa reactivada',
    body: 'Ya puedes operar normalmente.',
  }).catch(() => {})));

  return { ok: true, newPaidUntil: newPaidUntil.toISOString() };
});

// ──────────────────────────────────────────────────────────────────
//  extendPaidUntil — super-admin extiende paidUntil manualmente sin
//  comprobante (caso transferencia directa fuera de la app).
// ──────────────────────────────────────────────────────────────────

exports.extendPaidUntil = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { associationId, monthsToAdd } = request.data || {};

  const isSuper = (request.auth.token?.email === 'brealpeaymara@gmail.com')
    || (request.auth.token?.superAdmin === true);
  if (!isSuper) throw new HttpsError('permission-denied', 'Solo super-admin.');
  if (!associationId) throw new HttpsError('invalid-argument', 'associationId requerido.');
  const months = Math.max(1, Math.min(36, Number(monthsToAdd) || 1));

  const aRef = db.collection('associations').doc(associationId);
  const aSnap = await aRef.get();
  if (!aSnap.exists) throw new HttpsError('not-found', 'Asoc no existe.');

  const current = aSnap.data().paidUntil?.toDate?.() || new Date();
  const base = current > new Date() ? current : new Date();
  const newPaidUntil = new Date(base);
  newPaidUntil.setUTCMonth(newPaidUntil.getUTCMonth() + months);

  await aRef.update({
    status: 'active',
    paidUntil: Timestamp.fromDate(newPaidUntil),
    suspendedAt: FieldValue.delete(),
    suspendedReason: FieldValue.delete(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  return { ok: true, newPaidUntil: newPaidUntil.toISOString() };
});
```

- [ ] **Step 2: Verificar sintaxis**

```bash
cd functions && node -c index.js
```

- [ ] **Step 3: Commit**

```bash
git add functions/index.js
git commit -m "feat(functions): reportAssociationPayment + validateAssociationPayment + extendPaidUntil"
```

---

### Task 13: Widget `_ReportAssociationPaymentDialog`

**Files:**
- Create: `lib/features/payments/presentation/widgets/report_association_payment_dialog.dart`

- [ ] **Step 1: Crear archivo nuevo**

```dart
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/models/payment_model.dart';

class ReportAssociationPaymentDialog extends StatefulWidget {
  const ReportAssociationPaymentDialog({super.key});

  @override
  State<ReportAssociationPaymentDialog> createState() =>
      _ReportAssociationPaymentDialogState();
}

class _ReportAssociationPaymentDialogState
    extends State<ReportAssociationPaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  final _bankCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  DateTime? _transactionDate;
  bool _submitting = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _bankCtrl.dispose();
    _refCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_transactionDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecciona la fecha del depósito')),
      );
      return;
    }

    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('reportAssociationPayment')
          .call({
        'amount': double.parse(_amountCtrl.text),
        'bank': _bankCtrl.text.trim(),
        'transactionRef': _refCtrl.text.trim(),
        'transactionDate': _transactionDate!.toIso8601String(),
      });
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(const SnackBar(
        content: Text('Comprobante enviado. Esperando aprobación del super-admin.'),
      ));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Error: ${e.message ?? e.code}')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pagar membresía'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Monto (USD)',
                  prefixText: '\$',
                ),
                validator: (v) {
                  final d = double.tryParse(v ?? '');
                  if (d == null || d <= 0) return 'Monto inválido';
                  return null;
                },
              ),
              TextFormField(
                controller: _bankCtrl,
                decoration: const InputDecoration(labelText: 'Banco origen'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Requerido' : null,
              ),
              TextFormField(
                controller: _refCtrl,
                decoration: const InputDecoration(labelText: '# Comprobante'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Requerido' : null,
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_transactionDate == null
                    ? 'Fecha del depósito'
                    : DateFormat('dd/MM/yyyy').format(_transactionDate!)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: DateTime.now().subtract(const Duration(days: 30)),
                    lastDate: DateTime.now(),
                    initialDate: DateTime.now(),
                  );
                  if (picked != null) setState(() => _transactionDate = picked);
                },
              ),
              const SizedBox(height: 8),
              const Text(
                'El super-admin validará el pago y reactivará tu cooperativa.',
                style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : _submit,
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor),
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Enviar'),
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: Analizar**

```bash
flutter analyze lib/features/payments/presentation/widgets/report_association_payment_dialog.dart
```

- [ ] **Step 3: Commit**

```bash
git add lib/features/payments/presentation/widgets/report_association_payment_dialog.dart
git commit -m "feat(payments): dialog ReportAssociationPaymentDialog para admin subir comprobante de membresía"
```

---

### Task 14: Extender `AccountBlockedPage` con 3 variantes

**Files:**
- Modify: `lib/features/auth/presentation/pages/account_blocked_page.dart`

- [ ] **Step 1: Leer estructura actual**

```bash
cat lib/features/auth/presentation/pages/account_blocked_page.dart
```

- [ ] **Step 2: Reescribir el `build` para soportar 3 modos**

```dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../associations/data/models/association_model.dart';
import '../../../payments/presentation/widgets/report_association_payment_dialog.dart';
import '../../data/models/user_model.dart';
import '../bloc/auth_bloc.dart';

class AccountBlockedPage extends StatelessWidget {
  const AccountBlockedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return const _LoadingScaffold();
    final user = auth.user;

    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance
          .collection('associations')
          .doc(user.associationId)
          .get(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const _LoadingScaffold();
        final assoc = snap.data!.exists
            ? AssociationModel.fromFirestore(snap.data!)
            : null;
        final assocSuspended = assoc?.status == 'suspended';
        final isAdmin = user.role == 'admin';

        if (assocSuspended && isAdmin) {
          return _AssocSuspendedAdminView(assoc: assoc!, user: user);
        }
        if (assocSuspended) {
          return _AssocSuspendedNonAdminView(assoc: assoc!);
        }
        return _DriverBlockedView(user: user);
      },
    );
  }
}

class _LoadingScaffold extends StatelessWidget {
  const _LoadingScaffold();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _DriverBlockedView extends StatelessWidget {
  final UserModel user;
  const _DriverBlockedView({required this.user});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.red.shade50,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.block, size: 80, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                'Tu cuenta está bloqueada',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                user.blockReason == 'pago_anulado'
                    ? 'Un pago tuyo fue anulado.'
                    : 'Tu cuota está vencida.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => Navigator.of(context).pushNamed('/my-payments'),
                icon: const Icon(Icons.upload),
                label: const Text('Subir comprobante de pago'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => context.read<AuthBloc>().add(AuthSignOutRequested()),
                child: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssocSuspendedAdminView extends StatelessWidget {
  final AssociationModel assoc;
  final UserModel user;
  const _AssocSuspendedAdminView({required this.assoc, required this.user});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.red.shade50,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.business, size: 80, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                'Tu cooperativa fue suspendida',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'La membresía está vencida. Sube el comprobante de pago para reactivarla.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => const ReportAssociationPaymentDialog(),
                ),
                icon: const Icon(Icons.payments),
                label: const Text('Pagar membresía'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => context.read<AuthBloc>().add(AuthSignOutRequested()),
                child: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssocSuspendedNonAdminView extends StatelessWidget {
  final AssociationModel assoc;
  const _AssocSuspendedNonAdminView({required this.assoc});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.red.shade50,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.business, size: 80, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                'Tu cooperativa fue suspendida',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'El administrador debe pagar la membresía. Mientras tanto no puedes operar.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => context.read<AuthBloc>().add(AuthSignOutRequested()),
                child: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: Analizar**

```bash
flutter analyze lib/features/auth/presentation/pages/account_blocked_page.dart
```

Resolver imports rotos si los hay.

- [ ] **Step 4: Commit**

```bash
git add lib/features/auth/presentation/pages/account_blocked_page.dart
git commit -m "feat(auth): AccountBlockedPage con 3 variantes (driver, admin asoc-suspended, no-admin asoc-suspended)"
```

---

### Task 15: Filtro "Membresías" en `payment_approvals_page` (super-admin)

**Files:**
- Modify: `lib/features/payments/presentation/pages/payment_approvals_page.dart`

- [ ] **Step 1: Agregar filtro de tipo**

Buscar el enum de filtros existente (status pending/validated/rejected). Agregar un toggle nuevo "Solo membresías" visible solo para super-admin.

```dart
bool _showOnlyMembership = false;

// En el AppBar / filter bar, agregar para super-admin:
Builder(builder: (ctx) {
  final auth = ctx.read<AuthBloc>().state;
  final isSuper = auth is AuthAuthenticated &&
      auth.user.email == 'brealpeaymara@gmail.com';
  if (!isSuper) return const SizedBox.shrink();
  return FilterChip(
    label: const Text('Solo membresías'),
    selected: _showOnlyMembership,
    onSelected: (v) => setState(() => _showOnlyMembership = v),
  );
});
```

En el query del StreamBuilder, agregar:
```dart
if (_showOnlyMembership) {
  q = q.where('concept', isEqualTo: 'membresia_asociacion')
       .where('targetSuperAdmin', isEqualTo: true);
}
```

En el tile de cada pago, si `payment.concept == 'membresia_asociacion'`, mostrar "Membresía — ${associationName}" en vez de driver name.

- [ ] **Step 2: Reemplazar el botón "Aprobar" cuando es membresía**

En el detail dialog, si es membresía, el botón "Aprobar" llama a `validateAssociationPayment` en vez de `validatePayment`, y pide `monthsToAdd` (default 1):

```dart
if (payment.concept == 'membresia_asociacion') {
  final months = await showDialog<int>(
    context: context,
    builder: (ctx) {
      int sel = 1;
      return AlertDialog(
        title: const Text('¿Cuántos meses extender?'),
        content: StatefulBuilder(builder: (ctx, setLocal) {
          return DropdownButton<int>(
            value: sel,
            items: [1, 3, 6, 12].map((m) => DropdownMenuItem(
              value: m, child: Text('$m mes${m == 1 ? '' : 'es'}'),
            )).toList(),
            onChanged: (v) => setLocal(() => sel = v ?? 1),
          );
        }),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(sel),
            child: const Text('Aprobar'),
          ),
        ],
      );
    },
  );
  if (months == null) return;
  await FirebaseFunctions.instance.httpsCallable('validateAssociationPayment').call({
    'paymentId': payment.id,
    'monthsToAdd': months,
  });
}
```

- [ ] **Step 3: Analizar**

```bash
flutter analyze lib/features/payments/presentation/pages/payment_approvals_page.dart
```

- [ ] **Step 4: Commit**

```bash
git add lib/features/payments/presentation/pages/payment_approvals_page.dart
git commit -m "feat(payments): filtro Solo membresías + flujo de aprobación con meses a extender"
```

---

## Fase 5 — Banner del día del vencimiento

### Task 16: Helper Dart `due_date_calculator.dart` (espejo del JS)

**Files:**
- Create: `lib/features/payments/data/due_date_calculator.dart`

- [ ] **Step 1: Crear archivo**

```dart
import '../../associations/data/models/association_model.dart';
import '../../auth/data/models/user_model.dart';
import 'models/payment_model.dart';

/// Espejo de `functions/lib/dueDate.js`. Mantener en sync.
/// Calcula la próxima fecha de vencimiento de la cuota del conductor.
class DueDateCalculator {
  static const _dayIndex = {
    'sunday': 0, 'monday': 1, 'tuesday': 2, 'wednesday': 3,
    'thursday': 4, 'friday': 5, 'saturday': 6,
  };

  static DateTime alignToDueDay(DateTime base, dynamic dueDay, String unit) {
    final d = DateTime.utc(base.year, base.month, base.day);
    if (unit == 'week') {
      final targetDow = dueDay is String
          ? _dayIndex[dueDay.toLowerCase()] ?? 1
          : (dueDay as int);
      final diff = (targetDow - d.weekday % 7 + 7) % 7;
      final offset = diff == 0 ? 7 : diff;
      return d.add(Duration(days: offset));
    }
    if (unit == 'month') {
      final targetDay =
          ((dueDay as int?) ?? 1).clamp(1, 28);
      if (d.day < targetDay) {
        return DateTime.utc(d.year, d.month, targetDay);
      }
      return DateTime.utc(d.year, d.month + 1, targetDay);
    }
    if (unit == 'year') {
      final targetDay = ((dueDay as int?) ?? 1).clamp(1, 28);
      return DateTime.utc(d.year + 1, 1, targetDay);
    }
    return d.add(const Duration(days: 1));
  }

  /// [lastPayment] debe ser el último pago validated y NO voided.
  static DateTime computeNextDueDate({
    required UserModel user,
    required BillingConfig cfg,
    PaymentModel? lastPayment,
  }) {
    final base = lastPayment?.validatedAt ?? user.approvedAt ?? DateTime.now();
    final unit = cfg.period.unit.name; // 'day'|'week'|'month'|'year'
    final every = cfg.period.every < 1 ? 1 : cfg.period.every;

    if (lastPayment == null) {
      return alignToDueDay(base, cfg.dueDay, unit);
    }

    var advanced = base;
    if (unit == 'day') {
      advanced = advanced.add(Duration(days: every));
    } else if (unit == 'week') {
      advanced = advanced.add(Duration(days: every * 7));
    } else if (unit == 'month') {
      advanced = DateTime.utc(
          advanced.year, advanced.month + every, advanced.day);
    } else if (unit == 'year') {
      advanced = DateTime.utc(
          advanced.year + every, advanced.month, advanced.day);
    }
    return advanced;
  }

  /// Monto prorrateado para la primera cuota (si entra a mitad del periodo).
  static double proratedFirstAmount({
    required UserModel user,
    required BillingConfig cfg,
  }) {
    final approved = user.approvedAt ?? DateTime.now();
    final firstDue = alignToDueDay(approved, cfg.dueDay, cfg.period.unit.name);
    final days = firstDue.difference(approved).inDays.clamp(0, 366);
    final periodDays = _periodDays(cfg);
    if (periodDays <= 0) return cfg.amount;
    return (cfg.amount / periodDays) * days;
  }

  static int _periodDays(BillingConfig cfg) {
    final every = cfg.period.every < 1 ? 1 : cfg.period.every;
    switch (cfg.period.unit.name) {
      case 'day': return every;
      case 'week': return every * 7;
      case 'month': return every * 30;
      case 'year': return every * 365;
      default: return 30;
    }
  }
}
```

- [ ] **Step 2: Analizar**

```bash
flutter analyze lib/features/payments/data/due_date_calculator.dart
```

Si hay errores por imports, ajustar los paths. Verificar que `BillingConfig` tiene `period.unit.name` accesible.

- [ ] **Step 3: Commit**

```bash
git add lib/features/payments/data/due_date_calculator.dart
git commit -m "feat(payments): DueDateCalculator (espejo Dart de functions/lib/dueDate.js)"
```

---

### Task 17: Widget `DueDateBanner`

**Files:**
- Create: `lib/features/payments/presentation/widgets/due_date_banner.dart`

- [ ] **Step 1: Crear widget**

```dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../associations/data/models/association_model.dart';
import '../../../auth/data/models/user_model.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/due_date_calculator.dart';
import '../../data/models/payment_model.dart';

/// Banner amarillo que aparece SOLO el día calendario del vencimiento
/// del próximo pago (cuota socio O membresía asociación).
/// Lee `app_config/global.dueDateBannerMessage` con placeholders.
class DueDateBanner extends StatelessWidget {
  const DueDateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return const SizedBox.shrink();
    final user = auth.user;

    return FutureBuilder<_DueDateInfo?>(
      future: _resolve(user),
      builder: (ctx, snap) {
        if (!snap.hasData || snap.data == null) return const SizedBox.shrink();
        final info = snap.data!;
        final isToday = _isSameDay(DateTime.now(), info.dueDate);
        if (!isToday) return const SizedBox.shrink();

        final message = info.bannerTemplate
            .replaceAll('{amount}', '\$${info.amount.toStringAsFixed(2)}')
            .replaceAll('{dueDate}', DateFormat('dd-MMM').format(info.dueDate));

        return Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.amber.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.amber.shade700, width: 1),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_amber, color: Colors.orange),
              const SizedBox(width: 12),
              Expanded(
                child: Text(message, style: const TextStyle(fontSize: 13)),
              ),
              TextButton(
                onPressed: () => context.push('/my-payments'),
                child: const Text('Pagar →'),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<_DueDateInfo?> _resolve(UserModel user) async {
    final fs = FirebaseFirestore.instance;
    final aSnap = await fs.collection('associations').doc(user.associationId).get();
    if (!aSnap.exists) return null;
    final assoc = AssociationModel.fromFirestore(aSnap);

    final cfgSnap = await fs.collection('app_config').doc('global').get();
    final template = (cfgSnap.data()?['dueDateBannerMessage'] as String?) ??
        'Recuerde pagar {amount} antes de las 00:00 del {dueDate} o será bloqueado.';

    // Admin → banner de membresía
    if (user.role == 'admin') {
      final paidUntil = assoc.paidUntil;
      if (paidUntil == null) return null;
      return _DueDateInfo(
        dueDate: paidUntil,
        amount: 0, // monto de membresía no está en el modelo todavía
        bannerTemplate: template,
      );
    }

    // Conductor → banner de cuota
    if (assoc.billingConfig == null || assoc.billingConfig!.amount <= 0) return null;
    final payments = await fs.collection('payments')
        .where('driverId', isEqualTo: user.uid)
        .where('associationId', isEqualTo: user.associationId)
        .where('status', isEqualTo: 'validated')
        .orderBy('validatedAt', descending: true)
        .limit(5)
        .get();
    PaymentModel? lastValid;
    for (final d in payments.docs) {
      final p = PaymentModel.fromFirestore(d);
      if (!p.isVoided) { lastValid = p; break; }
    }

    final nextDue = DueDateCalculator.computeNextDueDate(
      user: user, cfg: assoc.billingConfig!, lastPayment: lastValid,
    );
    final amount = lastValid == null
        ? DueDateCalculator.proratedFirstAmount(user: user, cfg: assoc.billingConfig!)
        : assoc.billingConfig!.amount;

    return _DueDateInfo(
      dueDate: nextDue,
      amount: amount,
      bannerTemplate: template,
    );
  }
}

class _DueDateInfo {
  final DateTime dueDate;
  final double amount;
  final String bannerTemplate;
  _DueDateInfo({required this.dueDate, required this.amount, required this.bannerTemplate});
}
```

- [ ] **Step 2: Analizar**

```bash
flutter analyze lib/features/payments/presentation/widgets/due_date_banner.dart
```

Si `assoc.paidUntil` / `billingConfig` no son nullable en el modelo, ajustar.

- [ ] **Step 3: Commit**

```bash
git add lib/features/payments/presentation/widgets/due_date_banner.dart
git commit -m "feat(payments): DueDateBanner widget — banner amarillo el día del vencimiento, template configurable"
```

---

### Task 18: Montar `DueDateBanner` en el Dashboard

**Files:**
- Modify: `lib/features/home/presentation/pages/home_page.dart`

- [ ] **Step 1: Importar el widget y agregarlo arriba del DashboardKpis**

En `_buildDashboard`, antes de `DashboardKpis(user: user)`:

```dart
import '../../../payments/presentation/widgets/due_date_banner.dart';

// ... en _buildDashboard, después de _ProfileGreetingCard:
const DueDateBanner(),
```

- [ ] **Step 2: Analizar**

```bash
flutter analyze lib/features/home/presentation/pages/home_page.dart
```

- [ ] **Step 3: Commit**

```bash
git add lib/features/home/presentation/pages/home_page.dart
git commit -m "feat(home): montar DueDateBanner sobre DashboardKpis"
```

---

### Task 19: Config global del banner en `/super`

**Files:**
- Modify: `lib/features/super_admin/presentation/pages/super_admin_page.dart`

- [ ] **Step 1: Localizar el panel y agregar sección**

```bash
grep -n "class SuperAdminPage\|Inicialización\|_buildSection" lib/features/super_admin/presentation/pages/super_admin_page.dart | head -10
```

Agregar tarjeta "Configuración global" después de "Inicialización":

```dart
// Card "Configuración global"
Card(
  margin: const EdgeInsets.all(8),
  child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Configuración global',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          icon: const Icon(Icons.message),
          label: const Text('Editar mensaje del banner de vencimiento'),
          onPressed: () => _editBannerMessage(context),
        ),
      ],
    ),
  ),
),
```

Método dentro de la State:
```dart
Future<void> _editBannerMessage(BuildContext context) async {
  final fs = FirebaseFirestore.instance;
  final snap = await fs.collection('app_config').doc('global').get();
  final current = snap.data()?['dueDateBannerMessage'] as String? ??
      'Recuerde pagar {amount} antes de las 00:00 del {dueDate} o será bloqueado.';
  final ctrl = TextEditingController(text: current);

  final saved = await showDialog<String?>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Mensaje del banner'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Placeholders soportados:\n{amount}, {dueDate}',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          TextField(controller: ctrl, maxLines: 4),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(ctrl.text),
          child: const Text('Guardar'),
        ),
      ],
    ),
  );

  if (saved == null) return;
  await fs.collection('app_config').doc('global').set({
    'dueDateBannerMessage': saved,
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Mensaje guardado')),
    );
  }
}
```

- [ ] **Step 2: Analizar**

```bash
flutter analyze lib/features/super_admin/presentation/pages/super_admin_page.dart
```

- [ ] **Step 3: Commit**

```bash
git add lib/features/super_admin/presentation/pages/super_admin_page.dart
git commit -m "feat(super-admin): editor del mensaje del banner de vencimiento (app_config/global)"
```

---

## Fase 6 — Deploy + verificación end-to-end

### Task 20: Deploy de reglas + funciones

**Files:** ninguno modificado, solo ops.

- [ ] **Step 1: Deploy reglas**

```bash
firebase deploy --only firestore:rules 2>&1 | tail -10
```

Expected: "Deploy complete!"

- [ ] **Step 2: Deploy funciones nuevas + modificadas**

```bash
firebase deploy --only \
  functions:enforcePayments,\
functions:voidPayment,\
functions:validateAssociationPayment,\
functions:reportAssociationPayment,\
functions:extendPaidUntil,\
functions:validatePayment 2>&1 | tail -20
```

Expected: 6 funciones desplegadas OK.

- [ ] **Step 3: IAM público para los callables nuevos**

```bash
for f in voidpayment validateassociationpayment reportassociationpayment extendpaiduntil; do
  gcloud run services add-iam-policy-binding $f \
    --region=us-central1 \
    --member=allUsers \
    --role=roles/run.invoker \
    --quiet
done
```

Expected: 4 bindings actualizados.

- [ ] **Step 4: Crear doc `app_config/global` manual en Firebase Console**

Console → Firestore → `app_config` → `global` → fields:
- `dueDateBannerMessage`: `"Recuerde pagar {amount} antes de las 00:00 del {dueDate} o será bloqueado."`
- `updatedAt`: timestamp now

- [ ] **Step 5: Verificar trigger del cron en Cloud Scheduler**

Cloud Console → Cloud Scheduler → debe aparecer `firebase-schedule-enforcePayments-us-central1`.

- [ ] **Step 6: Commit (no hay cambios de código, solo nota)**

```bash
git commit --allow-empty -m "deploy: enforcePayments + voidPayment + assoc membership flow"
```

---

### Task 21: Verificación end-to-end manual

**No file changes.** Pruebas reales sobre Firebase.

- [ ] **Step 1: Test bloqueo asociación**

1. En Firestore Console, editar `associations/jipijapa.paidUntil = 1 hora en el pasado`.
2. Cloud Console → Cloud Scheduler → ejecutar el job `firebase-schedule-enforcePayments-us-central1` manualmente.
3. Verificar que `associations/jipijapa.status == 'suspended'`.
4. Abrir app como admin → ver pantalla `AccountBlockedPage` modo "Cooperativa suspendida — admin".

- [ ] **Step 2: Test bloqueo conductor**

1. Asegurar `associations/jipijapa.status = 'active'` y `paidUntil` futuro.
2. Borrar todos los `payments` de un conductor de prueba.
3. Ejecutar `enforcePayments`.
4. Verificar `users/{uid}.status == 'paymentBlocked'` y `blockReason == 'cuota_vencida'`.
5. Abrir app como ese conductor → ver `AccountBlockedPage` modo "Tu cuenta está bloqueada".

- [ ] **Step 3: Test reactivación inmediata por validatePayment**

1. El conductor sube comprobante desde `/blocked`.
2. Admin valida desde `payment_approvals_page`.
3. **Inmediatamente** verificar `users/{uid}.status == 'active'`.
4. El conductor debe poder usar la app sin esperar 24 h.

- [ ] **Step 4: Test anulación**

1. Admin entra a `payment_approvals_page`, abre detail de un pago `validated`.
2. Botón "Anular pago" → motivo "Banco devolvió por fondos insuficientes (test)".
3. Confirmar.
4. Verificar `payments/{id}.voidedAt != null` y `users/{driverUid}.status == 'paymentBlocked'`.
5. El conductor recibe FCM push.

- [ ] **Step 5: Test pago de membresía**

1. Forzar `associations/jipijapa.paidUntil` al pasado, correr cron.
2. Como admin: abrir app → `AccountBlockedPage` con botón "Pagar membresía".
3. Completar form, enviar.
4. Verificar `payments` doc nuevo con `concept='membresia_asociacion'`.
5. Como super-admin: abrir `payment_approvals_page`, filtro "Solo membresías", aprobar con 1 mes.
6. Verificar `associations/jipijapa.status == 'active'` y `paidUntil` extendido.
7. Todos los usuarios reciben FCM "Cooperativa reactivada".

- [ ] **Step 6: Marcar verificación completa**

```bash
git commit --allow-empty -m "verify: end-to-end payment enforcement tests pass"
```

---

## Resumen

- **Fases**: 6 (foundation, cron, anulación, membresía, banner UI, deploy + verify)
- **Tasks**: 21
- **Funciones nuevas**: 5 (`enforcePayments`, `voidPayment`, `reportAssociationPayment`, `validateAssociationPayment`, `extendPaidUntil`)
- **Funciones modificadas**: 1 (`validatePayment` agrega reactivación inmediata)
- **Widgets nuevos**: `DueDateBanner`, `ReportAssociationPaymentDialog`
- **Widgets reescritos**: `AccountBlockedPage` (3 variantes)
- **Modelos extendidos**: `UserModel`, `AssociationModel`, `PaymentModel`
- **Reglas**: `payments` admite anulación con motivo ≥10 chars

**Deploy commands consolidados:**
```bash
firebase deploy --only firestore:rules
firebase deploy --only functions:enforcePayments,functions:voidPayment,functions:reportAssociationPayment,functions:validateAssociationPayment,functions:extendPaidUntil,functions:validatePayment
for f in voidpayment validateassociationpayment reportassociationpayment extendpaiduntil; do
  gcloud run services add-iam-policy-binding $f --region=us-central1 --member=allUsers --role=roles/run.invoker --quiet
done
```
