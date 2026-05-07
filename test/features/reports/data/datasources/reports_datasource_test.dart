import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_jipijapa/features/reports/data/datasources/reports_remote_datasource.dart';

void main() {
  late FakeFirebaseFirestore fakeFirestore;
  late ReportsRemoteDatasource datasource;

  final now = DateTime(2026, 3, 29, 14, 0);
  final todayStart = DateTime(2026, 3, 29);
  final prevStart = DateTime(2026, 3, 28);
  final prevEnd = DateTime(2026, 3, 28, 23, 59, 59);

  /// Inserta datos de prueba en Firestore falso
  Future<void> seedData(FakeFirebaseFirestore fs) async {
    // Crear 2 usuarios (conductores)
    await fs.collection('users').doc('driver1').set({
      'name': 'Carlos',
      'lastname': 'Lopez',
      'role': 'conductor',
    });
    await fs.collection('users').doc('driver2').set({
      'name': 'Maria',
      'lastname': 'Garcia',
      'role': 'conductor',
    });

    // Crear viajes de hoy (periodo actual)
    final todayTrips = [
      {
        'status': 'completado',
        'driverId': 'driver1',
        'fare': 5.0,
        'paymentMethod': 'efectivo',
        'dropoffAddress': 'Terminal Terrestre, Jipijapa',
        'createdAt': Timestamp.fromDate(DateTime(2026, 3, 29, 8, 30)),
      },
      {
        'status': 'completado',
        'driverId': 'driver1',
        'fare': 7.0,
        'paymentMethod': 'digital',
        'dropoffAddress': 'Hospital General',
        'createdAt': Timestamp.fromDate(DateTime(2026, 3, 29, 10, 15)),
      },
      {
        'status': 'completado',
        'driverId': 'driver2',
        'fare': 4.5,
        'paymentMethod': 'efectivo',
        'dropoffAddress': 'Terminal Terrestre, Jipijapa',
        'createdAt': Timestamp.fromDate(DateTime(2026, 3, 29, 12, 0)),
      },
      {
        'status': 'cancelado',
        'driverId': 'driver2',
        'fare': 0.0,
        'paymentMethod': 'efectivo',
        'dropoffAddress': 'Mercado Central',
        'createdAt': Timestamp.fromDate(DateTime(2026, 3, 29, 13, 0)),
      },
      {
        'status': 'en_progreso',
        'driverId': 'driver1',
        'fare': 0.0,
        'paymentMethod': 'efectivo',
        'dropoffAddress': 'Parque Central',
        'createdAt': Timestamp.fromDate(DateTime(2026, 3, 29, 13, 30)),
      },
    ];

    for (final trip in todayTrips) {
      await fs.collection('trips').add(trip);
    }

    // Viajes del periodo anterior (ayer)
    final yesterdayTrips = [
      {
        'status': 'completado',
        'driverId': 'driver1',
        'fare': 6.0,
        'paymentMethod': 'efectivo',
        'dropoffAddress': 'Terminal Terrestre',
        'createdAt': Timestamp.fromDate(DateTime(2026, 3, 28, 9, 0)),
      },
      {
        'status': 'completado',
        'driverId': 'driver2',
        'fare': 5.5,
        'paymentMethod': 'digital',
        'dropoffAddress': 'Hospital',
        'createdAt': Timestamp.fromDate(DateTime(2026, 3, 28, 11, 0)),
      },
    ];

    for (final trip in yesterdayTrips) {
      await fs.collection('trips').add(trip);
    }
  }

  setUp(() async {
    fakeFirestore = FakeFirebaseFirestore();
    datasource = ReportsRemoteDatasource(firestore: fakeFirestore);
    await seedData(fakeFirestore);
  });

  group('ReportsRemoteDatasource', () {
    test('retorna ReportData con conteos correctos', () async {
      final result = await datasource.getReportData(
        period: 'Hoy',
        fromDate: todayStart,
        toDate: now,
        prevFrom: prevStart,
        prevTo: prevEnd,
      );

      // 5 viajes totales hoy
      expect(result.totalTrips, 5);
      // 3 completados
      expect(result.completedTrips, 3);
      // 1 cancelado
      expect(result.cancelledTrips, 1);
      // Periodo correcto
      expect(result.period, 'Hoy');
    });

    test('calcula ingresos correctamente', () async {
      final result = await datasource.getReportData(
        period: 'Hoy',
        fromDate: todayStart,
        toDate: now,
        prevFrom: prevStart,
        prevTo: prevEnd,
      );

      // Revenue = 5.0 + 7.0 + 4.5 = 16.5
      expect(result.totalRevenue, 16.5);
      // Average = 16.5 / 3 = 5.5
      expect(result.averageFare, 5.5);
    });

    test('genera tripsByHour correctamente', () async {
      final result = await datasource.getReportData(
        period: 'Hoy',
        fromDate: todayStart,
        toDate: now,
        prevFrom: prevStart,
        prevTo: prevEnd,
      );

      // Hora 8: 1 viaje, Hora 10: 1, Hora 12: 1, Hora 13: 2
      expect(result.tripsByHour[8], 1);
      expect(result.tripsByHour[10], 1);
      expect(result.tripsByHour[12], 1);
      expect(result.tripsByHour[13], 2);
    });

    test('genera dailyRevenue correctamente', () async {
      final result = await datasource.getReportData(
        period: 'Hoy',
        fromDate: todayStart,
        toDate: now,
        prevFrom: prevStart,
        prevTo: prevEnd,
      );

      // Solo una fecha: 29/03
      expect(result.dailyRevenue.keys.length, 1);
      expect(result.dailyRevenue['29/03'], 16.5);
    });

    test('genera top conductores ordenados por viajes', () async {
      final result = await datasource.getReportData(
        period: 'Hoy',
        fromDate: todayStart,
        toDate: now,
        prevFrom: prevStart,
        prevTo: prevEnd,
      );

      expect(result.topDrivers.length, 2);
      // driver1 tiene 2 viajes completos, driver2 tiene 1
      expect(result.topDrivers.first.driverId, 'driver1');
      expect(result.topDrivers.first.tripCount, 2);
      expect(result.topDrivers.first.income, 12.0); // 5+7
      expect(result.topDrivers.first.name, 'Carlos Lopez');

      expect(result.topDrivers.last.driverId, 'driver2');
      expect(result.topDrivers.last.tripCount, 1);
      expect(result.topDrivers.last.name, 'Maria Garcia');
    });

    test('calcula distribucion de pago correctamente', () async {
      final result = await datasource.getReportData(
        period: 'Hoy',
        fromDate: todayStart,
        toDate: now,
        prevFrom: prevStart,
        prevTo: prevEnd,
      );

      // 2 efectivo, 1 digital/Transferencia de 3 completados
      expect(result.paymentMethodDistribution['Efectivo'],
          closeTo(0.667, 0.01));
      expect(result.paymentMethodDistribution['Transferencia'],
          closeTo(0.333, 0.01));
    });

    test('genera destinos frecuentes ordenados', () async {
      final result = await datasource.getReportData(
        period: 'Hoy',
        fromDate: todayStart,
        toDate: now,
        prevFrom: prevStart,
        prevTo: prevEnd,
      );

      // "Terminal Terrestre" aparece 2 veces de completados (viajes 1 y 3)
      expect(result.frequentDestinations.isNotEmpty, isTrue);
      expect(result.frequentDestinations.first.address, 'Terminal Terrestre');
      expect(result.frequentDestinations.first.count, 2);
    });

    test('cuenta conductores activos correctamente', () async {
      final result = await datasource.getReportData(
        period: 'Hoy',
        fromDate: todayStart,
        toDate: now,
        prevFrom: prevStart,
        prevTo: prevEnd,
      );

      // driver1 tiene viajes 'completado' y 'en_progreso', driver2 tiene 'completado' y 'cancelado'
      // Activos: completado + en_progreso + asignado => driver1 y driver2
      expect(result.activeDriversCount, 2);
    });

    test('calcula tendencias vs periodo anterior', () async {
      final result = await datasource.getReportData(
        period: 'Hoy',
        fromDate: todayStart,
        toDate: now,
        prevFrom: prevStart,
        prevTo: prevEnd,
      );

      // Hoy: 5 viajes, Ayer: 2 viajes => tripsTrend = (5-2)/2*100 = 150%
      expect(result.tripsTrend, 150.0);

      // Revenue hoy: 16.5, ayer: 11.5 => (16.5-11.5)/11.5 * 100 = ~43%
      expect(result.revenueTrend, closeTo(43.0, 1.0));

      // Cancelados hoy: 1, ayer: 0 => trend = 100% (0 prev => 100 si current > 0)
      expect(result.cancelledTrend, 100.0);
    });

    test('funciona sin periodo anterior (sin tendencias)', () async {
      final result = await datasource.getReportData(
        period: 'Hoy',
        fromDate: todayStart,
        toDate: now,
      );

      expect(result.totalTrips, 5);
      expect(result.tripsTrend, 0.0);
      expect(result.revenueTrend, 0.0);
      expect(result.cancelledTrend, 0.0);
    });

    test('retorna datos vacios cuando no hay viajes', () async {
      final emptyFs = FakeFirebaseFirestore();
      final emptyDs = ReportsRemoteDatasource(firestore: emptyFs);

      final result = await emptyDs.getReportData(
        period: 'Hoy',
        fromDate: todayStart,
        toDate: now,
      );

      expect(result.totalTrips, 0);
      expect(result.completedTrips, 0);
      expect(result.totalRevenue, 0.0);
      expect(result.averageFare, 0.0);
      expect(result.topDrivers, isEmpty);
      expect(result.tripsByHour, isEmpty);
      expect(result.frequentDestinations, isEmpty);
    });
  });
}
