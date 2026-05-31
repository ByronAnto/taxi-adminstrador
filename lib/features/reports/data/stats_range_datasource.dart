import 'package:cloud_firestore/cloud_firestore.dart';

import 'stats_aggregator.dart';

/// Capa de LECTURA de los agregados diarios desplegados en Firestore
/// (`tripStatsDaily` por base y `driverStatsDaily` por conductor).
///
/// Solo se encarga del I/O con Firestore: trae los docs de un rango y los
/// convierte a [DailyStat]. Toda la lógica de agregación (totales, heatmap,
/// tendencias, comparativas) vive en [StatsAggregator], que es pura y testeable
/// sin red.
///
/// Multi-tenant: la base se filtra por `associationId` y el conductor por
/// `driverId`. Las reglas de Firestore ya permiten estas lecturas (miembro
/// activo del tenant para `tripStatsDaily`; dueño/admin para `driverStatsDaily`).
class StatsRangeDatasource {
  final FirebaseFirestore _firestore;

  StatsRangeDatasource({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  static const _tripStatsDaily = 'tripStatsDaily';
  static const _driverStatsDaily = 'driverStatsDaily';
  static const _tripRequestStatsDaily = 'tripRequestStatsDaily';

  /// Convierte el `dateTs` crudo de Firestore a [DateTime]. Aislado para que
  /// [StatsAggregator] no dependa de cloud_firestore.
  static DateTime _resolveTs(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    // Fallback defensivo: epoch.
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  /// Diarios de la BASE en [range]. Query: `associationId == X &&
  /// dateTs >= from && dateTs <= to` (índice compuesto existente).
  Future<List<DailyStat>> fetchAssociationRange({
    required String associationId,
    required StatsRange range,
  }) {
    return _fetchRange(
      collection: _tripStatsDaily,
      field: 'associationId',
      value: associationId,
      range: range,
    );
  }

  /// Diarios de un CONDUCTOR en [range]. Query: `driverId == X &&
  /// dateTs >= from && dateTs <= to` (índice compuesto existente).
  Future<List<DailyStat>> fetchDriverRange({
    required String driverId,
    required StatsRange range,
  }) {
    return _fetchRange(
      collection: _driverStatsDaily,
      field: 'driverId',
      value: driverId,
      range: range,
    );
  }

  /// Embudo de solicitudes web de la BASE en [range]. Lee
  /// `tripRequestStatsDaily` con la query `associationId == X &&
  /// dateTs >= from && dateTs <= to` (índice compuesto existente
  /// `associationId ASC, dateTs ASC`). Contadores por cohorte (fecha de la
  /// solicitud); campos ausentes en docs viejos → 0.
  Future<List<TripRequestDaily>> fetchTripRequestRange({
    required String associationId,
    required StatsRange range,
  }) async {
    if (associationId.isEmpty) return const [];
    final qs = await _firestore
        .collection(_tripRequestStatsDaily)
        .where('associationId', isEqualTo: associationId)
        .where('dateTs',
            isGreaterThanOrEqualTo: Timestamp.fromDate(range.fromTs))
        .where('dateTs', isLessThanOrEqualTo: Timestamp.fromDate(range.toTs))
        .get();
    return qs.docs
        .map((d) =>
            TripRequestDaily.fromMap(d.data(), dateTsResolver: _resolveTs))
        .toList();
  }

  Future<List<DailyStat>> _fetchRange({
    required String collection,
    required String field,
    required String value,
    required StatsRange range,
  }) async {
    if (value.isEmpty) return const [];
    final qs = await _firestore
        .collection(collection)
        .where(field, isEqualTo: value)
        .where('dateTs',
            isGreaterThanOrEqualTo: Timestamp.fromDate(range.fromTs))
        .where('dateTs', isLessThanOrEqualTo: Timestamp.fromDate(range.toTs))
        .get();
    return qs.docs
        .map((d) => DailyStat.fromMap(d.data(), dateTsResolver: _resolveTs))
        .toList();
  }
}
