import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../payments/data/models/payment_model.dart';

enum _OpPeriod { day, week, month, year }

/// Reporte para la operadora con los pagos que ELLA validó en un
/// período. La operadora no debería ver "Caja" ni "Reportes globales"
/// (ambos son del admin), pero sí su propio historial de validaciones.
class OperatorValidationsPage extends StatefulWidget {
  const OperatorValidationsPage({super.key});

  @override
  State<OperatorValidationsPage> createState() =>
      _OperatorValidationsPageState();
}

class _OperatorValidationsPageState extends State<OperatorValidationsPage> {
  _OpPeriod _period = _OpPeriod.day;
  bool _loading = true;
  String? _error;
  List<PaymentModel> _items = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadWhenReady());
  }

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
      _error = 'No se pudo cargar la sesión.';
    });
  }

  (DateTime, DateTime, String) _range() {
    final now = DateTime.now();
    switch (_period) {
      case _OpPeriod.day:
        return (DateTime(now.year, now.month, now.day), now, 'Hoy');
      case _OpPeriod.week:
        final monday = now.subtract(Duration(days: now.weekday - 1));
        return (
          DateTime(monday.year, monday.month, monday.day),
          now,
          'Esta semana'
        );
      case _OpPeriod.month:
        return (DateTime(now.year, now.month, 1), now, 'Este mes');
      case _OpPeriod.year:
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
    final me = auth.user;
    setState(() {
      _loading = true;
      _error = null;
    });
    final (from, to, _) = _range();
    try {
      final snap = await FirebaseFirestore.instance
          .collection('payments')
          .where('validatedBy', isEqualTo: me.uid)
          .where('validatedAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(from))
          .where('validatedAt',
              isLessThanOrEqualTo: Timestamp.fromDate(to))
          .orderBy('validatedAt', descending: true)
          .limit(500)
          .get();
      final items = snap.docs.map(PaymentModel.fromFirestore).toList();
      if (!mounted) return;
      setState(() {
        _items = items;
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
    final fmtMoney = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final fmtDate = DateFormat('dd MMM HH:mm', 'es');
    final total = _items.fold<double>(0, (s, p) => s + p.amount);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis validaciones'),
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
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<_OpPeriod>(
              segments: const [
                ButtonSegment(value: _OpPeriod.day, label: Text('Hoy')),
                ButtonSegment(value: _OpPeriod.week, label: Text('Semana')),
                ButtonSegment(value: _OpPeriod.month, label: Text('Mes')),
                ButtonSegment(value: _OpPeriod.year, label: Text('Año')),
              ],
              selected: {_period},
              onSelectionChanged: (s) {
                setState(() => _period = s.first);
                _load();
              },
            ),
          ),
          if (!_loading && _error == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: _kpi(
                        'Validados',
                        '${_items.length}',
                        Icons.fact_check_outlined,
                        AppTheme.primaryColor),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _kpi(
                        'Total \$',
                        fmtMoney.format(total),
                        Icons.attach_money,
                        Colors.green.shade700),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _buildError(_error!)
                    : _items.isEmpty
                        ? const Center(
                            child: Text('Sin validaciones en el periodo'))
                        : ListView.separated(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _items.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (ctx, i) {
                              final p = _items[i];
                              return ListTile(
                                dense: true,
                                leading: const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                ),
                                title: Text(
                                  p.driverName ?? p.driverId,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700),
                                ),
                                subtitle: Text(
                                  '${p.concept} · ${p.validatedAt != null ? fmtDate.format(p.validatedAt!) : "—"}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: Text(
                                  fmtMoney.format(p.amount),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: Colors.green.shade700,
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
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

  Widget _buildError(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 56, color: Colors.red.shade400),
            const SizedBox(height: 12),
            const Text('No pudimos cargar tus validaciones',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(error,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
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
}
