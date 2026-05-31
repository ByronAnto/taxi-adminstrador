import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../associations/data/models/association_model.dart';
import '../../../payments/presentation/widgets/report_association_payment_dialog.dart';
import '../../data/models/user_model.dart';
import '../bloc/auth_bloc.dart';

/// Pantalla mostrada al usuario cuando su cuenta está bloqueada por mora,
/// o cuando la asociación a la que pertenece está suspendida.
///
/// Variantes:
///  - Conductor bloqueado por su mora personal: puede subir comprobante.
///  - Admin con asociación suspendida: puede subir comprobante de membresía.
///  - Conductor/operadora con asociación suspendida: solo puede cerrar sesión.
class AccountBlockedPage extends StatelessWidget {
  const AccountBlockedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return const _LoadingScaffold();
    final user = auth.user;

    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance
          .collection('associations')
          .doc(user.associationId)
          .get(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const _LoadingScaffold();
        final assoc = snap.data!.exists
            ? AssociationModel.fromFirestore(snap.data!)
            : null;
        final assocSuspended = assoc?.status == AssociationStatus.suspended;
        final isAdmin = user.role == 'admin';

        if (assocSuspended && isAdmin) {
          return _AssocSuspendedAdminView(assoc: assoc!, user: user);
        }
        if (assocSuspended) {
          return _AssocSuspendedNonAdminView(assoc: assoc!);
        }
        return _DriverBlockedView(user: user);
      },
    );
  }
}

class _LoadingScaffold extends StatelessWidget {
  const _LoadingScaffold();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: LoadingState());
}

class _DriverBlockedView extends StatelessWidget {
  final UserModel user;
  const _DriverBlockedView({required this.user});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final reason = user.blockReason;
    final reasonText = reason == 'pago_anulado'
        ? 'Un pago tuyo fue anulado.'
        : reason == 'cuota_vencida'
            ? 'Tu cuota está vencida.'
            : 'Tu cuenta está bloqueada.';
    return Scaffold(
      backgroundColor: AppTheme.errorColor.withValues(alpha: 0.06),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.block, size: 80, color: AppTheme.errorColor),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Tu cuenta está bloqueada',
                style: textTheme.displaySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                reasonText,
                textAlign: TextAlign.center,
                style: textTheme.bodyLarge,
              ),
              const SizedBox(height: AppSpacing.xl),
              ElevatedButton.icon(
                onPressed: () => context.push('/my-payments'),
                icon: const Icon(Icons.upload),
                label: const Text('Subir comprobante de pago'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton(
                onPressed: () =>
                    context.read<AuthBloc>().add(AuthSignOutRequested()),
                child: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssocSuspendedAdminView extends StatelessWidget {
  final AssociationModel assoc;
  final UserModel user;
  const _AssocSuspendedAdminView({required this.assoc, required this.user});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.errorColor.withValues(alpha: 0.06),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.business, size: 80, color: AppTheme.errorColor),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Tu cooperativa fue suspendida',
                style: textTheme.displaySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'La membresía está vencida. Sube el comprobante de pago para reactivarla.',
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.xl),
              ElevatedButton.icon(
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => const ReportAssociationPaymentDialog(),
                ),
                icon: const Icon(Icons.payments),
                label: const Text('Pagar membresía'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton(
                onPressed: () =>
                    context.read<AuthBloc>().add(AuthSignOutRequested()),
                child: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssocSuspendedNonAdminView extends StatelessWidget {
  final AssociationModel assoc;
  const _AssocSuspendedNonAdminView({required this.assoc});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.errorColor.withValues(alpha: 0.06),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.business, size: 80, color: AppTheme.errorColor),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Tu cooperativa fue suspendida',
                style: textTheme.displaySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'El administrador debe pagar la membresía. Mientras tanto no puedes operar.',
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.xl),
              OutlinedButton(
                onPressed: () =>
                    context.read<AuthBloc>().add(AuthSignOutRequested()),
                child: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
