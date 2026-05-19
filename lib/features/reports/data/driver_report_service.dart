import 'package:cloud_firestore/cloud_firestore.dart';

/// Reporte de un conductor específico en un periodo dado.
///
/// Agrupa carreras por hora, por día y por método de pago. Usado por
/// el conductor para ver su desempeño y por el admin para auditar a
/// un socio puntual.
class DriverPeriodReport {
  final String driverId;
  final String driverName;
  final String associationId;
  final DateTime fromDate;
  final DateTime toDate;
  final String periodLabel;

  /// Total de carreras del periodo.
  final int totalTrips;

  /// Total ingresado (suma de fare).
  final double totalIncome;

  /// Promedio de fare por carrera.
  double get averageFare =>
      totalTrips == 0 ? 0 : totalIncome / totalTrips;

  /// Carreras agrupadas por hora del día (0-23).
  final Map<int, int> tripsByHour;

  /// Ingresos diarios {dd/MM: monto}.
  final Map<String, double> dailyIncome;

  /// Carreras diarias {dd/MM: count}.
  final Map<String, int> dailyTrips;

  /// Distribución por método: {efectivo: count, transferencia: count}.
  final Map<String, int> tripsByPaymentMethod;

  /// Top destinos (resumido).
  final Map<String, int> topDestinations;

  /// Carreras de TODA la asociación agrupadas por hora del día (0-23).
  /// Para que el conductor compare su actividad vs la global.
  final Map<int, int> associationTripsByHour;

  /// Cantidad de carreras por origen: 'standQueue', 'street', 'manual',
  /// 'apkOperadora', 'walkieTalkie', 'webCliente'.
  final Map<String, int> tripsBySource;

  const DriverPeriodReport({
    required this.driverId,
    required this.driverName,
    required this.associationId,
    required this.fromDate,
    required this.toDate,
    required this.periodLabel,
    required this.totalTrips,
    required this.totalIncome,
    required this.tripsByHour,
    required this.dailyIncome,
    required this.dailyTrips,
    required this.tripsByPaymentMethod,
    required this.topDestinations,
    required this.associationTripsByHour,
    required this.tripsBySource,
  });
}

class DriverReportService {
  DriverReportService._();
  static final DriverReportService instance = DriverReportService._();

  final _firestore = FirebaseFirestore.instance;

  /// Genera el reporte del conductor entre [fromDate] y [toDate].
  Future<DriverPeriodReport> build({
    required String driverId,
    required String driverName,
    required String associationId,
    required DateTime fromDate,
    required DateTime toDate,
    required String periodLabel,
  }) async {
    // Ejecutar ambas queries en paralelo
    final results = await Future.wait([
      _firestore
          .collection('trips')
          .where('driverId', isEqualTo: driverId)
          .where('createdAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(fromDate))
          .where('createdAt',
              isLessThanOrEqualTo: Timestamp.fromDate(toDate))
          .get(),
      _firestore
          .collection('trips')
          .where('associationId', isEqualTo: associationId)
          .where('createdAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(fromDate))
          .where('createdAt',
              isLessThanOrEqualTo: Timestamp.fromDate(toDate))
          .get(),
    ]);

    final docs = results[0].docs.map((d) => d.data()).toList();
    final assocDocs = results[1].docs.map((d) => d.data()).toList();

    int totalTrips = docs.length;
    double totalIncome = 0;
    final byHour = <int, int>{};
    final dailyIncome = <String, double>{};
    final dailyTrips = <String, int>{};
    final byMethod = <String, int>{};
    final byDest = <String, int>{};
    final bySource = <String, int>{};

    for (final t in docs) {
      final ts = (t['createdAt'] as Timestamp?)?.toDate();
      final fare = (t['fare'] as num?)?.toDouble() ?? 0.0;
      totalIncome += fare;
      if (ts != null) {
        byHour[ts.hour] = (byHour[ts.hour] ?? 0) + 1;
        final dayKey =
            '${ts.day.toString().padLeft(2, '0')}/${ts.month.toString().padLeft(2, '0')}';
        dailyTrips[dayKey] = (dailyTrips[dayKey] ?? 0) + 1;
        dailyIncome[dayKey] = (dailyIncome[dayKey] ?? 0) + fare;
      }
      final method = (t['paymentMethod'] as String?) ?? 'efectivo';
      byMethod[method] = (byMethod[method] ?? 0) + 1;
      final dest = (t['dropoffAddress'] as String?)?.trim();
      if (dest != null && dest.isNotEmpty) {
        final shortDest = dest.split(',').first.trim();
        byDest[shortDest] = (byDest[shortDest] ?? 0) + 1;
      }
      final src = (t['source'] as String?) ?? 'manual';
      bySource[src] = (bySource[src] ?? 0) + 1;
    }

    // Calcular carreras de la asociación por hora
    final assocByHour = <int, int>{};
    for (final d in assocDocs) {
      final ts = (d['createdAt'] as Timestamp?)?.toDate();
      if (ts != null) {
        assocByHour[ts.hour] = (assocByHour[ts.hour] ?? 0) + 1;
      }
    }

    return DriverPeriodReport(
      driverId: driverId,
      driverName: driverName,
      associationId: associationId,
      fromDate: fromDate,
      toDate: toDate,
      periodLabel: periodLabel,
      totalTrips: totalTrips,
      totalIncome: totalIncome,
      tripsByHour: byHour,
      dailyIncome: dailyIncome,
      dailyTrips: dailyTrips,
      tripsByPaymentMethod: byMethod,
      topDestinations: byDest,
      associationTripsByHour: assocByHour,
      tripsBySource: bySource,
    );
  }
}
