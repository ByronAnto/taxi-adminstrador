// ───────────────────────────────────────────────────────────────────
//  tripStats — lógica pura (sin Firestore) para los triggers de
//  estadísticas de viajes y calificaciones. Se aísla aquí para poder
//  testearla con Jest sin necesidad del emulador.
// ───────────────────────────────────────────────────────────────────

// Estados que consideramos "carrera finalizada" para sumar totales.
// 'finalizado' es el canónico del contrato; 'completado' se acepta como
// sinónimo por compatibilidad con datos/clientes que lo usen.
const FINALIZED_STATUSES = ["finalizado", "completado"];

/**
 * ¿Es este status uno de los que cuentan como carrera finalizada?
 * @param {*} status
 * @returns {boolean}
 */
function isFinalizedStatus(status) {
  return typeof status === "string" && FINALIZED_STATUSES.includes(status);
}

/**
 * Detecta la transición a finalizado: antes NO estaba finalizado y
 * ahora SÍ. Esto garantiza idempotencia (solo cuenta en el flanco de
 * subida, nunca en re-escrituras que ya estaban en 'finalizado').
 * @param {string|undefined} beforeStatus
 * @param {string|undefined} afterStatus
 * @returns {boolean}
 */
function isTransitionToFinalized(beforeStatus, afterStatus) {
  return !isFinalizedStatus(beforeStatus) && isFinalizedStatus(afterStatus);
}

/**
 * ¿Apareció una calificación por primera vez? before sin rating válido
 * y after con un entero 1..5. Solo la primera aparición cuenta (evita
 * recontar si el cliente edita la calificación más tarde).
 * @param {*} beforeRating
 * @param {*} afterRating
 * @returns {boolean}
 */
function isFirstRating(beforeRating, afterRating) {
  // before debe estar ausente/nulo (o no ser una calificación válida).
  // after debe ser un entero 1..5.
  const beforeAbsent = beforeRating == null || !isValidRating(beforeRating);
  return beforeAbsent && isValidRating(afterRating);
}

/**
 * Valida que un rating sea un entero entre 1 y 5 inclusive.
 * @param {*} rating
 * @returns {boolean}
 */
function isValidRating(rating) {
  return (
    typeof rating === "number" &&
    Number.isInteger(rating) &&
    rating >= 1 &&
    rating <= 5
  );
}

/**
 * Calcula el nuevo promedio del conductor al agregar una calificación.
 * Inicializa en 0 si los acumuladores no existen (conductor nuevo).
 * @param {object} current  { ratingSum?, ratingCount? } estado actual del driver
 * @param {number} newRating calificación entera 1..5
 * @returns {{ ratingSum: number, ratingCount: number, rating: number }}
 */
function computeNewAverage(current, newRating) {
  const prevSum = Number(current?.ratingSum) || 0;
  const prevCount = Number(current?.ratingCount) || 0;
  const ratingSum = prevSum + newRating;
  const ratingCount = prevCount + 1;
  const rating = ratingCount > 0 ? ratingSum / ratingCount : 0;
  return { ratingSum, ratingCount, rating };
}

/**
 * Tarifa mínima estimada de Quito según la HORA del día (0..23, en
 * hora local America/Guayaquil = UTC-5). Diurna 06:00–18:59 → 1.45;
 * nocturna 19:00–05:59 → 1.75.
 *
 * Bordes (inclusivos): hora 6 = diurna (1.45), hora 18 = diurna (1.45),
 * hora 19 = nocturna (1.75), hora 5 = nocturna (1.75).
 *
 * @param {number} h hora del día 0..23 (UTC-5)
 * @returns {number} tarifa estimada en USD
 */
function fareForHour(h) {
  return h >= 6 && h <= 18 ? 1.45 : 1.75;
}

/**
 * Deriva la fecha y la hora local de Ecuador (America/Guayaquil, UTC-5
 * fijo, sin horario de verano) a partir de un epoch en milisegundos UTC.
 *
 * Cálculo: Ecuador es UTC-5 todo el año, así que restamos 5 horas al
 * epoch UTC y leemos los componentes en UTC con los getters `getUTC*`
 * sobre una Date "desplazada". De ese modo evitamos depender de la zona
 * horaria del servidor (las Cloud Functions corren en UTC) y de librerías
 * externas. El desplazamiento de -5h maneja correctamente el cambio de
 * día: p.ej. 2026-05-29T03:00:00Z → 2026-05-28 22:00 hora EC (día anterior).
 *
 * @param {number} epochMs milisegundos desde epoch en UTC
 * @returns {{ date: string, hour: number }}
 *   date "YYYY-MM-DD" y hour 0..23, ambos en hora local de Ecuador.
 */
function localDateHourEC(epochMs) {
  const UTC_OFFSET_HOURS = -5; // America/Guayaquil, fijo todo el año
  const shifted = new Date(epochMs + UTC_OFFSET_HOURS * 60 * 60 * 1000);
  const yyyy = shifted.getUTCFullYear();
  const mm = String(shifted.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(shifted.getUTCDate()).padStart(2, "0");
  return {
    date: `${yyyy}-${mm}-${dd}`,
    hour: shifted.getUTCHours(),
  };
}

module.exports = {
  FINALIZED_STATUSES,
  isFinalizedStatus,
  isTransitionToFinalized,
  isFirstRating,
  isValidRating,
  computeNewAverage,
  fareForHour,
  localDateHourEC,
};
