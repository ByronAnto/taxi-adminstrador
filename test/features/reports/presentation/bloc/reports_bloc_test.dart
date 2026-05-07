import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:taxi_jipijapa/features/reports/domain/entities/report_data.dart';
import 'package:taxi_jipijapa/features/reports/domain/usecases/reports_usecases.dart';
import 'package:taxi_jipijapa/features/reports/presentation/bloc/reports_bloc.dart';

// ============ MOCKS ============

class MockGetReportDataUseCase extends Mock implements GetReportDataUseCase {}

// ============ HELPERS ============

final _now = DateTime(2026, 3, 29, 14, 0);
final _todayStart = DateTime(2026, 3, 29);

ReportData _makeReportData({String period = 'Hoy'}) => ReportData(
      period: period,
      fromDate: _todayStart,
      toDate: _now,
      totalTrips: 25,
      completedTrips: 20,
      cancelledTrips: 3,
      totalRevenue: 500.0,
      averageFare: 25.0,
      activeDriversCount: 8,
      tripsTrend: 10.0,
      revenueTrend: 15.0,
      cancelledTrend: -5.0,
      tripsByHour: {8: 5, 12: 10, 18: 7},
      dailyRevenue: {'29/03': 500.0},
      topDrivers: const [
        DriverReportItem(
          driverId: 'd1',
          name: 'Juan Perez',
          tripCount: 10,
          income: 250.0,
        ),
      ],
      paymentMethodDistribution: {'Efectivo': 0.6, 'Transferencia': 0.4},
      frequentDestinations: const [
        DestinationReportItem(address: 'Terminal', count: 8),
      ],
    );

void main() {
  late MockGetReportDataUseCase mockUseCase;

  setUp(() {
    mockUseCase = MockGetReportDataUseCase();
  });

  setUpAll(() {
    // Registrar fallback values para matchers
    registerFallbackValue(DateTime(2020));
  });

  group('ReportsBloc', () {
    // ---- Estado inicial ----
    test('estado inicial es ReportsInitial', () {
      final bloc = ReportsBloc(getReportData: mockUseCase);
      expect(bloc.state, isA<ReportsInitial>());
      bloc.close();
    });

    // ---- Carga exitosa (periodo Hoy) ----
    blocTest<ReportsBloc, ReportsState>(
      'emite [ReportsLoading, ReportsLoaded] al cargar con periodo Hoy',
      build: () {
        when(() => mockUseCase(
              period: any(named: 'period'),
              fromDate: any(named: 'fromDate'),
              toDate: any(named: 'toDate'),
            )).thenAnswer((_) async => _makeReportData());
        return ReportsBloc(getReportData: mockUseCase);
      },
      act: (bloc) => bloc.add(ReportsLoadRequested(period: 'Hoy')),
      expect: () => [
        isA<ReportsLoading>(),
        isA<ReportsLoaded>(),
      ],
      verify: (_) {
        verify(() => mockUseCase(
              period: 'Hoy',
              fromDate: any(named: 'fromDate'),
              toDate: any(named: 'toDate'),
            )).called(1);
      },
    );

    // ---- Carga exitosa con periodo Semana ----
    blocTest<ReportsBloc, ReportsState>(
      'emite [ReportsLoading, ReportsLoaded] al cargar con periodo Semana',
      build: () {
        when(() => mockUseCase(
              period: any(named: 'period'),
              fromDate: any(named: 'fromDate'),
              toDate: any(named: 'toDate'),
            )).thenAnswer((_) async => _makeReportData(period: 'Semana'));
        return ReportsBloc(getReportData: mockUseCase);
      },
      act: (bloc) => bloc.add(ReportsLoadRequested(period: 'Semana')),
      expect: () => [
        isA<ReportsLoading>(),
        isA<ReportsLoaded>(),
      ],
    );

    // ---- Carga exitosa con periodo Mes ----
    blocTest<ReportsBloc, ReportsState>(
      'emite [ReportsLoading, ReportsLoaded] al cargar con periodo Mes',
      build: () {
        when(() => mockUseCase(
              period: any(named: 'period'),
              fromDate: any(named: 'fromDate'),
              toDate: any(named: 'toDate'),
            )).thenAnswer((_) async => _makeReportData(period: 'Mes'));
        return ReportsBloc(getReportData: mockUseCase);
      },
      act: (bloc) => bloc.add(ReportsLoadRequested(period: 'Mes')),
      expect: () => [
        isA<ReportsLoading>(),
        isA<ReportsLoaded>(),
      ],
    );

    // ---- Carga exitosa con periodo Ano ----
    blocTest<ReportsBloc, ReportsState>(
      'emite [ReportsLoading, ReportsLoaded] al cargar con periodo Ano',
      build: () {
        when(() => mockUseCase(
              period: any(named: 'period'),
              fromDate: any(named: 'fromDate'),
              toDate: any(named: 'toDate'),
            )).thenAnswer((_) async => _makeReportData(period: 'Ano'));
        return ReportsBloc(getReportData: mockUseCase);
      },
      act: (bloc) => bloc.add(ReportsLoadRequested(period: 'Ano')),
      expect: () => [
        isA<ReportsLoading>(),
        isA<ReportsLoaded>(),
      ],
    );

    // ---- Error al cargar ----
    blocTest<ReportsBloc, ReportsState>(
      'emite [ReportsLoading, ReportsError] cuando el use case falla',
      build: () {
        when(() => mockUseCase(
              period: any(named: 'period'),
              fromDate: any(named: 'fromDate'),
              toDate: any(named: 'toDate'),
            )).thenThrow(Exception('Firestore no disponible'));
        return ReportsBloc(getReportData: mockUseCase);
      },
      act: (bloc) => bloc.add(ReportsLoadRequested()),
      expect: () => [
        isA<ReportsLoading>(),
        isA<ReportsError>(),
      ],
    );

    // ---- Verifica datos en ReportsLoaded ----
    blocTest<ReportsBloc, ReportsState>(
      'ReportsLoaded contiene el ReportData correcto',
      build: () {
        when(() => mockUseCase(
              period: any(named: 'period'),
              fromDate: any(named: 'fromDate'),
              toDate: any(named: 'toDate'),
            )).thenAnswer((_) async => _makeReportData());
        return ReportsBloc(getReportData: mockUseCase);
      },
      act: (bloc) => bloc.add(ReportsLoadRequested()),
      verify: (bloc) {
        final state = bloc.state;
        expect(state, isA<ReportsLoaded>());
        final loaded = state as ReportsLoaded;
        expect(loaded.reportData.totalTrips, 25);
        expect(loaded.reportData.totalRevenue, 500.0);
        expect(loaded.reportData.topDrivers.length, 1);
        expect(loaded.reportData.topDrivers.first.name, 'Juan Perez');
      },
    );

    // ---- Periodo por defecto es Hoy ----
    test('ReportsLoadRequested tiene periodo Hoy por defecto', () {
      final event = ReportsLoadRequested();
      expect(event.period, 'Hoy');
    });

    // ---- Mensaje de error incluye la excepcion ----
    blocTest<ReportsBloc, ReportsState>(
      'ReportsError contiene mensaje descriptivo',
      build: () {
        when(() => mockUseCase(
              period: any(named: 'period'),
              fromDate: any(named: 'fromDate'),
              toDate: any(named: 'toDate'),
            )).thenThrow(Exception('timeout'));
        return ReportsBloc(getReportData: mockUseCase);
      },
      act: (bloc) => bloc.add(ReportsLoadRequested()),
      verify: (bloc) {
        final state = bloc.state;
        expect(state, isA<ReportsError>());
        expect((state as ReportsError).message, contains('timeout'));
      },
    );

    // ---- Equatable: estados iguales no duplican emit ----
    blocTest<ReportsBloc, ReportsState>(
      'dos cargas iguales emiten estados completos cada vez',
      build: () {
        when(() => mockUseCase(
              period: any(named: 'period'),
              fromDate: any(named: 'fromDate'),
              toDate: any(named: 'toDate'),
            )).thenAnswer((_) async => _makeReportData());
        return ReportsBloc(getReportData: mockUseCase);
      },
      act: (bloc) async {
        bloc.add(ReportsLoadRequested());
        await Future.delayed(const Duration(milliseconds: 100));
        bloc.add(ReportsLoadRequested());
      },
      expect: () => [
        isA<ReportsLoading>(),
        isA<ReportsLoaded>(),
        isA<ReportsLoading>(),
        isA<ReportsLoaded>(),
      ],
    );
  });

  // ---- Equatable de Events ----
  group('ReportsEvent Equatable', () {
    test('dos ReportsLoadRequested con mismo periodo son iguales', () {
      expect(
        ReportsLoadRequested(period: 'Hoy'),
        equals(ReportsLoadRequested(period: 'Hoy')),
      );
    });

    test('dos ReportsLoadRequested con distinto periodo son distintos', () {
      expect(
        ReportsLoadRequested(period: 'Hoy'),
        isNot(equals(ReportsLoadRequested(period: 'Mes'))),
      );
    });
  });

  // ---- Equatable de States ----
  group('ReportsState Equatable', () {
    test('dos ReportsLoaded con misma data son iguales', () {
      final data = _makeReportData();
      expect(ReportsLoaded(data), equals(ReportsLoaded(data)));
    });

    test('dos ReportsError con mismo mensaje son iguales', () {
      expect(ReportsError('err'), equals(ReportsError('err')));
    });
  });
}
