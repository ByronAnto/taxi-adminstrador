import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/constants/app_constants.dart';
import '../../domain/entities/report_data.dart';

/// Fuente de datos remota para reportes (agrega datos de Firestore)
class ReportsRemoteDatasource {
  final FirebaseFirestore _firestore;

  ReportsRemoteDatasource({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference get _tripsRef =>
      _firestore.collection(AppConstants.tripsCollection);

  CollectionReference get _usersRef =>
      _firestore.collection(AppConstants.usersCollection);

  /// Obtener datos agregados del reporte
  Future<ReportData> getReportData({
    required String period,
    required DateTime fromDate,
    required DateTime toDate,
    DateTime? prevFrom,
    DateTime? prevTo,
  }) async {
    // 1. Obtener viajes del período actual
    final tripsSnap = await _tripsRef
        .where('createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(fromDate))
        .where('createdAt', isLessThanOrEqualTo: Timestamp.fromDate(toDate))
        .get();

    final trips = tripsSnap.docs.map((d) => d.data() as Map<String, dynamic>).toList();

    // 2. Clasificar viajes
    final completedTrips =
        trips.where((t) => t['status'] == 'completado').toList();
    final cancelledTrips =
        trips.where((t) => t['status'] == 'cancelado').toList();

    // 3. Calcular ingresos
    double totalRevenue = 0;
    for (final trip in completedTrips) {
      totalRevenue += (trip['fare'] ?? 0.0).toDouble();
    }
    final averageFare =
        completedTrips.isEmpty ? 0.0 : totalRevenue / completedTrips.length;

    // 4. Carreras por hora
    final Map<int, int> tripsByHour = {};
    for (final trip in trips) {
      final ts = trip['createdAt'];
      if (ts is Timestamp) {
        final hour = ts.toDate().hour;
        tripsByHour[hour] = (tripsByHour[hour] ?? 0) + 1;
      }
    }

    // 5. Ingresos diarios
    final Map<String, double> dailyRevenue = {};
    for (final trip in completedTrips) {
      final ts = trip['createdAt'];
      if (ts is Timestamp) {
        final date = ts.toDate();
        final key =
            '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}';
        dailyRevenue[key] = (dailyRevenue[key] ?? 0) + (trip['fare'] ?? 0.0).toDouble();
      }
    }

    // 6. Top conductores (agrupar por driverId)
    final Map<String, _DriverAggr> driverMap = {};
    for (final trip in completedTrips) {
      final dId = trip['driverId'] as String? ?? '';
      if (dId.isEmpty) continue;
      driverMap.putIfAbsent(dId, () => _DriverAggr());
      driverMap[dId]!.tripCount++;
      driverMap[dId]!.income += (trip['fare'] ?? 0.0).toDouble();
    }

    // Obtener nombres de conductores
    final driverIds = driverMap.keys.toList();
    final Map<String, String> driverNames = {};
    // Firestore whereIn tiene límite de 30
    for (var i = 0; i < driverIds.length; i += 30) {
      final batch =
          driverIds.sublist(i, i + 30 > driverIds.length ? driverIds.length : i + 30);
      if (batch.isEmpty) continue;
      final usersSnap =
          await _usersRef.where(FieldPath.documentId, whereIn: batch).get();
      for (final doc in usersSnap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        driverNames[doc.id] =
            '${data['name'] ?? ''} ${data['lastname'] ?? ''}'.trim();
      }
    }

    final topDrivers = driverMap.entries.map((e) {
      return DriverReportItem(
        driverId: e.key,
        name: driverNames[e.key] ?? 'Conductor',
        tripCount: e.value.tripCount,
        income: e.value.income,
      );
    }).toList()
      ..sort((a, b) => b.tripCount.compareTo(a.tripCount));

    // 7. Distribución por método de pago
    final Map<String, int> paymentCounts = {};
    for (final trip in completedTrips) {
      final method = trip['paymentMethod'] as String? ?? 'efectivo';
      final label = method == 'digital' ? 'Transferencia' : 'Efectivo';
      paymentCounts[label] = (paymentCounts[label] ?? 0) + 1;
    }
    final totalForPayment =
        paymentCounts.values.fold<int>(0, (acc, c) => acc + c);
    final Map<String, double> paymentDistribution = {};
    if (totalForPayment > 0) {
      for (final entry in paymentCounts.entries) {
        paymentDistribution[entry.key] = entry.value / totalForPayment;
      }
    }

    // 8. Destinos frecuentes
    final Map<String, int> destCounts = {};
    for (final trip in completedTrips) {
      final addr = trip['dropoffAddress'] as String?;
      if (addr != null && addr.isNotEmpty) {
        // Usar solo las primeras 3 palabras como clave agrupadora
        final shortAddr =
            addr.split(',').first.trim();
        destCounts[shortAddr] = (destCounts[shortAddr] ?? 0) + 1;
      }
    }
    final freqDest = destCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final destinations = freqDest
        .take(5)
        .map((e) => DestinationReportItem(address: e.key, count: e.value))
        .toList();

    // 9. Conductores activos: obtener drivers distintos con viajes hoy
    final activeDriverIds = <String>{};
    for (final trip in trips) {
      final status = trip['status'] as String? ?? '';
      if (status == 'asignado' || status == 'en_progreso' || status == 'completado') {
        final dId = trip['driverId'] as String? ?? '';
        if (dId.isNotEmpty) activeDriverIds.add(dId);
      }
    }

    // 10. Tendencias (período anterior)
    double tripsTrend = 0;
    double revenueTrend = 0;
    double cancelledTrend = 0;
    if (prevFrom != null && prevTo != null) {
      try {
        final prevSnap = await _tripsRef
            .where('createdAt',
                isGreaterThanOrEqualTo: Timestamp.fromDate(prevFrom))
            .where('createdAt',
                isLessThanOrEqualTo: Timestamp.fromDate(prevTo))
            .get();
        final prevTrips =
            prevSnap.docs.map((d) => d.data() as Map<String, dynamic>).toList();
        final prevCompleted =
            prevTrips.where((t) => t['status'] == 'completado').toList();
        final prevCancelled =
            prevTrips.where((t) => t['status'] == 'cancelado').toList();
        double prevRevenue = 0;
        for (final t in prevCompleted) {
          prevRevenue += (t['fare'] ?? 0.0).toDouble();
        }

        tripsTrend = _calcTrend(trips.length, prevTrips.length);
        revenueTrend = _calcTrend(totalRevenue, prevRevenue);
        cancelledTrend =
            _calcTrend(cancelledTrips.length.toDouble(), prevCancelled.length.toDouble());
      } catch (_) {
        // Si falla la comparación, dejamos en 0
      }
    }

    return ReportData(
      period: period,
      fromDate: fromDate,
      toDate: toDate,
      totalTrips: trips.length,
      completedTrips: completedTrips.length,
      cancelledTrips: cancelledTrips.length,
      totalRevenue: totalRevenue,
      averageFare: averageFare,
      activeDriversCount: activeDriverIds.length,
      tripsTrend: tripsTrend,
      revenueTrend: revenueTrend,
      cancelledTrend: cancelledTrend,
      tripsByHour: tripsByHour,
      dailyRevenue: dailyRevenue,
      topDrivers: topDrivers.take(5).toList(),
      paymentMethodDistribution: paymentDistribution,
      frequentDestinations: destinations,
    );
  }

  double _calcTrend(num current, num previous) {
    if (previous == 0) return current > 0 ? 100.0 : 0.0;
    return ((current - previous) / previous * 100).roundToDouble();
  }
}

class _DriverAggr {
  int tripCount = 0;
  double income = 0;
}
