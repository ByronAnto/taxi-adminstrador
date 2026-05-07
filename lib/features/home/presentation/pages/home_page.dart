import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/data/models/user_model.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/driver_location_service.dart';
import '../../../../core/widgets/availability_toggle.dart';
import '../../../../core/widgets/payment_pending_banner.dart';
import '../../../map/presentation/pages/map_page.dart';
import '../../../communication/presentation/pages/walkie_talkie_page.dart';
import '../../../trips/presentation/pages/trips_page.dart';
import '../../../chat/presentation/pages/chat_list_page.dart';
import '../widgets/dashboard_kpis.dart';

/// Página principal con navegación inferior
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = -1; // Se inicializa al index del Radio

  /// ¿Este usuario envía GPS (y por tanto debe ver el switch Activo/Inactivo)?
  /// Mismo criterio que en `main.dart` al inicializar el location service.
  bool _sendsGps(UserModel user) {
    if (user.role == AppConstants.roleDriver) return true;
    if (user.role == AppConstants.roleAdmin && user.numeroVehiculo.isNotEmpty) {
      return true;
    }
    return false;
  }

  int _radioIndexForRole(String role) {
    switch (role) {
      case AppConstants.roleAdmin:
      case AppConstants.roleOperator:
        return 3; // [Panel, Mapa, Viajes, Radio, Chat]
      case AppConstants.roleDriver:
      default:
        return 2; // [Inicio, Mapa, Radio, Viajes, Chat]
    }
  }

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
        // Inicializar al tab de Radio la primera vez
        if (_currentIndex == -1) {
          _currentIndex = _radioIndexForRole(user.role);
        }
        final pages = _getPagesForRole(user);
        final navItems = _getNavItemsForRole(user);

        return Scaffold(
          appBar: AppBar(
            title: const Text(AppConstants.appName),
            actions: [
              // Switch general "Activo/Inactivo" — solo para conductores y
              // admins con vehículo (los que envían GPS).
              if (_sendsGps(user))
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Center(child: const AvailabilityToggle()),
                ),
              // Botón de pánico / emergencia
              IconButton(
                onPressed: () => _showEmergencyDialog(context),
                icon: const Icon(Icons.sos, color: AppTheme.errorColor),
                tooltip: 'Emergencia',
              ),
              IconButton(
                onPressed: () {
                  context.push('/profile');
                },
                icon: const CircleAvatar(
                  radius: 16,
                  backgroundColor: AppTheme.secondaryColor,
                  child: Icon(Icons.person, size: 18, color: Colors.white),
                ),
              ),
            ],
          ),
          body: PaymentPendingBanner.wrap(
            IndexedStack(
              index: _currentIndex,
              children: pages,
            ),
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            items: navItems,
          ),
        );
      },
    );
  }

  List<Widget> _getPagesForRole(UserModel user) {
    switch (user.role) {
      case AppConstants.roleAdmin:
        return [
          _buildDashboard(user),
          const MapPage(),
          const TripsPage(),
          const WalkieTalkiePage(),
          const ChatListPage(),
        ];
      case AppConstants.roleOperator:
        return [
          _buildDashboard(user),
          const MapPage(),
          const TripsPage(),
          const WalkieTalkiePage(),
          const ChatListPage(),
        ];
      case AppConstants.roleDriver:
      default:
        return [
          _buildDashboard(user),
          const MapPage(),
          const WalkieTalkiePage(),
          const TripsPage(),
          const ChatListPage(),
        ];
    }
  }

  List<BottomNavigationBarItem> _getNavItemsForRole(UserModel user) {
    switch (user.role) {
      case AppConstants.roleAdmin:
        return const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Panel'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Mapa'),
          BottomNavigationBarItem(icon: Icon(Icons.directions_car), label: 'Viajes'),
          BottomNavigationBarItem(icon: Icon(Icons.mic), label: 'Radio'),
          BottomNavigationBarItem(icon: Icon(Icons.chat), label: 'Chat'),
        ];
      case AppConstants.roleOperator:
        return const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Panel'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Mapa'),
          BottomNavigationBarItem(icon: Icon(Icons.directions_car), label: 'Viajes'),
          BottomNavigationBarItem(icon: Icon(Icons.mic), label: 'Radio'),
          BottomNavigationBarItem(icon: Icon(Icons.chat), label: 'Chat'),
        ];
      case AppConstants.roleDriver:
      default:
        return const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Inicio'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Mapa'),
          BottomNavigationBarItem(icon: Icon(Icons.mic), label: 'Radio'),
          BottomNavigationBarItem(icon: Icon(Icons.directions_car), label: 'Viajes'),
          BottomNavigationBarItem(icon: Icon(Icons.chat), label: 'Chat'),
        ];
    }
  }

  Widget _buildDashboard(UserModel user) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Saludo
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: AppTheme.primaryColor,
                    child: Text(
                      user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.secondaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '¡Hola, ${user.name}!',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _getRoleColor(user.role),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _getRoleName(user.role),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Accesos rápidos
          const Text(
            'Accesos Rápidos',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.4,
            children: _getQuickActionsForRole(user.role),
          ),
          const SizedBox(height: 24),
          // KPIs en tiempo real según rol
          DashboardKpis(user: user),
        ],
      ),
    );
  }


  List<Widget> _getQuickActionsForRole(String role) {
    final List<Widget> actions = [];

    // El admin hereda capacidades de conductor + operadora.
    final canDrive =
        role == AppConstants.roleDriver || role == AppConstants.roleAdmin;
    final canOperate =
        role == AppConstants.roleOperator || role == AppConstants.roleAdmin;
    final isAdmin = role == AppConstants.roleAdmin;

    // ─── Conductor ───
    if (canDrive) {
      actions.addAll([
        _buildQuickAction(
          'Cambiar Estado',
          Icons.swap_horiz,
          AppTheme.successColor,
          () => _showStatusDialog(),
        ),
        _buildQuickAction(
          'Mis Pagos',
          Icons.payments,
          AppTheme.secondaryColor,
          () => context.push('/my-payments'),
        ),
        _buildQuickAction(
          'Registrar Gasto',
          Icons.receipt_long,
          AppTheme.warningColor,
          () => context.push('/expenses'),
        ),
      ]);
    }

    // ─── Operadora ───
    if (canOperate) {
      actions.addAll([
        _buildQuickAction(
          'Asignar Viaje',
          Icons.add_circle,
          AppTheme.primaryColor,
          () => context.push('/assign-trip'),
        ),
        _buildQuickAction(
          'Paradas',
          Icons.flag,
          Colors.orange,
          () => context.push('/taxi-stands'),
        ),
      ]);
    }

    // ─── Admin / Operadora: validar pagos ───
    if (isAdmin || canOperate) {
      actions.add(
        _buildQuickAction(
          'Validar Pagos',
          Icons.fact_check,
          Colors.deepOrange,
          () => context.push('/payment-approvals'),
        ),
      );
    }

    // ─── Admin ───
    if (isAdmin) {
      actions.addAll([
        _buildQuickAction(
          'Socios',
          Icons.people,
          AppTheme.successColor,
          () => context.push('/users'),
        ),
        _buildQuickAction(
          'Caja',
          Icons.account_balance_wallet,
          Colors.teal,
          () => context.push('/cashflow'),
        ),
        _buildQuickAction(
          'Config. Cobros',
          Icons.tune,
          AppTheme.primaryDark,
          () => context.push('/billing-config'),
        ),
        _buildQuickAction(
          'Emergencias',
          Icons.sos,
          AppTheme.errorColor,
          () => context.push('/emergency'),
        ),
      ]);
    }

    // ─── Comunes ───
    actions.add(
      _buildQuickAction(
        'Reportes',
        Icons.bar_chart,
        AppTheme.accentColor,
        () => context.push('/reports'),
      ),
    );

    return actions;
  }

  Widget _buildQuickAction(
    String title,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 32),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getRoleColor(String role) {
    switch (role) {
      case AppConstants.roleAdmin:
        return AppTheme.errorColor;
      case AppConstants.roleOperator:
        return AppTheme.accentColor;
      default:
        return AppTheme.secondaryColor;
    }
  }

  String _getRoleName(String role) {
    switch (role) {
      case AppConstants.roleAdmin:
        return 'Administrador';
      case AppConstants.roleOperator:
        return 'Operadora';
      default:
        return 'Conductor';
    }
  }

  void _showStatusDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cambiar Estado'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildStatusOption('Libre', Icons.check_circle, AppTheme.statusFree, AppConstants.statusFree),
            _buildStatusOption('Con pasajero', Icons.person, AppTheme.statusBusy, AppConstants.statusBusy),
            _buildStatusOption(
              'En camino a base',
              Icons.home,
              AppTheme.statusReturning,
              AppConstants.statusReturning,
            ),
            _buildStatusOption(
              'Desconectado',
              Icons.power_settings_new,
              AppTheme.statusOffline,
              AppConstants.statusOffline,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusOption(String label, IconData icon, Color color, String statusValue) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label),
      onTap: () async {
        Navigator.pop(context);
        // Usar DriverLocationService global para cambiar estado
        // Esto maneja online/offline, GPS, y Firestore automáticamente
        await DriverLocationService.instance.updateStatus(statusValue);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Estado cambiado a: $label')),
          );
        }
      },
    );
  }

  void _showEmergencyDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning, color: AppTheme.errorColor),
            SizedBox(width: 8),
            Text('¡EMERGENCIA!'),
          ],
        ),
        content: const Text(
          '¿Estás seguro de que deseas enviar una alerta de emergencia? '
          'Se notificará a todos los miembros de la asociación y se '
          'compartirá tu ubicación actual.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('🚨 ¡Alerta de emergencia enviada!'),
                  backgroundColor: AppTheme.errorColor,
                  duration: Duration(seconds: 5),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.errorColor,
              foregroundColor: Colors.white,
            ),
            child: const Text('ENVIAR ALERTA'),
          ),
        ],
      ),
    );
  }
}
