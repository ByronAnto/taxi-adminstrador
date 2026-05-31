const { decideDuesAction } = require('../lib/dueDate');

// Helper: Timestamp-like wrapper para verificar que decideDuesAction acepta
// objetos con toMillis()/toDate() además de Date/number.
function tsLike(date) {
  return {
    toMillis: () => date.getTime(),
    toDate: () => date,
  };
}

describe('decideDuesAction', () => {
  const now = new Date('2026-05-31T05:00:00Z');
  const past = new Date('2026-05-30T05:00:00Z'); // nextDueAt <= now → vencido
  const future = new Date('2026-06-15T05:00:00Z'); // nextDueAt > now → al día

  test('activo vencido sin permiso (conductor) → WOULD_BLOCK', () => {
    expect(
      decideDuesAction({
        status: 'active',
        role: 'conductor',
        nextDueAt: past,
        now,
        hasPermit: false,
      }),
    ).toBe('WOULD_BLOCK');
  });

  test('activo vencido sin permiso (admin) → WOULD_BLOCK', () => {
    expect(
      decideDuesAction({
        status: 'active',
        role: 'admin',
        nextDueAt: past,
        now,
        hasPermit: false,
      }),
    ).toBe('WOULD_BLOCK');
  });

  test('activo vencido CON permiso → none', () => {
    expect(
      decideDuesAction({
        status: 'active',
        role: 'conductor',
        nextDueAt: past,
        now,
        hasPermit: true,
      }),
    ).toBe('none');
  });

  test('activo NO vencido (nextDueAt futuro) → none', () => {
    expect(
      decideDuesAction({
        status: 'active',
        role: 'conductor',
        nextDueAt: future,
        now,
        hasPermit: false,
      }),
    ).toBe('none');
  });

  test('gracia 0 días: nextDueAt == now exacto → WOULD_BLOCK', () => {
    expect(
      decideDuesAction({
        status: 'active',
        role: 'conductor',
        nextDueAt: now,
        now,
        hasPermit: false,
      }),
    ).toBe('WOULD_BLOCK');
  });

  test('activo vencido pero rol no elegible (operadora) → none', () => {
    expect(
      decideDuesAction({
        status: 'active',
        role: 'operadora',
        nextDueAt: past,
        now,
        hasPermit: false,
      }),
    ).toBe('none');
  });

  test('activo sin nextDueAt (null) → none', () => {
    expect(
      decideDuesAction({
        status: 'active',
        role: 'conductor',
        nextDueAt: null,
        now,
        hasPermit: false,
      }),
    ).toBe('none');
  });

  test('bloqueado por cuota_vencida con nextDueAt futuro → WOULD_REACTIVATE', () => {
    expect(
      decideDuesAction({
        status: 'paymentBlocked',
        role: 'conductor',
        blockReason: 'cuota_vencida',
        nextDueAt: future,
        now,
      }),
    ).toBe('WOULD_REACTIVATE');
  });

  test('bloqueado por cuota_vencida pero nextDueAt aún vencido → none', () => {
    expect(
      decideDuesAction({
        status: 'paymentBlocked',
        role: 'conductor',
        blockReason: 'cuota_vencida',
        nextDueAt: past,
        now,
      }),
    ).toBe('none');
  });

  test('bloqueado por OTRA razón (pago_anulado) con nextDueAt futuro → none', () => {
    expect(
      decideDuesAction({
        status: 'paymentBlocked',
        role: 'conductor',
        blockReason: 'pago_anulado',
        nextDueAt: future,
        now,
      }),
    ).toBe('none');
  });

  test('disabledByAdmin vencido → none (nunca bloquear/reactivar)', () => {
    expect(
      decideDuesAction({
        status: 'disabledByAdmin',
        role: 'conductor',
        nextDueAt: past,
        now,
        hasPermit: false,
      }),
    ).toBe('none');
  });

  test('deleted vencido → none', () => {
    expect(
      decideDuesAction({
        status: 'deleted',
        role: 'conductor',
        nextDueAt: past,
        now,
        hasPermit: false,
      }),
    ).toBe('none');
  });

  test('paymentPending vencido → none (no es active ni paymentBlocked)', () => {
    expect(
      decideDuesAction({
        status: 'paymentPending',
        role: 'conductor',
        nextDueAt: past,
        now,
        hasPermit: false,
      }),
    ).toBe('none');
  });

  test('acepta Timestamp-like (toMillis/toDate) además de Date', () => {
    expect(
      decideDuesAction({
        status: 'active',
        role: 'conductor',
        nextDueAt: tsLike(past),
        now: tsLike(now),
        hasPermit: false,
      }),
    ).toBe('WOULD_BLOCK');
  });

  test('acepta millis numéricos', () => {
    expect(
      decideDuesAction({
        status: 'paymentBlocked',
        role: 'conductor',
        blockReason: 'cuota_vencida',
        nextDueAt: future.getTime(),
        now: now.getTime(),
      }),
    ).toBe('WOULD_REACTIVATE');
  });
});
