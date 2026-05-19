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

module.exports = { computeNextDueDate, alignToDueDay };
