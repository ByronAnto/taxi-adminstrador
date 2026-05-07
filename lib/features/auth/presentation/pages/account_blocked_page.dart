import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/models/user_model.dart';
import '../bloc/auth_bloc.dart';

/// Pantalla mostrada cuando la cuenta del conductor está bloqueada.
///
/// Cubre dos casos:
/// - `paymentBlocked`: el conductor no pagó. Puede subir comprobante para que
///   el admin lo apruebe y vuelva a `active`.
/// - `disabledByAdmin`: admin lo desactivó manualmente. Solo puede contactar
///   al admin (no puede subir pago).
///
/// El router redirige aquí cuando `user.isBlocked == true`.
class AccountBlockedPage extends StatelessWidget {
  const AccountBlockedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      builder: (context, state) {
        if (state is! AuthAuthenticated) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = state.user;
        final canPay = user.canUploadPayment;
        final isAdminDisabled = user.status == UserStatus.disabledByAdmin;
        // Cuando es el admin del grupo el que está bloqueado por mora, el
        // flujo no es "subir comprobante" sino "contactar al proveedor del
        // software". Los admins no pagan vía el formulario de pagos del
        // conductor — pagan al operador del SaaS (Byron) por fuera.
        final isAdminWithExpiredSub =
            user.role == AppConstants.roleAdmin &&
                user.status == UserStatus.paymentBlocked;

        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: const Text('Cuenta bloqueada'),
            backgroundColor: AppTheme.errorColor,
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                tooltip: 'Cerrar sesión',
                icon: const Icon(Icons.logout),
                onPressed: () {
                  context.read<AuthBloc>().add(AuthSignOutRequested());
                },
              ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  Icon(
                    isAdminDisabled
                        ? Icons.person_off_outlined
                        : isAdminWithExpiredSub
                            ? Icons.event_busy
                            : Icons.lock_outline,
                    size: 80,
                    color: AppTheme.errorColor,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isAdminDisabled
                        ? 'Tu cuenta fue desactivada'
                        : isAdminWithExpiredSub
                            ? 'Suscripción vencida'
                            : 'Pago pendiente',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isAdminDisabled
                        ? 'El administrador de tu asociación desactivó tu cuenta. '
                            'Contáctalo para restaurar el acceso.'
                        : isAdminWithExpiredSub
                            ? 'La suscripción de ${AppConstants.appName} de tu '
                                'asociación venció. Contacta a tu proveedor del '
                                'software para renovar el plan y reactivar el '
                                'acceso de todos los socios.'
                            : 'Para seguir usando ${AppConstants.appName} debes '
                                'completar el pago de tu cuota. Sube un '
                                'comprobante y el administrador lo aprobará '
                                'para reactivar tu cuenta.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: Colors.grey.shade700,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 32),
                  if (canPay && !isAdminWithExpiredSub) ...[
                    ElevatedButton.icon(
                      onPressed: () => context.push('/my-payments'),
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Subir comprobante de pago'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => context.push('/profile'),
                      icon: const Icon(Icons.person_outline),
                      label: const Text('Ver mi perfil'),
                    ),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange.shade200),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline,
                              color: Colors.orange.shade800),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              isAdminWithExpiredSub
                                  ? 'Una vez que tu proveedor renueve la '
                                      'suscripción, todos los socios y tu '
                                      'cuenta se reactivarán automáticamente.'
                                  : 'No puedes subir comprobante mientras tu '
                                      'cuenta esté desactivada. Habla con el '
                                      'administrador.',
                              style: TextStyle(
                                color: Colors.orange.shade900,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Center(
                    child: TextButton.icon(
                      onPressed: () {
                        context.read<AuthBloc>().add(AuthCheckRequested());
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refrescar estado'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
