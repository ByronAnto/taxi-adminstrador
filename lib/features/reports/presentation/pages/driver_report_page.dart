import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/analytics_report_service.dart';
import '../../data/driver_report_service.dart';
import '../../data/drivers_summary_service.dart';
import '../../data/report_export_service.dart';
import '../../data/stats_aggregator.dart';
import '../widgets/analytics_widgets.dart';

/// Reporte detallado del conductor en un periodo.
///
/// Permite al conductor ver sus carreras por hora/día/total, y al admin
/// ver el reporte de cualquier socio. La ruta acepta `?driverId=&name=`
/// query params para apuntar al conductor.
class DriverReportPage extends StatefulWidget {
  /// Si null, se usa el uid del usuario autenticado (caso conductor
  /// viendo su propio reporte).
  final String? driverId;
  final String? driverName;

  const DriverReportPage({
    super.key,
    this.driverId,
    this.driverName,
  });

  @override
  State<DriverReportPage> createState() => _DriverReportPageState();
}

enum _Period { day, week, month, year }

class _DriverReportPageState extends State<DriverReportPage> {
  _Period _period = _Period.week;
  DriverPeriodReport? _data;

  /// Analítica del conductor desde el agregado `driverStatsDaily` (heatmap y
  /// horas pico de "cuándo me conviene conectarme"). Complementa a [_data],
  /// que viene de las carreras crudas del propio conductor.
  AnalyticsReport? _analytics;

  /// Ranking del propio conductor (top X%, puesto N de M) desde su doc en
  /// `drivers`. `null` si el cron aún no corrió o no aplica (admin viendo a
  /// otro conductor → se carga el del target).
  DriverRanking? _ranking;
  bool _loading = true; // Arranca true para mostrar spinner desde el inicio
  String? _error;

  ReportCadence get _cadence {
    switch (_period) {
      case _Period.day:
        return ReportCadence.day;
      case _Period.week:
        return ReportCadence.week;
      case _Period.month:
        return ReportCadence.month;
      case _Period.year:
        return ReportCadence.year;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadWhenReady());
  }

  /// Espera a que el AuthBloc esté listo antes de cargar — en cold-start
  /// rápido la página puede construirse antes de que llegue
  /// `AuthAuthenticated`, lo que dejaba la pantalla en blanco.
  Future<void> _loadWhenReady() async {
    for (int i = 0; i < 25; i++) {
      if (!mounted) return;
      final auth = context.read<AuthBloc>().state;
      if (auth is AuthAuthenticated) {
        if (!mounted) return;
        await _load();
        return;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = 'No se pudo cargar la sesión. Cierra y vuelve a abrir la app.';
    });
  }

  (DateTime, DateTime, String) _periodRange() {
    final now = DateTime.now();
    switch (_period) {
      case _Period.day:
        final s = DateTime(now.year, now.month, now.day);
        return (s, now, 'Hoy');
      case _Period.week:
        final monday = now.subtract(Duration(days: now.weekday - 1));
        final s = DateTime(monday.year, monday.month, monday.day);
        return (s, now, 'Esta semana');
      case _Period.month:
        return (DateTime(now.year, now.month, 1), now, 'Este mes');
      case _Period.year:
        return (DateTime(now.year, 1, 1), now, 'Este año');
    }
  }

  Future<void> _load() async {
    final auth = context.read<AuthBloc>().state;
    if (auth is! AuthAuthenticated) {
      setState(() {
        _loading = false;
        _error = 'Sesión no disponible.';
      });
      return;
    }
    final user = auth.user;
    final targetId = widget.driverId ?? user.uid;
    final targetName = widget.driverName ??
        '${user.name} ${user.lastname}'.trim();
    final aid = user.associationId;
    setState(() {
      _loading = true;
      _error = null;
    });
    final (from, to, label) = _periodRange();
    try {
      // Reporte de carreras crudas (origen, pago, destinos) + analítica desde
      // el agregado `driverStatsDaily` (heatmap, horas pico) en paralelo.
      final results = await Future.wait([
        DriverReportService.instance.build(
          driverId: targetId,
          driverName: targetName,
          associationId: aid,
          fromDate: from,
          toDate: to,
          periodLabel: label,
        ),
        AnalyticsReportService.instance
            .buildDriverReport(driverId: targetId, cadence: _cadence)
            // Si el agregado no está disponible aún, no rompe el reporte.
            .catchError((_) => AnalyticsReport.empty(
                _cadence, StatsRanges.forCadence(_cadence, DateTime.now()))),
        // Ranking del conductor (degrada a null por su cuenta si falta/falla).
        DriversSummaryService.instance.fetchDriverRanking(uid: targetId),
      ]);
      if (!mounted) return;
      setState(() {
        _data = results[0] as DriverPeriodReport;
        _analytics = results[1] as AnalyticsReport;
        _ranking = results[2] as DriverRanking?;
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
    final df = DateFormat('dd MMM yyyy', 'es');
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.driverName != null
            ? 'Reporte: ${widget.driverName}'
            : 'Mi reporte'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        actions: [
          _buildExportMenu(),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildPeriodSelector(),
          if (_data != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Text(
                '${df.format(_data!.fromDate)} – ${df.format(_data!.toDate)}',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: AppTheme.textSecondary),
              ),
            ),
          Expanded(
            child: _loading
                ? const LoadingState(message: 'Cargando reporte…')
                : _error != null
                    ? ErrorState(message: _error!, onRetry: _load)
                    : _data == null
                        ? const EmptyState(
                            icon: Icons.bar_chart,
                            title: 'Sin datos',
                          )
                        : _buildBody(_data!),
          ),
        ],
      ),
    );
  }

  Widget _buildPeriodSelector() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: SegmentedButton<_Period>(
        segments: const [
          ButtonSegment(value: _Period.day, label: Text('Hoy')),
          ButtonSegment(value: _Period.week, label: Text('Semana')),
          ButtonSegment(value: _Period.month, label: Text('Mes')),
          ButtonSegment(value: _Period.year, label: Text('Año')),
        ],
        selected: {_period},
        onSelectionChanged: (s) {
          setState(() => _period = s.first);
          _load();
        },
      ),
    );
  }

  /// Menú "Exportar → PDF / CSV" del reporte del conductor. Usa la analítica
  /// ya cargada (`driverStatsDaily`); deshabilitado si no hay datos.
  Widget _buildExportMenu() {
    final canExport = !_loading &&
        _analytics != null &&
        !_analytics!.current.isEmpty;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.ios_share),
      tooltip: 'Exportar',
      enabled: canExport,
      onSelected: _export,
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
    final a = _analytics;
    if (a == null) return;
    final title = widget.driverName != null
        ? 'Reporte: ${widget.driverName}'
        : 'Mi reporte';
    try {
      if (kind == 'pdf') {
        await ReportExportService.instance
            .sharePdf(report: a, title: title, isDriver: true);
      } else {
        await ReportExportService.instance
            .shareCsv(report: a, title: title, isDriver: true);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo exportar: $e')),
      );
    }
  }

  Widget _buildBody(DriverPeriodReport r) {
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final sectionStyle =
        textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800);
    // Comparativa WoW/MoM/YoY del total de carreras (desde driverStatsDaily):
    // solo Semana/Mes/Año, con data suficiente y base previa.
    final cmpLabel = comparisonLabelFor(_cadence);
    final showTrend = cmpLabel != null &&
        _analytics != null &&
        !_analytics!.dataInsufficient &&
        _analytics!.comparison.tripsChangePct != null;
    final trendPct = _analytics?.comparison.tripsChangePct;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        // Tarjeta motivacional de ranking (top X%, puesto N de M). Sin nombres
        // de otros conductores; se oculta si el cron aún no la calculó.
        if (_ranking != null) ...[
          _RankingCard(ranking: _ranking!),
          const SizedBox(height: AppSpacing.md),
        ],
        // KPIs
        Row(
          children: [
            Expanded(
              child: _kpi(
                  'Carreras',
                  '${r.totalTrips}',
                  Icons.directions_car,
                  scheme.secondary,
                  changePct: showTrend ? trendPct : null,
                  changeLabel: cmpLabel),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _kpi(
                  'Ingresos',
                  fmt.format(r.totalIncome),
                  Icons.attach_money,
                  AppTheme.successColor),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _kpi(
                  'Promedio',
                  fmt.format(r.averageFare),
                  Icons.trending_up,
                  AppTheme.categorical[7]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _kpi(
                  'Días con carrera',
                  '${r.dailyTrips.length}',
                  Icons.calendar_today,
                  AppTheme.categorical[2]),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Estimado por tarifa mínima de Quito (UTC-5): el propio vs el de la
        // base (asociación). Sirve cuando no se registra el cobro real.
        Row(
          children: [
            Expanded(
              child: _kpi(
                  'Mi estimado',
                  fmt.format(r.estimatedRevenue),
                  Icons.calculate_outlined,
                  AppTheme.categorical[1]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _kpi(
                  'Estimado base',
                  fmt.format(r.associationEstimatedRevenue),
                  Icons.groups_outlined,
                  AppTheme.infoColor),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),

        // Carreras por origen
        Text('Carreras por origen', style: sectionStyle),
        const SizedBox(height: AppSpacing.sm),
        _buildSourceBreakdown(r.tripsBySource),
        const SizedBox(height: AppSpacing.xl),

        // Mi heatmap + mis horas pico (desde `driverStatsDaily`).
        if (_analytics != null && !_analytics!.current.isEmpty) ...[
          Text('Mis horas pico', style: sectionStyle),
          const SizedBox(height: AppSpacing.sm),
          PeakHoursChips(peaks: _analytics!.peaks),
          const SizedBox(height: AppSpacing.xl),
          Text('Cuándo me conviene conectarme (día × hora)',
              style: sectionStyle),
          const SizedBox(height: AppSpacing.sm),
          DowHourHeatmap(heatmap: _analytics!.current.heatmap),
          const SizedBox(height: AppSpacing.xl),
        ],

        // Carreras por hora (mías + asociación)
        Text('Carreras por hora del día', style: sectionStyle),
        const SizedBox(height: AppSpacing.sm),
        _buildHourBars(r.tripsByHour, r.associationTripsByHour),
        const SizedBox(height: AppSpacing.xl),

        // Carreras por día
        Text('Carreras y \$ por día', style: sectionStyle),
        const SizedBox(height: AppSpacing.sm),
        if (r.dailyTrips.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Text(
              'Sin carreras en este periodo.',
              style: textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                  fontStyle: FontStyle.italic),
            ),
          )
        else
          Column(
            children: (r.dailyTrips.entries.toList()
                  ..sort((a, b) => b.key.compareTo(a.key)))
                .map((e) {
              final dayKey = e.key;
              final count = e.value;
              final income = r.dailyIncome[dayKey] ?? 0;
              return Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  side: BorderSide(color: Colors.grey.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.event,
                      color: scheme.secondary, size: 20),
                  title: Text(dayKey,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700)),
                  subtitle: Text('$count carrera${count == 1 ? "" : "s"}'),
                  trailing: Text(
                    fmt.format(income),
                    style: const TextStyle(
                        color: AppTheme.successColor,
                        fontWeight: FontWeight.w800),
                  ),
                ),
              );
            }).toList(),
          ),
        const SizedBox(height: AppSpacing.xl),

        // Métodos de pago
        Text('Métodos de pago', style: sectionStyle),
        const SizedBox(height: AppSpacing.sm),
        for (final entry in r.tripsByPaymentMethod.entries)
          ListTile(
            dense: true,
            leading: Icon(
              entry.key == 'transferencia'
                  ? Icons.swap_horiz
                  : Icons.attach_money,
              color: scheme.secondary,
            ),
            title: Text(entry.key == 'transferencia'
                ? 'Transferencia'
                : 'Efectivo'),
            trailing: Text('${entry.value}',
                style: const TextStyle(
                    fontWeight: FontWeight.w800)),
          ),
        const SizedBox(height: AppSpacing.xl),

        // Top destinos
        if (r.topDestinations.isNotEmpty) ...[
          Text('Destinos frecuentes', style: sectionStyle),
          const SizedBox(height: AppSpacing.sm),
          for (final d in (r.topDestinations.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value)))
              .take(5))
            ListTile(
              dense: true,
              leading: const Icon(Icons.place_outlined,
                  color: AppTheme.warningColor),
              title: Text(d.key),
              trailing: Text('${d.value}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800)),
            ),
        ],
      ],
    );
  }

  Widget _kpi(String label, String value, IconData icon, Color color,
      {double? changePct, String? changeLabel}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: color.withValues(alpha: 0.85),
                      fontWeight: FontWeight.w700)),
            ),
            if (changePct != null) TrendBadge(pct: changePct),
          ]),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: color)),
          if (changePct != null && changeLabel != null) ...[
            const SizedBox(height: 2),
            Text(changeLabel,
                style: const TextStyle(
                    fontSize: 10, color: AppTheme.textSecondary)),
          ],
        ],
      ),
    );
  }

  Widget _buildHourBars(
    Map<int, int> myData,
    Map<int, int> assocData,
  ) {
    if (myData.isEmpty && assocData.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Text(
          'Sin carreras en este periodo.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppTheme.textSecondary,
              fontStyle: FontStyle.italic),
        ),
      );
    }

    // Calcular máximo global para escalar ambas series juntas
    final allValues = [
      ...myData.values,
      ...assocData.values,
    ];
    final maxCount =
        allValues.isEmpty ? 1 : allValues.reduce((a, b) => a > b ? a : b);

    // Dos series categóricas: mías (naranja) vs base (azul/info).
    final mineColor = AppTheme.categorical[6];
    const assocColor = AppTheme.infoColor;
    final labelStyle = Theme.of(context).textTheme.labelSmall;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Leyenda
        Row(
          children: [
            Container(width: 12, height: 12,
                decoration: BoxDecoration(
                    color: mineColor,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: AppSpacing.xs),
            Text('Mis carreras', style: labelStyle),
            const SizedBox(width: AppSpacing.md),
            Container(width: 12, height: 12,
                decoration: BoxDecoration(
                    color: assocColor.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: AppSpacing.xs),
            Text('Total de la base', style: labelStyle),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 130,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(24, (h) {
              final mine = myData[h] ?? 0;
              final assoc = assocData[h] ?? 0;
              final myRatio = maxCount > 0 ? mine / maxCount : 0.0;
              final assocRatio = maxCount > 0 ? assoc / maxCount : 0.0;
              // Show label every 3 hours
              final showLabel = h % 3 == 0;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // Stacked: assoc bar behind (wider, semi-transparent)
                      // then my bar on top
                      Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          // Association bar (info, behind)
                          Container(
                            height: (100 * assocRatio).clamp(1, 100).toDouble(),
                            decoration: BoxDecoration(
                              color: assocColor.withValues(
                                  alpha: assoc == 0 ? 0.05 : 0.35),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          // My bar (categorical, front)
                          Container(
                            height: (100 * myRatio).clamp(
                                mine == 0 ? 0 : 2, 100).toDouble(),
                            decoration: BoxDecoration(
                              color: mineColor.withValues(
                                  alpha: mine == 0 ? 0 : 0.9),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        showLabel ? '$h' : '',
                        style: labelStyle?.copyWith(
                            color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildSourceBreakdown(Map<String, int> bySource) {
    // Definición de labels e íconos por origen
    final sources = [
      ('standQueue', 'Sacadas de la base', Icons.queue),
      ('street', 'Calle', Icons.traffic),
      ('manual', '+1 carrera (yo)', Icons.add_circle_outline),
      ('apkOperadora', 'Operadora', Icons.assignment),
      ('walkieTalkie', 'Radio', Icons.radio),
      ('webCliente', 'Cliente web', Icons.language),
    ];

    final hasData = sources.any((s) => (bySource[s.$1] ?? 0) > 0);

    if (!hasData) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Text(
          'Aún no se han registrado carreras con origen detallado.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary,
              fontStyle: FontStyle.italic),
        ),
      );
    }

    final visible = sources.where((s) => (bySource[s.$1] ?? 0) > 0).toList();

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: List.generate(visible.length, (i) {
        final s = visible[i];
        final count = bySource[s.$1] ?? 0;
        final color = AppTheme.categorical[
            sources.indexWhere((x) => x.$1 == s.$1) %
                AppTheme.categorical.length];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(s.$3, size: 14, color: color),
              const SizedBox(width: 5),
              Text(s.$2,
                  style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('$count',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: color)),
            ],
          ),
        );
      }),
    );
  }
}

/// Tarjeta motivacional con el ranking propio del conductor: "Estás en el
/// top X%" + "Puesto N de M". Tono positivo (verde/secundario), nunca
/// punitivo, y sin exponer datos de otros conductores.
class _RankingCard extends StatelessWidget {
  final DriverRanking ranking;
  const _RankingCard({required this.ranking});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    const color = AppTheme.successColor;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: 0.14),
            color.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.emoji_events_outlined,
                size: 26, color: color),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Estás en el top ${ranking.topPercent}%',
                  style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900, color: color),
                ),
                const SizedBox(height: 2),
                Text(
                  'Puesto ${ranking.rank} de ${ranking.totalDrivers} '
                  'conductores de tu base.',
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
