import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_jipijapa/features/reports/domain/entities/report_data.dart';

void main() {
  final fromDate = DateTime(2026, 3, 1);
  final toDate = DateTime(2026, 3, 31);

  group('ReportData', () {
    test('valores por defecto correctos', () {
      final data = ReportData(
        period: 'Hoy',
        fromDate: fromDate,
        toDate: toDate,
      );

      expect(data.totalTrips, 0);
      expect(data.completedTrips, 0);
      expect(data.cancelledTrips, 0);
      expect(data.totalRevenue, 0.0);
      expect(data.averageFare, 0.0);
      expect(data.activeDriversCount, 0);
      expect(data.tripsTrend, 0.0);
      expect(data.revenueTrend, 0.0);
      expect(data.cancelledTrend, 0.0);
      expect(data.tripsByHour, isEmpty);
      expect(data.dailyRevenue, isEmpty);
      expect(data.topDrivers, isEmpty);
      expect(data.paymentMethodDistribution, isEmpty);
      expect(data.frequentDestinations, isEmpty);
    });

    test('Equatable: mismos valores son iguales', () {
      final data1 = ReportData(
        period: 'Hoy',
        fromDate: fromDate,
        toDate: toDate,
        totalTrips: 10,
      );
      final data2 = ReportData(
        period: 'Hoy',
        fromDate: fromDate,
        toDate: toDate,
        totalTrips: 10,
      );
      expect(data1, equals(data2));
    });

    test('Equatable: distintos valores son desiguales', () {
      final data1 = ReportData(
        period: 'Hoy',
        fromDate: fromDate,
        toDate: toDate,
        totalTrips: 10,
      );
      final data2 = ReportData(
        period: 'Hoy',
        fromDate: fromDate,
        toDate: toDate,
        totalTrips: 20,
      );
      expect(data1, isNot(equals(data2)));
    });

    test('props incluye todos los campos', () {
      final data = ReportData(
        period: 'Mes',
        fromDate: fromDate,
        toDate: toDate,
        totalTrips: 5,
        totalRevenue: 100.0,
      );
      // props debe tener 17 elementos
      expect(data.props.length, 17);
    });
  });

  group('DriverReportItem', () {
    test('construye con valores correctos', () {
      const driver = DriverReportItem(
        driverId: 'd1',
        name: 'Juan',
        tripCount: 5,
        income: 125.0,
      );
      expect(driver.driverId, 'd1');
      expect(driver.name, 'Juan');
      expect(driver.tripCount, 5);
      expect(driver.income, 125.0);
      expect(driver.rating, 0.0); // default
    });

    test('Equatable funciona correctamente', () {
      const d1 = DriverReportItem(
        driverId: 'd1',
        name: 'Juan',
        tripCount: 5,
        income: 125.0,
      );
      const d2 = DriverReportItem(
        driverId: 'd1',
        name: 'Juan',
        tripCount: 5,
        income: 125.0,
      );
      expect(d1, equals(d2));
    });
  });

  group('DestinationReportItem', () {
    test('construye con valores correctos', () {
      const dest = DestinationReportItem(address: 'Terminal', count: 8);
      expect(dest.address, 'Terminal');
      expect(dest.count, 8);
    });

    test('Equatable funciona correctamente', () {
      const d1 = DestinationReportItem(address: 'Terminal', count: 8);
      const d2 = DestinationReportItem(address: 'Terminal', count: 8);
      expect(d1, equals(d2));
    });

    test('distintos valores son desiguales', () {
      const d1 = DestinationReportItem(address: 'Terminal', count: 8);
      const d2 = DestinationReportItem(address: 'Hospital', count: 3);
      expect(d1, isNot(equals(d2)));
    });
  });
}
