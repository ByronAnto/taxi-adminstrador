import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/state_views.dart';
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
            return const LoadingState(message: 'Cargando paradas...');
          }

          if (stands.isEmpty) {
            return EmptyState(
              icon: Icons.flag_outlined,
              title: 'No hay paradas configuradas',
              subtitle: 'Toca + para agregar una parada',
              action: ElevatedButton.icon(
                onPressed: () => _showStandDialog(context),
                icon: const Icon(Icons.add),
                label: const Text('Agregar Parada'),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: stands.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
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
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final activeColor = colorScheme.tertiary;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        leading: CircleAvatar(
          backgroundColor: stand.isActive
              ? activeColor.withValues(alpha: 0.15)
              : AppTheme.statusOffline.withValues(alpha: 0.15),
          child: Icon(
            Icons.flag,
            color: stand.isActive ? activeColor : AppTheme.statusOffline,
          ),
        ),
        title: Text(
          stand.name,
          style: textTheme.titleMedium,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (stand.address != null && stand.address!.isNotEmpty)
              Text(stand.address!, style: textTheme.bodyMedium),
            Text(
              '${stand.latitude.toStringAsFixed(5)}, ${stand.longitude.toStringAsFixed(5)}',
              style: textTheme.labelSmall
                  ?.copyWith(color: AppTheme.textSecondary),
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
                leading: Icon(Icons.delete, color: AppTheme.errorColor),
                title: Text('Eliminar',
                    style: TextStyle(color: AppTheme.errorColor)),
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
            style: FilledButton.styleFrom(backgroundColor: AppTheme.errorColor),
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
          final textTheme = Theme.of(ctx).textTheme;
          return Padding(
            padding: EdgeInsets.only(
              left: AppSpacing.xl,
              right: AppSpacing.xl,
              top: AppSpacing.xl,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + AppSpacing.xl,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    existing != null ? 'Editar Parada' : 'Nueva Parada',
                    style: textTheme.titleLarge,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nombre de la parada *',
                      hintText: 'Ej: Parada Principal',
                      prefixIcon: Icon(Icons.flag),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: addressCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Dirección (opcional)',
                      hintText: 'Ej: Av. Principal y Calle 1',
                      prefixIcon: Icon(Icons.location_on),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    'Toca el mapa para seleccionar la ubicación:',
                    style: textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Container(
                    height: 250,
                    decoration: BoxDecoration(
                      border: Border.all(color: AppTheme.dividerColor),
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
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Lat: ${selectedPos.latitude.toStringAsFixed(6)}, '
                    'Lng: ${selectedPos.longitude.toStringAsFixed(6)}',
                    style: textTheme.bodySmall
                        ?.copyWith(color: AppTheme.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.xl),
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
