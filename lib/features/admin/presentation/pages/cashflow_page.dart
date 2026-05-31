import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/services/excel_export_service.dart';
import '../../../../core/services/pdf_export_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../reports/data/weekly_closing_service.dart';
import '../../data/models/cashflow_model.dart';

/// Agregados de ingresos/egresos/balance de un período, reutilizable para el
/// período actual y el anterior (comparativa).
class _CashTotals {
  final double ingresos;
  final double egresos;
  double get balance => ingresos - egresos;
  const _CashTotals(this.ingresos, this.egresos);

  factory _CashTotals.of(Iterable<CashflowMovement> movs) {
    var ing = 0.0;
    var egr = 0.0;
    for (final m in movs) {
      if (m.isIngreso) {
        ing += m.monto;
      } else {
        egr += m.monto;
      }
    }
    return _CashTotals(ing, egr);
  }
}

/// Un bucket del gráfico de barras: etiqueta del eje X + totales del sub-período.
class _CashBucket {
  final String label;
  double ingresos = 0;
  double egresos = 0;
  _CashBucket(this.label);
  double get balance => ingresos - egresos;
}

/// Pantalla "Caja" del admin: resumen, movimientos y pagos a operadoras.
///
/// Multi-tenant: filtra siempre por la `associationId` del admin logueado.
/// La colección Firestore es `cashflow/{}`.
class CashflowPage extends StatefulWidget {
  const CashflowPage({super.key});

  @override
  State<CashflowPage> createState() => _CashflowPageState();
}

class _CashflowPageState extends State<CashflowPage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  String _period = 'month'; // day | week | month | year

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  DateTime get _periodStart {
    final now = DateTime.now();
    switch (_period) {
      case 'day':
        return DateTime(now.year, now.month, now.day);
      case 'week':
        return now.subtract(Duration(days: now.weekday - 1));
      case 'year':
        return DateTime(now.year, 1, 1);
      case 'month':
      default:
        return DateTime(now.year, now.month, 1);
    }
  }

  /// Inicio del período inmediatamente anterior, del mismo largo calendario.
  DateTime get _prevPeriodStart {
    final start = _periodStart;
    switch (_period) {
      case 'day':
        return start.subtract(const Duration(days: 1));
      case 'week':
        return start.subtract(const Duration(days: 7));
      case 'year':
        return DateTime(start.year - 1, 1, 1);
      case 'month':
      default:
        return DateTime(start.year, start.month - 1, 1);
    }
  }

  /// Fin (exclusivo) del período anterior: coincide con el inicio del actual.
  DateTime get _prevPeriodEnd => _periodStart;

  /// Texto "vs día/semana/mes/año anterior" según [_period].
  String get _comparisonLabel {
    switch (_period) {
      case 'day':
        return 'vs día anterior';
      case 'week':
        return 'vs semana anterior';
      case 'year':
        return 'vs año anterior';
      case 'month':
      default:
        return 'vs mes anterior';
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _stream(String aid) {
    return FirebaseFirestore.instance
        .collection('cashflow')
        .where('associationId', isEqualTo: aid)
        .where('fecha',
            isGreaterThanOrEqualTo: Timestamp.fromDate(_periodStart))
        .orderBy('fecha', descending: true)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) {
      return const Scaffold(body: LoadingState());
    }
    final aid = auth.user.associationId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Caja'),
        actions: [
          IconButton(
            tooltip: 'Categorías',
            icon: const Icon(Icons.category_outlined),
            onPressed: () => context.push('/cashflow-categories'),
          ),
          IconButton(
            tooltip: 'Exportar Excel',
            icon: const Icon(Icons.table_chart),
            onPressed: () => _exportExcel(aid),
          ),
          IconButton(
            tooltip: 'Exportar PDF',
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: () => _exportPdf(aid),
          ),
          PopupMenuButton<String>(
            tooltip: 'Cierres',
            icon: const Icon(Icons.assignment_outlined),
            onSelected: (v) {
              if (v == 'weekly') _showWeeklyClosingDialog(aid);
              if (v == 'monthly') _showMonthlyClosingDialog(aid);
              if (v == 'annual') _showAnnualClosingDialog(aid);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'weekly',
                  child: Row(children: [
                    Icon(Icons.calendar_view_week, size: 18),
                    SizedBox(width: 8),
                    Text('Cierre semanal'),
                  ])),
              PopupMenuItem(
                  value: 'monthly',
                  child: Row(children: [
                    Icon(Icons.calendar_month, size: 18),
                    SizedBox(width: 8),
                    Text('Cierre mensual'),
                  ])),
              PopupMenuItem(
                  value: 'annual',
                  child: Row(children: [
                    Icon(Icons.calendar_today, size: 18),
                    SizedBox(width: 8),
                    Text('Cierre anual'),
                  ])),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Resumen', icon: Icon(Icons.dashboard, size: 20)),
            Tab(text: 'Movimientos', icon: Icon(Icons.list, size: 20)),
            Tab(text: 'Operadoras', icon: Icon(Icons.headset_mic, size: 20)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddMovement(context, aid, auth.user.uid),
        icon: const Icon(Icons.add),
        label: const Text('Movimiento'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _stream(aid),
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorState.fromError(snap.error);
          }
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const LoadingState();
          }
          final docs = snap.data?.docs ?? [];
          final movs = docs
              .map((d) => CashflowMovement.fromFirestore(d))
              .toList();
          return Column(
            children: [
              _buildPeriodFilter(),
              Expanded(
                child: TabBarView(
                  controller: _tab,
                  children: [
                    _buildSummary(movs, aid),
                    _buildMovements(movs),
                    _buildOperadoras(movs),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPeriodFilter() {
    final periods = {
      'day': 'Día',
      'week': 'Semana',
      'month': 'Mes',
      'year': 'Año',
    };
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: periods.entries.map((e) {
          final isSelected = _period == e.key;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text(e.value),
              selected: isSelected,
              onSelected: (_) => setState(() => _period = e.key),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSummary(List<CashflowMovement> movs, String aid) {
    final totals = _CashTotals.of(movs);
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);

    // Comparativa: traemos el período anterior y, cuando llega, recalculamos
    // los KPIs con badges de % de cambio. Mientras tanto / si falla, se
    // muestran los KPIs sin badge (degradación con gracia).
    return FutureBuilder<_CashTotals?>(
      // key liga el future al período activo para refrescar al cambiar de chip.
      key: ValueKey('prev_$_period'),
      future: _loadPreviousTotals(aid),
      builder: (context, prevSnap) {
        final prev = prevSnap.data;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _kpi(
                'Ingresos',
                fmt.format(totals.ingresos),
                Icons.trending_up,
                AppTheme.successColor,
                // Ingresos: subir es bueno → mejora si sube.
                changePct: _pctChange(prev?.ingresos, totals.ingresos),
                improvesWhenUp: true,
              ),
              const SizedBox(height: AppSpacing.md),
              _kpi(
                'Egresos',
                fmt.format(totals.egresos),
                Icons.trending_down,
                AppTheme.errorColor,
                // Egresos: subir es malo → mejora si baja.
                changePct: _pctChange(prev?.egresos, totals.egresos),
                improvesWhenUp: false,
              ),
              const SizedBox(height: AppSpacing.md),
              _kpi(
                'Balance',
                fmt.format(totals.balance),
                Icons.account_balance_wallet,
                totals.balance >= 0
                    ? AppTheme.infoColor
                    : AppTheme.errorColor,
                // Balance: subir es bueno.
                changePct: _pctChange(prev?.balance, totals.balance),
                improvesWhenUp: true,
              ),
              const SizedBox(height: AppSpacing.xl),
              Text('Tendencia del período',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              _buildCharts(movs, fmt),
              const SizedBox(height: AppSpacing.xl),
              Text('Por categoría',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ..._byCategory(movs, CashflowType.ingreso, fmt),
              if (movs.any((m) => m.isEgreso)) ...[
                const Divider(),
                ..._byCategory(movs, CashflowType.egreso, fmt),
              ],
            ],
          ),
        );
      },
    );
  }

  /// % de cambio de [current] respecto a [previous]. Devuelve `null` cuando no
  /// hay base de comparación (período anterior nulo o con valor 0), para
  /// mostrar "—" sin badge.
  double? _pctChange(double? previous, double current) {
    if (previous == null) return null;
    if (previous == 0) return null;
    return (current - previous) / previous.abs() * 100;
  }

  /// Consulta el rango previo `[prevStart, prevEnd)` en `cashflow` respetando
  /// el multi-tenant `aid`. Degrada a `null` ante cualquier error.
  Future<_CashTotals?> _loadPreviousTotals(String aid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('cashflow')
          .where('associationId', isEqualTo: aid)
          .where('fecha',
              isGreaterThanOrEqualTo: Timestamp.fromDate(_prevPeriodStart))
          .where('fecha', isLessThan: Timestamp.fromDate(_prevPeriodEnd))
          .get();
      final movs = snap.docs.map(CashflowMovement.fromFirestore);
      return _CashTotals.of(movs);
    } catch (_) {
      return null;
    }
  }

  // ==========================================================================
  // Gráficos (fl_chart): barras agrupadas Ingresos/Egresos + línea de balance.
  // ==========================================================================

  /// Agrupa los movimientos del período actual en sub-buckets según [_period]:
  /// día → 2 barras (total ing vs egr); week → Lun..Dom; month → semanas del
  /// mes; year → Ene..Dic.
  List<_CashBucket> _bucketize(List<CashflowMovement> movs) {
    final start = _periodStart;
    switch (_period) {
      case 'week':
        {
          const labels = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
          final buckets = [for (final l in labels) _CashBucket(l)];
          for (final m in movs) {
            final idx = (m.fecha.weekday - 1).clamp(0, 6);
            _add(buckets[idx], m);
          }
          return buckets;
        }
      case 'month':
        {
          // Semanas del mes por número de semana calendario (1..n).
          final lastDay = DateTime(start.year, start.month + 1, 0).day;
          final nWeeks = (((start.weekday - 1) + lastDay) / 7).ceil();
          final buckets = [
            for (var i = 0; i < nWeeks; i++) _CashBucket('S${i + 1}')
          ];
          for (final m in movs) {
            final dayIdx = m.fecha.day - 1;
            final wk = ((start.weekday - 1) + dayIdx) ~/ 7;
            if (wk >= 0 && wk < buckets.length) _add(buckets[wk], m);
          }
          return buckets;
        }
      case 'year':
        {
          const labels = [
            'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
            'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'
          ];
          final buckets = [for (final l in labels) _CashBucket(l)];
          for (final m in movs) {
            final idx = (m.fecha.month - 1).clamp(0, 11);
            _add(buckets[idx], m);
          }
          return buckets;
        }
      case 'day':
      default:
        {
          // Día: 2 barras agregadas (Ingresos vs Egresos) para evitar ruido.
          final b = _CashBucket('Hoy');
          for (final m in movs) {
            _add(b, m);
          }
          return [b];
        }
    }
  }

  void _add(_CashBucket b, CashflowMovement m) {
    if (m.isIngreso) {
      b.ingresos += m.monto;
    } else {
      b.egresos += m.monto;
    }
  }

  Widget _buildCharts(List<CashflowMovement> movs, NumberFormat fmt) {
    if (movs.isEmpty) {
      return _chartPlaceholder('Sin movimientos en este período');
    }
    final buckets = _bucketize(movs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _chartLegend(),
        const SizedBox(height: AppSpacing.sm),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 12, 8),
            child: _IncomeExpenseBars(buckets: buckets),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Icon(Icons.show_chart, size: 16, color: AppTheme.infoColor),
            const SizedBox(width: 6),
            Text('Balance por sub-período',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 12, 8),
            child: _BalanceLine(buckets: buckets),
          ),
        ),
      ],
    );
  }

  Widget _chartLegend() {
    Widget item(Color c, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                    color: c, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        );
    return Row(
      children: [
        item(AppTheme.successColor, 'Ingresos'),
        const SizedBox(width: AppSpacing.lg),
        item(AppTheme.errorColor, 'Egresos'),
      ],
    );
  }

  Widget _chartPlaceholder(String msg) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_chart_outlined,
                  size: 36, color: Colors.grey[400]),
              const SizedBox(height: 8),
              Text(msg,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[500], fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _byCategory(List<CashflowMovement> movs, CashflowType tipo,
      NumberFormat fmt) {
    final filtered = movs.where((m) => m.tipo == tipo);
    final byCat = <String, double>{};
    for (final m in filtered) {
      byCat[m.categoria] = (byCat[m.categoria] ?? 0) + m.monto;
    }
    if (byCat.isEmpty) return [];
    final sorted = byCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        child: Text(
          tipo == CashflowType.ingreso ? 'Ingresos' : 'Egresos',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: tipo == CashflowType.ingreso
                    ? AppTheme.successColor
                    : AppTheme.errorColor,
              ),
        ),
      ),
      ...sorted.map((e) => ListTile(
            dense: true,
            title: Text(e.key),
            trailing: Text(fmt.format(e.value),
                style: const TextStyle(fontWeight: FontWeight.w600)),
          )),
    ];
  }

  Widget _kpi(String label, String value, IconData icon, Color color,
      {double? changePct, bool improvesWhenUp = true}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 36, color: color),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textSecondary)),
                  const SizedBox(height: AppSpacing.xs),
                  Text(value,
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(color: color)),
                  if (changePct != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    _comparisonRow(changePct, improvesWhenUp),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Fila de comparativa: badge ↑/↓ coloreado por "mejora" (no por signo) +
  /// el texto "vs … anterior". Para ingresos/balance mejora = subir; para
  /// egresos mejora = bajar ([improvesWhenUp] = false).
  Widget _comparisonRow(double pct, bool improvesWhenUp) {
    final improved =
        pct == 0 ? null : (improvesWhenUp ? pct > 0 : pct < 0);
    final color = improved == null
        ? Colors.grey
        : (improved ? AppTheme.successColor : AppTheme.errorColor);
    final arrow = pct == 0
        ? ''
        : (pct > 0 ? '↑ ' : '↓ ');
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$arrow${pct.abs().toStringAsFixed(0)}%',
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            _comparisonLabel,
            style: const TextStyle(
                fontSize: 11, color: AppTheme.textSecondary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildMovements(List<CashflowMovement> movs) {
    if (movs.isEmpty) {
      return const EmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'Sin movimientos en el período',
      );
    }
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: movs.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.xs),
      itemBuilder: (_, i) {
        final m = movs[i];
        final color =
            m.isIngreso ? AppTheme.successColor : AppTheme.errorColor;
        return Dismissible(
          key: ValueKey(m.uid),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: AppSpacing.xl),
            color: AppTheme.errorColor,
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (_) => _confirmDelete(m),
          onDismissed: (_) => _deleteMovement(m),
          child: Card(
            child: ListTile(
              leading: Icon(
                m.isIngreso ? Icons.add_circle : Icons.remove_circle,
                color: color,
              ),
              title: Text(m.categoria),
              subtitle: Text(
                [
                  if (m.descripcion != null && m.descripcion!.isNotEmpty)
                    m.descripcion,
                  if (m.beneficiario != null && m.beneficiario!.isNotEmpty)
                    '→ ${m.beneficiario}',
                  DateFormat('dd MMM yyyy').format(m.fecha),
                ].whereType<String>().join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                '${m.isIngreso ? '+' : '-'}${fmt.format(m.monto)}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                    ),
              ),
              onTap: () => _editMovement(m),
            ),
          ),
        );
      },
    );
  }

  Future<bool?> _confirmDelete(CashflowMovement m) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar movimiento'),
        content: Text(
            '¿Seguro que quieres borrar este ${m.isIngreso ? "ingreso" : "egreso"} de ${m.categoria} por \$${m.monto.toStringAsFixed(2)}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.errorColor),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteMovement(CashflowMovement m) async {
    try {
      await FirebaseFirestore.instance
          .collection('cashflow')
          .doc(m.uid)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Movimiento borrado')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  void _editMovement(CashflowMovement m) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddMovementForm(
        associationId: m.associationId,
        createdBy: m.createdBy,
        existing: m,
      ),
    );
  }

  Widget _buildOperadoras(List<CashflowMovement> movs) {
    final pagosOp = movs
        .where((m) =>
            m.isEgreso && m.categoria.toLowerCase().contains('operadora'))
        .toList();
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final total = pagosOp.fold<double>(0, (s, m) => s + m.monto);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: _kpi('Pagado a operadoras', fmt.format(total),
              Icons.headset_mic, AppTheme.categorical[2]),
        ),
        Expanded(
          child: pagosOp.isEmpty
              ? const EmptyState(
                  icon: Icons.headset_mic_outlined,
                  title: 'Sin pagos a operadoras',
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md),
                  children: pagosOp.map((m) {
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.headset_mic),
                        title: Text(m.beneficiario ?? '(sin beneficiario)'),
                        subtitle: Text(DateFormat('dd MMM yyyy').format(m.fecha)),
                        trailing: Text(
                          '-${fmt.format(m.monto)}',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: AppTheme.errorColor),
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }

  Future<void> _exportExcel(String aid) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Generando Excel…')),
    );
    try {
      final docs = await FirebaseFirestore.instance
          .collection('cashflow')
          .where('associationId', isEqualTo: aid)
          .where('fecha',
              isGreaterThanOrEqualTo: Timestamp.fromDate(_periodStart))
          .orderBy('fecha', descending: true)
          .get();
      final movs = docs.docs.map(CashflowMovement.fromFirestore).toList();
      final assocName =
          await ExcelExportService.instance.loadAssociationName(aid);
      final periodLabel = {
            'day': 'Hoy',
            'week': 'Esta semana',
            'month': 'Este mes',
            'year': 'Este año',
          }[_period] ??
          'Período';
      final bytes = ExcelExportService.instance.buildCashflowReport(
        associationName: assocName,
        movements: movs,
        periodStart: _periodStart,
        periodEnd: DateTime.now(),
        periodLabel: periodLabel,
      );
      await ExcelExportService.instance.share(
        bytes,
        fileName:
            'caja_${aid}_${DateFormat('yyyyMMdd').format(DateTime.now())}.xlsx',
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error generando Excel: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  Future<void> _exportPdf(String aid) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Generando PDF…')),
    );
    try {
      final docs = await FirebaseFirestore.instance
          .collection('cashflow')
          .where('associationId', isEqualTo: aid)
          .where('fecha',
              isGreaterThanOrEqualTo: Timestamp.fromDate(_periodStart))
          .orderBy('fecha', descending: true)
          .get();
      final movs = docs.docs.map(CashflowMovement.fromFirestore).toList();
      final assoc = await PdfExportService.instance.loadAssociation(aid);
      final periodLabel = {
            'day': 'Hoy',
            'week': 'Esta semana',
            'month': 'Este mes',
            'year': 'Este año',
          }[_period] ??
          'Período';
      final bytes = await PdfExportService.instance.buildCashflowReport(
        associationName: assoc.name,
        logoUrl: assoc.logoUrl,
        primaryColor: assoc.primary,
        movements: movs,
        periodStart: _periodStart,
        periodEnd: DateTime.now(),
        periodLabel: periodLabel,
      );
      await PdfExportService.instance.share(
        bytes,
        fileName:
            'caja_${aid}_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error generando PDF: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  /// Muestra dialog para elegir semana (lunes anterior, esta semana,
  /// otra) y genera el cierre semanal estilo Excel del admin en PDF
  /// o Excel real.
  Future<void> _showWeeklyClosingDialog(String aid) async {
    final now = DateTime.now();
    // Lunes de esta semana (DateTime.monday == 1).
    final mondayThisWeek =
        DateTime(now.year, now.month, now.day - (now.weekday - 1));
    final sundayThisWeek = mondayThisWeek.add(const Duration(days: 6));
    final mondayPrev = mondayThisWeek.subtract(const Duration(days: 7));
    final sundayPrev = mondayPrev.add(const Duration(days: 6));
    DateTime selStart = mondayThisWeek;
    DateTime selEnd = sundayThisWeek;
    final df = DateFormat('dd MMM', 'es');

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        Widget radio(String label, DateTime s, DateTime e) {
          final selected = selStart == s;
          return RadioListTile<DateTime>(
            value: s,
            groupValue: selStart,
            onChanged: (v) => setLocal(() {
              selStart = s;
              selEnd = e;
            }),
            title: Text(label),
            subtitle: Text('${df.format(s)} – ${df.format(e)}'),
            selected: selected,
          );
        }

        return AlertDialog(
          title: const Text('Cierre semanal'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Genera el reporte semanal de la administración con el '
                'formato del Excel manual (unidades, operadoras, '
                'gastos, sobrante).',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              radio('Esta semana', mondayThisWeek, sundayThisWeek),
              radio('Semana pasada', mondayPrev, sundayPrev),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.calendar_today),
                title: const Text('Otro rango…'),
                onTap: () async {
                  final picked = await showDateRangePicker(
                    context: ctx,
                    firstDate: DateTime(2024),
                    lastDate: DateTime(2030),
                    initialDateRange:
                        DateTimeRange(start: selStart, end: selEnd),
                  );
                  if (picked != null) {
                    setLocal(() {
                      selStart = picked.start;
                      selEnd = picked.end;
                    });
                  }
                },
                subtitle: Text(
                  '${df.format(selStart)} – ${df.format(selEnd)}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            TextButton.icon(
              onPressed: () => Navigator.pop(ctx, 'excel'),
              icon: const Icon(Icons.table_chart),
              label: const Text('Excel'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, 'pdf'),
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('PDF'),
            ),
          ],
        );
      }),
    );
    if (action == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
        content: Text(action == 'pdf'
            ? 'Generando PDF…'
            : 'Generando Excel…')));
    try {
      // Normalizar el rango: 00:00 inicio, 23:59 fin.
      final from = DateTime(selStart.year, selStart.month, selStart.day);
      final to =
          DateTime(selEnd.year, selEnd.month, selEnd.day, 23, 59, 59);
      final report = await WeeklyClosingService.instance.build(
        associationId: aid,
        weekStart: from,
        weekEnd: to,
      );
      final ymd = DateFormat('yyyyMMdd').format(from);
      if (action == 'pdf') {
        final assoc = await PdfExportService.instance.loadAssociation(aid);
        final bytes = await PdfExportService.instance.buildWeeklyClosingPdf(
          report: report,
          logoUrl: assoc.logoUrl,
          primaryColor: assoc.primary,
        );
        await PdfExportService.instance.share(
          bytes,
          fileName: 'cierre_semanal_$ymd.pdf',
        );
      } else {
        final bytes =
            ExcelExportService.instance.buildWeeklyClosingReport(report);
        await ExcelExportService.instance.share(
          bytes,
          fileName: 'cierre_semanal_$ymd.xlsx',
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  Future<void> _showMonthlyClosingDialog(String aid) async {
    final now = DateTime.now();
    int year = now.year;
    int month = now.month;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        const monthNames = [
          '', 'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
          'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
        ];
        return AlertDialog(
          title: const Text('Cierre mensual'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Reporte con todas las semanas del mes + saldo acumulado del mes anterior. Replica el formato del Excel del admin.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: month,
                decoration: const InputDecoration(
                  labelText: 'Mes',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: List.generate(
                    12,
                    (i) => DropdownMenuItem(
                          value: i + 1,
                          child: Text(monthNames[i + 1]),
                        )),
                onChanged: (v) => setLocal(() => month = v ?? month),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: year,
                decoration: const InputDecoration(
                  labelText: 'Año',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (int y = now.year - 2; y <= now.year + 1; y++)
                    DropdownMenuItem(value: y, child: Text('$y'))
                ],
                onChanged: (v) => setLocal(() => year = v ?? year),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar')),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, 'pdf'),
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('PDF'),
            ),
          ],
        );
      }),
    );
    if (action == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
        content: Text('Generando cierre mensual… (puede tomar unos segundos)')));
    try {
      final report = await WeeklyClosingService.instance.buildMonth(
        associationId: aid,
        year: year,
        month: month,
      );
      // Cachear el balance final para el siguiente mes.
      await WeeklyClosingService.instance.cacheMonthlyBalance(report);
      final assoc = await PdfExportService.instance.loadAssociation(aid);
      final bytes = await PdfExportService.instance.buildMonthlyClosingPdf(
        report: report,
        logoUrl: assoc.logoUrl,
        primaryColor: assoc.primary,
      );
      await PdfExportService.instance.share(
        bytes,
        fileName:
            'cierre_mensual_${year}_${month.toString().padLeft(2, '0')}.pdf',
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: AppTheme.errorColor,
      ));
    }
  }

  Future<void> _showAnnualClosingDialog(String aid) async {
    final now = DateTime.now();
    int year = now.year;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: const Text('Cierre anual'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Reporte de los 12 meses con sobrante acumulado.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: AppTheme.warningColor),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      'Este reporte agrega 12 meses × N semanas, puede '
                      'tardar un minuto.',
                      style: TextStyle(
                          fontSize: 11, fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: year,
                decoration: const InputDecoration(
                  labelText: 'Año',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (int y = now.year - 2; y <= now.year + 1; y++)
                    DropdownMenuItem(value: y, child: Text('$y'))
                ],
                onChanged: (v) => setLocal(() => year = v ?? year),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar')),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, 'pdf'),
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('PDF'),
            ),
          ],
        );
      }),
    );
    if (action == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
        const SnackBar(content: Text('Generando cierre anual…')));
    try {
      final report = await WeeklyClosingService.instance.buildYear(
        associationId: aid,
        year: year,
      );
      final assoc = await PdfExportService.instance.loadAssociation(aid);
      final bytes = await PdfExportService.instance.buildAnnualClosingPdf(
        report: report,
        logoUrl: assoc.logoUrl,
        primaryColor: assoc.primary,
      );
      await PdfExportService.instance.share(
        bytes,
        fileName: 'cierre_anual_$year.pdf',
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: AppTheme.errorColor,
      ));
    }
  }

  void _showAddMovement(
      BuildContext context, String aid, String adminUid) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _AddMovementForm(associationId: aid, createdBy: adminUid),
    );
  }
}

class _AddMovementForm extends StatefulWidget {
  final String associationId;
  final String createdBy;

  /// Si se pasa un movimiento existente, el form entra en modo edición.
  final CashflowMovement? existing;

  const _AddMovementForm({
    required this.associationId,
    required this.createdBy,
    this.existing,
  });

  @override
  State<_AddMovementForm> createState() => _AddMovementFormState();
}

class _AddMovementFormState extends State<_AddMovementForm> {
  final _form = GlobalKey<FormState>();
  late CashflowType _tipo;
  String? _categoria;
  late final TextEditingController _monto;
  late final TextEditingController _beneficiario;
  late final TextEditingController _descripcion;
  String? _metodo;
  late DateTime _fecha;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    _tipo = ex?.tipo ?? CashflowType.ingreso;
    _categoria = ex?.categoria;
    _monto = TextEditingController(
        text: ex == null ? '' : ex.monto.toStringAsFixed(2));
    _beneficiario = TextEditingController(text: ex?.beneficiario ?? '');
    _descripcion = TextEditingController(text: ex?.descripcion ?? '');
    _metodo = ex?.metodoPago;
    _fecha = ex?.fecha ?? DateTime.now();
  }

  @override
  void dispose() {
    _monto.dispose();
    _beneficiario.dispose();
    _descripcion.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_categoria == null) return;
    setState(() => _saving = true);
    final ex = widget.existing;
    final isEditing = ex != null;
    final mov = CashflowMovement(
      uid: ex?.uid ?? const Uuid().v4(),
      associationId: widget.associationId,
      tipo: _tipo,
      categoria: _categoria!,
      monto: double.parse(_monto.text.replaceAll(',', '.')),
      fecha: _fecha,
      metodoPago: _metodo,
      beneficiario: _beneficiario.text.trim().isEmpty
          ? null
          : _beneficiario.text.trim(),
      descripcion: _descripcion.text.trim().isEmpty
          ? null
          : _descripcion.text.trim(),
      createdBy: widget.createdBy,
      createdAt: ex?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );
    try {
      await FirebaseFirestore.instance
          .collection('cashflow')
          .doc(mov.uid)
          .set(mov.toFirestore());
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isEditing
                ? 'Movimiento actualizado'
                : (_tipo == CashflowType.ingreso
                    ? 'Ingreso registrado'
                    : 'Egreso registrado')),
            backgroundColor: AppTheme.successColor,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({List<String> ingresos, List<String> egresos})>(
      future: _loadCategories(widget.associationId),
      builder: (context, snap) {
        final cats = (_tipo == CashflowType.ingreso
                ? snap.data?.ingresos
                : snap.data?.egresos) ??
            (_tipo == CashflowType.ingreso
                ? DefaultCashflowCategories.ingresos
                : DefaultCashflowCategories.egresos);
        // El categoría seleccionada puede no estar en la lista (cuando el
        // admin la borró pero el doc aún la usa); la mantenemos visible.
        final items = {..._categoria == null ? <String>{} : {_categoria!}, ...cats}
            .toList();
        return _buildBody(items);
      },
    );
  }

  Future<({List<String> ingresos, List<String> egresos})> _loadCategories(
      String aid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .get();
      final cf = doc.data()?['cashflowCategories'] as Map<String, dynamic>?;
      if (cf == null) {
        return (
          ingresos: DefaultCashflowCategories.ingresos,
          egresos: DefaultCashflowCategories.egresos,
        );
      }
      final ing = (cf['ingresos'] as List?)?.cast<String>() ??
          DefaultCashflowCategories.ingresos;
      final egr = (cf['egresos'] as List?)?.cast<String>() ??
          DefaultCashflowCategories.egresos;
      return (ingresos: ing, egresos: egr);
    } catch (_) {
      return (
        ingresos: DefaultCashflowCategories.ingresos,
        egresos: DefaultCashflowCategories.egresos,
      );
    }
  }

  Widget _buildBody(List<String> cats) {

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.existing != null
                    ? 'Editar movimiento'
                    : (_tipo == CashflowType.ingreso
                        ? 'Nuevo ingreso'
                        : 'Nuevo egreso'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.md),
              SegmentedButton<CashflowType>(
                segments: const [
                  ButtonSegment(
                    value: CashflowType.ingreso,
                    label: Text('Ingreso'),
                    icon: Icon(Icons.trending_up),
                  ),
                  ButtonSegment(
                    value: CashflowType.egreso,
                    label: Text('Egreso'),
                    icon: Icon(Icons.trending_down),
                  ),
                ],
                selected: {_tipo},
                onSelectionChanged: (s) => setState(() {
                  _tipo = s.first;
                  _categoria = null;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _categoria,
                decoration: const InputDecoration(
                  labelText: 'Categoría *',
                  border: OutlineInputBorder(),
                ),
                items: cats
                    .map((c) =>
                        DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setState(() => _categoria = v),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Requerido' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _monto,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Monto *',
                  prefixText: '\$ ',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final d = double.tryParse((v ?? '').replaceAll(',', '.'));
                  if (d == null || d <= 0) return 'Monto inválido';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _beneficiario,
                decoration: const InputDecoration(
                  labelText: 'Beneficiario / De quién',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descripcion,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Descripción',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _metodo,
                decoration: const InputDecoration(
                  labelText: 'Método de pago',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                      value: 'efectivo', child: Text('Efectivo')),
                  DropdownMenuItem(
                      value: 'transferencia', child: Text('Transferencia')),
                  DropdownMenuItem(
                      value: 'deposito', child: Text('Depósito')),
                ],
                onChanged: (v) => setState(() => _metodo = v),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Fecha'),
                      subtitle:
                          Text(DateFormat('dd MMM yyyy').format(_fecha)),
                      trailing: const Icon(Icons.calendar_today),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _fecha,
                          firstDate:
                              DateTime.now().subtract(const Duration(days: 365)),
                          lastDate:
                              DateTime.now().add(const Duration(days: 1)),
                        );
                        if (picked != null) {
                          setState(() => _fecha = picked);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(_saving ? 'Guardando...' : 'Guardar'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Gráficos de caja (fl_chart)
// ============================================================================

/// Barras agrupadas Ingresos (verde) vs Egresos (rojo) por sub-bucket del
/// período. Etiquetas del eje X según el bucketing (días, semanas, meses…).
class _IncomeExpenseBars extends StatelessWidget {
  final List<_CashBucket> buckets;
  const _IncomeExpenseBars({required this.buckets});

  @override
  Widget build(BuildContext context) {
    var maxV = 0.0;
    for (final b in buckets) {
      if (b.ingresos > maxV) maxV = b.ingresos;
      if (b.egresos > maxV) maxV = b.egresos;
    }
    if (maxV <= 0) maxV = 1;
    final fmt = NumberFormat.compactCurrency(symbol: '\$', decimalDigits: 0);

    return SizedBox(
      height: 220,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxV * 1.2,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, gIndex, rod, rIndex) {
                final b = buckets[group.x];
                final isIng = rIndex == 0;
                return BarTooltipItem(
                  '${b.label}\n${isIng ? 'Ingresos' : 'Egresos'}: '
                  '\$${rod.toY.toStringAsFixed(2)}',
                  const TextStyle(color: Colors.white, fontSize: 12),
                );
              },
            ),
          ),
          titlesData: FlTitlesData(
            show: true,
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                getTitlesWidget: (v, m) => Text(
                  v <= 0 ? '0' : fmt.format(v),
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (v, m) {
                  final i = v.toInt();
                  if (i < 0 || i >= buckets.length) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(buckets[i].label,
                        style: const TextStyle(fontSize: 10)),
                  );
                },
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          barGroups: [
            for (var i = 0; i < buckets.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: buckets[i].ingresos,
                    color: AppTheme.successColor,
                    width: 9,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(3),
                      topRight: Radius.circular(3),
                    ),
                  ),
                  BarChartRodData(
                    toY: buckets[i].egresos,
                    color: AppTheme.errorColor,
                    width: 9,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(3),
                      topRight: Radius.circular(3),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Línea del balance (ingresos − egresos) por sub-bucket, en infoColor.
class _BalanceLine extends StatelessWidget {
  final List<_CashBucket> buckets;
  const _BalanceLine({required this.buckets});

  @override
  Widget build(BuildContext context) {
    // Con un solo bucket (período = día) la línea no aporta; mostramos el
    // balance como un punto y su valor para que no quede un gráfico plano raro.
    final spots = [
      for (var i = 0; i < buckets.length; i++)
        FlSpot(i.toDouble(), buckets[i].balance),
    ];
    var minV = 0.0;
    var maxV = 0.0;
    for (final b in buckets) {
      if (b.balance < minV) minV = b.balance;
      if (b.balance > maxV) maxV = b.balance;
    }
    if (minV == maxV) {
      minV -= 1;
      maxV += 1;
    }
    final pad = (maxV - minV) * 0.15;
    final fmt = NumberFormat.compactCurrency(symbol: '\$', decimalDigits: 0);

    return SizedBox(
      height: 200,
      child: LineChart(
        LineChartData(
          minY: minV - pad,
          maxY: maxV + pad,
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (touched) => touched.map((spot) {
                final i = spot.x.toInt();
                final label =
                    (i >= 0 && i < buckets.length) ? buckets[i].label : '';
                return LineTooltipItem(
                  '$label\n\$${spot.y.toStringAsFixed(2)}',
                  const TextStyle(color: Colors.white, fontSize: 12),
                );
              }).toList(),
            ),
          ),
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          titlesData: FlTitlesData(
            show: true,
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                getTitlesWidget: (v, m) =>
                    Text(fmt.format(v), style: const TextStyle(fontSize: 10)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (v, m) {
                  final i = v.toInt();
                  if (i < 0 || i >= buckets.length || v != i.toDouble()) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(buckets[i].label,
                        style: const TextStyle(fontSize: 10)),
                  );
                },
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: AppTheme.infoColor,
              barWidth: 3,
              isStrokeCapRound: true,
              dotData: FlDotData(show: buckets.length <= 12),
              belowBarData: BarAreaData(
                show: true,
                color: AppTheme.infoColor.withValues(alpha: 0.15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
