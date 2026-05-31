import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../../core/services/current_user_context.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/analytics_report_service.dart';
import '../../data/drivers_summary_service.dart';
import '../../data/report_export_service.dart';
import '../../data/stats_aggregator.dart';
import '../widgets/analytics_widgets.dart';

/// Reporte analítico de la BASE (admin/operadora).
///
/// Lee los agregados diarios desplegados (`tripStatsDaily`) en vez de las
/// carreras crudas: KPIs, heatmap día-de-semana × hora (vista estrella),
/// barras por hora, línea de tendencia y comparativa vs el periodo anterior.
/// El `associationId` sale de [CurrentUserContext] (con respaldo del AuthBloc).
class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  ReportCadence _cadence = ReportCadence.week;
  AnalyticsReport? _report;
  AssociationRating _rating = AssociationRating.empty;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadWhenReady());
  }

  /// El associationId puede venir del contexto global o, como respaldo, del
  /// AuthBloc (en cold-start el contexto puede llegar un instante después).
  Future<void> _loadWhenReady() async {
    for (var i = 0; i < 25; i++) {
      if (!mounted) return;
      if (_resolveAssociationId() != null) {
        await _load();
        return;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = 'No se pudo determinar la asociación del usuario.';
    });
  }

  String? _resolveAssociationId() {
    final fromCtx = CurrentUserContext.instance.associationId;
    if (fromCtx != null && fromCtx.isNotEmpty) return fromCtx;
    final auth = context.read<AuthBloc>().state;
    if (auth is AuthAuthenticated && auth.user.associationId.isNotEmpty) {
      return auth.user.associationId;
    }
    return null;
  }

  Future<void> _load() async {
    final aid = _resolveAssociationId();
    if (aid == null) {
      setState(() {
        _loading = false;
        _error = 'No se pudo determinar la asociación del usuario.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // El reporte es lo crítico; el rating de la base es secundario y degrada
      // a vacío por su cuenta (no rompe la carga si falla/permiso).
      final results = await Future.wait([
        AnalyticsReportService.instance
            .buildAssociationReport(associationId: aid, cadence: _cadence),
        DriversSummaryService.instance.fetchAssociationRating(associationId: aid),
      ]);
      if (!mounted) return;
      setState(() {
        _report = results[0] as AnalyticsReport;
        _rating = results[1] as AssociationRating;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reportes'),
        actions: [
          _buildExportMenu(),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: CadenceSelector(
              value: _cadence,
              onChanged: (c) {
                setState(() => _cadence = c);
                _load();
              },
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// Menú "Exportar → PDF / CSV". Deshabilitado mientras no haya un reporte
  /// cargado (no hay datos que exportar).
  Widget _buildExportMenu() {
    final canExport = !_loading && _report != null;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.ios_share),
      tooltip: 'Exportar',
      enabled: canExport,
      onSelected: (v) => _export(v),
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'pdf',
          child: ListTile(
            leading: Icon(Icons.picture_as_pdf_outlined),
            title: Text('Exportar a PDF'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'csv',
          child: ListTile(
            leading: Icon(Icons.table_view_outlined),
            title: Text('Exportar a CSV'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }

  Future<void> _export(String kind) async {
    final r = _report;
    if (r == null) return;
    const title = 'Reporte de la base';
    try {
      if (kind == 'pdf') {
        await ReportExportService.instance
            .sharePdf(report: r, title: title, rating: _rating);
      } else {
        await ReportExportService.instance
            .shareCsv(report: r, title: title, rating: _rating);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo exportar: $e')),
      );
    }
  }

  Widget _buildBody() {
    if (_loading) {
      return const LoadingState(message: 'Generando reporte…');
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _load);
    }
    final r = _report;
    if (r == null) {
      return const EmptyState(
        icon: Icons.bar_chart,
        title: 'Sin datos en este período',
      );
    }
    return _ReportContent(report: r, rating: _rating);
  }
}

// ============================================================================

class _ReportContent extends StatelessWidget {
  final AnalyticsReport report;
  final AssociationRating rating;
  const _ReportContent({required this.report, required this.rating});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = report.current;
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    // Comparativa WoW/MoM/YoY: solo en Semana/Mes/Año (no en "Hoy") y solo si
    // hay suficiente data y base de comparación (pct != null).
    final cmpLabel = comparisonLabelFor(report.cadence);
    final showTrend = cmpLabel != null && !report.dataInsufficient;
    final pct = showTrend ? report.comparison.tripsChangePct : null;

    if (c.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _RangeLabel(report: report),
          const SizedBox(height: AppSpacing.xl),
          const EmptyState(
            icon: Icons.bar_chart,
            title: 'Sin datos en este período',
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _RangeLabel(report: report),
        const SizedBox(height: AppSpacing.md),
        if (report.dataInsufficient) ...[
          InsufficientDataNotice(daysWithTrips: c.daysWithTrips),
          const SizedBox(height: AppSpacing.lg),
        ],
        // KPIs
        Row(
          children: [
            Expanded(
              child: AnalyticsKpiCard(
                label: 'Total carreras',
                value: '${c.totalTrips}',
                icon: Icons.local_taxi,
                color: scheme.secondary,
                changePct: pct,
                changeLabel: cmpLabel,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: AnalyticsKpiCard(
                label: 'Ingreso estimado',
                value: fmt.format(c.estimatedRevenue),
                icon: Icons.calculate_outlined,
                color: AppTheme.categorical[0],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: AnalyticsKpiCard(
                label: 'Carreras/día (prom.)',
                value: c.averageTripsPerDay.toStringAsFixed(1),
                icon: Icons.trending_up,
                color: AppTheme.statusFree,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: AnalyticsKpiCard(
                label: 'Días con carreras',
                value: '${c.daysWithTrips}',
                icon: Icons.calendar_today,
                color: AppTheme.infoColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        // Rating promedio ponderado de la base (solo reporte de BASE).
        Row(
          children: [
            Expanded(
              child: AnalyticsKpiCard(
                label: rating.hasRatings
                    ? '${rating.ratingCount} calificaciones'
                    : 'Sin calificaciones aún',
                value: rating.hasRatings
                    ? 'Rating ⭐ ${rating.average!.toStringAsFixed(1)}'
                    : '⭐ —',
                icon: Icons.star_outline,
                color: AppTheme.warningColor,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'El "ingreso estimado" es un proxy de demanda (tarifa mínima), '
          'no el ingreso real.',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 20),

        // Embudo de solicitudes web (recibidas → asignadas → finalizadas)
        if (report.funnel != null) ...[
          const SectionTitle(
              icon: Icons.filter_alt_outlined,
              text: 'Embudo de solicitudes web',
              color: AppTheme.infoColor),
          const SizedBox(height: AppSpacing.sm),
          RequestFunnelSection(funnel: report.funnel!),
          const SizedBox(height: AppSpacing.xl),
        ],

        // Heatmap (vista estrella)
        const SectionTitle(
            icon: Icons.grid_on,
            text: 'Mapa de calor (día × hora)',
            color: AppTheme.warningColor),
        const SizedBox(height: AppSpacing.sm),
        DowHourHeatmap(heatmap: c.heatmap),
        const SizedBox(height: AppSpacing.xl),

        // Horas pico
        const SectionTitle(
            icon: Icons.schedule,
            text: 'Horas pico',
            color: AppTheme.warningColor),
        const SizedBox(height: AppSpacing.sm),
        PeakHoursChips(peaks: report.peaks),
        const SizedBox(height: AppSpacing.xl),

        // Carreras por hora
        SectionTitle(
            icon: Icons.show_chart,
            text: 'Carreras por hora',
            color: scheme.secondary),
        const SizedBox(height: AppSpacing.md),
        TripsByHourBars(tripsByHour: c.tripsByHour),
        const SizedBox(height: AppSpacing.xl),

        // Tendencia diaria
        const SectionTitle(
            icon: Icons.bar_chart,
            text: 'Tendencia de carreras por día',
            color: AppTheme.statusFree),
        const SizedBox(height: AppSpacing.md),
        DailyTrendLine(series: c.dailySeries),
        const SizedBox(height: AppSpacing.xl),

        // Comparativa por día de semana (solo en vista semanal)
        if (report.cadence == ReportCadence.week) ...[
          SectionTitle(
              icon: Icons.compare_arrows,
              text: 'Mismo día vs semana anterior',
              color: AppTheme.categorical[0]),
          const SizedBox(height: AppSpacing.md),
          DayOfWeekComparison(
            current: report.tripsByDayOfWeek,
            previous: report.previousTripsByDayOfWeek,
          ),
          const SizedBox(height: AppSpacing.xl),
        ],
      ],
    );
  }
}

class _RangeLabel extends StatelessWidget {
  final AnalyticsReport report;
  const _RangeLabel({required this.report});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd MMM', 'es');
    // dateTs es 05:00 UTC; el día EC es -5h.
    DateTime ec(DateTime ts) => ts.toUtc().subtract(const Duration(hours: 5));
    final from = df.format(ec(report.range.fromTs));
    final to = df.format(ec(report.range.toTs));
    return Text(
      '${report.range.label} · $from – $to',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppTheme.textSecondary, fontWeight: FontWeight.w600),
    );
  }
}

