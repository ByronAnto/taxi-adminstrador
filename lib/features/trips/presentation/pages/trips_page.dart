import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/driver_location_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/trip_model.dart';
import '../../domain/usecases/trip_usecases.dart';
import '../bloc/trip_bloc.dart';
import '../widgets/active_driver_picker_sheet.dart';

/// Página de gestión de carreras/viajes
class TripsPage extends StatefulWidget {
  const TripsPage({super.key});

  @override
  State<TripsPage> createState() => _TripsPageState();
}

class _TripsPageState extends State<TripsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _filterStatus = 'Todos';

  /// Línea de detalle con icono Material + texto (reemplaza emojis en UI).
  Widget _iconLine(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: AppSpacing.xs),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  /// Mapeo de los chips válidos por tab. Evita combinaciones imposibles
  /// como "Historial + Asignado" (asignado nunca está en historial).
  static const _filtersForActive = ['Todos', 'En progreso', 'Asignado'];
  static const _filtersForHistory = [
    'Todos',
    'Finalizado',
    'Completado',
    'Cancelado',
  ];

  @override
  void initState() {
    super.initState();
    // Solo 2 tabs: Activas + Historial. Stats vivían acá pero
    // duplicaban /reports → eliminados. Hoy "Reportes" es el único
    // lugar canónico para análisis.
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);

    // Visibilidad por rol (debe cuadrar con las reglas Firestore):
    // - Conductor: solo SUS carreras (watchTripsByDriver(uid)). No debe ver
    //   las carreras asignadas a otros conductores.
    // - Operadora/Admin: todas las activas (watchActiveTrips()).
    final auth = context.read<AuthBloc>().state;
    final isDriver = auth is AuthAuthenticated &&
        auth.user.role == AppConstants.roleDriver;
    if (isDriver) {
      final uid = (auth).user.uid;
      context.read<TripBloc>().add(TripsWatchStarted(driverId: uid));
      context.read<TripBloc>().add(TripHistoryLoadRequested(driverId: uid));
    } else {
      context.read<TripBloc>().add(TripsWatchStarted());
      context.read<TripBloc>().add(TripHistoryLoadRequested());
    }
  }

  /// uid del conductor logueado, o null si el rol es operadora/admin.
  /// Centraliza la decisión de query por rol para no divergir entre el
  /// arranque (initState) y los refrescos tras una acción (listener).
  String? get _driverScopeUid {
    final auth = context.read<AuthBloc>().state;
    if (auth is AuthAuthenticated &&
        auth.user.role == AppConstants.roleDriver) {
      return auth.user.uid;
    }
    return null;
  }

  /// Relanza los streams/historial respetando la visibilidad por rol.
  void _refreshTripStreams() {
    final uid = _driverScopeUid;
    context.read<TripBloc>().add(TripsWatchStarted(driverId: uid));
    context.read<TripBloc>().add(TripHistoryLoadRequested(driverId: uid));
  }

  /// Si el usuario tenía un chip que no aplica al nuevo tab, resetea a "Todos".
  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final allowed = _allowedFiltersForCurrentTab();
    if (!allowed.contains(_filterStatus)) {
      setState(() => _filterStatus = 'Todos');
    } else {
      setState(() {}); // forzar re-render de los chips visibles
    }
  }

  List<String> _allowedFiltersForCurrentTab() {
    switch (_tabController.index) {
      case 0:
        return _filtersForActive;
      case 1:
      default:
        return _filtersForHistory;
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<TripBloc, TripState>(
      listener: (context, state) {
        if (state is TripActionSuccess) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: AppTheme.statusFree,
            ),
          );
          _refreshTripStreams();
        } else if (state is TripError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: AppTheme.errorColor,
            ),
          );
        }
      },
      buildWhen: (prev, curr) =>
          curr is TripsLoaded || curr is TripLoading || curr is TripInitial,
      builder: (context, state) {
        // Esta página se abre como ruta pusheada (context.push('/trips')),
        // por eso necesita su propio Scaffold + AppBar con flecha de
        // regresar. El leading usa context.pop() (go_router) para volver a
        // la pantalla anterior; si no hay nada que descartar, hace fallback
        // a la raíz.
        final title = _driverScopeUid != null ? 'Mis carreras' : 'Carreras';
        return Scaffold(
          appBar: AppBar(
            title: Text(title),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Regresar',
              onPressed: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/');
                }
              },
            ),
          ),
          body: Column(
            children: [
              _buildQuickTripBar(),
            Container(
              color: Theme.of(context).colorScheme.secondary,
              child: TabBar(
                controller: _tabController,
                indicatorColor: Theme.of(context).colorScheme.primary,
                labelColor: Theme.of(context).colorScheme.primary,
                unselectedLabelColor: Colors.white70,
                tabs: const [
                  Tab(text: 'Activas', icon: Icon(Icons.directions_car, size: 20)),
                  Tab(text: 'Historial', icon: Icon(Icons.history, size: 20)),
                ],
              ),
            ),
            _buildFilterBar(),
            Expanded(
              child: state is TripLoading
                  ? const LoadingState(message: 'Cargando carreras...')
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildActiveTrips(state),
                        _buildTripHistory(state),
                      ],
                    ),
            ),
            ],
          ),
        );
      },
    );
  }

  /// Barra superior con botón "+1 carrera" (solo conductores).
  ///
  /// Crea una carrera rápida con el GPS actual como pickup, status finalizado
  /// y source manual. Sin formularios — un click y listo. Después en el
  /// historial el conductor puede tap-largo para editar monto/destino.
  Widget _buildQuickTripBar() {
    final authState = context.watch<AuthBloc>().state;
    if (authState is! AuthAuthenticated) return const SizedBox.shrink();
    if (authState.user.role != AppConstants.roleDriver) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _showQuickTripDialog(
                authState.user.uid,
                '${authState.user.name} ${authState.user.lastname}'.trim(),
                authState.user.associationId,
              ),
              icon: const Icon(Icons.add_circle_outline),
              label: Text('+1 carrera',
                  style: Theme.of(context).textTheme.titleMedium),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Dialog rápido para registrar carrera con tarifa, método y destino.
  ///
  /// Mantiene la velocidad del flujo (los 3 campos son opcionales —
  /// dejarlos en blanco crea la carrera "sin datos" como antes), pero
  /// cuando el conductor sí los llena, los reportes financieros (top
  /// conductores, ingresos diarios, métodos de pago) se llenan con
  /// data real en vez de ceros.
  Future<void> _showQuickTripDialog(
      String driverId, String driverName, String associationId) async {
    final fareCtrl = TextEditingController();
    final destCtrl = TextEditingController();
    String method = 'efectivo'; // efectivo | transferencia
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: const Text('+1 carrera'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: fareCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Tarifa (opcional)',
                  prefixText: '\$ ',
                  hintText: '2.50',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'efectivo',
                      label: Text('Efectivo'),
                      icon: Icon(Icons.attach_money)),
                  ButtonSegment(
                      value: 'transferencia',
                      label: Text('Transfer'),
                      icon: Icon(Icons.swap_horiz)),
                ],
                selected: {method},
                onSelectionChanged: (s) =>
                    setLocal(() => method = s.first),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: destCtrl,
                decoration: const InputDecoration(
                  labelText: 'Destino (opcional)',
                  hintText: 'Ej. La Carolina',
                  prefixIcon: Icon(Icons.flag_outlined),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Si dejas en blanco, registra solo la carrera sin datos. '
                'Pero llenarlos hace que los reportes muestren tus '
                'ingresos reales.',
                style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                    color: AppTheme.textSecondary,
                    fontStyle: FontStyle.italic),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.check),
              label: const Text('Guardar'),
            ),
          ],
        );
      }),
    );
    if (ok != true) return;
    final fare = double.tryParse(fareCtrl.text.replaceAll(',', '.'));
    await _addQuickTrip(
      driverId,
      driverName,
      associationId,
      fare: (fare != null && fare > 0) ? fare : null,
      paymentMethod: method,
      dropoffAddress: destCtrl.text.trim().isEmpty
          ? null
          : destCtrl.text.trim(),
    );
  }

  /// Crea una carrera rápida en Firestore.
  /// Pickup = última posición conocida del GPS, o (0,0) si no hay.
  /// Status = finalizado, source = manual.
  /// Si el conductor llenó tarifa/método/destino, se guardan también
  /// para que los reports financieros tengan data real.
  Future<void> _addQuickTrip(
    String driverId,
    String driverName,
    String associationId, {
    double? fare,
    String paymentMethod = 'efectivo',
    String? dropoffAddress,
  }) async {
    final loc = DriverLocationService.instance;
    final now = DateTime.now();
    final trip = TripModel(
      uid: const Uuid().v4(),
      associationId: associationId,
      driverId: driverId,
      driverName: driverName.isEmpty ? null : driverName,
      pickupLatitude: loc.lastLatitude ?? 0.0,
      pickupLongitude: loc.lastLongitude ?? 0.0,
      pickupAddress: '',
      dropoffAddress: dropoffAddress,
      fare: fare,
      paymentMethod: paymentMethod,
      status: TripStatus.finalizado,
      source: TripSource.manual,
      startTime: now,
      endTime: now,
      durationMinutes: 0,
      createdAt: now,
    );
    HapticFeedback.lightImpact();
    context.read<TripBloc>().add(TripCreateRequested(trip));
  }

  Widget _buildFilterBar() {
    final statuses = _allowedFiltersForCurrentTab();
    // Estadísticas no usa chips → no mostramos la barra entera.
    if (statuses.isEmpty) return const SizedBox.shrink();
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: statuses.length,
        itemBuilder: (context, index) {
          final status = statuses[index];
          final isSelected = status == _filterStatus;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilterChip(
              label: Text(status,
                  style: Theme.of(context).textTheme.bodySmall),
              selected: isSelected,
              selectedColor: Theme.of(context).colorScheme.primary,
              onSelected: (selected) {
                setState(() => _filterStatus = selected ? status : 'Todos');
              },
            ),
          );
        },
      ),
    );
  }

  /// Filtro client-side: esta pantalla SOLO muestra las carreras del flujo
  /// web (`source == 'webCliente'`), tanto en Activas como en Historial. Las
  /// de calle (`street`) y parada/cola (`standQueue`) siguen otro flujo (se
  /// finalizan al día siguiente) y no pertenecen a este apartado web de
  /// asignar→finalizar. Se aplica sobre los resultados del stream para no
  /// requerir índices Firestore nuevos. Las carreras viejas sin `source` se
  /// leen como `manual` en el modelo, así que quedan excluidas (no-web).
  static bool _isWebTrip(TripModel t) => t.source == TripSource.webCliente;

  List<TripModel> _getActiveTrips(TripState state) {
    if (state is! TripsLoaded) return [];
    final trips = state.activeTrips.where(_isWebTrip);
    if (_filterStatus == 'Todos') {
      return trips.where((t) => t.status == 'en_progreso' || t.status == 'asignado').toList();
    }
    final statusKey = _filterStatus.toLowerCase().replaceAll(' ', '_');
    return trips.where((t) => t.status == statusKey).toList();
  }

  List<TripModel> _getHistoryTrips(TripState state) {
    if (state is! TripsLoaded) return [];
    final trips = state.historyTrips.where(_isWebTrip);
    if (_filterStatus == 'Todos') {
      // El historial incluye las carreras finalizadas (status nuevo
      // 'finalizado' del botón "Viaje finalizado"), las completadas (alias
      // legacy 'completado') y las canceladas.
      return trips
          .where((t) =>
              t.status == TripStatus.finalizado ||
              t.status == TripStatus.completado ||
              t.status == TripStatus.cancelado)
          .toList();
    }
    final statusKey = _filterStatus.toLowerCase().replaceAll(' ', '_');
    return trips.where((t) => t.status == statusKey).toList();
  }

  Widget _buildActiveTrips(TripState state) {
    final activeTrips = _getActiveTrips(state);
    // Separar carreras programadas (paraCuando en futuro) de inmediatas.
    // Las programadas van arriba con badge "PROGRAMADA · 14:30".
    final now = DateTime.now();
    final scheduled = activeTrips
        .where((t) =>
            t.scheduledFor != null && t.scheduledFor!.isAfter(now))
        .toList()
      ..sort((a, b) => a.scheduledFor!.compareTo(b.scheduledFor!));
    final immediate = activeTrips
        .where((t) =>
            t.scheduledFor == null || !t.scheduledFor!.isAfter(now))
        .toList();

    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        // Sección "Por asignar": solicitudes pendientes del tenant. Visible a
        // TODOS los roles (lectura); el botón "Asignar" se restringe dentro
        // del widget a operadora/admin.
        _buildPendingRequestsSection(),
        if (activeTrips.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: EmptyState(
              icon: Icons.local_taxi,
              title: 'No hay carreras web por ahora',
            ),
          ),
        if (scheduled.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs + 2),
            child: Row(
              children: [
                Icon(Icons.schedule,
                    size: 16, color: AppTheme.categorical[2]),
                const SizedBox(width: AppSpacing.xs + 2),
                Text(
                  'CARRERAS PROGRAMADAS (${scheduled.length})',
                  style: textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                    color: AppTheme.categorical[2],
                  ),
                ),
              ],
            ),
          ),
          for (final t in scheduled) _buildScheduledCard(t),
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs + 2),
            child: Text(
              'CARRERAS INMEDIATAS',
              style: textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w900,
                letterSpacing: 0.6,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        ],
        for (final t in immediate) _buildTripCard(t, isActive: true),
      ],
    );
  }

  /// Sección "Por asignar": tripRequests con estado 'pendiente' del tenant.
  ///
  /// La lista es de SOLO LECTURA para conductores (ven qué carreras hay por
  /// asignar pero no pueden asignarlas). Operadora/admin obtienen el botón
  /// "Asignar". Si no hay pendientes, no ocupa espacio.
  Widget _buildPendingRequestsSection() {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return const SizedBox.shrink();
    final user = auth.user;
    final aid = user.associationId;
    final canAssign = user.role == AppConstants.roleAdmin ||
        user.role == AppConstants.roleOperator;

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppConstants.tripRequestsCollection)
          .where('associationId', isEqualTo: aid)
          .where('estado', isEqualTo: 'pendiente')
          .orderBy('cuandoSolicitado', descending: true)
          .limit(50)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        final textTheme = Theme.of(context).textTheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs + 2),
              child: Row(
                children: [
                  const Icon(Icons.assignment_late,
                      size: 16, color: AppTheme.warningColor),
                  const SizedBox(width: AppSpacing.xs + 2),
                  Text(
                    'POR ASIGNAR (${docs.length})',
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                      color: AppTheme.warningColor,
                    ),
                  ),
                ],
              ),
            ),
            for (final d in docs)
              _buildPendingRequestCard(
                d.reference,
                d.data(),
                canAssign: canAssign,
                user: user,
                aid: aid,
              ),
            const SizedBox(height: AppSpacing.lg),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs + 2),
              child: Text(
                'CARRERAS ASIGNADAS',
                style: textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.6,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Card de una solicitud pendiente. El botón "Asignar" solo aparece para
  /// operadora/admin; el conductor la ve en modo lectura.
  Widget _buildPendingRequestCard(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> r, {
    required bool canAssign,
    required dynamic user,
    required String aid,
  }) {
    final cuando = (r['cuandoSolicitado'] as Timestamp?)?.toDate();
    final origen = r['origen'] as Map<String, dynamic>?;
    final destino = r['destino'] as Map<String, dynamic>?;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AppTheme.warningColor.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.warningColor.withValues(alpha: 0.15),
          child: const Icon(Icons.schedule, color: AppTheme.warningColor),
        ),
        title: Text(
          r['clienteNombre'] ?? 'Cliente sin nombre',
          style: textTheme.titleMedium,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((r['clienteTelefono'] ?? '').toString().isNotEmpty)
              _iconLine(Icons.phone, '${r['clienteTelefono']}'),
            _iconLine(
                Icons.location_on, origen?['address'] ?? '(sin origen)'),
            if (destino != null && destino['address'] != null)
              _iconLine(Icons.flag, '${destino['address']}'),
            if (cuando != null)
              Text(
                'Solicitada: ${DateFormat('dd MMM HH:mm').format(cuando)}',
                style: textTheme.labelSmall
                    ?.copyWith(color: AppTheme.textSecondary),
              ),
          ],
        ),
        trailing: canAssign
            ? FilledButton.tonal(
                onPressed: () => _assignPendingRequest(ref, r, user, aid),
                child: const Text('Asignar'),
              )
            : null,
      ),
    );
  }

  /// Card especial para carreras programadas (paraCuando futuro).
  /// Muestra un countdown si falta poco, o la fecha/hora completa.
  Widget _buildScheduledCard(TripModel trip) {
    final dt = trip.scheduledFor!;
    final now = DateTime.now();
    final diff = dt.difference(now);
    String label;
    Color color;
    if (diff.inMinutes < 60) {
      label = 'En ${diff.inMinutes} min';
      color = AppTheme.errorColor;
    } else if (diff.inHours < 24) {
      label = 'En ${diff.inHours} h ${diff.inMinutes.remainder(60)} min';
      color = AppTheme.warningColor;
    } else {
      label = DateFormat('dd MMM HH:mm').format(dt);
      color = AppTheme.categorical[2];
    }
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(Icons.schedule, color: color),
        ),
        title: Text(
          trip.clienteNombre ?? 'Carrera programada',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((trip.clienteTelefono ?? '').isNotEmpty)
              _iconLine(Icons.phone, '${trip.clienteTelefono}'),
            if (trip.pickupAddress.isNotEmpty)
              _iconLine(Icons.location_on, trip.pickupAddress),
            if ((trip.dropoffAddress ?? '').isNotEmpty)
              _iconLine(Icons.flag, '${trip.dropoffAddress}'),
          ],
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        onTap: () => _showTripDetails(trip),
      ),
    );
  }

  Widget _buildTripHistory(TripState state) {
    final historyTrips = _getHistoryTrips(state);
    final primary = Theme.of(context).colorScheme.primary;
    final reportsButton = Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => context.push('/reports'),
          icon: const Icon(Icons.bar_chart, size: 18),
          label: const Text('Ver reportes completos'),
          style: OutlinedButton.styleFrom(
            foregroundColor: primary,
            side: BorderSide(color: primary.withValues(alpha: 0.4)),
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          ),
        ),
      ),
    );

    if (historyTrips.isEmpty) {
      return Column(
        children: [
          reportsButton,
          const Expanded(
            child: EmptyState(
              icon: Icons.history,
              title: 'No hay carreras web en el historial',
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        reportsButton,
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
            itemCount: historyTrips.length,
            itemBuilder: (context, index) =>
                _buildTripCard(historyTrips[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildTripCard(TripModel trip, {bool isActive = false}) {
    Color statusColor;
    String statusLabel;
    IconData statusIcon;

    switch (trip.status) {
      case 'en_progreso':
        statusColor = AppTheme.statusFree;
        statusLabel = 'En progreso';
        statusIcon = Icons.directions_car;
      case 'asignado':
        statusColor = AppTheme.statusReturning;
        statusLabel = 'Asignado';
        statusIcon = Icons.assignment;
      case 'finalizado':
        statusColor = AppTheme.infoColor;
        statusLabel = 'Finalizado';
        statusIcon = Icons.flag;
      case 'completado':
        statusColor = AppTheme.infoColor;
        statusLabel = 'Completado';
        statusIcon = Icons.check_circle;
      case 'cancelado':
        statusColor = AppTheme.errorColor;
        statusLabel = 'Cancelado';
        statusIcon = Icons.cancel;
      default:
        statusColor = AppTheme.statusOffline;
        statusLabel = 'Desconocido';
        statusIcon = Icons.help;
    }

    final timeStr = DateFormat('HH:mm').format(trip.startTime);

    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showTripDetails(trip),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(statusIcon, size: 14, color: statusColor),
                        const SizedBox(width: AppSpacing.xs),
                        Text(statusLabel,
                            style: textTheme.bodySmall?.copyWith(
                                color: statusColor,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(timeStr,
                      style: textTheme.bodySmall
                          ?.copyWith(color: AppTheme.textSecondary)),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      Container(
                        width: 10, height: 10,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: AppTheme.statusFree),
                      ),
                      Container(
                          width: 2, height: 20, color: AppTheme.dividerColor),
                      Container(
                        width: 10, height: 10,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: AppTheme.errorColor),
                      ),
                    ],
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(trip.pickupAddress, style: textTheme.bodyMedium),
                        const SizedBox(height: AppSpacing.sm),
                        Text(trip.dropoffAddress ?? 'Destino pendiente',
                            style: textTheme.bodyMedium),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.md),
              // Carrera web: lo relevante es el cliente. Mostramos su nombre
              // de forma prominente (+ teléfono si hay) y el conductor por
              // NOMBRE denormalizado, nunca por UID crudo.
              Row(
                children: [
                  const Icon(Icons.person, size: 16, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(trip.clienteNombre ?? 'Cliente',
                            style: textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        if ((trip.clienteTelefono ?? '').trim().isNotEmpty)
                          Row(
                            children: [
                              const Icon(Icons.phone,
                                  size: 12, color: AppTheme.textSecondary),
                              const SizedBox(width: AppSpacing.xs),
                              Text(trip.clienteTelefono!.trim(),
                                  style: textTheme.bodySmall?.copyWith(
                                      color: AppTheme.textSecondary)),
                            ],
                          ),
                        Text('Conductor: ${trip.driverName ?? 'Conductor'}',
                            style: textTheme.bodySmall
                                ?.copyWith(color: AppTheme.textSecondary)),
                      ],
                    ),
                  ),
                  if (trip.fare != null && trip.fare! > 0)
                    Text('\$${trip.fare!.toStringAsFixed(2)}',
                        style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color:
                                Theme.of(context).colorScheme.secondary)),
                ],
              ),
              if (isActive) _buildActiveCardActions(trip),
            ],
          ),
        ),
      ),
    );
  }

  /// Botones de acción inline en una card de carrera activa.
  ///
  /// - El conductor DUEÑO (driverId == uid) puede "Viaje finalizado" desde
  ///   'asignado' o 'en_progreso' (cierra directo, sin tarifa).
  /// - "Completar" (legacy, captura datos por defecto) se mantiene solo para
  ///   'en_progreso'.
  /// - "Cancelar" disponible para operadora/admin sobre carreras vivas.
  Widget _buildActiveCardActions(TripModel trip) {
    final auth = context.read<AuthBloc>().state;
    final user = auth is AuthAuthenticated ? auth.user : null;
    final isDriverOwner = user != null && trip.driverId == user.uid;
    final isOperatorOrAdmin = user != null &&
        (user.role == AppConstants.roleAdmin ||
            user.role == AppConstants.roleOperator);
    final isLive = !trip.isFinished && trip.status != TripStatus.cancelado;

    final buttons = <Widget>[];

    if (isOperatorOrAdmin && isLive) {
      // "Reasignar" visible directamente en la tarjeta (antes solo estaba
      // enterrada en la hoja de detalle y la operadora no la encontraba).
      // Reutiliza el flujo existente `_reassignTrip` (selector de activos +
      // auditoría en trips/{id}/reassignments).
      final secondary = Theme.of(context).colorScheme.secondary;
      buttons.add(OutlinedButton.icon(
        onPressed: () => _reassignTrip(trip),
        icon: const Icon(Icons.swap_horiz, size: 16),
        label: const Text('Reasignar'),
        style: OutlinedButton.styleFrom(
          foregroundColor: secondary,
          side: BorderSide(color: secondary),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        ),
      ));
      buttons.add(OutlinedButton.icon(
        onPressed: () => _cancelTrip(trip),
        icon: const Icon(Icons.cancel, size: 16),
        label: const Text('Cancelar'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.errorColor,
          side: const BorderSide(color: AppTheme.errorColor),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        ),
      ));
    }

    // "Viaje finalizado": el conductor dueño cierra la carrera directamente
    // desde 'asignado' (o 'en_progreso'). No captura monto — los totales solo
    // cuentan cantidad de carreras y los incrementa una Cloud Function.
    if (isDriverOwner && isLive) {
      buttons.add(ElevatedButton.icon(
        onPressed: () => _finalizeTrip(trip),
        icon: const Icon(Icons.flag, size: 16),
        label: const Text('Viaje finalizado'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        ),
      ));
    }

    if (trip.status == 'en_progreso' && (isDriverOwner || isOperatorOrAdmin)) {
      buttons.add(ElevatedButton.icon(
        onPressed: () => _completeTrip(trip),
        icon: const Icon(Icons.check, size: 16),
        label: const Text('Completar'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.statusFree,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        ),
      ));
    }

    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: buttons,
      ),
    );
  }

  /// Finaliza la carrera (status 'finalizado' + finalizadoAt). Confirma con
  /// un SnackBar a través del listener del BlocConsumer (TripActionSuccess).
  void _finalizeTrip(TripModel trip) {
    context.read<TripBloc>().add(
          TripFinalizeRequested(trip.uid, tripRequestId: trip.tripRequestId),
        );
  }

  /// Cancela la carrera (operadora/admin). Pide confirmación + motivo opcional,
  /// despacha [TripCancelRequested] (pone `status: 'cancelado'` + `canceladoAt`
  /// + `updatedAt`) y propaga la cancelación al `tripRequests/{id}` enlazado
  /// (`estado: 'cancelada'`) cuando existe `tripRequestId`. El resultado se
  /// confirma con un SnackBar vía el listener del BlocConsumer.
  void _cancelTrip(TripModel trip) {
    showDialog(
      context: context,
      builder: (ctx) {
        final reasonController = TextEditingController();
        return AlertDialog(
          title: const Text('¿Cancelar esta carrera?'),
          content: TextField(
            controller: reasonController,
            decoration: const InputDecoration(
              labelText: 'Razón (opcional)',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('No')),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                context.read<TripBloc>().add(TripCancelRequested(
                  trip.uid,
                  reason: reasonController.text.isNotEmpty ? reasonController.text : null,
                  tripRequestId: trip.tripRequestId,
                ));
              },
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorColor),
              child: const Text('Cancelar carrera'),
            ),
          ],
        );
      },
    );
  }

  void _completeTrip(TripModel trip) {
    context.read<TripBloc>().add(TripCompleteRequested(CompleteTripParams(
      tripId: trip.uid,
      dropoffLatitude: trip.dropoffLatitude ?? trip.pickupLatitude,
      dropoffLongitude: trip.dropoffLongitude ?? trip.pickupLongitude,
      dropoffAddress: trip.dropoffAddress ?? 'Sin dirección',
      fare: trip.fare ?? 3.0,
      durationMinutes: trip.durationMinutes ?? 10,
      distanceKm: trip.distanceKm ?? 2.0,
    )));
  }

  void _showTripDetails(TripModel trip) {
    final timeStr = DateFormat('HH:mm').format(trip.startTime);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.8,
        minChildSize: 0.3,
        expand: false,
        builder: (ctx, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                      color: AppTheme.dividerColor,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Carrera ${trip.uid.length > 8 ? trip.uid.substring(0, 8) : trip.uid}',
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.lg),
              // Mostramos nombres legibles, nunca UIDs crudos.
              _detailRow(Icons.account_circle, 'Cliente',
                  trip.clienteNombre ?? 'Cliente'),
              if ((trip.clienteTelefono ?? '').trim().isNotEmpty)
                _detailRow(Icons.phone, 'Teléfono', trip.clienteTelefono!.trim()),
              _detailRow(
                  Icons.person, 'Conductor', trip.driverName ?? trip.driverId),
              if (trip.vehicleId != null)
                _detailRow(Icons.directions_car, 'Vehículo', trip.vehicleId!),
              _detailRow(Icons.location_on, 'Origen', trip.pickupAddress),
              _detailRow(Icons.flag, 'Destino', trip.dropoffAddress ?? 'Pendiente'),
              _detailRow(Icons.access_time, 'Hora', timeStr),
              if (trip.fare != null && trip.fare! > 0)
                _detailRow(Icons.attach_money, 'Tarifa', '\$${trip.fare!.toStringAsFixed(2)}'),
              _detailRow(Icons.payment, 'Método pago', trip.paymentMethod),
              if (trip.durationMinutes != null)
                _detailRow(Icons.timer, 'Duración', '${trip.durationMinutes} min'),
              if (trip.distanceKm != null)
                _detailRow(Icons.straighten, 'Distancia', '${trip.distanceKm!.toStringAsFixed(1)} km'),
              if (trip.notes != null && trip.notes!.isNotEmpty)
                _detailRow(Icons.note, 'Notas', trip.notes!),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              _buildTripActions(trip, ctx),
            ],
          ),
        ),
      ),
    );
  }

  /// Acciones disponibles en la hoja de detalle del viaje según rol y estado.
  Widget _buildTripActions(TripModel trip, BuildContext sheetCtx) {
    final auth = context.read<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return const SizedBox.shrink();
    final user = auth.user;
    final isDriverOwner = trip.driverId == user.uid;
    final isOperatorOrAdmin = user.role == AppConstants.roleAdmin ||
        user.role == AppConstants.roleOperator;
    final canEdit =
        isDriverOwner || isOperatorOrAdmin; // ambos pueden editar info
    final canCancel = isOperatorOrAdmin && !trip.isFinished &&
        trip.status != TripStatus.cancelado;
    final canDelete = user.role == AppConstants.roleAdmin;
    // Reasignar: solo operadora/admin y solo sobre carreras vivas
    // (asignada / en ruta / en progreso). No tiene sentido reasignar una
    // carrera finalizada o cancelada.
    final canReassign = isOperatorOrAdmin &&
        !trip.isFinished &&
        trip.status != TripStatus.cancelado;

    // Acciones del conductor asignado: navegar al punto de recogida y
    // llamar al cliente. Solo se muestran cuando el conductor es el dueño
    // de la carrera y existen los datos necesarios.
    final hasPickupLocation =
        trip.pickupLatitude != 0.0 || trip.pickupLongitude != 0.0;
    final clientPhone = (trip.clienteTelefono ?? '').trim();
    final hasClientPhone = clientPhone.isNotEmpty;

    // El conductor dueño puede finalizar la carrera viva directamente.
    final canFinalize = isDriverOwner &&
        !trip.isFinished &&
        trip.status != TripStatus.cancelado;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (canFinalize)
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(sheetCtx).pop();
              _finalizeTrip(trip);
            },
            icon: const Icon(Icons.flag, size: 18),
            label: const Text('Viaje finalizado'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(sheetCtx).colorScheme.primary,
              foregroundColor: Theme.of(sheetCtx).colorScheme.onPrimary,
            ),
          ),
        if (isDriverOwner && hasPickupLocation)
          ElevatedButton.icon(
            onPressed: () => _navigateToPickup(trip),
            icon: const Icon(Icons.navigation, size: 18),
            label: const Text('Navegar a recogida'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.statusFree,
              foregroundColor: Colors.white,
            ),
          ),
        if (isDriverOwner && hasClientPhone)
          ElevatedButton.icon(
            onPressed: () => _callClient(clientPhone),
            icon: const Icon(Icons.phone, size: 18),
            label: const Text('Llamar al cliente'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondary,
              foregroundColor: Colors.white,
            ),
          ),
        if (canEdit)
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(sheetCtx).pop();
              _showEditTripDialog(trip);
            },
            icon: const Icon(Icons.edit, size: 18),
            label: const Text('Editar'),
          ),
        if (canReassign)
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(sheetCtx).pop();
              _reassignTrip(trip);
            },
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('Reasignar'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.secondary,
              side: BorderSide(color: Theme.of(context).colorScheme.secondary),
            ),
          ),
        if (canCancel)
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(sheetCtx).pop();
              _cancelTrip(trip);
            },
            icon: const Icon(Icons.cancel_outlined, size: 18),
            label: const Text('Cancelar viaje'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.warningColor,
              side: const BorderSide(color: AppTheme.warningColor),
            ),
          ),
        if (canDelete)
          OutlinedButton.icon(
            onPressed: () => _deleteTrip(trip, sheetCtx),
            icon: const Icon(Icons.delete, size: 18),
            label: const Text('Borrar'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.errorColor,
              side: const BorderSide(color: AppTheme.errorColor),
            ),
          ),
      ],
    );
  }

  /// Asigna una solicitud pendiente (tripRequests) a un conductor activo.
  ///
  /// Reutiliza el mismo selector y contrato de datos que
  /// `TripRequestsPage._assignRequest`: crea el doc en `trips/` con
  /// `tripRequestId` y refleja en el tripRequest `estado: 'asignada'`,
  /// `tripId` y `driverId` (para que el portal web del cliente y la Cloud
  /// Function vean el enlace). Solo operadora/admin llegan aquí.
  Future<void> _assignPendingRequest(
    DocumentReference<Map<String, dynamic>> reqRef,
    Map<String, dynamic> reqData,
    dynamic user,
    String aid,
  ) async {
    final pick = await showActiveDriverPicker(context, associationId: aid);
    if (pick == null) return;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    final tripId = const Uuid().v4();
    final reqId = reqRef.id;
    final origen = reqData['origen'] as Map<String, dynamic>?;
    final destino = reqData['destino'] as Map<String, dynamic>?;
    final operatorName = '${user.name} ${user.lastname}'.trim();

    final trip = TripModel(
      uid: tripId,
      associationId: aid,
      driverId: pick.userId,
      driverName: pick.driverName,
      operatorId: user.uid,
      operatorName: operatorName,
      tripRequestId: reqId,
      clienteNombre: reqData['clienteNombre'],
      clienteTelefono: reqData['clienteTelefono'],
      pickupLatitude: (origen?['lat'] ?? 0.0).toDouble(),
      pickupLongitude: (origen?['lng'] ?? 0.0).toDouble(),
      pickupAddress: origen?['address'] ?? '',
      dropoffLatitude:
          destino != null ? (destino['lat'] ?? 0.0).toDouble() : null,
      dropoffLongitude:
          destino != null ? (destino['lng'] ?? 0.0).toDouble() : null,
      dropoffAddress: destino?['address'],
      status: TripStatus.asignado,
      source: TripSource.webCliente,
      startTime: now,
      notes: reqData['notas'],
      createdAt: now,
    );

    try {
      await FirebaseFirestore.instance
          .collection(AppConstants.tripsCollection)
          .doc(tripId)
          .set(trip.toFirestore());
      await reqRef.update({
        'estado': 'asignada',
        'tripId': tripId,
        'driverId': pick.userId,
        // Datos denormalizados del conductor para que el portal web del
        // cliente los lea desde su propio tripRequest (no tiene permiso para
        // leer la colección `drivers/`).
        'conductorNombre': pick.driverName,
        'conductorVehiculo': pick.vehicleNumber,
        // Compatibilidad con lectores previos:
        'asignadoA': pick.userId,
        'asignadoTripId': tripId,
        'asignadoAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text('Carrera asignada a ${pick.driverName}'),
          backgroundColor: AppTheme.statusFree,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  /// Reasigna (redirecciona) una carrera viva a OTRO conductor activo.
  ///
  /// Reutiliza el selector centralizado de conductores activos
  /// ([showActiveDriverPicker], mismo stream/filtro que la asignación inicial)
  /// y deja registro de auditoría del cambio en
  /// `trips/{id}/reassignments/{autoId}` + campos rápidos en el doc principal.
  Future<void> _reassignTrip(TripModel trip) async {
    final auth = context.read<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return;
    final operator_ = auth.user;
    final aid = operator_.associationId;

    // 1) Elegir el nuevo conductor (se excluye el conductor actual).
    final pick = await showActiveDriverPicker(
      context,
      associationId: aid,
      title: 'Reasignar carrera a…',
      excludeUserId: trip.driverId,
    );
    if (pick == null) return;
    if (!mounted) return;

    // 2) Capturar un motivo opcional del cambio.
    final reason = await _askReassignReason(pick.driverName);
    if (!mounted) return;
    // Si el usuario cerró el diálogo con el botón "No reasignar", abortamos.
    if (reason == _kReassignCancelled) return;

    final messenger = ScaffoldMessenger.of(context);
    final changedByName =
        '${operator_.name} ${operator_.lastname}'.trim();

    final tripRef =
        FirebaseFirestore.instance.collection('trips').doc(trip.uid);
    final reassignmentRef = tripRef.collection('reassignments').doc();

    try {
      // Escritura atómica: actualiza el trip + agrega el registro de
      // auditoría en la subcolección, en un solo batch.
      final batch = FirebaseFirestore.instance.batch();
      batch.update(tripRef, {
        'driverId': pick.userId,
        'driverName': pick.driverName,
        // Datos rápidos para mostrar el último cambio sin abrir la subcol.
        'previousDriverId': trip.driverId,
        'previousDriverName': trip.driverName,
        'reassignedAt': FieldValue.serverTimestamp(),
        'reassignedByUid': operator_.uid,
        'reassignedByName': changedByName,
        'reassignmentCount': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      batch.set(reassignmentRef, {
        'associationId': trip.associationId,
        'fromDriverId': trip.driverId,
        'fromDriverName': trip.driverName,
        'toDriverId': pick.userId,
        'toDriverName': pick.driverName,
        'changedByUid': operator_.uid,
        'changedByName': changedByName,
        'reason': (reason ?? '').trim().isEmpty ? null : reason!.trim(),
        'timestamp': FieldValue.serverTimestamp(),
      });
      // Propaga el nuevo conductor al tripRequest enlazado (si existe), para
      // que el portal web del cliente vea el taxi reasignado sin leer
      // `drivers/`. Se hace en el mismo batch para mantener la atomicidad.
      final tripRequestId = trip.tripRequestId;
      if (tripRequestId != null && tripRequestId.isNotEmpty) {
        final reqRef = FirebaseFirestore.instance
            .collection(AppConstants.tripRequestsCollection)
            .doc(tripRequestId);
        batch.update(reqRef, {
          'driverId': pick.userId,
          'conductorNombre': pick.driverName,
          'conductorVehiculo': pick.vehicleNumber,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();

      // NOTA / TODO (status del conductor): NO tocamos el campo `status` de
      // los docs `drivers/` (ni el anterior a 'libre' ni el nuevo a
      // 'con_pasajero'). En esta app el status del conductor no se cambia
      // automáticamente al asignar (ver AssignTripModal) — lo maneja el
      // propio conductor / el flujo de queue. Cambiarlo aquí podría pisar
      // ese estado y dejar al conductor anterior marcado libre cuando aún
      // está atendiendo otra carrera. Se deja explícito como decisión.

      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Carrera reasignada a ${pick.driverName}'),
          backgroundColor: AppTheme.statusFree,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error al reasignar: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  /// Centinela para distinguir "diálogo cancelado" de "sin motivo".
  static const String _kReassignCancelled = '__cancelled__';

  /// Pide un motivo opcional para la reasignación. Devuelve el texto
  /// (posiblemente vacío) si se confirma, o [_kReassignCancelled] si se
  /// cancela el diálogo.
  Future<String?> _askReassignReason(String toDriverName) async {
    final reasonCtrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reasignar carrera'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Se reasignará a $toDriverName.',
                style: Theme.of(ctx).textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(
                labelText: 'Motivo (opcional)',
                hintText: 'Ej. conductor no disponible',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _kReassignCancelled),
            child: const Text('No reasignar'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, reasonCtrl.text),
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('Reasignar'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteTrip(TripModel trip, BuildContext sheetCtx) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar viaje'),
        content: const Text('¿Seguro? Esta acción es permanente.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.errorColor),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(trip.uid)
          .delete();
      messenger.showSnackBar(
        const SnackBar(content: Text('Viaje borrado')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _showEditTripDialog(TripModel trip) {
    final fareCtrl = TextEditingController(
        text: trip.fare == null ? '' : trip.fare!.toStringAsFixed(2));
    final destCtrl = TextEditingController(text: trip.dropoffAddress ?? '');
    final notesCtrl = TextEditingController(text: trip.notes ?? '');
    String method = trip.paymentMethod;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Editar viaje'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: fareCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Monto',
                    prefixText: '\$ ',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: destCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Destino',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: method,
                  decoration: const InputDecoration(
                    labelText: 'Método de pago',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'efectivo', child: Text('Efectivo')),
                    DropdownMenuItem(
                        value: 'digital', child: Text('Digital')),
                    DropdownMenuItem(
                        value: 'transferencia', child: Text('Transferencia')),
                  ],
                  onChanged: (v) => setLocal(() => method = v ?? 'efectivo'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Notas',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                final fare =
                    double.tryParse(fareCtrl.text.replaceAll(',', '.'));
                final updates = <String, dynamic>{
                  'fare': fare,
                  'dropoffAddress': destCtrl.text.trim().isEmpty
                      ? null
                      : destCtrl.text.trim(),
                  'paymentMethod': method,
                  'notes': notesCtrl.text.trim().isEmpty
                      ? null
                      : notesCtrl.text.trim(),
                  'updatedAt': FieldValue.serverTimestamp(),
                };
                try {
                  await FirebaseFirestore.instance
                      .collection('trips')
                      .doc(trip.uid)
                      .update(updates);
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Viaje actualizado')),
                  );
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Error: $e')),
                    );
                  }
                }
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
  }

  /// Muestra un selector (bottom sheet) para elegir la app de navegación
  /// hacia el punto de recogida: Google Maps o Waze. Cada opción abre la app
  /// externa correspondiente y avisa con SnackBar si no está disponible.
  Future<void> _navigateToPickup(TripModel trip) async {
    final lat = trip.pickupLatitude;
    final lng = trip.pickupLongitude;
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text('Navegar con…',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.map, color: AppTheme.statusFree),
              title: const Text('Google Maps'),
              onTap: () => Navigator.pop(ctx, 'gmaps'),
            ),
            ListTile(
              leading: const Icon(Icons.navigation, color: AppTheme.infoColor),
              title: const Text('Waze'),
              onTap: () => Navigator.pop(ctx, 'waze'),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (choice == null) return;

    // Google Maps: esquema universal (api=1) con travelmode=driving.
    // Waze: deep link ll + navigate=yes.
    final uri = choice == 'waze'
        ? Uri.parse('https://waze.com/ul?ll=$lat,$lng&navigate=yes')
        : Uri.parse(
            'https://www.google.com/maps/dir/?api=1'
            '&destination=$lat,$lng&travelmode=driving',
          );
    final appName = choice == 'waze' ? 'Waze' : 'Google Maps';
    await _launchExternal(uri, appName);
  }

  /// Lanza un URI en una app externa y maneja errores con SnackBar.
  Future<void> _launchExternal(Uri uri, String appName) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('No se pudo abrir $appName.'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('$appName no está disponible.'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  /// Abre el marcador del teléfono con el número del cliente (tel:).
  /// Un toque → marcador listo para llamar.
  Future<void> _callClient(String phone) async {
    final messenger = ScaffoldMessenger.of(context);
    // Limpia espacios y caracteres de formato que rompen el esquema tel:.
    final sanitized = phone.replaceAll(RegExp(r'[^\d+]'), '');
    final uri = Uri(scheme: 'tel', path: sanitized);
    try {
      final ok = await launchUrl(uri);
      if (!ok && mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('No se pudo abrir el marcador.'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No se pudo iniciar la llamada.'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  Widget _detailRow(IconData icon, String label, String value) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppTheme.textSecondary),
          const SizedBox(width: AppSpacing.md),
          Text('$label: ',
              style: textTheme.bodyMedium
                  ?.copyWith(color: AppTheme.textSecondary)),
          Expanded(
            child: Text(value,
                style: textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
