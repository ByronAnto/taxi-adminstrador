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
