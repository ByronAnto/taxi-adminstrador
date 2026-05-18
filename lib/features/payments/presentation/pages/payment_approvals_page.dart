import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/data/models/user_model.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/payment_model.dart';

/// Pantalla de validación de pagos para admin/operadora de la asociación.
///
/// Reutilizable también por el super-admin (pasando `?aid=`) para
/// auditar pagos de cualquier asociación.
class PaymentApprovalsPage extends StatefulWidget {
  /// Si null, se infiere del [AuthBloc] (caso admin/operadora de la suya).
  final String? associationId;

  const PaymentApprovalsPage({super.key, this.associationId});

  @override
  State<PaymentApprovalsPage> createState() => _PaymentApprovalsPageState();
}

enum _ApprovalFilter { pending, validated, rejected, all }

class _PaymentApprovalsPageState extends State<PaymentApprovalsPage> {
  final _firestore = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instance;

  _ApprovalFilter _filter = _ApprovalFilter.pending;

  String? _resolveAid(BuildContext context) {
    if (widget.associationId != null && widget.associationId!.isNotEmpty) {
      return widget.associationId;
    }
    final auth = context.read<AuthBloc>().state;
    if (auth is AuthAuthenticated) return auth.user.associationId;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final aid = _resolveAid(context);

    if (aid == null || aid.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Validar pagos')),
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

    final auth = context.read<AuthBloc>().state;
    final isSuper = auth is AuthAuthenticated &&
        auth.user.email == 'brealpeaymara@gmail.com';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Validar pagos'),
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        actions: [
          if (isSuper)
            IconButton(
              tooltip: 'Backfill nombres conductor (super-admin)',
              icon: const Icon(Icons.healing),
              onPressed: _runBackfill,
            ),
        ],
      ),
      body: Column(
        children: [
          _buildFilters(),
          const Divider(height: 1),
          Expanded(child: _buildList(aid)),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        children: _ApprovalFilter.values.map((f) {
          final selected = _filter == f;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(_filterLabel(f)),
              selected: selected,
              onSelected: (_) => setState(() => _filter = f),
            ),
          );
        }).toList(),
      ),
    );
  }

  String _filterLabel(_ApprovalFilter f) {
    switch (f) {
      case _ApprovalFilter.pending:
        return 'Pendientes';
      case _ApprovalFilter.validated:
        return 'Validados';
      case _ApprovalFilter.rejected:
        return 'Rechazados';
      case _ApprovalFilter.all:
        return 'Todos';
    }
  }

  Widget _buildList(String aid) {
    final query = _firestore
        .collection('payments')
        .where('associationId', isEqualTo: aid);

    return StreamBuilder<QuerySnapshot>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Error cargando pagos: ${snap.error}',
                style: const TextStyle(color: Colors.red),
              ),
            ),
          );
        }

        final docs = snap.data?.docs ?? [];
        var payments =
            docs.map((d) => PaymentModel.fromFirestore(d)).toList();

        // Filtro por status
        if (_filter != _ApprovalFilter.all) {
          final wanted = switch (_filter) {
            _ApprovalFilter.pending => PaymentStatus.pending,
            _ApprovalFilter.validated => PaymentStatus.validated,
            _ApprovalFilter.rejected => PaymentStatus.rejected,
            _ApprovalFilter.all => null,
          };
          payments = payments.where((p) => p.status == wanted).toList();
        }

        // Ordenar: pending primero, luego más reciente
        payments.sort((a, b) {
          if (a.isPending && !b.isPending) return -1;
          if (!a.isPending && b.isPending) return 1;
          return b.reportedAt.compareTo(a.reportedAt);
        });

        if (payments.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.inbox, size: 56, color: Colors.grey[300]),
                  const SizedBox(height: 12),
                  Text(
                    _filter == _ApprovalFilter.pending
                        ? 'No hay pagos pendientes por validar.'
                        : 'No hay pagos en este filtro.',
                    style: const TextStyle(color: Colors.black54),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: payments.length,
          separatorBuilder: (_, _) => const SizedBox(height: 4),
          itemBuilder: (_, i) => _PaymentTile(
            payment: payments[i],
            onTap: () => _openDetail(payments[i]),
          ),
        );
      },
    );
  }

  Future<void> _openDetail(PaymentModel p) async {
    // Lookup del conductor
    final driverSnap = await _firestore.collection('users').doc(p.driverId).get();
    final driver = driverSnap.exists ? UserModel.fromFirestore(driverSnap) : null;

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _PaymentDetailDialog(
        payment: p,
        driver: driver,
        onApprove: () => _approve(p),
        onReject: () => _reject(p),
      ),
    );
  }

  /// Llama la Cloud Function backfillPayments. Solo super-admin.
  /// Recorre todos los payments donde driverName == null y los rellena
  /// con un lookup a users/{driverId}.
  Future<void> _runBackfill() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backfill nombres conductor'),
        content: const Text(
          'Recorre todos los pagos antiguos sin nombre y los completa '
          'con un lookup a users/. Es seguro de re-ejecutar (saltea los '
          'que ya tienen nombre).',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.healing),
            label: const Text('Ejecutar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final res = await _functions
          .httpsCallable('backfillPayments')
          .call({});
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      final data = (res.data as Map?) ?? const {};
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '✅ Backfill: ${data['updated']} actualizados, '
              '${data['skipped']} saltados, ${data['scanned']} totales'),
          backgroundColor: AppTheme.successColor,
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  Future<void> _approve(PaymentModel p) async {
    Navigator.pop(context); // cerrar dialog
    try {
      await _functions
          .httpsCallable('validatePayment')
          .call({'paymentId': p.uid});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pago validado.'),
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
    }
  }

  Future<void> _reject(PaymentModel p) async {
    Navigator.pop(context); // cerrar dialog detalle
    final reasonController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Motivo del rechazo'),
        content: TextField(
          controller: reasonController,
          decoration: const InputDecoration(
            hintText: 'Explica al conductor por qué se rechaza',
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Rechazar'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      await _functions.httpsCallable('rejectPayment').call({
        'paymentId': p.uid,
        'reason': reasonController.text.trim(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pago rechazado.'),
          backgroundColor: Colors.orange,
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
    }
  }
}

// ─────────────────── Tile de pago en la lista ───────────────────

class _PaymentTile extends StatelessWidget {
  final PaymentModel payment;
  final VoidCallback onTap;

  const _PaymentTile({required this.payment, required this.onTap});

  @override
  Widget build(BuildContext context) {
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
    final methodLabel = switch (payment.proof?.method) {
      PaymentMethod.transferencia => 'Transferencia',
      PaymentMethod.deposito => 'Depósito',
      PaymentMethod.efectivo => 'Efectivo',
      _ => '—',
    };
    final df = DateFormat('dd MMM');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: ListTile(
        onTap: onTap,
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
        title: Row(
          children: [
            Expanded(
              child: Text(
                '\$${payment.amount.toStringAsFixed(2)}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${PaymentConcepts.label(payment.concept)} · $methodLabel',
              style: const TextStyle(fontSize: 12),
            ),
            // Nombre + unidad denormalizados al doc en el reporte. Si
            // no están (doc antiguo), caemos al UID truncado.
            Builder(builder: (_) {
              final name = (payment.driverName ?? '').trim();
              final unit = (payment.driverVehicleNumber ?? '').trim();
              final who = name.isNotEmpty
                  ? (unit.isNotEmpty ? '$name · Unidad #$unit' : name)
                  : 'Conductor: ${payment.driverId.substring(0, 8)}…';
              return Text(
                'Reportado ${df.format(payment.reportedAt)} · $who',
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              );
            }),
            if (payment.proof?.photoUrl != null)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Row(children: [
                  Icon(Icons.image, size: 12, color: Colors.blue),
                  SizedBox(width: 4),
                  Text('Con comprobante',
                      style: TextStyle(fontSize: 11, color: Colors.blue)),
                ]),
              ),
          ],
        ),
        isThreeLine: true,
        trailing: payment.isPending
            ? const Icon(Icons.chevron_right, color: Colors.orange)
            : null,
      ),
    );
  }
}

// ─────────────────── Dialog de detalle del pago ───────────────────

class _PaymentDetailDialog extends StatelessWidget {
  final PaymentModel payment;
  final UserModel? driver;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _PaymentDetailDialog({
    required this.payment,
    required this.driver,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
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

    final proof = payment.proof;
    final hasPhoto = proof?.photoUrl != null && proof!.photoUrl!.isNotEmpty;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              color: AppTheme.primaryColor,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '\$${payment.amount.toStringAsFixed(2)}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold),
                        ),
                        Text(
                          PaymentConcepts.label(payment.concept),
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            statusLabel,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Body
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _section('Conductor'),
                  if (driver != null) ...[
                    _info(
                      'Nombre',
                      '${driver!.name} ${driver!.lastname}'.trim().isEmpty
                          ? driver!.email
                          : '${driver!.name} ${driver!.lastname}',
                    ),
                    _info('Cédula',
                        driver!.cedula.isEmpty ? '—' : driver!.cedula),
                    _info('Vehículo',
                        driver!.numeroVehiculo.isEmpty
                            ? '—'
                            : 'Veh ${driver!.numeroVehiculo} · ${driver!.placa}'),
                    _info('Teléfono',
                        driver!.phone.isEmpty ? '—' : driver!.phone),
                  ] else
                    _info('UID', payment.driverId),
                  const SizedBox(height: 12),
                  _section('Pago'),
                  _info('Fecha de pago', df.format(payment.paymentDate)),
                  _info('Reportado el', df.format(payment.reportedAt)),
                  if (proof != null) ...[
                    const SizedBox(height: 12),
                    _section('Comprobante'),
                    _info('Método', _methodLabel(proof.method)),
                    if (proof.method == PaymentMethod.efectivo)
                      _info(
                          'Entregado a',
                          (proof.deliveredTo ?? '').isEmpty
                              ? '—'
                              : proof.deliveredTo!)
                    else ...[
                      _info('Banco', proof.bankLabel),
                      _info('N° comprobante',
                          (proof.transactionRef ?? '').isEmpty
                              ? '—'
                              : proof.transactionRef!),
                      if (proof.transactionDate != null)
                        _info('Fecha transacción',
                            df.format(proof.transactionDate!)),
                    ],
                  ],
                  if (hasPhoto) ...[
                    const SizedBox(height: 12),
                    _section('Foto del comprobante'),
                    InkWell(
                      onTap: () =>
                          _openFullScreen(context, proof.photoUrl!),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        height: 200,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                          image: DecorationImage(
                            image: NetworkImage(proof.photoUrl!),
                            fit: BoxFit.cover,
                          ),
                        ),
                        alignment: Alignment.bottomRight,
                        child: Container(
                          margin: const EdgeInsets.all(8),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Icon(Icons.zoom_in,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Toca para ampliar',
                      style: TextStyle(fontSize: 11, color: Colors.black54),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (payment.notes != null && payment.notes!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _section('Notas'),
                    Text(payment.notes!),
                  ],
                  if (payment.isRejected &&
                      payment.rejectionReason != null) ...[
                    const SizedBox(height: 12),
                    _section('Motivo de rechazo'),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(payment.rejectionReason!),
                    ),
                  ],
                ],
              ),
            ),
            // Acciones (solo si está pending)
            if (payment.isPending)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  border: Border(
                      top: BorderSide(color: Color(0xFFE0E0E0))),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onReject,
                        icon: const Icon(Icons.cancel, color: Colors.red),
                        label: const Text('Rechazar',
                            style: TextStyle(color: Colors.red)),
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
                          side: const BorderSide(color: Colors.red),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: onApprove,
                        icon: const Icon(Icons.check_circle),
                        label: const Text('Aprobar'),
                        style: ElevatedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            // Botón anular pago — solo admin, solo si validated y no voided
            Builder(builder: (ctx) {
              final auth = ctx.read<AuthBloc>().state;
              final isAdmin = auth is AuthAuthenticated &&
                  auth.user.role == AppConstants.roleAdmin;
              if (!isAdmin) return const SizedBox.shrink();
              if (payment.status != PaymentStatus.validated) {
                return const SizedBox.shrink();
              }
              if (payment.isVoided) return const SizedBox.shrink();

              return Container(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.block, color: Colors.red),
                    label: const Text('Anular pago',
                        style: TextStyle(color: Colors.red)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                    ),
                    onPressed: () =>
                        _confirmAndVoid(ctx, payment),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  String _methodLabel(PaymentMethod m) {
    switch (m) {
      case PaymentMethod.transferencia:
        return 'Transferencia';
      case PaymentMethod.deposito:
        return 'Depósito';
      case PaymentMethod.efectivo:
        return 'Efectivo';
    }
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 13,
          color: AppTheme.primaryColor,
        ),
      ),
    );
  }

  Widget _info(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style:
                    const TextStyle(color: Colors.black54, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  void _openFullScreen(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image,
                        color: Colors.white, size: 48),
                  ),
                  loadingBuilder: (_, child, progress) {
                    if (progress == null) return child;
                    return const Center(
                      child:
                          CircularProgressIndicator(color: Colors.white),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 32,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────── Standalone helper para anular pago ───────────────────

Future<void> _confirmAndVoid(
    BuildContext context, PaymentModel payment) async {
  final reasonCtrl = TextEditingController();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Anular pago'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Esta acción bloquea al conductor inmediatamente. '
            'Recibe FCM push con el motivo. ¿Continuar?',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: reasonCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Motivo (mín 10 caracteres)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () {
            if (reasonCtrl.text.trim().length < 10) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                    content:
                        Text('Motivo debe tener al menos 10 caracteres')),
              );
              return;
            }
            Navigator.of(ctx).pop(true);
          },
          child: const Text('Anular'),
        ),
      ],
    ),
  );

  if (confirmed != true) return;
  if (!context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  try {
    await FirebaseFunctions.instance.httpsCallable('voidPayment').call({
      'paymentId': payment.uid,
      'reason': reasonCtrl.text.trim(),
    });
    if (!context.mounted) return;
    navigator.pop(); // cierra el detail dialog
    messenger.showSnackBar(const SnackBar(
      content: Text('Pago anulado y conductor bloqueado'),
    ));
  } on FirebaseFunctionsException catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text('Error: ${e.message ?? e.code}'),
    ));
  }
}

