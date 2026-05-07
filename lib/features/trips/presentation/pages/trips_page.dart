import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_theme.dart';
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    // Dispatch watch event to load trips from Firebase
    context.read<TripBloc>().add(TripsWatchStarted());
    context.read<TripBloc>().add(TripHistoryLoadRequested());
  }

  @override
  void dispose() {
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
                  Tab(text: 'Estadísticas', icon: Icon(Icons.bar_chart, size: 20)),
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
                        _buildTripStats(state),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFilterBar() {
    final statuses = ['Todos', 'En progreso', 'Asignado', 'Completado', 'Cancelado'];
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
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: activeTrips.length,
      itemBuilder: (context, index) =>
          _buildTripCard(activeTrips[index], isActive: true),
    );
  }

  Widget _buildTripHistory(TripState state) {
    final historyTrips = _getHistoryTrips(state);
    if (historyTrips.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('Sin carreras en el historial',
                style: TextStyle(color: Colors.grey[500], fontSize: 16)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: historyTrips.length,
      itemBuilder: (context, index) => _buildTripCard(historyTrips[index]),
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

  Widget _buildTripStats(TripState state) {
    final stats = (state is TripsLoaded) ? state.stats : null;
    final todayTrips = stats?['todayTrips'] ?? 0;
    final todayIncome = (stats?['todayIncome'] ?? 0.0) as num;
    final weekTrips = stats?['weekTrips'] ?? 0;
    final cancelledToday = stats?['cancelledToday'] ?? 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _buildStatCard('Hoy', '$todayTrips', 'carreras', Icons.today, AppTheme.secondaryColor)),
              const SizedBox(width: 12),
              Expanded(child: _buildStatCard('Ingreso día', '\$${todayIncome.toStringAsFixed(2)}', '', Icons.attach_money, AppTheme.statusFree)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildStatCard('Semana', '$weekTrips', 'carreras', Icons.date_range, Colors.blue)),
              const SizedBox(width: 12),
              Expanded(child: _buildStatCard('Canceladas', '$cancelledToday', 'hoy', Icons.cancel, AppTheme.errorColor)),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Carreras por hora',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 12),
          Container(
            height: 200,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Text('Gráfico de carreras\n(se integrará con fl_chart)',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, String value, String subtitle, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
            ]),
            const SizedBox(height: 8),
            Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: color)),
            if (subtitle.isNotEmpty)
              Text(subtitle, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ],
        ),
      ),
    );
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
            ],
          ),
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
