const {
  isFinalizedStatus,
  isTransitionToFinalized,
  isFirstRating,
  isValidRating,
  computeNewAverage,
  fareForHour,
  localDateHourEC,
} = require("../lib/tripStats");

describe("isFinalizedStatus", () => {
  test("acepta 'finalizado' y 'completado'", () => {
    expect(isFinalizedStatus("finalizado")).toBe(true);
    expect(isFinalizedStatus("completado")).toBe(true);
  });
  test("rechaza otros estados y no-strings", () => {
    expect(isFinalizedStatus("asignado")).toBe(false);
    expect(isFinalizedStatus("cancelado")).toBe(false);
    expect(isFinalizedStatus(undefined)).toBe(false);
    expect(isFinalizedStatus(null)).toBe(false);
    expect(isFinalizedStatus(5)).toBe(false);
  });
});

describe("isTransitionToFinalized (idempotencia)", () => {
  test("asignado → finalizado cuenta", () => {
    expect(isTransitionToFinalized("asignado", "finalizado")).toBe(true);
  });
  test("undefined → finalizado cuenta (primera escritura ya finalizada)", () => {
    expect(isTransitionToFinalized(undefined, "finalizado")).toBe(true);
  });
  test("finalizado → finalizado NO cuenta (re-escritura)", () => {
    expect(isTransitionToFinalized("finalizado", "finalizado")).toBe(false);
  });
  test("completado → finalizado NO cuenta (ya estaba finalizado)", () => {
    expect(isTransitionToFinalized("completado", "finalizado")).toBe(false);
  });
  test("finalizado → cancelado NO cuenta", () => {
    expect(isTransitionToFinalized("finalizado", "cancelado")).toBe(false);
  });
  test("asignado → completado cuenta", () => {
    expect(isTransitionToFinalized("asignado", "completado")).toBe(true);
  });
});

describe("isValidRating", () => {
  test("acepta enteros 1..5", () => {
    [1, 2, 3, 4, 5].forEach((r) => expect(isValidRating(r)).toBe(true));
  });
  test("rechaza fuera de rango, decimales, no-numbers", () => {
    expect(isValidRating(0)).toBe(false);
    expect(isValidRating(6)).toBe(false);
    expect(isValidRating(3.5)).toBe(false);
    expect(isValidRating("4")).toBe(false);
    expect(isValidRating(null)).toBe(false);
    expect(isValidRating(undefined)).toBe(false);
  });
});

describe("isFirstRating (idempotencia)", () => {
  test("ausente → 4 cuenta", () => {
    expect(isFirstRating(undefined, 4)).toBe(true);
    expect(isFirstRating(null, 5)).toBe(true);
  });
  test("3 → 5 NO cuenta (edición de calificación)", () => {
    expect(isFirstRating(3, 5)).toBe(false);
  });
  test("ausente → rating inválido NO cuenta", () => {
    expect(isFirstRating(undefined, 0)).toBe(false);
    expect(isFirstRating(undefined, 6)).toBe(false);
    expect(isFirstRating(undefined, undefined)).toBe(false);
  });
});

describe("computeNewAverage", () => {
  test("conductor nuevo (sin acumuladores) → primera calificación", () => {
    const r = computeNewAverage({}, 5);
    expect(r).toEqual({ ratingSum: 5, ratingCount: 1, rating: 5 });
  });
  test("acumula sobre estado existente", () => {
    // 4 calificaciones sumando 16 (promedio 4), llega un 5
    const r = computeNewAverage({ ratingSum: 16, ratingCount: 4 }, 5);
    expect(r.ratingSum).toBe(21);
    expect(r.ratingCount).toBe(5);
    expect(r.rating).toBeCloseTo(4.2, 5);
  });
  test("trata acumuladores ausentes/no-numéricos como 0", () => {
    const r = computeNewAverage({ ratingSum: undefined, ratingCount: null }, 3);
    expect(r).toEqual({ ratingSum: 3, ratingCount: 1, rating: 3 });
  });
});

describe("fareForHour (tarifa mínima Quito)", () => {
  test("franja diurna 06..18 → 1.45", () => {
    [6, 7, 12, 17, 18].forEach((h) => expect(fareForHour(h)).toBe(1.45));
  });
  test("franja nocturna 19..23 y 0..5 → 1.75", () => {
    [19, 20, 23, 0, 3, 5].forEach((h) => expect(fareForHour(h)).toBe(1.75));
  });
  test("bordes exactos", () => {
    expect(fareForHour(6)).toBe(1.45); // inicio diurna
    expect(fareForHour(18)).toBe(1.45); // fin diurna
    expect(fareForHour(19)).toBe(1.75); // inicio nocturna
    expect(fareForHour(5)).toBe(1.75); // fin nocturna
  });
});

describe("localDateHourEC (zona America/Guayaquil UTC-5)", () => {
  test("medio día UTC → mañana en Ecuador, mismo día", () => {
    // 2026-05-29T12:00:00Z = 07:00 hora EC
    const ms = Date.parse("2026-05-29T12:00:00.000Z");
    expect(localDateHourEC(ms)).toEqual({ date: "2026-05-29", hour: 7, dayOfWeek: 5 });
  });
  test("madrugada UTC retrocede al día anterior en Ecuador", () => {
    // 2026-05-29T03:00:00Z = 2026-05-28 22:00 hora EC (cambio de día)
    const ms = Date.parse("2026-05-29T03:00:00.000Z");
    expect(localDateHourEC(ms)).toEqual({ date: "2026-05-28", hour: 22, dayOfWeek: 4 });
  });
  test("05:00Z marca el inicio del día local EC (00:00)", () => {
    const ms = Date.parse("2026-05-29T05:00:00.000Z");
    expect(localDateHourEC(ms)).toEqual({ date: "2026-05-29", hour: 0, dayOfWeek: 5 });
  });
});
