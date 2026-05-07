import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../map/presentation/bloc/map_bloc.dart';
import '../../../users/data/models/driver_model.dart';
import '../../data/models/trip_model.dart';
import '../bloc/trip_bloc.dart';

/// Página para asignar carreras a conductores (operadora)
class AssignTripPage extends StatefulWidget {
  const AssignTripPage({super.key});

  @override
  State<AssignTripPage> createState() => _AssignTripPageState();
}

class _AssignTripPageState extends State<AssignTripPage> {
  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropoffController = TextEditingController();
  final TextEditingController _passengerNameController = TextEditingController();
  final TextEditingController _passengerPhoneController = TextEditingController();

  String? _selectedDriverId;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    // Cargar conductores activos desde MapBloc
    context.read<MapBloc>().add(MapDriversWatchStarted());
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    _passengerNameController.dispose();
    _passengerPhoneController.dispose();
    super.dispose();
  }

  List<DriverModel> _getFreeDrivers(MapState state) {
    if (state is MapLoaded) {
      return state.activeDrivers
          .where((d) => d.status == 'libre' && d.isActive)
          .toList();
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<TripBloc, TripState>(
      listener: (context, state) {
        if (state is TripActionSuccess) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: AppTheme.statusFree,
            ),
          );
          context.pop();
        } else if (state is TripError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: AppTheme.errorColor,
            ),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Asignar Carrera'),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Sección pasajero
                _sectionHeader('Datos del Pasajero', Icons.person),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _passengerNameController,
                  decoration: const InputDecoration(
                    labelText: 'Nombre del pasajero',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Ingrese el nombre' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _passengerPhoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Teléfono del pasajero',
                    prefixIcon: Icon(Icons.phone),
                  ),
                ),

                const SizedBox(height: 24),

                // Sección ruta
                _sectionHeader('Ruta', Icons.route),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _pickupController,
                  decoration: InputDecoration(
                    labelText: 'Punto de recogida',
                    prefixIcon: const Icon(Icons.trip_origin,
                        color: AppTheme.statusFree),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.my_location),
                      onPressed: () {
                        _pickupController.text = AppConstants.baseAddress;
                      },
                    ),
                  ),
                  validator: (v) => v == null || v.isEmpty
                      ? 'Ingrese el punto de recogida'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _dropoffController,
                  decoration: const InputDecoration(
                    labelText: 'Destino',
                    prefixIcon:
                        Icon(Icons.location_on, color: AppTheme.errorColor),
                  ),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Ingrese el destino' : null,
                ),

                const SizedBox(height: 24),

                // Sección conductor (desde MapBloc)
                _sectionHeader('Conductor Disponible', Icons.local_taxi),
                const SizedBox(height: 8),
                BlocBuilder<MapBloc, MapState>(
                  builder: (context, mapState) {
                    final freeDrivers = _getFreeDrivers(mapState);

                    if (mapState is MapLoading) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }

                    if (freeDrivers.isEmpty) {
                      return Container(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(Icons.no_transfer,
                                  size: 48, color: Colors.grey[400]),
                              const SizedBox(height: 8),
                              Text(
                                'No hay conductores disponibles',
                                style: TextStyle(
                                    color: Colors.grey[600], fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    return RadioGroup<String>(
                      groupValue: _selectedDriverId,
                      onChanged: (v) => setState(() => _selectedDriverId = v),
                      child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${freeDrivers.length} conductores disponibles',
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        ...freeDrivers.map((d) => _buildDriverOption(d)),
                      ],
                    ));
                  },
                ),

                const SizedBox(height: 32),

                // Botón asignar
                BlocBuilder<TripBloc, TripState>(
                  builder: (context, tripState) {
                    final isLoading = tripState is TripLoading;
                    return SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed:
                            _selectedDriverId != null && !isLoading
                                ? () => _confirmAssignment(context)
                                : null,
                        icon: isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.send),
                        label: Text(
                          isLoading ? 'ASIGNANDO...' : 'ASIGNAR CARRERA',
                          style:
                              const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.primaryColor, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppTheme.secondaryColor,
          ),
        ),
      ],
    );
  }

  Widget _buildDriverOption(DriverModel driver) {
    final isSelected = _selectedDriverId == driver.uid;

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedDriverId = driver.uid;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryColor.withValues(alpha: 0.12)
              : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppTheme.primaryColor : Colors.grey[300]!,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Radio<String>(
              value: driver.uid,
              activeColor: AppTheme.primaryColor,
            ),
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 20,
              backgroundColor:
                  AppTheme.secondaryColor.withValues(alpha: 0.15),
              child: const Icon(Icons.person,
                  color: AppTheme.secondaryColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(driver.licenseNumber,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor
                              .withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          driver.activeVehicleId ?? 'Sin placa',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.star, size: 14, color: Colors.amber[700]),
                      const SizedBox(width: 2),
                      Text(driver.rating.toStringAsFixed(1),
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              children: [
                Text(
                  '${driver.totalTrips} carreras',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _confirmAssignment(BuildContext context) {
    if (!_formKey.currentState!.validate()) return;

    final mapState = context.read<MapBloc>().state;
    final drivers = _getFreeDrivers(mapState);
    final driver = drivers.firstWhere((d) => d.uid == _selectedDriverId);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar Asignación'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _confirmRow('Pasajero', _passengerNameController.text),
            _confirmRow('Recogida', _pickupController.text),
            _confirmRow('Destino', _dropoffController.text),
            const Divider(),
            _confirmRow('Conductor', driver.licenseNumber),
            _confirmRow('Placa', driver.activeVehicleId ?? 'N/A'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);

              final authState = context.read<AuthBloc>().state;
              final operatorId = authState is AuthAuthenticated
                  ? authState.user.uid
                  : '';

              final trip = TripModel(
                uid: const Uuid().v4(),
                driverId: driver.uid,
                operatorId: operatorId,
                pickupLatitude: AppConstants.baseLatitude,
                pickupLongitude: AppConstants.baseLongitude,
                pickupAddress: _pickupController.text,
                dropoffAddress: _dropoffController.text,
                status: 'asignado',
                paymentMethod: 'efectivo',
                startTime: DateTime.now(),
                createdAt: DateTime.now(),
                notes: _passengerNameController.text.isNotEmpty
                    ? 'Pasajero: ${_passengerNameController.text}'
                        '${_passengerPhoneController.text.isNotEmpty ? ' Tel: ${_passengerPhoneController.text}' : ''}'
                    : null,
              );

              context.read<TripBloc>().add(TripCreateRequested(trip));
            },
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
  }

  Widget _confirmRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text('$label:',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
