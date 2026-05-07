import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';

/// Banner de aviso "pago pendiente" — visible cuando el usuario está en
/// período de gracia (status = paymentPending). Da un click directo a la
/// pantalla de pagos para que suba el comprobante antes de bloquearse.
class PaymentPendingBanner extends StatelessWidget {
  const PaymentPendingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      buildWhen: (prev, curr) => curr is AuthAuthenticated,
      builder: (context, state) {
        if (state is! AuthAuthenticated) return const SizedBox.shrink();
        if (!state.user.hasPaymentWarning) return const SizedBox.shrink();

        return Material(
          color: Colors.orange.shade700,
          child: InkWell(
            onTap: () => context.push('/my-payments'),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Pago pendiente — sube tu comprobante antes de que se bloquee tu cuenta',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios,
                      color: Colors.white70, size: 14),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Wrapper conveniente para envolver un Scaffold body.
  static Widget wrap(Widget child) {
    return Column(
      children: [
        const PaymentPendingBanner(),
        Expanded(child: child),
      ],
    );
  }
}
