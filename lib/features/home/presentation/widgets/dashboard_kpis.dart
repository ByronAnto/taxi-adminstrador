import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../associations/data/models/association_model.dart';
import '../../../auth/data/models/user_model.dart';
import '../../../payments/data/due_date_calculator.dart';
import '../../../payments/data/models/payment_model.dart';

/// Panel de KPIs del Resumen del Día.
///
/// Adapta las métricas según el rol:
///   - **Admin**:    Viajes hoy / Libres / Ocupados / Pagos por validar / Recaudado mes
///   - **Operadora**: Viajes hoy / Libres / Ocupados
///   - **Conductor**: Mis viajes hoy / Estado / Próxima cuota / Deuda (si aplica)
///
/// Todos los datos se leen con Streams en tiempo real.
class DashboardKpis extends StatelessWidget {
  final UserModel user;

  const DashboardKpis({super.key, required this.user});

  bool get _isAdmin => user.role == AppConstants.roleAdmin;
  bool get _isOperator => user.role == AppConstants.roleOperator;
  bool get _isDriver => user.role == AppConstants.roleDriver;

  bool get _canViewOpsKpis => _isAdmin || _isOperator;
  bool get _hasFinanceKpis => _isAdmin;
  bool get _hasDriverKpis => _isAdmin || _isDriver;

  @override
  Widget build(BuildContext context) {
    final aid = user.associationId;
    if (aid.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Resumen del Día',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        _buildGrid(context, aid),
      ],
    );
  }

  Widget _buildGrid(BuildContext context, String aid) {
    final cards = <Widget>[];

    if (_canViewOpsKpis) {
      cards.add(_TripsTodayCard(aid: aid));
      // "Libres ahora" / "Ocupados ahora" se quitaron del resumen — esa
      // info ya está en el Mapa con los pines coloreados por estado.
    }

    if (_hasFinanceKpis) {
      cards.add(_PaymentsPendingCard(aid: aid));
      cards.add(_RevenueMonthCard(aid: aid));
    }

    if (_isDriver) {
      // Vista del conductor sin admin (admin ya tiene métricas operativas).
      cards.add(_MyTripsTodayCard(uid: user.uid));
    }

    if (_hasDriverKpis) {
      cards.add(_NextDueCard(aid: aid, user: user));
    }

    if (cards.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(
              'Sin métricas disponibles para este rol.',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ),
        ),
      );
    }

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.5,
      children: cards,
    );
  }
}

// ─────────────────── KPI base reutilizable ───────────────────

class _Kpi extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool loading;

  const _Kpi({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.subtitle,
    this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(icon, color: color, size: 24),
                  if (loading)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────── Viajes hoy (admin/operadora) ───────────────────

class _TripsTodayCard extends StatelessWidget {
  final String aid;
  const _TripsTodayCard({required this.aid});

  @override
  Widget build(BuildContext context) {
    final start = DateTime.now().copyWith(
        hour: 0, minute: 0, second: 0, millisecond: 0, microsecond: 0);

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .where('associationId', isEqualTo: aid)
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .snapshots(),
      builder: (_, snap) {
        final loading = snap.connectionState == ConnectionState.waiting;
        final count = snap.data?.docs.length ?? 0;
        return _Kpi(
          icon: Icons.directions_car,
          color: AppTheme.accentColor,
          label: 'Viajes hoy',
          value: '$count',
          subtitle: 'Asociación',
          loading: loading,
        );
      },
    );
  }
}

// ─────────────────── Mis viajes hoy (conductor) ───────────────────

class _MyTripsTodayCard extends StatelessWidget {
  final String uid;
  const _MyTripsTodayCard({required this.uid});

  @override
  Widget build(BuildContext context) {
    final start = DateTime.now().copyWith(
        hour: 0, minute: 0, second: 0, millisecond: 0, microsecond: 0);

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .where('driverId', isEqualTo: uid)
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .snapshots(),
      builder: (_, snap) {
        final loading = snap.connectionState == ConnectionState.waiting;
        final count = snap.data?.docs.length ?? 0;
        return _Kpi(
          icon: Icons.directions_car,
          color: AppTheme.accentColor,
          label: 'Mis viajes hoy',
          value: '$count',
          loading: loading,
        );
      },
    );
  }
}

// ─────────────────── Pagos por validar (admin) ───────────────────

class _PaymentsPendingCard extends StatelessWidget {
  final String aid;
  const _PaymentsPendingCard({required this.aid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('payments')
          .where('associationId', isEqualTo: aid)
          .where('status', isEqualTo: 'pending')
          .snapshots(),
      builder: (_, snap) {
        final loading = snap.connectionState == ConnectionState.waiting;
        final count = snap.data?.docs.length ?? 0;
        return _Kpi(
          icon: Icons.fact_check,
          color: count > 0 ? Colors.deepOrange : Colors.grey,
          label: 'Pagos por validar',
          value: '$count',
          subtitle: count > 0 ? 'Toca para revisar' : 'Sin pendientes',
          onTap: () => context.push('/payment-approvals'),
          loading: loading,
        );
      },
    );
  }
}

// ─────────────────── Recaudado este mes (admin) ───────────────────

class _RevenueMonthCard extends StatelessWidget {
  final String aid;
  const _RevenueMonthCard({required this.aid});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('payments')
          .where('associationId', isEqualTo: aid)
          .where('status', isEqualTo: 'validated')
          .where('validatedAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(monthStart))
          .snapshots(),
      builder: (_, snap) {
        final loading = snap.connectionState == ConnectionState.waiting;
        double total = 0;
        for (final d in snap.data?.docs ?? []) {
          final data = d.data() as Map<String, dynamic>;
          total += (data['amount'] as num?)?.toDouble() ?? 0;
        }

        final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);

        return _Kpi(
          icon: Icons.attach_money,
          color: AppTheme.primaryDark,
          label: 'Recaudado este mes',
          value: fmt.format(total),
          subtitle: DateFormat('MMM yyyy').format(now),
          loading: loading,
        );
      },
    );
  }
}

// ─────────────────── Próxima cuota / deuda (conductor / admin) ───────────────────

class _NextDueCard extends StatelessWidget {
  final String aid;
  final UserModel user;
  const _NextDueCard({required this.aid, required this.user});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .snapshots(),
      builder: (_, aidSnap) {
        if (!aidSnap.hasData || !aidSnap.data!.exists) {
          return const _Kpi(
            icon: Icons.event,
            color: Colors.grey,
            label: 'Próxima cuota',
            value: '—',
            loading: true,
          );
        }

        final assoc = AssociationModel.fromFirestore(aidSnap.data!);
        final cfg = assoc.billingConfig;

        // Stream del último pago validado del conductor (filtrado luego
        // por voidedAt en cliente para reusar índices existentes).
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('payments')
              .where('driverId', isEqualTo: user.uid)
              .where('status', isEqualTo: 'validated')
              .snapshots(),
          builder: (_, paySnap) {
            final loading =
                paySnap.connectionState == ConnectionState.waiting;

            // Buscar el último pago validado NO anulado.
            PaymentModel? lastValid;
            final docs = paySnap.data?.docs ?? [];
            for (final d in docs) {
              final p = PaymentModel.fromFirestore(d);
              if (p.isVoided) continue;
              if (lastValid == null ||
                  (p.validatedAt != null &&
                      lastValid.validatedAt != null &&
                      p.validatedAt!.isAfter(lastValid.validatedAt!))) {
                lastValid = p;
              }
            }

            // Usar el calculador espejo del cron (DueDateCalculator).
            // Mismo helper que `enforcePayments` para que dashboard
            // y backend coincidan en la fecha mostrada al conductor.
            final nextDue = cfg.amount > 0
                ? DueDateCalculator.computeNextDueDate(
                    user: user,
                    cfg: cfg,
                    lastPayment: lastValid,
                  )
                : null;
            final fmt = DateFormat('dd MMM');
            final amount =
                NumberFormat.currency(symbol: '\$', decimalDigits: 2)
                    .format(cfg.amount);

            final daysToDue = nextDue?.difference(DateTime.now()).inDays;

            final color = daysToDue == null
                ? Colors.grey
                : daysToDue < 0
                    ? Colors.red
                    : daysToDue <= 3
                        ? Colors.orange
                        : AppTheme.successColor;

            return _Kpi(
              icon: Icons.event,
              color: color,
              label: 'Próxima cuota',
              value: amount,
              subtitle: nextDue == null
                  ? 'Sin configurar'
                  : daysToDue != null && daysToDue < 0
                      ? 'Vencida ${-daysToDue}d'
                      : 'Vence ${fmt.format(nextDue)}',
              onTap: () => context.push('/my-payments'),
              loading: loading,
            );
          },
        );
      },
    );
  }
}
