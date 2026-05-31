import 'package:cloud_firestore/cloud_firestore.dart';

/// Rating promedio PONDERADO de la cooperativa (base), calculado desde la
/// colección `drivers`. Inmutable y sin lógica de UI.
///
/// El promedio se pondera por número de calificaciones:
/// `sum(ratingSum) / sum(ratingCount)` sobre los conductores con
/// `ratingCount > 0`. Si nadie tiene calificaciones, [ratingCount] es 0 y
/// [average] es `null`.
class AssociationRating {
  /// Promedio ponderado (1..5) o `null` si aún no hay calificaciones.
  final double? average;

  /// Total de calificaciones recibidas por toda la base.
  final int ratingCount;

  const AssociationRating({required this.average, required this.ratingCount});

  /// Sin calificaciones todavía.
  static const empty = AssociationRating(average: null, ratingCount: 0);

  bool get hasRatings => ratingCount > 0 && average != null;
}

/// Ranking del propio conductor dentro de su asociación, tal como lo dejó el
/// cron `computeDriverPercentiles` en su doc de `drivers`. Solo posición
/// agregada: NO expone datos de otros conductores.
class DriverRanking {
  /// Puesto, 1 = más carreras.
  final int rank;

  /// Total de conductores rankeados en la asociación.
  final int totalDrivers;

  /// Percentil "top" (rank/total*100, redondeado hacia arriba, mín. 1).
  final int topPercent;

  const DriverRanking({
    required this.rank,
    required this.totalDrivers,
    required this.topPercent,
  });
}

/// Lecturas agregadas sobre la colección `drivers` para reportería:
/// - rating promedio ponderado de la base (admin/operadora),
/// - ranking propio del conductor.
///
/// Multi-tenant: el rating se filtra por `associationId`; el ranking se lee
/// del doc propio (`userId == uid`). Toda lectura degrada con gracia ante
/// error/permiso (devuelve vacío / `null` en vez de propagar la excepción),
/// para que el reporte nunca se rompa por estas piezas secundarias.
class DriversSummaryService {
  final FirebaseFirestore _firestore;

  DriversSummaryService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Instancia compartida por defecto (Firestore real).
  static final DriversSummaryService instance = DriversSummaryService();

  /// Rating promedio ponderado de la cooperativa. Suma `ratingSum` y
  /// `ratingCount` de todos los conductores de la asociación y divide. Ignora
  /// conductores sin calificaciones. Degrada a [AssociationRating.empty] ante
  /// error/permiso.
  Future<AssociationRating> fetchAssociationRating({
    required String associationId,
  }) async {
    if (associationId.isEmpty) return AssociationRating.empty;
    try {
      final qs = await _firestore
          .collection('drivers')
          .where('associationId', isEqualTo: associationId)
          .get();
      double sum = 0;
      int count = 0;
      for (final d in qs.docs) {
        final data = d.data();
        final c = (data['ratingCount'] as num?)?.toInt() ?? 0;
        if (c <= 0) continue;
        sum += (data['ratingSum'] as num?)?.toDouble() ?? 0.0;
        count += c;
      }
      if (count == 0) return AssociationRating.empty;
      return AssociationRating(average: sum / count, ratingCount: count);
    } catch (_) {
      return AssociationRating.empty;
    }
  }

  /// Ranking del conductor [uid] desde su propio doc. Devuelve `null` si no se
  /// encuentra el doc, si los campos del cron aún no existen, o ante error.
  Future<DriverRanking?> fetchDriverRanking({required String uid}) async {
    if (uid.isEmpty) return null;
    try {
      final qs = await _firestore
          .collection('drivers')
          .where('userId', isEqualTo: uid)
          .limit(1)
          .get();
      if (qs.docs.isEmpty) return null;
      final data = qs.docs.first.data();
      final rank = (data['tripsRank'] as num?)?.toInt();
      final total = (data['tripsTotalDrivers'] as num?)?.toInt();
      final top = (data['tripsTopPercent'] as num?)?.toInt();
      // El cron aún no corrió para este conductor → ocultar tarjeta.
      if (rank == null || total == null || top == null || total <= 0) {
        return null;
      }
      return DriverRanking(
        rank: rank,
        totalDrivers: total,
        topPercent: top.clamp(1, 100),
      );
    } catch (_) {
      return null;
    }
  }
}
