import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:taxi_jipijapa/features/reports/data/datasources/reports_remote_datasource.dart';
import 'package:taxi_jipijapa/features/reports/data/repositories/reports_repository_impl.dart';
import 'package:taxi_jipijapa/features/reports/domain/entities/report_data.dart';

// ============ MOCKS ============

class MockReportsRemoteDatasource extends Mock
    implements ReportsRemoteDatasource {}

void main() {
  late MockReportsRemoteDatasource mockDatasource;
  late ReportsRepositoryImpl repository;

  final fromDate = DateTime(2026, 3, 1);
  final toDate = DateTime(2026, 3, 31, 23, 59, 59);

  final sampleData = ReportData(
    period: 'Mes',
    fromDate: fromDate,
    toDate: toDate,
    totalTrips: 50,
    completedTrips: 45,
    cancelledTrips: 3,
    totalRevenue: 1200.0,
    averageFare: 26.67,
    activeDriversCount: 10,
    tripsTrend: 5.0,
    revenueTrend: 8.0,
    cancelledTrend: -2.0,
  );

  setUp(() {
    mockDatasource = MockReportsRemoteDatasource();
    repository = ReportsRepositoryImpl(remoteDatasource: mockDatasource);
  });

  setUpAll(() {
    registerFallbackValue(DateTime(2020));
  });

  group('ReportsRepositoryImpl', () {
    group('getPreviousPeriodDates', () {
      test('calcula periodo anterior correctamente para un rango de 30 dias', () {
        final result = repository.getPreviousPeriodDates(
          period: 'Mes',
          fromDate: DateTime(2026, 3, 1),
          toDate: DateTime(2026, 3, 31),
        );

        // Duracion = 30 dias
        // prevFrom = fromDate - 30 dias = 2026-01-30
        // prevTo = fromDate - 1 segundo = 2026-02-28 23:59:59
        expect(result.from, DateTime(2026, 1, 30));
        expect(result.to, DateTime(2026, 2, 28, 23, 59, 59));
      });

      test('calcula periodo anterior para un dia (Hoy)', () {
        final from = DateTime(2026, 3, 29);
        final to = DateTime(2026, 3, 29, 23, 59, 59);

        final result = repository.getPreviousPeriodDates(
          period: 'Hoy',
          fromDate: from,
          toDate: to,
        );

        // Duracion ~= 23h 59m 59s
        // prevFrom = from - duracion = 2026-03-28 00:00:01
        expect(result.from.day, 28);
        expect(result.to, DateTime(2026, 3, 28, 23, 59, 59));
      });

      test('calcula periodo anterior para una semana', () {
        final from = DateTime(2026, 3, 23);
        final to = DateTime(2026, 3, 29, 23, 59, 59);

        final result = repository.getPreviousPeriodDates(
          period: 'Semana',
          fromDate: from,
          toDate: to,
        );

        // Duracion = ~7 dias
        expect(result.from.month, 3);
        expect(result.from.day, 16); // 23 - 6d 23h59m59s ≈ 16
        expect(result.to, DateTime(2026, 3, 22, 23, 59, 59));
      });
    });

    group('getReportData', () {
      test('calcula periodo anterior y delega al datasource', () async {
        when(() => mockDatasource.getReportData(
              associationId: any(named: 'associationId'),
              period: any(named: 'period'),
              fromDate: any(named: 'fromDate'),
              toDate: any(named: 'toDate'),
              prevFrom: any(named: 'prevFrom'),
              prevTo: any(named: 'prevTo'),
            )).thenAnswer((_) async => sampleData);

        final result = await repository.getReportData(
          associationId: 'assoc1',
          period: 'Mes',
          fromDate: fromDate,
          toDate: toDate,
        );

        expect(result, equals(sampleData));

        // Verificar que se paso el periodo anterior correcto
        final captured = verify(() => mockDatasource.getReportData(
              associationId: any(named: 'associationId'),
              period: 'Mes',
              fromDate: fromDate,
              toDate: toDate,
              prevFrom: captureAny(named: 'prevFrom'),
              prevTo: captureAny(named: 'prevTo'),
            )).captured;

        final prevFrom = captured[0] as DateTime;
        final prevTo = captured[1] as DateTime;

        // prevFrom debe ser anterior a fromDate
        expect(prevFrom.isBefore(fromDate), isTrue);
        // prevTo debe ser 1 segundo antes de fromDate
        expect(prevTo, DateTime(2026, 2, 28, 23, 59, 59));
      });

      test('propaga excepciones del datasource', () async {
        when(() => mockDatasource.getReportData(
              associationId: any(named: 'associationId'),
              period: any(named: 'period'),
              fromDate: any(named: 'fromDate'),
              toDate: any(named: 'toDate'),
              prevFrom: any(named: 'prevFrom'),
              prevTo: any(named: 'prevTo'),
            )).thenThrow(Exception('Firestore error'));

        expect(
          () => repository.getReportData(
            associationId: 'assoc1',
            period: 'Hoy',
            fromDate: fromDate,
            toDate: toDate,
          ),
          throwsA(isA<Exception>()),
        );
      });
    });
  });
}
