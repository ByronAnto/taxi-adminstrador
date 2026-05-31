import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/data/models/user_model.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../core/services/radio_power_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/availability_toggle.dart';
import '../../../../core/widgets/payment_pending_banner.dart';
import '../../../map/presentation/pages/map_page.dart';
import '../../../communication/presentation/pages/walkie_talkie_page.dart';
import '../../../chat/presentation/pages/chat_list_page.dart';
import '../../../group_chat/data/group_unread_service.dart';
import '../../../payments/presentation/widgets/due_date_banner.dart';
import '../widgets/dashboard_kpis.dart';
import '../widgets/notifications_bell_button.dart';
import '../widgets/radio_wave_button.dart';

/// Página principal con navegación inferior y dashboard por rol.
///
/// Diseño:
/// - Saludo: card con avatar, nombre, rol → tap abre el perfil.
/// - Acciones del día: lo que el usuario hace TODOS los días (su mic
///   carga rápida, sus pagos, sus viajes).
/// - Administración (solo admin): tarjetas cuadradas para todas las
///   herramientas de gestión, reemplazando los iconos minúsculos que
///   antes vivían en el AppBar del perfil.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = -1;

  @override
  void initState() {
    super.initState();
    // En vez de pedir los permisos en ráfaga (silencioso, fallaba por
    // colisiones de permission_handler y bloqueos de MIUI), comprobamos si
    // los REQUERIDOS (mic + ubicación en uso + notificaciones) ya están
    // concedidos. Si NO, mandamos a la página de onboarding de permisos,
    // donde se piden de a uno con un gesto del usuario.
    // Tras el primer frame para no chocar con la construcción de la UI.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gateRequiredPermissions();
    });
  }

  /// Si faltan permisos requeridos, navega a /permissions. El chequeo es
  /// async, por eso vive aquí y NO en el redirect (síncrono) de go_router.
  Future<void> _gateRequiredPermissions() async {
    final mic = await Permission.microphone.isGranted;
    final loc = await Permission.locationWhenInUse.isGranted;
    final notif = await Permission.notification.isGranted;
    if (mic && loc && notif) return; // todo concedido, nos quedamos en home.

    if (!mounted) return;
    // Evita reloops: solo navegamos si seguimos en /home.
    final location = GoRouterState.of(context).matchedLocation;
    if (location != '/home') return;
    context.go('/permissions');
  }

  bool _sendsGps(UserModel user) {
    if (user.role == AppConstants.roleDriver) return true;
    if (user.role == AppConstants.roleAdmin && user.numeroVehiculo.isNotEmpty) {
      return true;
    }
    return false;
  }

  /// Índice de Radio en el IndexedStack: siempre el 2 (3er página) tras
  /// la limpieza del nav. Layout fijo: [Panel/Inicio, Mapa, Radio, Chat].
  static const int _radioStackIndex = 2;

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
        if (_currentIndex == -1) {
          _currentIndex = _radioStackIndex;
        }
        final pages = _getPagesForRole(user);

        return Scaffold(
          appBar: AppBar(
            leading: NotificationsBellButton(user: user),
            title: const Text(AppConstants.appName),
            actions: [
              if (_sendsGps(user))
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Center(child: const AvailabilityToggle()),
                ),
              IconButton(
                onPressed: () => context.push('/emergency'),
                icon: const Icon(Icons.sos, color: AppTheme.errorColor),
                tooltip: 'Emergencia',
              ),
              IconButton(
                onPressed: () => context.push('/profile'),
                icon: CircleAvatar(
                  radius: 16,
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  child: Icon(
                    Icons.person,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSecondary,
                  ),
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
          bottomNavigationBar: _buildCustomNav(user),
        );
      },
    );
  }

  /// Bottom nav custom con Radio al centro.
  ///
  /// Layout: [Inicio/Panel] [Mapa] [🎙️ Radio (grande, ondas)] [Chat]
  /// [Mis pagos / Validar pagos]
  ///
  /// Radio al centro siempre, con animación de ondas concéntricas
  /// cuando el radio está encendido (RadioPowerService.isOn). Los demás
  /// items son normales (icon + label).
  Widget _buildCustomNav(UserModel user) {
    final isDriver = user.role == AppConstants.roleDriver;
    final isAdmin = user.role == AppConstants.roleAdmin;
    final isOperator = user.role == AppConstants.roleOperator;
    final canDrive = isDriver || (isAdmin && user.numeroVehiculo.isNotEmpty);

    // 5º item según rol: lo más usado por ese perfil.
    final IconData fifthIcon;
    final String fifthLabel;
    final VoidCallback fifthOnTap;
    if (isAdmin || isOperator) {
      fifthIcon = Icons.fact_check_outlined;
      fifthLabel = 'Validar';
      fifthOnTap = () => context.push('/payment-approvals');
    } else if (canDrive) {
      fifthIcon = Icons.payments_outlined;
      fifthLabel = 'Mis pagos';
      fifthOnTap = () => context.push('/my-payments');
    } else {
      fifthIcon = Icons.notifications_outlined;
      fifthLabel = 'Avisos';
      fifthOnTap = () => context.push('/notifications');
    }

    return ListenableBuilder(
      listenable: Listenable.merge([
        RadioPowerService.instance,
        ConnectivityService.instance,
      ]),
      builder: (context, _) {
        // Radio "activo" para la animación: encendido + con internet.
        final radioActive = RadioPowerService.instance.isOn &&
            ConnectivityService.instance.isConnected;
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 8,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 76,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: _NavBarItem(
                      icon: isDriver ? Icons.home : Icons.dashboard,
                      label: isDriver ? 'Inicio' : 'Panel',
                      selected: _currentIndex == 0,
                      onTap: () => setState(() => _currentIndex = 0),
                    ),
                  ),
                  Expanded(
                    child: _NavBarItem(
                      icon: Icons.map,
                      label: 'Mapa',
                      selected: _currentIndex == 1,
                      onTap: () => setState(() => _currentIndex = 1),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: RadioWaveButton(
                        selected: _currentIndex == _radioStackIndex,
                        active: radioActive,
                        onTap: () => setState(
                            () => _currentIndex = _radioStackIndex),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<int>(
                      valueListenable:
                          GroupUnreadService.instance.unreadNotifier,
                      builder: (context, unread, _) => _NavBarItem(
                        icon: Icons.chat,
                        label: 'Chat',
                        selected: _currentIndex == 3,
                        badgeCount: unread,
                        onTap: () => setState(() => _currentIndex = 3),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _NavBarItem(
                      icon: fifthIcon,
                      label: fifthLabel,
                      selected: false,
                      onTap: fifthOnTap,
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

  List<Widget> _getPagesForRole(UserModel user) {
    // Layout único para los 3 roles: el 5º slot del nav navega a otra
    // ruta (push), por eso solo necesitamos 4 páginas en el stack.
    return [
      _buildDashboard(user),
      const MapPage(),
      const WalkieTalkiePage(),
      const ChatListPage(),
    ];
  }

  // ────────────────────────── DASHBOARD ──────────────────────────

  Widget _buildDashboard(UserModel user) {
    final isSuper = user.email == 'brealpeaymara@gmail.com';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ProfileGreetingCard(user: user),
          const DueDateBanner(),
          const SizedBox(height: 20),
          _SectionTitle(title: 'Mi día'),
          const SizedBox(height: 10),
          _CardGrid(items: _myDayActions(user)),
          if (_operationsActions(user).isNotEmpty) ...[
            const SizedBox(height: 20),
            _SectionTitle(title: 'Operaciones'),
            const SizedBox(height: 10),
            _CardGrid(items: _operationsActions(user)),
          ],
          if (_adminActions(user, isSuper: isSuper).isNotEmpty) ...[
            const SizedBox(height: 20),
            _SectionTitle(title: 'Administración'),
            const SizedBox(height: 10),
            _CardGrid(items: _adminActions(user, isSuper: isSuper)),
          ],
          const SizedBox(height: 24),
          DashboardKpis(user: user),
        ],
      ),
    );
  }

  // ────────── Acciones agrupadas por rol y propósito ──────────

  List<_ActionTile> _myDayActions(UserModel user) {
    final isAdmin = user.role == AppConstants.roleAdmin;
    final isOperator = user.role == AppConstants.roleOperator;
    final isDriver = user.role == AppConstants.roleDriver;
    final canDrive = isDriver || (isAdmin && user.numeroVehiculo.isNotEmpty);

    final list = <_ActionTile>[];
    if (canDrive) {
      // Carreras del conductor: sus asignadas + las pendientes (solo ver).
      list.add(_ActionTile(
        title: 'Mis carreras',
        icon: Icons.local_taxi_outlined,
        onTap: () => context.push('/trips'),
      ));
      list.add(_ActionTile(
        title: 'Mis pagos',
        icon: Icons.payments_outlined,
        onTap: () => context.push('/my-payments'),
      ));
      list.add(_ActionTile(
        title: 'Registrar gasto',
        icon: Icons.receipt_long_outlined,
        onTap: () => context.push('/expenses'),
      ));
      list.add(_ActionTile(
        title: 'Mi reporte',
        icon: Icons.bar_chart,
        onTap: () => context.push('/driver-report'),
      ));
    }
    if (isOperator || isAdmin) {
      list.add(_ActionTile(
        title: 'Solicitudes web',
        icon: Icons.assignment_turned_in_outlined,
        onTap: () => context.push('/trip-requests'),
      ));
      // Carreras: ver asignadas/activas, reasignar (cambiar conductor) y
      // cancelar. Estas acciones viven en TripsPage.
      if (!canDrive) {
        list.add(_ActionTile(
          title: 'Carreras',
          icon: Icons.local_taxi_outlined,
          onTap: () => context.push('/trips'),
        ));
      }
    }
    return list;
  }

  List<_ActionTile> _operationsActions(UserModel user) {
    final isAdmin = user.role == AppConstants.roleAdmin;
    final isOperator = user.role == AppConstants.roleOperator;
    final canOperate = isAdmin || isOperator;

    if (!canOperate) return const [];

    // La operadora valida pagos y administra paradas. Lo financiero
    // (Caja) sigue siendo 100% del admin del grupo, así que NO lo ve.
    // El reporte GENERAL del tenant (carreras del día por hora + estimado $)
    // SÍ lo ve, porque la operadora gestiona la operación y por reglas ya
    // puede leer todas las carreras de la asociación. También tiene un
    // reporte personal con los pagos que ELLA validó por día/semana/mes.
    if (isOperator) {
      return [
        _ActionTile(
          title: 'Validar pagos',
          icon: Icons.fact_check_outlined,
          onTap: () => context.push('/payment-approvals'),
        ),
        _ActionTile(
          title: 'Cambios de unidad',
          icon: Icons.directions_car_filled,
          onTap: () => context.push('/vehicle-change-requests'),
        ),
        _ActionTile(
          title: 'Mis validaciones',
          icon: Icons.assignment_turned_in_outlined,
          onTap: () => context.push('/operator-validations'),
        ),
        _ActionTile(
          title: 'Reportes',
          icon: Icons.bar_chart_outlined,
          onTap: () => context.push('/reports'),
        ),
        _ActionTile(
          title: 'Paradas',
          icon: Icons.flag_outlined,
          onTap: () => context.push('/taxi-stands'),
        ),
      ];
    }

    return [
      _ActionTile(
        title: 'Validar pagos',
        icon: Icons.fact_check_outlined,
        onTap: () => context.push('/payment-approvals'),
      ),
      _ActionTile(
        title: 'Cambios de unidad',
        icon: Icons.directions_car_filled,
        onTap: () => context.push('/vehicle-change-requests'),
      ),
      _ActionTile(
        title: 'Caja',
        icon: Icons.account_balance_wallet_outlined,
        onTap: () => context.push('/cashflow'),
      ),
      _ActionTile(
        title: 'Reportes',
        icon: Icons.bar_chart_outlined,
        onTap: () => context.push('/reports'),
      ),
      _ActionTile(
        title: 'Paradas',
        icon: Icons.flag_outlined,
        onTap: () => context.push('/taxi-stands'),
      ),
    ];
  }

  List<_ActionTile> _adminActions(UserModel user, {required bool isSuper}) {
    final isAdmin = user.role == AppConstants.roleAdmin;
    if (!isAdmin && !isSuper) return const [];

    return [
      _ActionTile(
        title: 'Socios',
        icon: Icons.people_outline,
        onTap: () => context.push('/members'),
      ),
      _ActionTile(
        title: 'Avisos',
        icon: Icons.campaign_outlined,
        onTap: () => context.push('/notifications'),
      ),
      _ActionTile(
        title: 'Branding',
        icon: Icons.palette_outlined,
        onTap: () => context.push('/theme-settings'),
      ),
      // Configuración financiera agrupada en un solo tile → bottom-sheet
      // con las 3 opciones. Reduce la densidad de la grilla de Administración.
      _ActionTile(
        title: 'Cobros y caja',
        icon: Icons.tune,
        onTap: () => _showFinanceConfigSheet(context),
      ),
      _ActionTile(
        title: 'Ubicación parada',
        icon: Icons.location_on_outlined,
        onTap: () => context.push('/stand-location'),
      ),
      if (isSuper)
        _ActionTile(
          title: 'Panel SaaS',
          icon: Icons.shield_outlined,
          onTap: () => context.push('/super'),
        ),
    ];
  }

  /// Submenú de configuración financiera. Agrupa las 3 pantallas de cobros
  /// y caja en un bottom-sheet para no saturar la grilla de Administración.
  void _showFinanceConfigSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Cobros y caja',
                  style: Theme.of(sheetCtx).textTheme.titleMedium,
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.tune, color: AppTheme.categorical[0]),
              title: const Text('Configuración de cobros'),
              subtitle: const Text('Monto, periodo, multas'),
              onTap: () {
                Navigator.pop(sheetCtx);
                context.push('/billing-config');
              },
            ),
            ListTile(
              leading: Icon(Icons.list_alt_outlined,
                  color: AppTheme.categorical[1]),
              title: const Text('Conceptos de pago'),
              subtitle: const Text('Cuotas, multas, ayudas'),
              onTap: () {
                Navigator.pop(sheetCtx);
                context.push('/payment-concepts');
              },
            ),
            ListTile(
              leading: Icon(Icons.category_outlined,
                  color: AppTheme.categorical[2]),
              title: const Text('Categorías de caja'),
              subtitle: const Text('Ingresos y egresos'),
              onTap: () {
                Navigator.pop(sheetCtx);
                context.push('/cashflow-categories');
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────── Sub-widgets ──────────────────────────

/// Item simple del bottom-nav custom (icono + label).
class _NavBarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int badgeCount;

  const _NavBarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : Colors.grey.shade600;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          badgeCount > 0
              ? Badge(
                  label: Text('$badgeCount'),
                  child: Icon(icon, color: color, size: 24),
                )
              : Icon(icon, color: color, size: 24),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              color: color,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}

class _ProfileGreetingCard extends StatelessWidget {
  final UserModel user;
  const _ProfileGreetingCard({required this.user});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;
    final onPrimary = scheme.onPrimary;
    final initials = (user.name.isNotEmpty ? user.name[0] : '').toUpperCase() +
        (user.lastname.isNotEmpty ? user.lastname[0] : '').toUpperCase();
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/profile'),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                primary,
                primary.withValues(alpha: 0.75),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: onPrimary.withValues(alpha: 0.25),
                child: Text(
                  initials.isEmpty ? '?' : initials,
                  style: TextStyle(
                    color: onPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hola, ${user.name}',
                      style: TextStyle(
                        color: onPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: onPrimary.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _roleLabel(user.role),
                        style: TextStyle(
                            color: onPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (user.numeroVehiculo.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Unidad #${user.numeroVehiculo}'
                        '${user.placa.isNotEmpty ? " · ${user.placa}" : ""}',
                        style: TextStyle(
                          color: onPrimary.withValues(alpha: 0.85),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: onPrimary.withValues(alpha: 0.7)),
            ],
          ),
        ),
      ),
    );
  }

  String _roleLabel(String role) {
    switch (role) {
      case AppConstants.roleAdmin:
        return 'ADMINISTRADOR';
      case AppConstants.roleOperator:
        return 'OPERADORA';
      case AppConstants.roleDriver:
        return 'CONDUCTOR';
      default:
        return role.toUpperCase();
    }
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: Colors.black54,
        ),
      ),
    );
  }
}

class _CardGrid extends StatelessWidget {
  final List<_ActionTile> items;
  const _CardGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    // Paleta categórica coherente: color por posición en la grilla, en vez
    // de los colores ad-hoc (Colors.teal/deepPurple…) que tenía cada tile.
    final colored = <Widget>[
      for (var i = 0; i < items.length; i++)
        items[i]._withColor(
            AppTheme.categorical[i % AppTheme.categorical.length]),
    ];
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: AppSpacing.sm,
      mainAxisSpacing: AppSpacing.sm,
      childAspectRatio: 0.95, // tarjetas casi cuadradas
      children: colored,
    );
  }
}

class _ActionTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  /// Color asignado por la grilla (paleta categórica). Si es null se usa
  /// el primario del tema como respaldo.
  final Color? color;

  const _ActionTile({
    required this.title,
    required this.icon,
    required this.onTap,
    this.color,
  });

  _ActionTile _withColor(Color c) => _ActionTile(
        title: title,
        icon: icon,
        onTap: onTap,
        color: c,
      );

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Theme.of(context).colorScheme.primary;
    return Material(
      color: Colors.white,
      elevation: 1.5,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
