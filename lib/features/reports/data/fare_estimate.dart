import 'package:cloud_firestore/cloud_firestore.dart';

/// Helpers compartidos para el estimado monetario de carreras, basados en la
/// tarifa mínima de Quito (America/Guayaquil, UTC-5).
///
/// La tarifa depende de la HORA LOCAL (UTC-5) del `createdAt`:
/// - 06:00–18:59 (hora 6..18) → $1.45
/// - resto (19..23 y 0..5)    → $1.75
///
/// Estos cálculos deben coincidir con los del agregado `tripStatsDaily` que
/// genera el backend, por eso el bucket por hora usa SIEMPRE la hora en UTC-5
/// (se resta 5h al UTC del Timestamp).
double fareForHour(int h) => (h >= 6 && h <= 18) ? 1.45 : 1.75;

/// Devuelve la hora local (0-23) en UTC-5 a partir de un [Timestamp].
///
/// `toDate()` daría la hora del dispositivo; para que el reporte del conductor
/// y el agregado de la base sean comparables convertimos a UTC y restamos 5h.
int hourInEc(Timestamp ts) {
  final utc = ts.toDate().toUtc();
  // Restar 5h (UTC-5) y normalizar a 0-23.
  return (utc.hour - 5 + 24) % 24;
}
