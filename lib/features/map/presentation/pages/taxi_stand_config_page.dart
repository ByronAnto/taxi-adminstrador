import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../../core/constants/app_constants.dart';
import '../../data/models/taxi_stand_model.dart';
import '../bloc/map_bloc.dart';

/// Página de configuración de paradas (taxi stands) para admin y operadoras
class TaxiStandConfigPage extends StatefulWidget {
  const TaxiStandConfigPage({super.key});

  @override
  State<TaxiStandConfigPage> createState() => _TaxiStandConfigPageState();
}

class _TaxiStandConfigPageState extends State<TaxiStandConfigPage> {
  @override
  void initState() {
    super.initState();
    context.read<MapBloc>().add(MapTaxiStandsWatchStarted());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paradas de Taxis'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_location_alt),
            tooltip: 'Nueva parada',
            onPressed: () => _showStandDialog(context),
          ),
        ],
      ),
      body: BlocBuilder<MapBloc, MapState>(
        builder: (context, state) {
          final stands =
              state is MapLoaded ? state.taxiStands : <TaxiStandModel>[];

          if (state is MapLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (stands.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.flag_outlined, size: 72, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    'No hay paradas configuradas',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Toca + para agregar una parada',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => _showStandDialog(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Agregar Parada'),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: stands.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => _buildStandCard(context, stands[i]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showStandDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildStandCard(BuildContext context, TaxiStandModel stand) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: stand.isActive
              ? Colors.orange.withValues(alpha: 0.15)
              : Colors.grey.withValues(alpha: 0.15),
          child: Icon(
            Icons.flag,
            color: stand.isActive ? Colors.orange[700] : Colors.grey,
          ),
        ),
        title: Text(
          stand.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (stand.address != null && stand.address!.isNotEmpty)
              Text(stand.address!),
            Text(
              '${stand.latitude.toStringAsFixed(5)}, ${stand.longitude.toStringAsFixed(5)}',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'edit') {
              _showStandDialog(context, existing: stand);
            } else if (value == 'toggle') {
              context.read<MapBloc>().add(
                    MapUpdateTaxiStand(
                        stand.copyWith(isActive: !stand.isActive)),
                  );
            } else if (value == 'delete') {
              _confirmDelete(context, stand);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'edit',
              child: ListTile(
                leading: Icon(Icons.edit),
                title: Text('Editar'),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: 'toggle',
              child: ListTile(
                leading: Icon(
                    stand.isActive ? Icons.visibility_off : Icons.visibility),
                title: Text(stand.isActive ? 'Desactivar' : 'Activar'),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete, color: Colors.red),
                title: Text('Eliminar', style: TextStyle(color: Colors.red)),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, TaxiStandModel stand) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar parada'),
        content: Text('¿Estás seguro de eliminar "${stand.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              context.read<MapBloc>().add(MapDeleteTaxiStand(stand.id));
              Navigator.pop(ctx);
            },
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }

  void _showStandDialog(BuildContext context, {TaxiStandModel? existing}) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final addressCtrl = TextEditingController(text: existing?.address ?? '');
    LatLng selectedPos = existing != null
        ? LatLng(existing.latitude, existing.longitude)
        : const LatLng(AppConstants.baseLatitude, AppConstants.baseLongitude);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setModalState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    existing != null ? 'Editar Parada' : 'Nueva Parada',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nombre de la parada *',
                      hintText: 'Ej: Parada Principal',
                      prefixIcon: Icon(Icons.flag),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: addressCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Dirección (opcional)',
                      hintText: 'Ej: Av. Principal y Calle 1',
                      prefixIcon: Icon(Icons.location_on),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Toca el mapa para seleccionar la ubicación:',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 250,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: selectedPos,
                        zoom: 15.0,
                      ),
                      markers: {
                        Marker(
                          markerId: const MarkerId('selected'),
                          position: selectedPos,
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                              BitmapDescriptor.hueOrange),
                        ),
                      },
                      onTap: (pos) {
                        setModalState(() => selectedPos = pos);
                      },
                      myLocationEnabled: true,
                      myLocationButtonEnabled: true,
                      zoomControlsEnabled: true,
                      mapToolbarEnabled: false,
                      liteModeEnabled: false,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Lat: ${selectedPos.latitude.toStringAsFixed(6)}, '
                    'Lng: ${selectedPos.longitude.toStringAsFixed(6)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: () {
                      final name = nameCtrl.text.trim();
                      if (name.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('El nombre es obligatorio'),
                          ),
                        );
                        return;
                      }

                      final stand = TaxiStandModel(
                        id: existing?.id ?? '',
                        name: name,
                        address: addressCtrl.text.trim().isEmpty
                            ? null
                            : addressCtrl.text.trim(),
                        latitude: selectedPos.latitude,
                        longitude: selectedPos.longitude,
                        isActive: existing?.isActive ?? true,
                        createdBy: existing?.createdBy ?? '',
                        createdAt: existing?.createdAt ?? DateTime.now(),
                        updatedAt: DateTime.now(),
                      );

                      if (existing != null) {
                        context
                            .read<MapBloc>()
                            .add(MapUpdateTaxiStand(stand));
                      } else {
                        context
                            .read<MapBloc>()
                            .add(MapCreateTaxiStand(stand));
                      }

                      Navigator.pop(ctx);
                    },
                    icon: Icon(existing != null ? Icons.save : Icons.add),
                    label: Text(existing != null ? 'Guardar' : 'Crear Parada'),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }
}
