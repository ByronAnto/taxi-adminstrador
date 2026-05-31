import 'stats_aggregator.dart';
import 'stats_range_datasource.dart';

/// Reporte analítico completo de un rango, listo para pintar en la UI.
///
/// Combina el agregado del rango actual con el del rango anterior equivalente
/// (para comparativas) y precalcula horas pico, comparativa por día de semana
/// y el flag de "datos insuficientes". Es inmutable y sin deps de Firestore.
class AnalyticsReport {
  /// Rango efectivo consultado (fechas + etiqueta).
  final StatsRange range;

  /// Cadencia seleccionada.
  final ReportCadence cadence;

  /// Agregado del rango actual.
  final AggregatedStats current;

  /// Comparativa de totales vs el periodo anterior equivalente.
  final RangeComparison comparison;

  /// Horas pico del rango (top por volumen).
  final List<PeakHour> peaks;

  /// Carreras por día de semana (0=Dom..6=Sáb) del rango actual.
  final List<int> tripsByDayOfWeek;

  /// Carreras por día de semana del periodo anterior (para lunes-vs-lunes).
  final List<int> previousTripsByDayOfWeek;

  /// `true` si hay tan pocos días con data que las comparativas/tendencia no
  /// son confiables aún.
  final bool dataInsufficient;

  /// Embudo de solicitudes web del rango (recibidas→asignadas→finalizadas +
  /// canceladas y sus tasas). Solo se llena en el reporte de la BASE; en el
  /// reporte de conductor es `null` (no aplica).
  final FunnelStats? funnel;

  const AnalyticsReport({
    required this.range,
    required this.cadence,
    required this.current,
    required this.comparison,
    required this.peaks,
    required this.tripsByDayOfWeek,
    required this.previousTripsByDayOfWeek,
    required this.dataInsufficient,
    this.funnel,
  });

  /// Reporte vacío (sin red), útil para estados iniciales.
  factory AnalyticsReport.empty(ReportCadence cadence, StatsRange range) {
    final empty = StatsAggregator.aggregate(const []);
    return AnalyticsReport(
      range: range,
      cadence: cadence,
      current: empty,
      comparison: const RangeComparison(
        currentTrips: 0,
        previousTrips: 0,
        tripsChangePct: 0.0,
      ),
      peaks: const [],
      tripsByDayOfWeek: List<int>.filled(7, 0),
      previousTripsByDayOfWeek: List<int>.filled(7, 0),
      dataInsufficient: true,
    );
  }
}

/// Servicio de lectura de analítica. Orquesta [StatsRangeDatasource] +
/// [StatsAggregator]. Una sola instancia compartida (como
/// `DriverReportService`), pero acepta inyección para tests.
class AnalyticsReportService {
  final StatsRangeDatasource _ds;

  AnalyticsReportService({StatsRangeDatasource? datasource})
      : _ds = datasource ?? StatsRangeDatasource();

  /// Instancia compartida por defecto (Firestore real).
  static final AnalyticsReportService instance = AnalyticsReportService();

  /// Construye el reporte de la BASE (admin/operadora) para una [cadence].
  Future<AnalyticsReport> buildAssociationReport({
    required String associationId,
    required ReportCadence cadence,
    DateTime? now,
  }) {
    return _build(
      cadence: cadence,
      now: now ?? DateTime.now(),
      fetch: (range) =>
          _ds.fetchAssociationRange(associationId: associationId, range: range),
      // Embudo de solicitudes web: solo aplica al reporte de la base.
      fetchFunnel: (range) =>
          _ds.fetchTripRequestRange(associationId: associationId, range: range),
    );
  }

  /// Construye el reporte de un CONDUCTOR para una [cadence].
  Future<AnalyticsReport> buildDriverReport({
    required String driverId,
    required ReportCadence cadence,
    DateTime? now,
  }) {
    return _build(
      cadence: cadence,
      now: now ?? DateTime.now(),
      fetch: (range) => _ds.fetchDriverRange(driverId: driverId, range: range),
    );
  }

  Future<AnalyticsReport> _build({
    required ReportCadence cadence,
    required DateTime now,
    required Future<List<DailyStat>> Function(StatsRange range) fetch,
    Future<List<TripRequestDaily>> Function(StatsRange range)? fetchFunnel,
  }) async {
    final range = StatsRanges.forCadence(cadence, now);
    final prevRange = StatsRanges.previousOf(range);

    final currentDailies = await fetch(range);
    // El rango anterior es solo para comparativas; si falla, se trata como 0.
    List<DailyStat> prevDailies = const [];
    try {
      prevDailies = await fetch(prevRange);
    } catch (_) {
      prevDailies = const [];
    }

    // Embudo de solicitudes web (mismo rango que el resto). Solo presente en
    // el reporte de la base; si falla la lectura, se trata como sin datos.
    FunnelStats? funnel;
    if (fetchFunnel != null) {
      try {
        funnel = StatsAggregator.aggregateFunnel(await fetchFunnel(range));
      } catch (_) {
        funnel = FunnelStats.empty;
      }
    }

    final current = StatsAggregator.aggregate(currentDailies);
    final prev = StatsAggregator.aggregate(prevDailies);

    return AnalyticsReport(
      range: range,
      cadence: cadence,
      current: current,
      comparison: StatsAggregator.compareTotals(
        currentTrips: current.totalTrips,
        previousTrips: prev.totalTrips,
      ),
      peaks: StatsAggregator.peakHours(current.tripsByHour),
      tripsByDayOfWeek: StatsAggregator.tripsByDayOfWeek(currentDailies),
      previousTripsByDayOfWeek: StatsAggregator.tripsByDayOfWeek(prevDailies),
      dataInsufficient:
          StatsAggregator.isDataInsufficient(current.daysWithTrips),
      funnel: funnel,
    );
  }
}
