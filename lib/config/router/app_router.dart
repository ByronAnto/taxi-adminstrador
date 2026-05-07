import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../config/injection/injection.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/reports/presentation/bloc/reports_bloc.dart';
import '../../features/auth/presentation/pages/login_page.dart';
import '../../features/auth/presentation/pages/register_page.dart';
import '../../features/auth/presentation/pages/pending_approval_page.dart';
import '../../features/auth/presentation/pages/account_blocked_page.dart';
import '../../features/home/presentation/pages/home_page.dart';
import '../../features/users/presentation/pages/profile_page.dart';
import '../../features/payments/presentation/pages/payments_page.dart';
import '../../features/payments/presentation/pages/expenses_page.dart';
import '../../features/reports/presentation/pages/reports_page.dart';
// Pantalla vieja de gestión de usuarios reemplazada por MembersPage,
// que sí filtra por status (pendingApproval/active/suspended/rejected).
// import '../../features/users/presentation/pages/user_management_page.dart';
import '../../features/trips/presentation/pages/assign_trip_page.dart';
import '../../features/emergency/presentation/pages/emergency_page.dart';
import '../../features/map/presentation/pages/taxi_stand_config_page.dart';
import '../../features/super_admin/presentation/pages/super_admin_page.dart';
import '../../features/admin/presentation/pages/members_page.dart';
import '../../features/admin/presentation/pages/billing_config_page.dart';
import '../../features/admin/presentation/pages/cashflow_page.dart';
import '../../features/admin/presentation/pages/notifications_page.dart';
import '../../features/admin/presentation/pages/trip_requests_page.dart';
import '../../features/payments/presentation/pages/my_payments_page.dart';
import '../../features/payments/presentation/pages/payment_approvals_page.dart';

/// Configuración de rutas de la aplicación
class AppRouter {
  static GoRouter router(AuthBloc authBloc) {
    return GoRouter(
      initialLocation: '/login',
      refreshListenable: GoRouterRefreshStream(authBloc.stream),
      redirect: (context, state) {
        final authState = authBloc.state;
        final isAuthenticated = authState is AuthAuthenticated;
        final isLoggingIn = state.matchedLocation == '/login' ||
            state.matchedLocation == '/register';
        final isPendingPath =
            state.matchedLocation == '/pending-approval';
        final isBlockedPath = state.matchedLocation == '/blocked';
        final isMyPaymentsPath = state.matchedLocation == '/my-payments';

        // No autenticado: forzar /login (excepto si va a /register).
        if (!isAuthenticated && !isLoggingIn) {
          return '/login';
        }

        if (isAuthenticated) {
          final user = authState.user;
          final isApproved = user.isApproved;
          final isBlocked = user.isBlocked;

          // Bloqueado por admin o por mora: pantalla de bloqueo.
          // Permitir /my-payments solo si puede subir comprobante (paymentBlocked).
          if (isBlocked) {
            if (isBlockedPath) return null;
            if (isMyPaymentsPath && user.canUploadPayment) return null;
            return '/blocked';
          }

          // Status pendingApproval / rejected → pantalla de pendiente.
          if (!isApproved && !isPendingPath) {
            return '/pending-approval';
          }
          if (isApproved && (isLoggingIn || isPendingPath || isBlockedPath)) {
            return '/home';
          }
        }

        return null;
      },
      routes: [
        GoRoute(
          path: '/login',
          name: 'login',
          builder: (context, state) => const LoginPage(),
        ),
        GoRoute(
          path: '/register',
          name: 'register',
          builder: (context, state) => const RegisterPage(),
        ),
        GoRoute(
          path: '/pending-approval',
          name: 'pending-approval',
          builder: (context, state) => const PendingApprovalPage(),
        ),
        GoRoute(
          path: '/blocked',
          name: 'blocked',
          builder: (context, state) => const AccountBlockedPage(),
        ),
        GoRoute(
          path: '/home',
          name: 'home',
          builder: (context, state) => const HomePage(),
        ),
        GoRoute(
          path: '/profile',
          name: 'profile',
          builder: (context, state) => const ProfilePage(),
        ),
        GoRoute(
          path: '/payments',
          name: 'payments',
          builder: (context, state) => const PaymentsPage(),
        ),
        GoRoute(
          path: '/expenses',
          name: 'expenses',
          builder: (context, state) => const ExpensesPage(),
        ),
        GoRoute(
          path: '/reports',
          name: 'reports',
          builder: (context, state) => BlocProvider(
            create: (_) => sl<ReportsBloc>()..add(ReportsLoadRequested()),
            child: const ReportsPage(),
          ),
        ),
        GoRoute(
          path: '/users',
          name: 'users',
          // Redirige a la nueva MembersPage con filtros por status.
          // /users → MembersPage usa associationId del JWT (admin de la suya).
          // /users?aid=X → super-admin gestiona otra asociación.
          builder: (context, state) {
            final aid = state.uri.queryParameters['aid'];
            return MembersPage(associationId: aid);
          },
        ),
        GoRoute(
          path: '/assign-trip',
          name: 'assign-trip',
          builder: (context, state) => const AssignTripPage(),
        ),
        GoRoute(
          path: '/emergency',
          name: 'emergency',
          builder: (context, state) => const EmergencyPage(),
        ),
        GoRoute(
          path: '/taxi-stands',
          name: 'taxi-stands',
          builder: (context, state) => const TaxiStandConfigPage(),
        ),
        GoRoute(
          path: '/super',
          name: 'super-admin',
          builder: (context, state) => const SuperAdminPage(),
        ),
        GoRoute(
          path: '/members',
          name: 'members',
          builder: (context, state) {
            // /members?aid=ROLD → super-admin gestiona otra asociación
            // /members         → admin gestiona la suya (se infiere del JWT)
            final aid = state.uri.queryParameters['aid'];
            return MembersPage(associationId: aid);
          },
        ),
        GoRoute(
          path: '/billing-config',
          name: 'billing-config',
          builder: (context, state) {
            final aid = state.uri.queryParameters['aid'];
            return BillingConfigPage(associationId: aid);
          },
        ),
        GoRoute(
          path: '/my-payments',
          name: 'my-payments',
          builder: (context, state) => const MyPaymentsPage(),
        ),
        GoRoute(
          path: '/cashflow',
          name: 'cashflow',
          builder: (context, state) => const CashflowPage(),
        ),
        GoRoute(
          path: '/notifications',
          name: 'notifications',
          builder: (context, state) => const NotificationsPage(),
        ),
        GoRoute(
          path: '/trip-requests',
          name: 'trip-requests',
          builder: (context, state) => const TripRequestsPage(),
        ),
        GoRoute(
          path: '/payment-approvals',
          name: 'payment-approvals',
          builder: (context, state) {
            final aid = state.uri.queryParameters['aid'];
            return PaymentApprovalsPage(associationId: aid);
          },
        ),
      ],
      errorBuilder: (context, state) => Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Página no encontrada',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => context.go('/home'),
                child: const Text('Ir al inicio'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stream helper para refrescar GoRouter cuando cambia el estado de AuthBloc
class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    notifyListeners();
    _subscription = stream.asBroadcastStream().listen(
      (dynamic _) => notifyListeners(),
    );
  }

  late final dynamic _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
