import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_jipijapa/features/reports/data/stats_aggregator.dart';

/// Helper: construye un DailyStat para una fecha "YYYY-MM-DD" EC con un
/// `dayOfWeek` (0=Dom..6=Sáb) y un mapa hora→conteo.
DailyStat _daily(
  String date,
  int dow,
  Map<int, int> byHour, {
  double estimated = 0,
}) {
  final total = byHour.values.fold<int>(0, (a, b) => a + b);
  // dateTs = 05:00 UTC del día (00:00 EC).
  final parts = date.split('-').map(int.parse).toList();
  final dateTs = DateTime.utc(parts[0], parts[1], parts[2], 5);
  return DailyStat(
    date: date,
    dateTs: dateTs,
    dayOfWeek: dow,
    tripsByHour: byHour,
    totalTrips: total,
    estimatedRevenue: estimated,
  );
}

void main() {
  group('StatsAggregator.aggregate', () {
    test('suma totales, ingreso estimado y combina tripsByHour', () {
      final dailies = [
        _daily('2026-05-25', 1, {8: 2, 9: 1}, estimated: 4.35),
        _daily('2026-05-26', 2, {8: 3, 20: 1}, estimated: 6.10),
      ];
      final agg = StatsAggregator.aggregate(dailies);

      expect(agg.totalTrips, 7);
      expect(agg.estimatedRevenue, closeTo(10.45, 0.001));
      expect(agg.tripsByHour[8], 5); // 2 + 3
      expect(agg.tripsByHour[9], 1);
      expect(agg.tripsByHour[20], 1);
      expect(agg.daysWithTrips, 2);
      expect(agg.averageTripsPerDay, closeTo(3.5, 0.001));
    });

    test('construye matriz heatmap 7x24 agrupada por dayOfWeek', () {
      final dailies = [
        _daily('2026-05-25', 1, {8: 2}), // Lunes
        _daily('2026-06-01', 1, {8: 3}), // otro lunes
        _daily('2026-05-26', 2, {20: 4}), // Martes
      ];
      final agg = StatsAggregator.aggregate(dailies);

      expect(agg.heatmap.length, 7);
      expect(agg.heatmap[0].length, 24);
      // Lunes (dow=1) hora 8 acumula 2+3=5.
      expect(agg.heatmap[1][8], 5);
      // Martes (dow=2) hora 20 = 4.
      expect(agg.heatmap[2][20], 4);
      // Celda vacía = 0.
      expect(agg.heatmap[3][0], 0);
    });

    test('serie diaria queda ordenada por fecha ascendente', () {
      final dailies = [
        _daily('2026-05-27', 3, {10: 1}),
        _daily('2026-05-25', 1, {10: 2}),
        _daily('2026-05-26', 2, {10: 3}),
      ];
      final agg = StatsAggregator.aggregate(dailies);
      expect(agg.dailySeries.map((p) => p.date).toList(),
          ['2026-05-25', '2026-05-26', '2026-05-27']);
      expect(agg.dailySeries.map((p) => p.totalTrips).toList(), [2, 3, 1]);
    });

    test('lista vacía produce agregado vacío sin crashear', () {
      final agg = StatsAggregator.aggregate(const []);
      expect(agg.totalTrips, 0);
      expect(agg.isEmpty, isTrue);
      expect(agg.averageTripsPerDay, 0);
      expect(agg.heatmap.length, 7);
      expect(agg.daysWithTrips, 0);
    });
  });

  group('StatsAggregator.peakHours', () {
    test('devuelve top horas por volumen, descendente', () {
      final peaks =
          StatsAggregator.peakHours({8: 5, 9: 2, 18: 9, 0: 0}, count: 2);
      expect(peaks.length, 2);
      expect(peaks[0].hour, 18);
      expect(peaks[0].trips, 9);
      expect(peaks[1].hour, 8);
    });

    test('ignora horas con 0', () {
      final peaks = StatsAggregator.peakHours({3: 0, 4: 0});
      expect(peaks, isEmpty);
    });
  });

  group('StatsAggregator.compareTotals', () {
    test('calcula % de cambio positivo', () {
      final c = StatsAggregator.compareTotals(currentTrips: 15, previousTrips: 10);
      expect(c.tripsChangePct, closeTo(50.0, 0.001));
    });

    test('calcula % de cambio negativo', () {
      final c = StatsAggregator.compareTotals(currentTrips: 8, previousTrips: 10);
      expect(c.tripsChangePct, closeTo(-20.0, 0.001));
    });

    test('previo 0 con actual >0 → pct null (no significativo)', () {
      final c = StatsAggregator.compareTotals(currentTrips: 5, previousTrips: 0);
      expect(c.tripsChangePct, isNull);
    });

    test('ambos 0 → 0%', () {
      final c = StatsAggregator.compareTotals(currentTrips: 0, previousTrips: 0);
      expect(c.tripsChangePct, 0.0);
    });
  });

  group('StatsAggregator.tripsByDayOfWeek', () {
    test('agrupa totales por día de semana (largo 7)', () {
      final dailies = [
        _daily('2026-05-25', 1, {8: 2}),
        _daily('2026-06-01', 1, {8: 3}),
        _daily('2026-05-26', 2, {20: 4}),
      ];
      final byDow = StatsAggregator.tripsByDayOfWeek(dailies);
      expect(byDow.length, 7);
      expect(byDow[1], 5); // lunes
      expect(byDow[2], 4); // martes
      expect(byDow[0], 0); // domingo
    });
  });

  group('StatsAggregator.isDataInsufficient', () {
    test('true por debajo del umbral', () {
      expect(StatsAggregator.isDataInsufficient(5), isTrue);
      expect(StatsAggregator.isDataInsufficient(13), isTrue);
    });
    test('false en o por encima del umbral', () {
      expect(StatsAggregator.isDataInsufficient(14), isFalse);
      expect(StatsAggregator.isDataInsufficient(40), isFalse);
    });
  });

  group('StatsAggregator.aggregateFunnel', () {
    TripRequestDaily req(
      String date, {
      int recibidas = 0,
      int asignadas = 0,
      int finalizadas = 0,
      int canceladas = 0,
    }) {
      final parts = date.split('-').map(int.parse).toList();
      return TripRequestDaily(
        date: date,
        dateTs: DateTime.utc(parts[0], parts[1], parts[2], 5),
        recibidas: recibidas,
        asignadas: asignadas,
        finalizadas: finalizadas,
        canceladas: canceladas,
      );
    }

    test('suma contadores de todos los días', () {
      final f = StatsAggregator.aggregateFunnel([
        req('2026-05-25', recibidas: 10, asignadas: 8, finalizadas: 7, canceladas: 2),
        req('2026-05-26', recibidas: 6, asignadas: 5, finalizadas: 4, canceladas: 1),
      ]);
      expect(f.recibidas, 16);
      expect(f.asignadas, 13);
      expect(f.finalizadas, 11);
      expect(f.canceladas, 3);
    });

    test('tasas: cumplimiento/cancelación/asignación sobre recibidas', () {
      final f = StatsAggregator.aggregateFunnel([
        req('2026-05-25', recibidas: 20, asignadas: 15, finalizadas: 12, canceladas: 4),
      ]);
      expect(f.fulfillmentRate, closeTo(60.0, 0.001)); // 12/20
      expect(f.cancellationRate, closeTo(20.0, 0.001)); // 4/20
      expect(f.assignmentRate, closeTo(75.0, 0.001)); // 15/20
    });

    test('recibidas == 0 → tasas null (sin división por cero) y isEmpty', () {
      final f = StatsAggregator.aggregateFunnel(const []);
      expect(f.isEmpty, isTrue);
      expect(f.fulfillmentRate, isNull);
      expect(f.cancellationRate, isNull);
      expect(f.assignmentRate, isNull);
    });

    test('hay recibidas pero el resto 0 → no está vacío y tasas 0%', () {
      final f = StatsAggregator.aggregateFunnel([
        req('2026-05-25', recibidas: 5),
      ]);
      expect(f.isEmpty, isFalse);
      expect(f.fulfillmentRate, 0.0);
      expect(f.cancellationRate, 0.0);
      expect(f.assignmentRate, 0.0);
    });
  });

  group('TripRequestDaily.fromMap', () {
    DateTime resolve(dynamic raw) => raw as DateTime;

    test('parsea contadores y tolera campos faltantes como 0', () {
      final d = TripRequestDaily.fromMap({
        'date': '2026-05-25',
        'dateTs': DateTime.utc(2026, 5, 25, 5),
        'recibidas': 10,
        'asignadas': 8,
        // finalizadas/canceladas ausentes (doc viejo) → 0
      }, dateTsResolver: resolve);
      expect(d.date, '2026-05-25');
      expect(d.recibidas, 10);
      expect(d.asignadas, 8);
      expect(d.finalizadas, 0);
      expect(d.canceladas, 0);
    });
  });

  group('StatsRanges.forCadence', () {
    // Referencia: jueves 2026-05-28 12:00 EC = 17:00 UTC.
    final now = DateTime.utc(2026, 5, 28, 17);

    test('día → from==to == medianoche EC de hoy (05:00 UTC)', () {
      final r = StatsRanges.forCadence(ReportCadence.day, now);
      expect(r.fromTs, DateTime.utc(2026, 5, 28, 5));
      expect(r.toTs, DateTime.utc(2026, 5, 28, 5));
      expect(r.label, 'Hoy');
    });

    test('semana → lunes a hoy (EC)', () {
      final r = StatsRanges.forCadence(ReportCadence.week, now);
      // Semana del jueves 28: lunes = 25.
      expect(r.fromTs, DateTime.utc(2026, 5, 25, 5));
      expect(r.toTs, DateTime.utc(2026, 5, 28, 5));
    });

    test('mes → primero del mes a hoy (EC)', () {
      final r = StatsRanges.forCadence(ReportCadence.month, now);
      expect(r.fromTs, DateTime.utc(2026, 5, 1, 5));
      expect(r.toTs, DateTime.utc(2026, 5, 28, 5));
    });

    test('año → 1 ene a hoy (EC)', () {
      final r = StatsRanges.forCadence(ReportCadence.year, now);
      expect(r.fromTs, DateTime.utc(2026, 1, 1, 5));
      expect(r.toTs, DateTime.utc(2026, 5, 28, 5));
    });

    test('cerca de medianoche UTC, el día EC sigue siendo el anterior', () {
      // 2026-05-28 02:00 UTC = 2026-05-27 21:00 EC → día EC = 27.
      final lateUtc = DateTime.utc(2026, 5, 28, 2);
      final r = StatsRanges.forCadence(ReportCadence.day, lateUtc);
      expect(r.fromTs, DateTime.utc(2026, 5, 27, 5));
    });
  });

  group('StatsRanges.previousOf', () {
    test('rango anterior contiguo de misma longitud (semana)', () {
      final current = StatsRanges.forCadence(
          ReportCadence.week, DateTime.utc(2026, 5, 28, 17));
      // current: 25..28 (4 días).
      final prev = StatsRanges.previousOf(current);
      expect(prev.toTs, DateTime.utc(2026, 5, 24, 5)); // día antes del lunes 25
      expect(prev.fromTs, DateTime.utc(2026, 5, 21, 5)); // 4 días: 21..24
    });

    test('día único → anterior es el día previo', () {
      final current = StatsRanges.forCadence(
          ReportCadence.day, DateTime.utc(2026, 5, 28, 17));
      final prev = StatsRanges.previousOf(current);
      expect(prev.fromTs, DateTime.utc(2026, 5, 27, 5));
      expect(prev.toTs, DateTime.utc(2026, 5, 27, 5));
    });
  });

  group('DailyStat.fromMap', () {
    DateTime resolve(dynamic raw) => raw as DateTime;

    test('parsea campos y deriva dayOfWeek si falta', () {
      final ts = DateTime.utc(2026, 5, 25, 5); // lunes 25 EC
      final stat = DailyStat.fromMap({
        'date': '2026-05-25',
        'dateTs': ts,
        // sin dayOfWeek → se deriva
        'tripsByHour': {'8': 2, '9': 1},
        'totalTrips': 3,
        'estimatedRevenue': 4.35,
      }, dateTsResolver: resolve);

      expect(stat.date, '2026-05-25');
      expect(stat.totalTrips, 3);
      expect(stat.estimatedRevenue, closeTo(4.35, 0.001));
      expect(stat.tripsByHour[8], 2);
      // 25/05/2026 es lunes → Dart weekday=1 → dow = 1 % 7 = 1.
      expect(stat.dayOfWeek, 1);
    });

    test('respeta dayOfWeek explícito y tolera tipos faltantes', () {
      final stat = DailyStat.fromMap({
        'date': '2026-05-31',
        'dateTs': DateTime.utc(2026, 5, 31, 5),
        'dayOfWeek': 0, // domingo
        'tripsByHour': null,
      }, dateTsResolver: resolve);
      expect(stat.dayOfWeek, 0);
      expect(stat.totalTrips, 0);
      expect(stat.tripsByHour, isEmpty);
    });
  });
}
