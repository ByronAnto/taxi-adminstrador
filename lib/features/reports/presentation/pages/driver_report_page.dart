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
        const SizedBox(height: 24),

        // Carreras por hora
        const Text('Carreras por hora del día',
            style:
                TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        _buildHourBars(r.tripsByHour),
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

  Widget _buildHourBars(Map<int, int> data) {
    if (data.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Sin carreras en este periodo.',
          style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
        ),
      );
    }
    final maxCount = data.values.reduce((a, b) => a > b ? a : b);
    return SizedBox(
      height: 140,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(24, (h) {
          final count = data[h] ?? 0;
          final ratio = maxCount > 0 ? count / maxCount : 0.0;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (count > 0)
                    Text('$count',
                        style: const TextStyle(
                            fontSize: 8, fontWeight: FontWeight.w700)),
                  Container(
                    height: (100 * ratio).clamp(2, 100).toDouble(),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(
                          alpha: count == 0 ? 0.1 : 0.85),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('$h',
                      style: const TextStyle(fontSize: 7, color: Colors.grey)),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
