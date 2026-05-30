import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:taxi_jipijapa/features/reports/domain/entities/report_data.dart';
import 'package:taxi_jipijapa/features/reports/domain/repositories/reports_repository.dart';
import 'package:taxi_jipijapa/features/reports/domain/usecases/reports_usecases.dart';

// ============ MOCKS ============

class MockReportsRepository extends Mock implements ReportsRepository {}

void main() {
  late MockReportsRepository mockRepository;
  late GetReportDataUseCase useCase;

  final fromDate = DateTime(2026, 3, 1);
  final toDate = DateTime(2026, 3, 29, 23, 59);

  final sampleData = ReportData(
    period: 'Mes',
    fromDate: fromDate,
    toDate: toDate,
    totalTrips: 100,
    completedTrips: 90,
    cancelledTrips: 5,
    totalRevenue: 2500.0,
    averageFare: 27.78,
    activeDriversCount: 12,
  );

  setUp(() {
    mockRepository = MockReportsRepository();
    useCase = GetReportDataUseCase(mockRepository);
  });

  setUpAll(() {
    registerFallbackValue(DateTime(2020));
  });

  group('GetReportDataUseCase', () {
    test('delega al repositorio con los parametros correctos', () async {
      when(() => mockRepository.getReportData(
            associationId: any(named: 'associationId'),
            period: any(named: 'period'),
            fromDate: any(named: 'fromDate'),
            toDate: any(named: 'toDate'),
          )).thenAnswer((_) async => sampleData);

      final result = await useCase(
        associationId: 'assoc1',
        period: 'Mes',
        fromDate: fromDate,
        toDate: toDate,
      );

      expect(result, equals(sampleData));
      verify(() => mockRepository.getReportData(
            associationId: any(named: 'associationId'),
            period: 'Mes',
            fromDate: fromDate,
            toDate: toDate,
          )).called(1);
      verifyNoMoreInteractions(mockRepository);
    });

    test('propaga excepciones del repositorio', () async {
      when(() => mockRepository.getReportData(
            associationId: any(named: 'associationId'),
            period: any(named: 'period'),
            fromDate: any(named: 'fromDate'),
            toDate: any(named: 'toDate'),
          )).thenThrow(Exception('Network error'));

      expect(
        () => useCase(
          associationId: 'assoc1',
          period: 'Hoy',
          fromDate: fromDate,
          toDate: toDate,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('retorna datos con valores correctos de KPI', () async {
      when(() => mockRepository.getReportData(
            associationId: any(named: 'associationId'),
            period: any(named: 'period'),
            fromDate: any(named: 'fromDate'),
            toDate: any(named: 'toDate'),
          )).thenAnswer((_) async => sampleData);

      final result = await useCase(
        associationId: 'assoc1',
        period: 'Mes',
        fromDate: fromDate,
        toDate: toDate,
      );

      expect(result.totalTrips, 100);
      expect(result.completedTrips, 90);
      expect(result.cancelledTrips, 5);
      expect(result.totalRevenue, 2500.0);
      expect(result.activeDriversCount, 12);
    });
  });
}
