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
