/// Lógica PURA de agregación de estadísticas de carreras.
///
/// No depende de Firestore ni de Flutter: recibe una lista de [DailyStat]
/// (los docs diarios de `tripStatsDaily` / `driverStatsDaily` ya parseados)
/// y produce los agregados que consume la UI (totales, heatmap 7×24, serie
/// diaria, horas pico y comparativas). Así es testeable sin red.
///
/// **Modelo de fechas (Ecuador, UTC-5):** el doc diario representa un día EC
/// cuyo inicio (`dateTs`) es las 05:00 UTC. El `dayOfWeek` viene precalculado
/// del backend con 0=domingo..6=sábado. Aquí NO se recalculan tarifas: el
/// `estimatedRevenue` ya viene sumado en cada diario.
library;

import 'fare_estimate.dart';

/// Un documento diario agregado (de `tripStatsDaily` o `driverStatsDaily`).
class DailyStat {
  /// Fecha del día en formato "YYYY-MM-DD" (hora local EC).
  final String date;

  /// Inicio del día EC expresado en UTC (00:00 EC = 05:00 UTC).
  final DateTime dateTs;

  /// Día de la semana, 0=domingo .. 6=sábado (precalculado por el backend).
  final int dayOfWeek;

  /// Carreras por hora del día {hora 0..23 : conteo}.
  final Map<int, int> tripsByHour;

  /// Total de carreras del día.
  final int totalTrips;

  /// Ingreso ESTIMADO del día (proxy de demanda, NO finanzas reales).
  final double estimatedRevenue;

  const DailyStat({
    required this.date,
    required this.dateTs,
    required this.dayOfWeek,
    required this.tripsByHour,
    required this.totalTrips,
    required this.estimatedRevenue,
  });

  /// Construye un [DailyStat] desde el `data()` crudo de un doc Firestore,
  /// tolerando campos ausentes o tipos inesperados. [dateTsResolver] convierte
  /// el valor crudo de `dateTs` (un `Timestamp`) a [DateTime]; se inyecta para
  /// no acoplar este archivo a cloud_firestore.
  factory DailyStat.fromMap(
    Map<String, dynamic> data, {
    required DateTime Function(dynamic raw) dateTsResolver,
  }) {
    final byHour = <int, int>{};
    final raw = data['tripsByHour'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final h = int.tryParse(k.toString());
        final c = (v as num?)?.toInt() ?? 0;
        if (h != null && h >= 0 && h <= 23) {
          byHour[h] = (byHour[h] ?? 0) + c;
        }
      });
    }
    final date = (data['date'] as String?) ?? '';
    final dateTs = dateTsResolver(data['dateTs']);
    // dayOfWeek viene del backend; si falta, se deriva del dateTs (00:00 EC).
    int dow = (data['dayOfWeek'] as num?)?.toInt() ?? -1;
    if (dow < 0 || dow > 6) {
      // dateTs es 05:00 UTC = medianoche EC; el día EC es dateTs-5h.
      final ec = dateTs.toUtc().subtract(const Duration(hours: 5));
      // Dart: Monday=1..Sunday=7 → mapear a 0=domingo..6=sábado.
      dow = ec.weekday % 7;
    }
    return DailyStat(
      date: date,
      dateTs: dateTs,
      dayOfWeek: dow,
      tripsByHour: byHour,
      totalTrips: (data['totalTrips'] as num?)?.toInt() ?? 0,
      estimatedRevenue: (data['estimatedRevenue'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Un documento diario del embudo de solicitudes web
/// (`tripRequestStatsDaily`). Los contadores son por COHORTE: cuentan según la
/// fecha de la solicitud (no la fecha en que cambió de estado).
///
/// Campos pueden faltar en docs viejos → se tratan como 0.
class TripRequestDaily {
  /// Fecha del día en formato "YYYY-MM-DD" (hora local EC).
  final String date;

  /// Inicio del día EC expresado en UTC (00:00 EC = 05:00 UTC).
  final DateTime dateTs;

  /// Solicitudes recibidas (cohorte del día).
  final int recibidas;

  /// Solicitudes que llegaron a asignarse.
  final int asignadas;

  /// Solicitudes que se finalizaron.
  final int finalizadas;

  /// Solicitudes que se cancelaron.
  final int canceladas;

  const TripRequestDaily({
    required this.date,
    required this.dateTs,
    required this.recibidas,
    required this.asignadas,
    required this.finalizadas,
    required this.canceladas,
  });

  /// Construye desde el `data()` crudo de un doc Firestore, tolerando campos
  /// ausentes o tipos inesperados (→ 0). [dateTsResolver] convierte el `dateTs`
  /// crudo (`Timestamp`) a [DateTime] sin acoplar este archivo a cloud_firestore.
  factory TripRequestDaily.fromMap(
    Map<String, dynamic> data, {
    required DateTime Function(dynamic raw) dateTsResolver,
  }) {
    int n(String k) => (data[k] as num?)?.toInt() ?? 0;
    return TripRequestDaily(
      date: (data['date'] as String?) ?? '',
      dateTs: dateTsResolver(data['dateTs']),
      recibidas: n('recibidas'),
      asignadas: n('asignadas'),
      finalizadas: n('finalizadas'),
      canceladas: n('canceladas'),
    );
  }
}

/// Embudo de solicitudes web agregado de un rango: totales por etapa más las
/// tasas derivadas. Inmutable y sin deps de Firestore.
class FunnelStats {
  final int recibidas;
  final int asignadas;
  final int finalizadas;
  final int canceladas;

  const FunnelStats({
    required this.recibidas,
    required this.asignadas,
    required this.finalizadas,
    required this.canceladas,
  });

  /// Embudo vacío (todo 0).
  static const empty = FunnelStats(
    recibidas: 0,
    asignadas: 0,
    finalizadas: 0,
    canceladas: 0,
  );

  /// `true` si no hubo ninguna solicitud web en el periodo (todo 0).
  bool get isEmpty =>
      recibidas == 0 && asignadas == 0 && finalizadas == 0 && canceladas == 0;

  /// % de cumplimiento = finalizadas / recibidas. `null` si no hay recibidas
  /// (evita división por cero).
  double? get fulfillmentRate =>
      recibidas == 0 ? null : finalizadas / recibidas * 100.0;

  /// % de cancelación = canceladas / recibidas. `null` si no hay recibidas.
  double? get cancellationRate =>
      recibidas == 0 ? null : canceladas / recibidas * 100.0;

  /// % de asignación = asignadas / recibidas. `null` si no hay recibidas.
  double? get assignmentRate =>
      recibidas == 0 ? null : asignadas / recibidas * 100.0;
}

/// Un punto de la serie diaria (para la línea de tendencia).
class DailyPoint {
  final String date; // "YYYY-MM-DD"
  final int totalTrips;
  final double estimatedRevenue;
  const DailyPoint({
    required this.date,
    required this.totalTrips,
    required this.estimatedRevenue,
  });
}

/// Una hora pico: la hora del día (0..23) y su volumen acumulado.
class PeakHour {
  final int hour;
  final int trips;
  const PeakHour(this.hour, this.trips);
}

/// Resultado de comparar dos rangos equivalentes.
class RangeComparison {
  /// Total de carreras del rango actual.
  final int currentTrips;

  /// Total de carreras del rango anterior equivalente.
  final int previousTrips;

  /// % de cambio en carreras (actual vs anterior). `null` si no hay base
  /// previa (no se puede calcular un porcentaje sobre 0).
  final double? tripsChangePct;

  const RangeComparison({
    required this.currentTrips,
    required this.previousTrips,
    required this.tripsChangePct,
  });
}

/// Agregado completo de un rango, listo para la UI.
class AggregatedStats {
  /// Total de carreras del rango.
  final int totalTrips;

  /// Ingreso estimado total del rango (proxy de demanda).
  final double estimatedRevenue;

  /// Carreras por hora combinadas {hora 0..23 : conteo}.
  final Map<int, int> tripsByHour;

  /// Matriz heatmap [dayOfWeek 0..6][hora 0..23] → conteo.
  /// Acceso: `heatmap[dow][hour]`. Siempre 7×24 (rellena con 0).
  final List<List<int>> heatmap;

  /// Serie diaria ordenada por fecha ascendente.
  final List<DailyPoint> dailySeries;

  /// Cantidad de días distintos con al menos una carrera.
  final int daysWithTrips;

  const AggregatedStats({
    required this.totalTrips,
    required this.estimatedRevenue,
    required this.tripsByHour,
    required this.heatmap,
    required this.dailySeries,
    required this.daysWithTrips,
  });

  /// Promedio de carreras por día sobre el número de días con data. Devuelve
  /// 0 si no hay días con carreras (evita división por cero).
  double get averageTripsPerDay =>
      daysWithTrips == 0 ? 0 : totalTrips / daysWithTrips;

  /// Heatmap vacío para estado inicial / sin datos.
  bool get isEmpty => totalTrips == 0;
}

/// Funciones puras de agregación sobre listas de [DailyStat].
class StatsAggregator {
  const StatsAggregator._();

  /// Umbral (en días con carreras) por debajo del cual las comparativas y la
  /// tendencia NO son confiables y se debe mostrar un aviso. El spec sugiere
  /// ~14 días.
  static const int insufficientDataThreshold = 14;

  /// Agrega una lista de diarios en [AggregatedStats].
  static AggregatedStats aggregate(List<DailyStat> dailies) {
    int totalTrips = 0;
    double estimated = 0;
    final byHour = <int, int>{};
    // 7×24 inicializado en 0.
    final heatmap =
        List.generate(7, (_) => List<int>.filled(24, 0), growable: false);
    final series = <DailyPoint>[];
    int daysWithTrips = 0;

    // Orden estable por fecha para la serie/tendencia.
    final sorted = [...dailies]..sort((a, b) => a.date.compareTo(b.date));

    for (final d in sorted) {
      totalTrips += d.totalTrips;
      estimated += d.estimatedRevenue;
      if (d.totalTrips > 0) daysWithTrips++;
      d.tripsByHour.forEach((h, c) {
        byHour[h] = (byHour[h] ?? 0) + c;
        if (h >= 0 && h <= 23 && d.dayOfWeek >= 0 && d.dayOfWeek <= 6) {
          heatmap[d.dayOfWeek][h] += c;
        }
      });
      series.add(DailyPoint(
        date: d.date,
        totalTrips: d.totalTrips,
        estimatedRevenue: d.estimatedRevenue,
      ));
    }

    return AggregatedStats(
      totalTrips: totalTrips,
      estimatedRevenue: estimated,
      tripsByHour: byHour,
      heatmap: heatmap,
      dailySeries: series,
      daysWithTrips: daysWithTrips,
    );
  }

  /// Suma una lista de diarios del embudo (`tripRequestStatsDaily`) en un
  /// único [FunnelStats] (las tasas se derivan en el propio modelo).
  static FunnelStats aggregateFunnel(List<TripRequestDaily> dailies) {
    int recibidas = 0, asignadas = 0, finalizadas = 0, canceladas = 0;
    for (final d in dailies) {
      recibidas += d.recibidas;
      asignadas += d.asignadas;
      finalizadas += d.finalizadas;
      canceladas += d.canceladas;
    }
    return FunnelStats(
      recibidas: recibidas,
      asignadas: asignadas,
      finalizadas: finalizadas,
      canceladas: canceladas,
    );
  }

  /// Top [count] horas por volumen, de mayor a menor. Solo horas con >0.
  static List<PeakHour> peakHours(Map<int, int> tripsByHour, {int count = 3}) {
    final entries = tripsByHour.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) {
        final byVol = b.value.compareTo(a.value);
        return byVol != 0 ? byVol : a.key.compareTo(b.key);
      });
    return entries.take(count).map((e) => PeakHour(e.key, e.value)).toList();
  }

  /// Compara el total de carreras del rango actual vs el anterior.
  static RangeComparison compareTotals({
    required int currentTrips,
    required int previousTrips,
  }) {
    double? pct;
    if (previousTrips > 0) {
      pct = (currentTrips - previousTrips) / previousTrips * 100.0;
    } else if (currentTrips > 0) {
      pct = null; // crecimiento desde 0 no es un % significativo
    } else {
      pct = 0.0;
    }
    return RangeComparison(
      currentTrips: currentTrips,
      previousTrips: previousTrips,
      tripsChangePct: pct,
    );
  }

  /// Carreras totales agrupadas por día de semana (0..6) para la comparativa
  /// "mismo día de semana" (lunes vs lunes, etc.). Siempre largo 7.
  static List<int> tripsByDayOfWeek(List<DailyStat> dailies) {
    final out = List<int>.filled(7, 0);
    for (final d in dailies) {
      if (d.dayOfWeek >= 0 && d.dayOfWeek <= 6) {
        out[d.dayOfWeek] += d.totalTrips;
      }
    }
    return out;
  }

  /// `true` si hay tan pocos días con carreras que la tendencia/comparativas
  /// no son confiables todavía.
  static bool isDataInsufficient(int daysWithTrips) =>
      daysWithTrips < insufficientDataThreshold;
}

/// Cadencias de reporte soportadas.
enum ReportCadence { day, week, month, year }

/// Un rango de fechas resuelto (en hora local EC) más su etiqueta.
class StatsRange {
  /// Inicio del rango: medianoche EC del primer día, como instante UTC
  /// (00:00 EC = 05:00 UTC). Comparable directamente con `dateTs`.
  final DateTime fromTs;

  /// Fin del rango: medianoche EC del último día (inclusive), como UTC.
  final DateTime toTs;

  /// Etiqueta legible ("Hoy", "Esta semana", ...).
  final String label;

  const StatsRange({
    required this.fromTs,
    required this.toTs,
    required this.label,
  });
}

/// Helper PURO de rangos por cadencia, en hora local Ecuador (UTC-5).
///
/// Devuelve [fromTs]/[toTs] alineados a la medianoche EC de cada día expresada
/// como instante UTC (05:00 UTC), de modo que la query `dateTs >= from &&
/// dateTs <= to` capture exactamente los diarios del periodo.
class StatsRanges {
  const StatsRanges._();

  /// Medianoche EC de [y,m,d] como instante UTC (00:00 EC = 05:00 UTC).
  static DateTime ecMidnightUtc(int y, int m, int d) =>
      DateTime.utc(y, m, d, 5);

  /// Convierte un instante UTC "ahora" a la fecha calendario EC (UTC-5).
  static DateTime _ecCalendar(DateTime nowUtc) =>
      nowUtc.toUtc().subtract(const Duration(hours: 5));

  /// Rango para una [cadence] dado el instante actual [now] (cualquier zona;
  /// internamente se normaliza a UTC y se descuenta 5h para obtener el día EC).
  static StatsRange forCadence(ReportCadence cadence, DateTime now) {
    final ec = _ecCalendar(now);
    switch (cadence) {
      case ReportCadence.day:
        final ts = ecMidnightUtc(ec.year, ec.month, ec.day);
        return StatsRange(fromTs: ts, toTs: ts, label: 'Hoy');
      case ReportCadence.week:
        // Lunes..domingo de la semana actual (EC). Dart: Monday=1.
        final monday = ec.subtract(Duration(days: ec.weekday - 1));
        final from = ecMidnightUtc(monday.year, monday.month, monday.day);
        final to = ecMidnightUtc(ec.year, ec.month, ec.day);
        return StatsRange(fromTs: from, toTs: to, label: 'Esta semana');
      case ReportCadence.month:
        final from = ecMidnightUtc(ec.year, ec.month, 1);
        final to = ecMidnightUtc(ec.year, ec.month, ec.day);
        return StatsRange(fromTs: from, toTs: to, label: 'Este mes');
      case ReportCadence.year:
        final from = ecMidnightUtc(ec.year, 1, 1);
        final to = ecMidnightUtc(ec.year, ec.month, ec.day);
        return StatsRange(fromTs: from, toTs: to, label: 'Este año');
    }
  }

  /// Rango anterior equivalente al [current] (misma longitud, contiguo y
  /// terminando justo antes del inicio del actual). Para comparativas.
  static StatsRange previousOf(StatsRange current) {
    // Longitud en días (inclusive). +1 porque from/to son ambos inclusive.
    final spanDays = current.toTs.difference(current.fromTs).inDays + 1;
    final prevTo = current.fromTs.subtract(const Duration(days: 1));
    final prevFrom = prevTo.subtract(Duration(days: spanDays - 1));
    return StatsRange(
      fromTs: prevFrom,
      toTs: prevTo,
      label: 'Periodo anterior',
    );
  }
}

/// Reexport conveniente: la tarifa por hora vive en `fare_estimate.dart`.
/// (No se recalcula aquí; los diarios ya traen `estimatedRevenue`.)
double fareForHourEc(int h) => fareForHour(h);
