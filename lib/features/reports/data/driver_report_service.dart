import 'package:cloud_firestore/cloud_firestore.dart';

import 'fare_estimate.dart';

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

  /// Estimado monetario PROPIO del periodo según la tarifa mínima de Quito
  /// (UTC-5): Σ fareForHour(horaLocal del createdAt) sobre sus carreras.
  /// Independiente del `fare` real registrado.
  final double estimatedRevenue;

  /// Promedio de fare por carrera.
  double get averageFare =>
      totalTrips == 0 ? 0 : totalIncome / totalTrips;

  /// Carreras agrupadas por hora del día (0-23), hora local UTC-5.
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
  /// Para que el conductor compare su actividad vs la global. Proviene del
  /// agregado `tripStatsDaily` (no de las carreras ajenas, que el conductor
  /// no puede leer).
  final Map<int, int> associationTripsByHour;

  /// Estimado monetario de la BASE (asociación) en el periodo, sumado del
  /// campo `estimatedRevenue` de los docs de `tripStatsDaily`.
  final double associationEstimatedRevenue;

  /// Total de carreras de la BASE en el periodo (suma de `totalTrips` del
  /// agregado, o de las horas si no viniera el total).
  final int associationTotalTrips;

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
    required this.estimatedRevenue,
    required this.tripsByHour,
    required this.dailyIncome,
    required this.dailyTrips,
    required this.tripsByPaymentMethod,
    required this.topDestinations,
    required this.associationTripsByHour,
    required this.associationEstimatedRevenue,
    required this.associationTotalTrips,
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
    // ── 1. Carreras PROPIAS ──────────────────────────────────────────
    // Solo las carreras del PROPIO conductor. (El conductor NO puede leer
    // carreras ajenas por reglas → la comparación con la base se obtiene del
    // agregado `tripStatsDaily`, ver más abajo.)
    final snap = await _firestore
        .collection('trips')
        .where('driverId', isEqualTo: driverId)
        .where('createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(fromDate))
        .where('createdAt', isLessThanOrEqualTo: Timestamp.fromDate(toDate))
        .get();

    final docs = snap.docs.map((d) => d.data()).toList();

    int totalTrips = docs.length;
    double totalIncome = 0;
    double estimatedRevenue = 0;
    final byHour = <int, int>{};
    final dailyIncome = <String, double>{};
    final dailyTrips = <String, int>{};
    final byMethod = <String, int>{};
    final byDest = <String, int>{};
    final bySource = <String, int>{};

    for (final t in docs) {
      final ts = t['createdAt'] as Timestamp?;
      final fare = (t['fare'] as num?)?.toDouble() ?? 0.0;
      totalIncome += fare;
      if (ts != null) {
        // Hora local EC (UTC-5) para que el bucket sea comparable con el
        // agregado de la base.
        final h = hourInEc(ts);
        byHour[h] = (byHour[h] ?? 0) + 1;
        estimatedRevenue += fareForHour(h);
        final local = ts.toDate().toUtc().subtract(const Duration(hours: 5));
        final dayKey =
            '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}';
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

    // ── 2. BASE (asociación) desde el agregado `tripStatsDaily` ──────────
    // Se lee el agregado en vez de carreras ajenas. Cualquier error/ausencia
    // del agregado se trata como 0 (no rompe el reporte del conductor).
    final assocByHour = <int, int>{};
    double assocEstimated = 0;
    int assocTotal = 0;
    try {
      final stats = await _fetchAssociationStats(
        associationId: associationId,
        fromDate: fromDate,
        toDate: toDate,
        isToday: periodLabel == 'Hoy',
      );
      assocByHour.addAll(stats.tripsByHour);
      assocEstimated = stats.estimatedRevenue;
      assocTotal = stats.totalTrips;
    } catch (_) {
      // Sin agregado disponible → comparación de base vacía.
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
      estimatedRevenue: estimatedRevenue,
      tripsByHour: byHour,
      dailyIncome: dailyIncome,
      dailyTrips: dailyTrips,
      tripsByPaymentMethod: byMethod,
      topDestinations: byDest,
      associationTripsByHour: assocByHour,
      associationEstimatedRevenue: assocEstimated,
      associationTotalTrips: assocTotal,
      tripsBySource: bySource,
    );
  }

  /// Lee y suma el agregado diario de la asociación (`tripStatsDaily`).
  ///
  /// - "Hoy": un solo doc por id `${associationId}_${YYYY-MM-DD}` (getById,
  ///   sin índice). Si no existe aún, devuelve ceros.
  /// - Periodos: query `associationId == X && dateTs >= from && dateTs <= to`
  ///   (requiere índice compuesto associationId+dateTs) y suma los docs.
  Future<_AssocStats> _fetchAssociationStats({
    required String associationId,
    required DateTime fromDate,
    required DateTime toDate,
    required bool isToday,
  }) async {
    final col = _firestore.collection('tripStatsDaily');

    if (isToday) {
      // Fecha local EC (UTC-5) del periodo para construir el id del día.
      final ecDate = _ecDateString(fromDate);
      final doc = await col.doc('${associationId}_$ecDate').get();
      if (!doc.exists) return const _AssocStats({}, 0, 0);
      return _statsFromMap(doc.data()!);
    }

    // Para rangos: dateTs es el inicio del día en UTC-5
    // (`${date}T05:00:00Z` = medianoche EC). Construimos el rango sobre esa
    // base para capturar todos los días del periodo.
    final fromTs = _ecMidnightUtc(fromDate);
    final toTs = _ecMidnightUtc(toDate);
    final qs = await col
        .where('associationId', isEqualTo: associationId)
        .where('dateTs', isGreaterThanOrEqualTo: Timestamp.fromDate(fromTs))
        .where('dateTs', isLessThanOrEqualTo: Timestamp.fromDate(toTs))
        .get();

    final byHour = <int, int>{};
    double estimated = 0;
    int total = 0;
    for (final d in qs.docs) {
      final s = _statsFromMap(d.data());
      s.tripsByHour.forEach((h, c) => byHour[h] = (byHour[h] ?? 0) + c);
      estimated += s.estimatedRevenue;
      total += s.totalTrips;
    }
    return _AssocStats(byHour, estimated, total);
  }

  /// Convierte el map de un doc `tripStatsDaily` a [_AssocStats], tolerando
  /// campos ausentes o tipos inesperados.
  _AssocStats _statsFromMap(Map<String, dynamic> data) {
    final byHour = <int, int>{};
    final raw = data['tripsByHour'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final h = int.tryParse(k.toString());
        final c = (v as num?)?.toInt() ?? 0;
        if (h != null) byHour[h] = (byHour[h] ?? 0) + c;
      });
    }
    final estimated = (data['estimatedRevenue'] as num?)?.toDouble() ?? 0.0;
    final total = (data['totalTrips'] as num?)?.toInt() ?? 0;
    return _AssocStats(byHour, estimated, total);
  }

  /// Inicio del día en UTC-5 expresado como instante UTC (medianoche EC).
  /// Para `date` "2026-05-29" → `2026-05-29T05:00:00Z`.
  DateTime _ecMidnightUtc(DateTime local) {
    // `local` viene del selector de periodo en hora del dispositivo (EC).
    final d = DateTime.utc(local.year, local.month, local.day, 5);
    return d;
  }

  /// Cadena "YYYY-MM-DD" del día en EC a partir de una fecha local.
  String _ecDateString(DateTime local) {
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

/// Resultado agregado de la base para un periodo.
class _AssocStats {
  final Map<int, int> tripsByHour;
  final double estimatedRevenue;
  final int totalTrips;
  const _AssocStats(this.tripsByHour, this.estimatedRevenue, this.totalTrips);
}
