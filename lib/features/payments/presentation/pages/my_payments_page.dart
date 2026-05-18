import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../associations/data/models/association_model.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/payment_model.dart';

/// Pantalla "Mis pagos" del conductor.
///
/// Muestra historial de pagos reportados con su estado (pending /
/// validated / rejected) y un botón "+ Reportar pago" que abre el
/// dialog de reporte.
class MyPaymentsPage extends StatelessWidget {
  const MyPaymentsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      builder: (context, state) {
        if (state is! AuthAuthenticated) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final uid = state.user.uid;
        final aid = state.user.associationId;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Mis pagos'),
            backgroundColor: AppTheme.primaryColor,
            foregroundColor: Colors.white,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/home'),
            ),
          ),
          body: StreamBuilder<QuerySnapshot>(
            // Sin orderBy en la query: muchos docs legacy no tienen
            // `reportedAt` y Firestore con orderBy los excluye. Además
            // evita exigir un índice compuesto. Ordenamos en cliente —
            // un conductor tiene pocas filas, es despreciable.
            stream: FirebaseFirestore.instance
                .collection('payments')
                .where('driverId', isEqualTo: uid)
                .snapshots(),
            builder: (_, snap) {
              if (snap.hasError) {
                return _errorState(context, snap.error);
              }
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return _emptyState(context);
              }
              final payments =
                  docs.map(PaymentModel.fromFirestore).toList();
              // Subimos los cobros pendientes "Por pagar" al tope para que
              // el conductor los vea primero.
              payments.sort((a, b) {
                final aUnpaid = a.isUnpaidCharge;
                final bUnpaid = b.isUnpaidCharge;
                if (aUnpaid != bUnpaid) return aUnpaid ? -1 : 1;
                return b.reportedAt.compareTo(a.reportedAt);
              });
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: payments.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _PaymentTile(
                  payment: payments[i],
                  onPayCharge: () => _openReportDialog(
                    context,
                    aid,
                    chargeToPay: payments[i],
                  ),
                ),
              );
            },
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openReportDialog(context, aid),
            icon: const Icon(Icons.add),
            label: const Text('Reportar pago'),
          ),
        );
      },
    );
  }

  Widget _errorState(BuildContext context, Object? error) {
    final msg = error?.toString() ?? '';
    final isIndex = msg.contains('failed-precondition') ||
        msg.contains('requires an index');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 64, color: AppTheme.errorColor),
            const SizedBox(height: 16),
            const Text('No pudimos cargar tus pagos',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              isIndex
                  ? 'El administrador necesita desplegar el índice nuevo de Firestore. Avísale para que ejecute "firebase deploy --only firestore:indexes".'
                  : 'Error: $msg',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            const Text(
              'Aún no has reportado pagos.',
              style: TextStyle(fontSize: 16, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            const Text(
              'Toca "Reportar pago" para registrar tu primera cuota.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openReportDialog(
    BuildContext context,
    String aid, {
    PaymentModel? chargeToPay,
  }) async {
    // Cargar billingConfig para defaults
    final aidSnap = await FirebaseFirestore.instance
        .collection('associations')
        .doc(aid)
        .get();
    if (!aidSnap.exists || !context.mounted) return;
    final cfg = AssociationModel.fromFirestore(aidSnap).billingConfig;

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _ReportPaymentDialog(
        billingConfig: cfg,
        prefillCharge: chargeToPay,
      ),
    );
  }
}

class _PaymentTile extends StatelessWidget {
  final PaymentModel payment;
  final VoidCallback? onPayCharge;

  const _PaymentTile({required this.payment, this.onPayCharge});

  @override
  Widget build(BuildContext context) {
    if (payment.isUnpaidCharge) {
      return _UnpaidChargeTile(payment: payment, onPay: onPayCharge);
    }

    final statusColor = switch (payment.status) {
      PaymentStatus.pending => Colors.orange,
      PaymentStatus.validated => Colors.green,
      PaymentStatus.rejected => Colors.red,
    };
    final statusLabel = switch (payment.status) {
      PaymentStatus.pending => 'Pendiente',
      PaymentStatus.validated => 'Validado',
      PaymentStatus.rejected => 'Rechazado',
    };
    final df = DateFormat('dd/MM/yyyy');

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.15),
          child: Icon(
            switch (payment.status) {
              PaymentStatus.pending => Icons.schedule,
              PaymentStatus.validated => Icons.check_circle,
              PaymentStatus.rejected => Icons.cancel,
            },
            color: statusColor,
          ),
        ),
        title: Text(
          '\$${payment.amount.toStringAsFixed(2)} · ${PaymentConcepts.label(payment.concept)}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pagado el ${df.format(payment.paymentDate)} · '
              '${_methodLabel(payment.proof?.method)}',
              style: const TextStyle(fontSize: 12),
            ),
            Text(
              statusLabel,
              style: TextStyle(
                  fontSize: 11,
                  color: statusColor,
                  fontWeight: FontWeight.bold),
            ),
            if (payment.status == PaymentStatus.rejected &&
                payment.rejectionReason != null)
              Text(
                'Motivo: ${payment.rejectionReason}',
                style:
                    const TextStyle(fontSize: 11, color: Colors.black54),
              ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }

  String _methodLabel(PaymentMethod? m) {
    return switch (m) {
      PaymentMethod.transferencia => 'Transferencia',
      PaymentMethod.deposito => 'Depósito',
      PaymentMethod.efectivo => 'Efectivo',
      _ => '—',
    };
  }
}

// ─────────────── Tile especial: cobro emitido por admin ────────────

/// Card destacado para un payment con `isOneOff=true` y todavía sin
/// proof. El conductor lo ve naranja con CTA "Pagar este cobro" → abre
/// el dialog de reporte con monto y concepto pre-fijados (no editables)
/// y al guardar UPDATEa el doc en vez de crear uno nuevo.
class _UnpaidChargeTile extends StatelessWidget {
  final PaymentModel payment;
  final VoidCallback? onPay;
  const _UnpaidChargeTile({required this.payment, this.onPay});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd/MM/yyyy');
    final overdue = payment.dueDate != null &&
        payment.dueDate!.isBefore(DateTime.now());
    final orange = overdue ? Colors.red.shade700 : Colors.orange.shade700;

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: orange, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: orange,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    overdue ? 'VENCIDO' : 'POR PAGAR',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '\$${payment.amount.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: orange,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              PaymentConcepts.label(payment.concept),
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700),
            ),
            if (payment.notes != null && payment.notes!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                payment.notes!,
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade800,
                    fontStyle: FontStyle.italic),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                if (payment.dueDate != null) ...[
                  Icon(Icons.event,
                      size: 14, color: Colors.grey.shade700),
                  const SizedBox(width: 4),
                  Text(
                    'Vence ${df.format(payment.dueDate!)}',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade800),
                  ),
                  const SizedBox(width: 10),
                ],
                if (payment.emittedByName != null)
                  Expanded(
                    child: Text(
                      'Emitido por ${payment.emittedByName}',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onPay,
                icon: const Icon(Icons.payments),
                label: const Text('Pagar este cobro'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: orange,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────── Dialog: Reportar pago ───────────────────

class _ReportPaymentDialog extends StatefulWidget {
  final BillingConfig billingConfig;
  final PaymentModel? prefillCharge;
  const _ReportPaymentDialog({
    required this.billingConfig,
    this.prefillCharge,
  });

  @override
  State<_ReportPaymentDialog> createState() => _ReportPaymentDialogState();
}

class _ReportPaymentDialogState extends State<_ReportPaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _ref = TextEditingController();
  final _deliveredTo = TextEditingController();
  final _bankOther = TextEditingController();

  late String _concept;
  PaymentMethod _method = PaymentMethod.transferencia;
  String? _bank;
  DateTime _paymentDate = DateTime.now();
  DateTime? _transactionDate;
  File? _photo;
  String? _photoUploadedUrl;
  bool _saving = false;
  bool _uploadingPhoto = false;

  @override
  void initState() {
    super.initState();
    final prefill = widget.prefillCharge;
    if (prefill != null) {
      _concept = prefill.concept;
      _amount.text = prefill.amount.toStringAsFixed(2);
    } else {
      _concept = widget.billingConfig.defaultConcept;
      _amount.text = widget.billingConfig.amount > 0
          ? widget.billingConfig.amount.toStringAsFixed(2)
          : '';
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    _deliveredTo.dispose();
    _bankOther.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reportar pago'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _amount,
                  decoration: const InputDecoration(
                    labelText: 'Monto (USD)',
                    prefixText: '\$ ',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  validator: _validatePositive,
                ),
                DropdownButtonFormField<String>(
                  initialValue: _concept,
                  decoration: const InputDecoration(labelText: 'Concepto'),
                  items: PaymentConcepts.labels.entries
                      .map((e) => DropdownMenuItem(
                          value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _concept = v ?? _concept),
                ),
                const SizedBox(height: 12),
                _datePickerRow(
                  label: 'Fecha de pago',
                  value: _paymentDate,
                  onPick: (d) => setState(() => _paymentDate = d),
                ),
                const Divider(height: 24),
                const Text('Método',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                _methodChips(),
                const SizedBox(height: 12),
                if (_method == PaymentMethod.efectivo)
                  TextFormField(
                    controller: _deliveredTo,
                    decoration: const InputDecoration(
                      labelText: '¿A quién entregaste el efectivo?',
                      hintText: 'Ej: operadora María, admin Byron',
                    ),
                    validator: (v) {
                      if (_method == PaymentMethod.efectivo &&
                          (v == null || v.trim().isEmpty)) {
                        return 'Indica a quién entregaste';
                      }
                      return null;
                    },
                  )
                else ...[
                  DropdownButtonFormField<String>(
                    initialValue: _bank,
                    decoration: const InputDecoration(labelText: 'Banco'),
                    items: PaymentBanks.ecuador
                        .map((b) =>
                            DropdownMenuItem(value: b, child: Text(b)))
                        .toList(),
                    onChanged: (v) => setState(() => _bank = v),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Selecciona' : null,
                  ),
                  if (_bank == 'Otros')
                    TextFormField(
                      controller: _bankOther,
                      decoration: const InputDecoration(
                          labelText: 'Nombre del banco'),
                      validator: (v) {
                        if (_bank == 'Otros' &&
                            (v == null || v.trim().isEmpty)) {
                          return 'Indica el banco';
                        }
                        return null;
                      },
                    ),
                  TextFormField(
                    controller: _ref,
                    decoration: const InputDecoration(
                      labelText: 'N° de comprobante / referencia',
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Requerido' : null,
                  ),
                  const SizedBox(height: 8),
                  _datePickerRow(
                    label: 'Fecha de la transacción',
                    value: _transactionDate ?? _paymentDate,
                    onPick: (d) => setState(() => _transactionDate = d),
                  ),
                ],
                if (widget.billingConfig.allowProofPhoto) ...[
                  const Divider(height: 24),
                  Row(
                    children: [
                      const Expanded(
                          child: Text('Foto del comprobante (opcional)',
                              style: TextStyle(fontWeight: FontWeight.bold))),
                      if (_photo != null)
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() {
                            _photo = null;
                            _photoUploadedUrl = null;
                          }),
                        ),
                    ],
                  ),
                  if (_photo == null)
                    OutlinedButton.icon(
                      onPressed: _uploadingPhoto ? null : _pickPhoto,
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Adjuntar foto'),
                    )
                  else
                    Container(
                      height: 100,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        image: DecorationImage(
                          image: FileImage(_photo!),
                          fit: BoxFit.cover,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: _uploadingPhoto
                          ? Container(
                              color: Colors.black54,
                              child: const Center(
                                child: CircularProgressIndicator(
                                    color: Colors.white),
                              ),
                            )
                          : null,
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Reportar'),
        ),
      ],
    );
  }

  Widget _datePickerRow({
    required String label,
    required DateTime value,
    required void Function(DateTime) onPick,
  }) {
    final df = DateFormat('dd/MM/yyyy');
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime(2020),
          lastDate: DateTime.now(),
        );
        if (picked != null) onPick(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Row(
          children: [
            Expanded(child: Text(df.format(value))),
            const Icon(Icons.calendar_today, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _methodChips() {
    return Wrap(
      spacing: 8,
      children: PaymentMethod.values.map((m) {
        final selected = _method == m;
        final label = switch (m) {
          PaymentMethod.transferencia => 'Transferencia',
          PaymentMethod.deposito => 'Depósito',
          PaymentMethod.efectivo => 'Efectivo',
        };
        return ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => setState(() => _method = m),
        );
      }).toList(),
    );
  }

  String? _validatePositive(String? v) {
    if (v == null || v.trim().isEmpty) return 'Requerido';
    final n = double.tryParse(v);
    if (n == null) return 'Número inválido';
    if (n <= 0) return 'Debe ser > 0';
    return null;
  }

  Future<void> _pickPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Cámara'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galería'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      imageQuality: 75,
      maxWidth: 1280,
    );
    if (picked == null) return;
    setState(() => _photo = File(picked.path));
  }

  Future<String?> _uploadPhoto(String uid) async {
    if (_photo == null) return null;
    setState(() => _uploadingPhoto = true);
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ref = FirebaseStorage.instance
          .ref('payment_proofs/$uid/proof_$ts.jpg');
      await ref.putFile(_photo!);
      final url = await ref.getDownloadURL();
      _photoUploadedUrl = url;
      return url;
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final authState = context.read<AuthBloc>().state;
    if (authState is! AuthAuthenticated) return;

    setState(() => _saving = true);
    try {
      final photoUrl = await _uploadPhoto(authState.user.uid);
      if (!mounted) return;

      final proof = <String, dynamic>{
        'method': _method.name,
      };
      if (_method == PaymentMethod.efectivo) {
        proof['deliveredTo'] = _deliveredTo.text.trim();
      } else {
        proof['bank'] = _bank;
        if (_bank == 'Otros') proof['bankOther'] = _bankOther.text.trim();
        proof['transactionRef'] = _ref.text.trim();
        proof['transactionDate'] =
            (_transactionDate ?? _paymentDate).toIso8601String();
      }
      if (photoUrl != null) proof['photoUrl'] = photoUrl;

      await FirebaseFunctions.instance.httpsCallable('reportPayment').call({
        'amount': double.parse(_amount.text.trim()),
        'concept': _concept,
        'paymentDate': _paymentDate.toIso8601String(),
        'proof': proof,
        if (widget.prefillCharge != null)
          'chargeId': widget.prefillCharge!.uid,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Pago reportado. Espera la validación del administrador.'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: ${e.message ?? e.code}'),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
