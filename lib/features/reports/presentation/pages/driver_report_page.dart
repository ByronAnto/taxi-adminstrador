import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/driver_report_service.dart';

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
  bool _loading = true; // Arranca true para mostrar spinner desde el inicio
  String? _error;

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
      final report = await DriverReportService.instance.build(
        driverId: targetId,
        driverName: targetName,
        associationId: aid,
        fromDate: from,
        toDate: to,
        periodLabel: label,
      );
      if (!mounted) return;
      setState(() {
        _data = report;
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
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '${df.format(_data!.fromDate)} – ${df.format(_data!.toDate)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _buildErrorState(_error!)
                    : _data == null
                        ? const Center(child: Text('Sin datos'))
                        : _buildBody(_data!),
          ),
        ],
      ),
    );
  }

  Widget _buildPeriodSelector() {
    return Padding(
      padding: const EdgeInsets.all(12),
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

  Widget _buildBody(DriverPeriodReport r) {
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // KPIs
        Row(
          children: [
            Expanded(
              child: _kpi(
                  'Carreras',
                  '${r.totalTrips}',
                  Icons.directions_car,
                  AppTheme.primaryColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _kpi(
                  'Ingresos',
                  fmt.format(r.totalIncome),
                  Icons.attach_money,
                  Colors.green.shade700),
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
                  Colors.amber.shade800),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _kpi(
                  'Días con carrera',
                  '${r.dailyTrips.length}',
                  Icons.calendar_today,
                  Colors.purple.shade700),
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
                  Colors.teal.shade700),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _kpi(
                  'Estimado base',
                  fmt.format(r.associationEstimatedRevenue),
                  Icons.groups_outlined,
                  Colors.blue.shade700),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // Carreras por origen
        const Text('Carreras por origen',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        _buildSourceBreakdown(r.tripsBySource),
        const SizedBox(height: 24),

        // Carreras por hora (mías + asociación)
        const Text('Carreras por hora del día',
            style:
                TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        _buildHourBars(r.tripsByHour, r.associationTripsByHour),
        const SizedBox(height: 24),

        // Carreras por día
        const Text('Carreras y \$ por día',
            style:
                TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (r.dailyTrips.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Sin carreras en este periodo.',
              style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
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
                  leading: const Icon(Icons.event,
                      color: AppTheme.primaryColor, size: 20),
                  title: Text(dayKey,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700)),
                  subtitle: Text('$count carrera${count == 1 ? "" : "s"}'),
                  trailing: Text(
                    fmt.format(income),
                    style: TextStyle(
                        color: Colors.green.shade700,
                        fontWeight: FontWeight.w800),
                  ),
                ),
              );
            }).toList(),
          ),
        const SizedBox(height: 24),

        // Métodos de pago
        const Text('Métodos de pago',
            style:
                TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        for (final entry in r.tripsByPaymentMethod.entries)
          ListTile(
            dense: true,
            leading: Icon(
              entry.key == 'transferencia'
                  ? Icons.swap_horiz
                  : Icons.attach_money,
              color: AppTheme.primaryColor,
            ),
            title: Text(entry.key == 'transferencia'
                ? 'Transferencia'
                : 'Efectivo'),
            trailing: Text('${entry.value}',
                style: const TextStyle(
                    fontWeight: FontWeight.w800)),
          ),
        const SizedBox(height: 24),

        // Top destinos
        if (r.topDestinations.isNotEmpty) ...[
          const Text('Destinos frecuentes',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          for (final d in (r.topDestinations.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value)))
              .take(5))
            ListTile(
              dense: true,
              leading: const Icon(Icons.place_outlined,
                  color: Colors.orange),
              title: Text(d.key),
              trailing: Text('${d.value}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800)),
            ),
        ],
      ],
    );
  }

  Widget _kpi(String label, String value, IconData icon, Color color) {
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
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    color: color.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: color)),
        ],
      ),
    );
  }

  Widget _buildErrorState(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 56, color: Colors.red.shade400),
            const SizedBox(height: 12),
            const Text(
              'No pudimos cargar el reporte',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHourBars(
    Map<int, int> myData,
    Map<int, int> assocData,
  ) {
    if (myData.isEmpty && assocData.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Sin carreras en este periodo.',
          style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Leyenda
        Row(
          children: [
            Container(width: 12, height: 12,
                decoration: BoxDecoration(
                    color: Colors.amber.shade700,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 4),
            const Text('Mis carreras', style: TextStyle(fontSize: 10)),
            const SizedBox(width: 12),
            Container(width: 12, height: 12,
                decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 4),
            const Text('Total de la base', style: TextStyle(fontSize: 10)),
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
                          // Association bar (blue, behind)
                          Container(
                            height: (100 * assocRatio).clamp(1, 100).toDouble(),
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(
                                  alpha: assoc == 0 ? 0.05 : 0.35),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          // My bar (amber, front)
                          Container(
                            height: (100 * myRatio).clamp(
                                mine == 0 ? 0 : 2, 100).toDouble(),
                            decoration: BoxDecoration(
                              color: Colors.amber.shade700.withValues(
                                  alpha: mine == 0 ? 0 : 0.9),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        showLabel ? '$h' : '',
                        style: const TextStyle(
                            fontSize: 7, color: Colors.grey),
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
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Aún no se han registrado carreras con origen detallado.',
          style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic, fontSize: 12),
        ),
      );
    }

    final colors = [
      Colors.orange.shade700,
      Colors.teal.shade600,
      Colors.purple.shade600,
      Colors.blue.shade700,
      Colors.red.shade600,
      Colors.green.shade700,
    ];

    final visible = sources.where((s) => (bySource[s.$1] ?? 0) > 0).toList();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(visible.length, (i) {
        final s = visible[i];
        final count = bySource[s.$1] ?? 0;
        final color = colors[sources.indexWhere((x) => x.$1 == s.$1) % colors.length];
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
