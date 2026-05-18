import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/driver_location_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/trip_model.dart';
import '../../domain/usecases/trip_usecases.dart';
import '../bloc/trip_bloc.dart';

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

  /// Mapeo de los chips válidos por tab. Evita combinaciones imposibles
  /// como "Historial + Asignado" (asignado nunca está en historial).
  static const _filtersForActive = ['Todos', 'En progreso', 'Asignado'];
  static const _filtersForHistory = ['Todos', 'Completado', 'Cancelado'];

  @override
  void initState() {
    super.initState();
    // Solo 2 tabs: Activas + Historial. Stats vivían acá pero
    // duplicaban /reports → eliminados. Hoy "Reportes" es el único
    // lugar canónico para análisis.
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    context.read<TripBloc>().add(TripsWatchStarted());
    context.read<TripBloc>().add(TripHistoryLoadRequested());
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
          context.read<TripBloc>().add(TripsWatchStarted());
          context.read<TripBloc>().add(TripHistoryLoadRequested());
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
        return Column(
          children: [
            _buildQuickTripBar(),
            Container(
              color: AppTheme.secondaryColor,
              child: TabBar(
                controller: _tabController,
                indicatorColor: AppTheme.primaryColor,
                labelColor: AppTheme.primaryColor,
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
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildActiveTrips(state),
                        _buildTripHistory(state),
                      ],
                    ),
            ),
          ],
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: Colors.white,
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
              label: const Text('+1 carrera',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
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
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
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
              label: Text(status, style: const TextStyle(fontSize: 12)),
              selected: isSelected,
              selectedColor: AppTheme.primaryColor,
              onSelected: (selected) {
                setState(() => _filterStatus = selected ? status : 'Todos');
              },
            ),
          );
        },
      ),
    );
  }

  List<TripModel> _getActiveTrips(TripState state) {
    if (state is! TripsLoaded) return [];
    final trips = state.activeTrips;
    if (_filterStatus == 'Todos') {
      return trips.where((t) => t.status == 'en_progreso' || t.status == 'asignado').toList();
    }
    final statusKey = _filterStatus.toLowerCase().replaceAll(' ', '_');
    return trips.where((t) => t.status == statusKey).toList();
  }

  List<TripModel> _getHistoryTrips(TripState state) {
    if (state is! TripsLoaded) return [];
    final trips = state.historyTrips;
    if (_filterStatus == 'Todos') {
      return trips.where((t) => t.status == 'completado' || t.status == 'cancelado').toList();
    }
    final statusKey = _filterStatus.toLowerCase().replaceAll(' ', '_');
    return trips.where((t) => t.status == statusKey).toList();
  }

  Widget _buildActiveTrips(TripState state) {
    final activeTrips = _getActiveTrips(state);
    if (activeTrips.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.local_taxi, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('No hay carreras activas',
                style: TextStyle(color: Colors.grey[500], fontSize: 16)),
          ],
        ),
      );
    }
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

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (scheduled.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(Icons.schedule,
                    size: 16, color: Colors.deepPurple),
                const SizedBox(width: 6),
                Text(
                  'CARRERAS PROGRAMADAS (${scheduled.length})',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                    color: Colors.deepPurple,
                  ),
                ),
              ],
            ),
          ),
          for (final t in scheduled) _buildScheduledCard(t),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'CARRERAS INMEDIATAS',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.6,
                color: Colors.grey.shade700,
              ),
            ),
          ),
        ],
        for (final t in immediate) _buildTripCard(t, isActive: true),
      ],
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
      color = Colors.red.shade700;
    } else if (diff.inHours < 24) {
      label = 'En ${diff.inHours} h ${diff.inMinutes.remainder(60)} min';
      color = Colors.deepOrange;
    } else {
      label = DateFormat('dd MMM HH:mm').format(dt);
      color = Colors.deepPurple;
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
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((trip.clienteTelefono ?? '').isNotEmpty)
              Text('📞 ${trip.clienteTelefono}'),
            if (trip.pickupAddress.isNotEmpty)
              Text('📍 ${trip.pickupAddress}'),
            if ((trip.dropoffAddress ?? '').isNotEmpty)
              Text('🏁 ${trip.dropoffAddress}'),
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
    final reportsButton = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => context.push('/reports'),
          icon: const Icon(Icons.bar_chart, size: 18),
          label: const Text('Ver reportes completos'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.primaryColor,
            side: BorderSide(
                color: AppTheme.primaryColor.withValues(alpha: 0.4)),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
    );

    if (historyTrips.isEmpty) {
      return Column(
        children: [
          reportsButton,
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey[300]),
                  const SizedBox(height: 16),
                  Text('Sin carreras en el historial',
                      style: TextStyle(
                          color: Colors.grey[500], fontSize: 16)),
                ],
              ),
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
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
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
      case 'completado':
        statusColor = Colors.blue;
        statusLabel = 'Completado';
        statusIcon = Icons.check_circle;
      case 'cancelado':
        statusColor = AppTheme.errorColor;
        statusLabel = 'Cancelado';
        statusIcon = Icons.cancel;
      default:
        statusColor = Colors.grey;
        statusLabel = 'Desconocido';
        statusIcon = Icons.help;
    }

    final timeStr = DateFormat('HH:mm').format(trip.startTime);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showTripDetails(trip),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(statusIcon, size: 14, color: statusColor),
                        const SizedBox(width: 4),
                        Text(statusLabel,
                            style: TextStyle(
                                color: statusColor,
                                fontWeight: FontWeight.w600,
                                fontSize: 12)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(timeStr,
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 12),
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
                      Container(width: 2, height: 20, color: Colors.grey[300]),
                      Container(
                        width: 10, height: 10,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: AppTheme.errorColor),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(trip.pickupAddress, style: const TextStyle(fontSize: 14)),
                        const SizedBox(height: 10),
                        Text(trip.dropoffAddress ?? 'Destino pendiente',
                            style: const TextStyle(fontSize: 14)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.person, size: 16, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  Text(trip.driverId,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                  const Spacer(),
                  if (trip.fare != null && trip.fare! > 0)
                    Text('\$${trip.fare!.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: AppTheme.secondaryColor)),
                ],
              ),
              if (isActive) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _cancelTrip(trip),
                      icon: const Icon(Icons.cancel, size: 16),
                      label: const Text('Cancelar'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.errorColor,
                        side: const BorderSide(color: AppTheme.errorColor),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (trip.status == 'en_progreso')
                      ElevatedButton.icon(
                        onPressed: () => _completeTrip(trip),
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('Completar'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.statusFree,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _cancelTrip(TripModel trip) {
    showDialog(
      context: context,
      builder: (ctx) {
        final reasonController = TextEditingController();
        return AlertDialog(
          title: const Text('Cancelar carrera'),
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
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              Text('Carrera ${trip.uid.length > 8 ? trip.uid.substring(0, 8) : trip.uid}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
              const SizedBox(height: 16),
              _detailRow(Icons.person, 'Conductor', trip.driverId),
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

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (canEdit)
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(sheetCtx).pop();
              _showEditTripDialog(trip);
            },
            icon: const Icon(Icons.edit, size: 18),
            label: const Text('Editar'),
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
              foregroundColor: Colors.orange.shade800,
              side: BorderSide(color: Colors.orange.shade800),
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

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppTheme.textSecondary),
          const SizedBox(width: 12),
          Text('$label: ',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}
