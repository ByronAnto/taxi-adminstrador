'use strict';

const DAY_INDEX = {
  sunday: 0, monday: 1, tuesday: 2, wednesday: 3,
  thursday: 4, friday: 5, saturday: 6,
};

const MAX_DUE_DAY = 28; // febrero es el mes más corto

const VALID_UNITS = new Set(['day', 'week', 'month', 'year']);

/**
 * Alinea una fecha al dueDay según la unidad del período.
 *
 * @param {Date} base          - Fecha de partida.
 * @param {string|number} dueDay
 * @param {string} unit        - 'day'|'week'|'month'|'year'
 * @param {boolean} [inclusive=false]
 *   - false (default): para 'week', si base ya cae en el día correcto, salta a la
 *     próxima ocurrencia (útil para primera cuota: approvedAt = hoy, no vence hoy).
 *   - true: si base ya cae en el día correcto, se acepta (útil para cuota recurrente
 *     donde base+período puede aterrizar exactamente en el dueDay correcto).
 * @throws {Error} si unit no pertenece a VALID_UNITS
 */
function alignToDueDay(base, dueDay, unit, inclusive) {
  if (!VALID_UNITS.has(unit)) {
    throw new Error(`Invalid period unit: ${unit}`);
  }
  const d = new Date(base);
  if (unit === 'week') {
    const targetDow = typeof dueDay === 'string' ? DAY_INDEX[dueDay.toLowerCase()] : Number(dueDay);
    if (Number.isNaN(targetDow)) return d;
    const diff = (targetDow - d.getUTCDay() + 7) % 7;
    // inclusive=true: si diff===0 el día ya es correcto, no saltar semana.
    // inclusive=false (default): si diff===0 saltar 7 días a la próxima ocurrencia.
    const offset = (diff === 0 && !inclusive) ? 7 : diff;
    if (offset === 0) {
      d.setUTCHours(0, 0, 0, 0);
      return d;
    }
    d.setUTCDate(d.getUTCDate() + offset);
    d.setUTCHours(0, 0, 0, 0);
    return d;
  }
  if (unit === 'month') {
    const targetDay = Math.min(Math.max(1, Number(dueDay) || 1), MAX_DUE_DAY);
    const currentDay = d.getUTCDate();
    if (currentDay < targetDay) {
      d.setUTCDate(targetDay);
    } else {
      d.setUTCDate(1); // pin a día 1 para evitar overflow al cambiar de mes
      d.setUTCMonth(d.getUTCMonth() + 1);
      d.setUTCDate(targetDay);
    }
    d.setUTCHours(0, 0, 0, 0);
    return d;
  }
  if (unit === 'year') {
    const targetDay = Math.min(Math.max(1, Number(dueDay) || 1), MAX_DUE_DAY);
    // Construir candidato del año actual: enero día N
    const candidate = new Date(Date.UTC(d.getUTCFullYear(), 0, targetDay));
    if (candidate.getTime() > d.getTime()) {
      return candidate;
    }
    // Si el candidato del año actual ya pasó, ir al próximo enero
    return new Date(Date.UTC(d.getUTCFullYear() + 1, 0, targetDay));
  }
  // day: retornar d sin modificar (el caller ya sumó el período)
  d.setUTCHours(0, 0, 0, 0);
  return d;
}

/**
 * Calcula la próxima fecha de vencimiento para un usuario según su billingConfig.
 * @param {{approvedAt: Date|Timestamp}} user
 * @param {{period: {every: number, unit: string}, dueDay: any}} cfg
 * @param {{validatedAt: Date|Timestamp}|null} lastPayment - último pago no voided
 * @returns {Date}
 * @throws {Error} si cfg.period.unit no pertenece a VALID_UNITS
 */
function computeNextDueDate(user, cfg, lastPayment) {
  const unit = cfg.period.unit || 'month';
  if (!VALID_UNITS.has(unit)) {
    throw new Error(`Invalid period unit: ${unit}`);
  }

  const baseRaw = lastPayment
    ? lastPayment.validatedAt
    : user.approvedAt;
  const base = baseRaw && baseRaw.toDate ? baseRaw.toDate() : new Date(baseRaw);
  const every = Math.max(1, Number(cfg.period.every) || 1);

  if (!lastPayment) {
    // Primera cuota: alinear desde approvedAt al dueDay (INCLUSIVO).
    // Si el conductor se inscribe exactamente en dueDay (ej. Lunes con
    // cuota semanal lunes), debe pagar HOY MISMO, no la próxima semana.
    // Sin inclusive=true, los conductores aprobados en dueDay tendrían
    // 7 días de "gracia gratis" antes de pagar — eso NO es lo definido
    // en el spec (que pide pago prorrateado/inmediato según día de ingreso).
    return alignToDueDay(base, cfg.dueDay, unit, true);
  }

  // Cuota recurrente: avanzar el período y alinear al dueDay correcto.
  // Si el resultado de base+período aterriza exactamente en dueDay, es válido (inclusive=true).
  let advanced = new Date(base);
  if (unit === 'day') {
    advanced.setUTCDate(advanced.getUTCDate() + every);
  } else if (unit === 'week') {
    advanced.setUTCDate(advanced.getUTCDate() + every * 7);
  } else if (unit === 'month') {
    advanced.setUTCDate(1); // pin a día 1 para evitar overflow (C2)
    advanced.setUTCMonth(advanced.getUTCMonth() + every);
  } else if (unit === 'year') {
    advanced.setUTCDate(1);
    advanced.setUTCMonth(0);
    advanced.setUTCFullYear(advanced.getUTCFullYear() + every);
  }
  return alignToDueDay(advanced, cfg.dueDay, unit, true);
}

/**
 * Materializa el próximo vencimiento (`nextDueAt`) de la cuota interna de un
 * conductor, listo para escribir en `users/{uid}`. Puro, sin Firestore.
 *
 * Reglas (decisiones del dueño: 0 días de gracia, cálculo preciso):
 *  - Si no hay `approvedAt` → null (nunca se bloquea sin fecha de aprobación).
 *  - Si no hay billingConfig con `amount > 0` → null (sin cobro, no se materializa).
 *  - En otro caso → Date exacto via `computeNextDueDate` (alineado a dueDay).
 *    `lastPayment` null = primera cuota desde `approvedAt`.
 *
 * @param {Object} params
 * @param {Date|Timestamp|null} [params.approvedAt]
 * @param {{validatedAt: Date|Timestamp}|null} [params.lastPayment]
 * @param {{amount?: number, period: {every: number, unit: string}, dueDay: any}|null} [params.billingConfig]
 * @returns {Date|null}
 */
function computeNextDueAtForUser({ approvedAt, lastPayment, billingConfig } = {}) {
  if (!approvedAt) return null;
  if (!billingConfig || !(Number(billingConfig.amount) > 0)) return null;
  return computeNextDueDate({ approvedAt }, billingConfig, lastPayment || null);
}

/**
 * Decisión PURA de morosidad de un conductor (sin Firestore).
 *
 * Modela el núcleo del cron unificado `enforceMembershipDues`: dado el estado
 * actual de un user, su `nextDueAt`, la hora `now`, si tiene permiso activo y
 * su rol/blockReason, decide qué acción tomaría el cron.
 *
 * Decisiones del dueño aplicadas:
 *  - Gracia conductor: 0 días → se bloquea exactamente cuando `nextDueAt <= now`.
 *  - Solo roles conductor/admin son sujetos de cuota interna.
 *  - Un permiso activo evita el bloqueo (no la reactivación, que no lo necesita).
 *
 * Reglas:
 *  WOULD_BLOCK: status==="active", rol elegible, nextDueAt!=null, nextDueAt<=now,
 *               y NO hay permiso activo.
 *  WOULD_REACTIVATE: status==="paymentBlocked", blockReason==="cuota_vencida",
 *               nextDueAt!=null, nextDueAt>now.
 *  "none": cualquier otro caso (incl. status deleted/disabledByAdmin/etc.,
 *               bloqueado por otra razón, sin nextDueAt, con permiso activo,
 *               rol no elegible).
 *
 * @param {Object} params
 * @param {string} params.status            - status actual del user.
 * @param {Date|Timestamp|null} params.nextDueAt
 * @param {Date|Timestamp|number} params.now
 * @param {boolean} [params.hasPermit=false]
 * @param {string} [params.role]
 * @param {string} [params.blockReason]
 * @returns {"WOULD_BLOCK"|"WOULD_REACTIVATE"|"none"}
 */
const DUES_ELIGIBLE_ROLES = new Set(['conductor', 'admin']);

function _toMillis(v) {
  if (v == null) return null;
  if (typeof v === 'number') return v;
  if (v.toMillis) return v.toMillis();
  if (v.toDate) return v.toDate().getTime();
  if (v instanceof Date) return v.getTime();
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d.getTime();
}

function decideDuesAction({ status, nextDueAt, now, hasPermit = false, role, blockReason } = {}) {
  const nowMs = _toMillis(now);
  const dueMs = _toMillis(nextDueAt);

  // Reactivación: bloqueado por cuota vencida pero ya con vencimiento futuro.
  if (status === 'paymentBlocked' && blockReason === 'cuota_vencida') {
    if (dueMs != null && nowMs != null && dueMs > nowMs) {
      return 'WOULD_REACTIVATE';
    }
    return 'none';
  }

  // Bloqueo: activo, rol elegible, vencido y sin permiso activo.
  if (status === 'active') {
    if (!DUES_ELIGIBLE_ROLES.has(role)) return 'none';
    if (dueMs == null || nowMs == null) return 'none';
    if (dueMs > nowMs) return 'none';
    if (hasPermit) return 'none';
    return 'WOULD_BLOCK';
  }

  return 'none';
}

module.exports = {
  computeNextDueDate,
  alignToDueDay,
  computeNextDueAtForUser,
  decideDuesAction,
};
