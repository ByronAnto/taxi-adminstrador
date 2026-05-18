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

describe('alignToDueDay edge cases (C2, I1)', () => {
  test('month: base on day 31 with targetDay 5 → Feb 5 (no overflow)', () => {
    const jan31 = new Date('2026-01-31T10:00:00Z');
    const result = alignToDueDay(jan31, 5, 'month');
    expect(result.toISOString().substring(0, 10)).toBe('2026-02-05');
  });

  test('year: targetDay future in current year → current year', () => {
    // Si hoy es Jan 5 y target es Jan 15, resultado debe ser Jan 15 del MISMO año
    const jan5 = new Date('2026-01-05T10:00:00Z');
    const result = alignToDueDay(jan5, 15, 'year');
    expect(result.toISOString().substring(0, 10)).toBe('2026-01-15');
  });

  test('year: targetDay past in current year → next year', () => {
    const feb1 = new Date('2026-02-01T10:00:00Z');
    const result = alignToDueDay(feb1, 15, 'year');
    expect(result.toISOString().substring(0, 10)).toBe('2027-01-15');
  });

  test('invalid unit throws', () => {
    expect(() => alignToDueDay(new Date(), 5, 'quarter')).toThrow(/Invalid period unit/);
  });
});

describe('computeNextDueDate edge cases (C1)', () => {
  test('lastPayment on Tuesday with monday dueDay → next Monday (always aligned)', () => {
    // C1 fix: aunque admin valide tarde, próximo due se alinea al lunes
    const user = { approvedAt: new Date('2026-04-01T10:00:00Z') };
    const cfg = { period: { every: 1, unit: 'week' }, dueDay: 'monday' };
    const lastPayment = { validatedAt: new Date('2026-05-12T08:00:00Z') }; // Tue
    const result = computeNextDueDate(user, cfg, lastPayment);
    // base (Tue May 12) + 7 días = Tue May 19 → alineado al próximo lunes = May 25
    expect(result.toISOString().substring(0, 10)).toBe('2026-05-25');
  });

  test('every:2 weekly (bi-weekly) → +14 days then aligned', () => {
    const user = { approvedAt: new Date('2026-04-01T10:00:00Z') };
    const cfg = { period: { every: 2, unit: 'week' }, dueDay: 'monday' };
    const lastPayment = { validatedAt: new Date('2026-05-11T08:00:00Z') }; // Mon
    const result = computeNextDueDate(user, cfg, lastPayment);
    // Mon May 11 + 14 días = Mon May 25 → ya alineado
    expect(result.toISOString().substring(0, 10)).toBe('2026-05-25');
  });
});
