import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../associations/data/models/association_model.dart';
import '../../../auth/data/models/user_model.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/due_date_calculator.dart';
import '../../data/models/payment_model.dart';

/// Banner amarillo que aparece SOLO el día calendario del vencimiento
/// del próximo pago (cuota socio O membresía asociación).
/// Lee `app_config/global.dueDateBannerMessage` con placeholders.
class DueDateBanner extends StatelessWidget {
  const DueDateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return const SizedBox.shrink();
    final user = auth.user;

    return FutureBuilder<_DueDateInfo?>(
      future: _resolve(user),
      builder: (ctx, snap) {
        if (!snap.hasData || snap.data == null) return const SizedBox.shrink();
        final info = snap.data!;
        final isToday = _isSameDay(DateTime.now(), info.dueDate);
        if (!isToday) return const SizedBox.shrink();

        final message = info.bannerTemplate
            .replaceAll('{amount}', '\$${info.amount.toStringAsFixed(2)}')
            .replaceAll('{dueDate}', DateFormat('dd-MMM').format(info.dueDate));

        return Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.amber.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.amber.shade700, width: 1),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_amber, color: Colors.orange),
              const SizedBox(width: 12),
              Expanded(
                child: Text(message, style: const TextStyle(fontSize: 13)),
              ),
              TextButton(
                onPressed: () => context.push('/my-payments'),
                child: const Text('Pagar →'),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<_DueDateInfo?> _resolve(UserModel user) async {
    final fs = FirebaseFirestore.instance;
    final aSnap =
        await fs.collection('associations').doc(user.associationId).get();
    if (!aSnap.exists) return null;
    final assoc = AssociationModel.fromFirestore(aSnap);

    final cfgSnap =
        await fs.collection('app_config').doc('global').get();
    final template =
        (cfgSnap.data()?['dueDateBannerMessage'] as String?) ??
            'Recuerde pagar {amount} antes de las 00:00 del {dueDate} o será bloqueado.';

    // Admin → banner de membresía (paidUntil de la asoc)
    if (user.role == 'admin') {
      final paidUntil = assoc.paidUntil;
      if (paidUntil == null) return null;
      return _DueDateInfo(
        dueDate: paidUntil,
        amount: 0, // monto de membresía no está en el modelo todavía
        bannerTemplate: template,
      );
    }

    // Conductor → banner de cuota
    final cfg = assoc.billingConfig;
    if (cfg.amount <= 0) return null;

    final payments = await fs
        .collection('payments')
        .where('driverId', isEqualTo: user.uid)
        .where('associationId', isEqualTo: user.associationId)
        .where('status', isEqualTo: 'validated')
        .orderBy('validatedAt', descending: true)
        .limit(5)
        .get();
    PaymentModel? lastValid;
    for (final d in payments.docs) {
      final p = PaymentModel.fromFirestore(d);
      if (!p.isVoided) {
        lastValid = p;
        break;
      }
    }

    final nextDue = DueDateCalculator.computeNextDueDate(
      user: user,
      cfg: cfg,
      lastPayment: lastValid,
    );
    if (nextDue == null) return null;

    final amount = lastValid == null
        ? DueDateCalculator.proratedFirstAmount(user: user, cfg: cfg)
        : cfg.amount;

    return _DueDateInfo(
      dueDate: nextDue,
      amount: amount,
      bannerTemplate: template,
    );
  }
}

class _DueDateInfo {
  final DateTime dueDate;
  final double amount;
  final String bannerTemplate;

  _DueDateInfo({
    required this.dueDate,
    required this.amount,
    required this.bannerTemplate,
  });
}
