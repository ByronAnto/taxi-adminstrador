import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../auth/data/models/user_model.dart';
import '../../data/models/payment_model.dart';

/// Bottom-sheet para que admin/operadora **emita un cobro** a un
/// conductor (multa, ayuda, deuda, cuota extra).
///
/// Crea un doc en `payments/` con `isOneOff=true`, `status=pending`,
/// `proof=null`. El conductor ve el cobro como "Por pagar" y reporta
/// el comprobante por el flujo normal de "Reportar pago".
///
/// Uso:
/// ```dart
/// await showCreateChargeSheet(context, target: user, aid: aid,
///                             emittedBy: me);
/// ```
Future<void> showCreateChargeSheet(
  BuildContext context, {
  required UserModel target,
  required String aid,
  required UserModel emittedBy,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CreateChargeSheet(
      target: target,
      aid: aid,
      emittedBy: emittedBy,
    ),
  );
}

class _CreateChargeSheet extends StatefulWidget {
  final UserModel target;
  final String aid;
  final UserModel emittedBy;

  const _CreateChargeSheet({
    required this.target,
    required this.aid,
    required this.emittedBy,
  });

  @override
  State<_CreateChargeSheet> createState() => _CreateChargeSheetState();
}

class _CreateChargeSheetState extends State<_CreateChargeSheet> {
  final _amountCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  String? _conceptKey;
  DateTime? _dueDate;
  Map<String, String> _concepts = const {};
  bool _loadingConcepts = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadConcepts();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConcepts() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('associations')
          .doc(widget.aid)
          .get();
      final raw = doc.data()?['paymentConcepts'];
      if (raw is Map && raw.isNotEmpty) {
        _concepts =
            raw.map((k, v) => MapEntry(k.toString(), v.toString()));
      } else {
        _concepts = const {
          'multa': 'Multa',
          'ayuda': 'Ayuda',
          'deuda': 'Deuda',
          'incentivo': 'Incentivo',
          'cuota_extra': 'Cuota extra',
        };
      }
    } catch (_) {
      _concepts = const {
        'multa': 'Multa',
        'ayuda': 'Ayuda',
        'deuda': 'Deuda',
      };
    }
    if (mounted) {
      setState(() {
        _loadingConcepts = false;
        _conceptKey ??= _concepts.keys.first;
      });
    }
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  Future<void> _submit() async {
    final amount = double.tryParse(_amountCtrl.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ingresa un monto válido'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
      return;
    }
    if (_conceptKey == null) return;

    setState(() => _saving = true);
    try {
      final id = const Uuid().v4();
      final now = DateTime.now();
      final driverFullName =
          '${widget.target.name} ${widget.target.lastname}'.trim();
      final doc = {
        'associationId': widget.aid,
        'driverId': widget.target.uid,
        // Denormalizado para que el admin lea nombre + unidad sin
        // hacer un lookup adicional por driverId.
        'driverName': driverFullName.isEmpty ? null : driverFullName,
        'driverVehicleNumber': widget.target.numeroVehiculo.isEmpty
            ? null
            : widget.target.numeroVehiculo,
        'amount': amount,
        'concept': _conceptKey,
        'status': 'pending',
        'paymentDate': Timestamp.fromDate(now),
        'dueDate': _dueDate != null ? Timestamp.fromDate(_dueDate!) : null,
        'notes': _notesCtrl.text.trim().isEmpty
            ? null
            : _notesCtrl.text.trim(),
        'proof': null,
        'reportedAt': Timestamp.fromDate(now),
        'isOneOff': true,
        'emittedBy': widget.emittedBy.uid,
        'emittedByName':
            '${widget.emittedBy.name} ${widget.emittedBy.lastname}'.trim(),
        'emittedAt': FieldValue.serverTimestamp(),
      };
      await FirebaseFirestore.instance
          .collection('payments')
          .doc(id)
          .set(doc);

      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '✅ Cobro emitido a ${widget.target.name}: '
              '\$${amount.toStringAsFixed(2)}'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = _dueDate == null
        ? 'Sin fecha límite'
        : '${_dueDate!.day.toString().padLeft(2, '0')}/'
            '${_dueDate!.month.toString().padLeft(2, '0')}/'
            '${_dueDate!.year}';

    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.request_quote_outlined,
                      color: AppTheme.primaryColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Crear cobro',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        'a ${widget.target.name} ${widget.target.lastname}',
                        style: TextStyle(
                            fontSize: 13, color: Colors.grey.shade700),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_loadingConcepts)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              const Text('Concepto',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: _conceptKey,
                items: _concepts.entries
                    .map((e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _conceptKey = v),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Monto (USD)',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              TextField(
                controller: _amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                      RegExp(r'[0-9.,]')),
                ],
                decoration: const InputDecoration(
                  prefixText: '\$ ',
                  hintText: '10.00',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Fecha límite (opcional)',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: _pickDueDate,
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(dateLabel),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 14),
                ),
              ),
              if (_dueDate != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _dueDate = null),
                    icon: const Icon(Icons.clear, size: 14),
                    label: const Text('Quitar fecha',
                        style: TextStyle(fontSize: 11)),
                  ),
                ),
              const SizedBox(height: 12),
              const Text('Nota (visible al conductor)',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              TextField(
                controller: _notesCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: 'Ej. Ayuda mecánica, multa por atraso, …',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _saving ? null : () => Navigator.pop(context),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: _saving ? null : _submit,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check),
                      label: Text(_saving ? 'Emitiendo…' : 'Emitir cobro'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'El conductor verá esto en "Mis pagos" como "Por pagar". '
                'Cuando reporte el comprobante, pasa a "Pendiente de validación".',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Etiqueta humana de un concepto, leyendo primero los conceptos
/// custom de la asociación y cayendo a [PaymentConcepts.label] si no
/// existe. Para usar desde la UI sin async: pasa el mapa pre-cargado.
String chargeConceptLabel(String key, Map<String, String>? customLabels) {
  if (customLabels != null && customLabels.containsKey(key)) {
    return customLabels[key]!;
  }
  return PaymentConcepts.label(key);
}
