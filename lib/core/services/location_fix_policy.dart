/// Decisión de qué hacer con un intento de fix de ubicación.
///
/// Separa dos cosas que ANTES estaban acopladas en `_onFix`:
///  - la **calidad del fix** (mover el marcador solo con fixes buenos), y
///  - la **presencia** (que el conductor siga "vivo" para el cron
///    `markStaleDriversOffline`, aunque el GPS esté impreciso bajo techo).
enum FixDecision {
  /// Fix bueno → actualizar marcador + refrescar presencia.
  push,

  /// Fix impreciso o ausente, pero el conductor sigue online y tenemos una
  /// última posición conocida → refrescar SOLO la presencia (updatedAt +
  /// isActive) con esa última posición, sin mover el marcador.
  keepAlive,

  /// Nada que hacer (offline, o sin fix y sin última posición conocida).
  ignore,
}

/// Decide la acción para un intento de fix.
///
/// [accuracyMeters] null = no se pudo obtener fix en este intento.
FixDecision decideFix({
  required bool online,
  required double? accuracyMeters,
  required double maxAccuracyMeters,
  required bool hasLastKnown,
}) {
  if (!online) return FixDecision.ignore;
  if (accuracyMeters != null && accuracyMeters <= maxAccuracyMeters) {
    return FixDecision.push;
  }
  // Fix impreciso (>maxAccuracy, típico bajo techo) o ausente: NO movemos el
  // marcador, pero si seguimos online y tenemos una última posición conocida
  // mantenemos viva la presencia (keep-alive) para que el cron
  // markStaleDriversOffline NO nos marque offline. Es el "siempre enviando
  // mientras esté activo".
  return hasLastKnown ? FixDecision.keepAlive : FixDecision.ignore;
}
