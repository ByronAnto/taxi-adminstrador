import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_theme.dart';

/// Dialog que el admin usa para subir comprobante de pago de membresía
/// de la asociación al super-admin. Llama a la Cloud Function
/// `reportAssociationPayment` que crea un doc en `payments` con
/// `concept='membresia_asociacion'`.
class ReportAssociationPaymentDialog extends StatefulWidget {
  const ReportAssociationPaymentDialog({super.key});

  @override
  State<ReportAssociationPaymentDialog> createState() =>
      _ReportAssociationPaymentDialogState();
}

class _ReportAssociationPaymentDialogState
    extends State<ReportAssociationPaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  final _bankCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  DateTime? _transactionDate;
  bool _submitting = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _bankCtrl.dispose();
    _refCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_transactionDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecciona la fecha del depósito')),
      );
      return;
    }

    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('reportAssociationPayment')
          .call({
        'amount': double.parse(_amountCtrl.text),
        'bank': _bankCtrl.text.trim(),
        'transactionRef': _refCtrl.text.trim(),
        'transactionDate': _transactionDate!.toIso8601String(),
      });
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(const SnackBar(
        content: Text('Comprobante enviado. Esperando aprobación del super-admin.'),
      ));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Error: ${e.message ?? e.code}')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pagar membresía'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Monto (USD)',
                  prefixText: '\$',
                ),
                validator: (v) {
                  final d = double.tryParse(v ?? '');
                  if (d == null || d <= 0) return 'Monto inválido';
                  return null;
                },
              ),
              TextFormField(
                controller: _bankCtrl,
                decoration: const InputDecoration(labelText: 'Banco origen'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Requerido' : null,
              ),
              TextFormField(
                controller: _refCtrl,
                decoration: const InputDecoration(labelText: '# Comprobante'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Requerido' : null,
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_transactionDate == null
                    ? 'Fecha del depósito'
                    : DateFormat('dd/MM/yyyy').format(_transactionDate!)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: DateTime.now().subtract(const Duration(days: 30)),
                    lastDate: DateTime.now(),
                    initialDate: DateTime.now(),
                  );
                  if (picked != null) setState(() => _transactionDate = picked);
                },
              ),
              const SizedBox(height: 8),
              const Text(
                'El super-admin validará el pago y reactivará tu cooperativa.',
                style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : _submit,
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor),
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Enviar'),
        ),
      ],
    );
  }
}
