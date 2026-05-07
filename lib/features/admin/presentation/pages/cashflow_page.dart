import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/cashflow_model.dart';

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
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final aid = auth.user.associationId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Caja'),
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
                    _buildSummary(movs),
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

  Widget _buildSummary(List<CashflowMovement> movs) {
    final ingresos =
        movs.where((m) => m.isIngreso).fold<double>(0, (s, m) => s + m.monto);
    final egresos =
        movs.where((m) => m.isEgreso).fold<double>(0, (s, m) => s + m.monto);
    final balance = ingresos - egresos;
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _kpi('Ingresos', fmt.format(ingresos), Icons.trending_up,
              Colors.green.shade700),
          const SizedBox(height: 12),
          _kpi('Egresos', fmt.format(egresos), Icons.trending_down,
              Colors.red.shade700),
          const SizedBox(height: 12),
          _kpi('Balance', fmt.format(balance), Icons.account_balance_wallet,
              balance >= 0 ? Colors.blue.shade800 : Colors.red.shade800),
          const SizedBox(height: 24),
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
          style: TextStyle(
            color: tipo == CashflowType.ingreso
                ? Colors.green.shade700
                : Colors.red.shade700,
            fontWeight: FontWeight.w700,
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

  Widget _kpi(String label, String value, IconData icon, Color color) {
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
                      style: TextStyle(color: Colors.grey.shade700)),
                  const SizedBox(height: 4),
                  Text(value,
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: color)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMovements(List<CashflowMovement> movs) {
    if (movs.isEmpty) {
      return const Center(child: Text('Sin movimientos en el período'));
    }
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: movs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (_, i) {
        final m = movs[i];
        final color =
            m.isIngreso ? Colors.green.shade700 : Colors.red.shade700;
        return Card(
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
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w800, fontSize: 15),
            ),
          ),
        );
      },
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
          padding: const EdgeInsets.all(16),
          child: _kpi('Pagado a operadoras', fmt.format(total),
              Icons.headset_mic, Colors.purple.shade700),
        ),
        Expanded(
          child: pagosOp.isEmpty
              ? const Center(child: Text('Sin pagos a operadoras'))
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: pagosOp.map((m) {
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.headset_mic),
                        title: Text(m.beneficiario ?? '(sin beneficiario)'),
                        subtitle: Text(DateFormat('dd MMM yyyy').format(m.fecha)),
                        trailing: Text(
                          '-${fmt.format(m.monto)}',
                          style: TextStyle(
                              color: Colors.red.shade700,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
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
  const _AddMovementForm(
      {required this.associationId, required this.createdBy});

  @override
  State<_AddMovementForm> createState() => _AddMovementFormState();
}

class _AddMovementFormState extends State<_AddMovementForm> {
  final _form = GlobalKey<FormState>();
  CashflowType _tipo = CashflowType.ingreso;
  String? _categoria;
  final _monto = TextEditingController();
  final _beneficiario = TextEditingController();
  final _descripcion = TextEditingController();
  String? _metodo;
  DateTime _fecha = DateTime.now();
  bool _saving = false;

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
    final mov = CashflowMovement(
      uid: const Uuid().v4(),
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
      createdAt: DateTime.now(),
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
            content: Text(_tipo == CashflowType.ingreso
                ? 'Ingreso registrado'
                : 'Egreso registrado'),
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
    final cats = _tipo == CashflowType.ingreso
        ? DefaultCashflowCategories.ingresos
        : DefaultCashflowCategories.egresos;

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
                _tipo == CashflowType.ingreso
                    ? 'Nuevo ingreso'
                    : 'Nuevo egreso',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
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
