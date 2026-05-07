import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../associations/data/models/association_model.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';

/// Pantalla para configurar el cobro de cuotas de la asociación.
///
/// Edita `associations/{aid}.billingConfig`. Accesible solo para
/// admin de la asociación (o super-admin via query param `?aid=`).
class BillingConfigPage extends StatefulWidget {
  final String? associationId;
  const BillingConfigPage({super.key, this.associationId});

  @override
  State<BillingConfigPage> createState() => _BillingConfigPageState();
}

class _BillingConfigPageState extends State<BillingConfigPage> {
  final _formKey = GlobalKey<FormState>();
  final _functions = FirebaseFunctions.instance;
  final _firestore = FirebaseFirestore.instance;

  final _amount = TextEditingController();
  final _periodEvery = TextEditingController(text: '1');
  final _dueDay = TextEditingController(text: '1');
  final _retention = TextEditingController(text: '90');

  String _concept = 'cuota_mensual';
  BillingPeriodUnit _unit = BillingPeriodUnit.month;
  bool _carryOver = false;
  bool _allowPhoto = true;
  bool _loading = true;
  bool _saving = false;
  String? _aid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _amount.dispose();
    _periodEvery.dispose();
    _dueDay.dispose();
    _retention.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    String? aid = widget.associationId;
    if (aid == null || aid.isEmpty) {
      final state = context.read<AuthBloc>().state;
      if (state is AuthAuthenticated) aid = state.user.associationId;
    }
    if (aid == null || aid.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    _aid = aid;

    final snap = await _firestore.collection('associations').doc(aid).get();
    if (snap.exists) {
      final cfg = AssociationModel.fromFirestore(snap).billingConfig;
      _amount.text = cfg.amount.toStringAsFixed(2);
      _concept = cfg.defaultConcept;
      _periodEvery.text = cfg.periodEvery.toString();
      _unit = cfg.periodUnit;
      _dueDay.text = cfg.dueDay.toString();
      _carryOver = cfg.allowDebtCarryOver;
      _retention.text = cfg.proofRetentionDays.toString();
      _allowPhoto = cfg.allowProofPhoto;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_aid == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Configuración de pagos')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No se pudo determinar la asociación.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuración de pagos'),
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Define cómo se cobran las cuotas a los conductores de tu asociación.',
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 16),
            _section('Cuota base'),
            TextFormField(
              controller: _amount,
              decoration: const InputDecoration(
                labelText: 'Monto (USD)',
                prefixText: '\$ ',
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: _validatePositive,
            ),
            DropdownButtonFormField<String>(
              initialValue: _concept,
              decoration:
                  const InputDecoration(labelText: 'Concepto por defecto'),
              items: const [
                DropdownMenuItem(
                    value: 'cuota_mensual', child: Text('Cuota mensual')),
                DropdownMenuItem(
                    value: 'cuota_semanal', child: Text('Cuota semanal')),
                DropdownMenuItem(value: 'multa', child: Text('Multa')),
                DropdownMenuItem(value: 'deuda', child: Text('Deuda')),
                DropdownMenuItem(value: 'incentivo', child: Text('Incentivo')),
                DropdownMenuItem(value: 'ayuda', child: Text('Ayuda')),
              ],
              onChanged: (v) =>
                  setState(() => _concept = v ?? 'cuota_mensual'),
            ),
            const SizedBox(height: 16),
            _section('Periodicidad'),
            const Text(
              'Cada cuántas unidades vence la cuota. Ej: cada 1 mes (mensual), '
              'cada 2 semanas (quincenal), cada 1 día (diario).',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _periodEvery,
                    decoration:
                        const InputDecoration(labelText: 'Cada (número)'),
                    keyboardType: TextInputType.number,
                    validator: _validatePositiveInt,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<BillingPeriodUnit>(
                    initialValue: _unit,
                    decoration: const InputDecoration(labelText: 'Unidad'),
                    items: const [
                      DropdownMenuItem(
                          value: BillingPeriodUnit.day, child: Text('Día(s)')),
                      DropdownMenuItem(
                          value: BillingPeriodUnit.week,
                          child: Text('Semana(s)')),
                      DropdownMenuItem(
                          value: BillingPeriodUnit.month,
                          child: Text('Mes(es)')),
                      DropdownMenuItem(
                          value: BillingPeriodUnit.year, child: Text('Año(s)')),
                    ],
                    onChanged: (v) => setState(
                        () => _unit = v ?? BillingPeriodUnit.month),
                  ),
                ),
              ],
            ),
            TextFormField(
              controller: _dueDay,
              decoration: InputDecoration(
                labelText: 'Día de vencimiento',
                helperText: _dueDayHelper(),
              ),
              keyboardType: TextInputType.number,
              validator: _validatePositiveInt,
            ),
            const SizedBox(height: 16),
            _section('Política'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Acumular deuda entre periodos'),
              subtitle: const Text(
                'Si está activado, las cuotas vencidas no pagadas '
                'aparecen como deuda en el panel del conductor.',
                style: TextStyle(fontSize: 12),
              ),
              value: _carryOver,
              onChanged: (v) => setState(() => _carryOver = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Permitir foto de comprobante'),
              subtitle: const Text(
                'Si está activado, el conductor puede adjuntar foto del '
                'recibo. Si está desactivado, solo formulario.',
                style: TextStyle(fontSize: 12),
              ),
              value: _allowPhoto,
              onChanged: (v) => setState(() => _allowPhoto = v),
            ),
            TextFormField(
              controller: _retention,
              decoration: const InputDecoration(
                labelText: 'Retención de fotos (días)',
                helperText:
                    'Pasado este plazo, los blobs se purgan automáticamente. '
                    'El registro Firestore queda permanente.',
                helperMaxLines: 3,
              ),
              keyboardType: TextInputType.number,
              validator: _validatePositiveInt,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('GUARDAR CONFIGURACIÓN'),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      ),
    );
  }

  String _dueDayHelper() {
    switch (_unit) {
      case BillingPeriodUnit.month:
        return 'Día del mes (1-28)';
      case BillingPeriodUnit.week:
        return 'Día de la semana (1=lunes ... 7=domingo)';
      case BillingPeriodUnit.day:
      case BillingPeriodUnit.year:
        return 'No aplica para este periodo (puedes dejarlo en 1)';
    }
  }

  String? _validatePositive(String? v) {
    if (v == null || v.trim().isEmpty) return 'Requerido';
    final n = double.tryParse(v);
    if (n == null) return 'Número inválido';
    if (n < 0) return 'Debe ser ≥ 0';
    return null;
  }

  String? _validatePositiveInt(String? v) {
    if (v == null || v.trim().isEmpty) return 'Requerido';
    final n = int.tryParse(v);
    if (n == null) return 'Entero inválido';
    if (n < 1) return 'Debe ser ≥ 1';
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      await _functions.httpsCallable('updateBillingConfig').call({
        'associationId': _aid,
        'billingConfig': {
          'amount': double.parse(_amount.text.trim()),
          'defaultConcept': _concept,
          'period': {
            'every': int.parse(_periodEvery.text.trim()),
            'unit': _unit.name,
          },
          'dueDay': int.parse(_dueDay.text.trim()),
          'allowDebtCarryOver': _carryOver,
          'proofRetentionDays': int.parse(_retention.text.trim()),
          'allowProofPhoto': _allowPhoto,
        },
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Configuración guardada.'),
          backgroundColor: Colors.green,
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: ${e.message ?? e.code}'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
