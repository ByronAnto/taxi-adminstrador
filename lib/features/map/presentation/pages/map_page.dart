import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/driver_location_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../users/data/models/driver_model.dart';
import '../../data/models/taxi_stand_model.dart';
import '../bloc/map_bloc.dart';

/// Página de mapa con seguimiento de conductores y paradas
class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> with TickerProviderStateMixin {
  final Completer<GoogleMapController> _mapController = Completer();
  final Set<String> _activeFilters = {
    AppConstants.statusFree,
    AppConstants.statusBusy,
    AppConstants.statusReturning,
  };
  LatLng? _myPosition;
  LatLng? _animatedPosition; // posición interpolada para el marcador
  double _bearing = 0; // dirección del movimiento
  BitmapDescriptor? _myCarIcon; // ícono ámbar para mi ubicación
  final Map<String, BitmapDescriptor> _driverIcons = {}; // íconos por status
  final Map<String, BitmapDescriptor> _driverNumberIcons = {}; // íconos con número
  StreamSubscription<Position>? _positionStream;
  AnimationController? _moveController;
  Animation<double>? _moveAnimation;
  LatLng _selectedDestination = const LatLng(
    AppConstants.baseLatitude,
    AppConstants.baseLongitude,
  );
  String _selectedDestinationName = 'Estación Base';

  static const LatLng _basePosition = LatLng(
    AppConstants.baseLatitude,
    AppConstants.baseLongitude,
  );

  @override
  void initState() {
    super.initState();
    final bloc = context.read<MapBloc>();
    bloc.add(MapDriversWatchStarted());
    bloc.add(MapTaxiStandsWatchStarted());
    _requestLocationPermission();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _moveController?.dispose();
    // NO marcar desconectado al salir del mapa.
    // El estado online/offline lo gestiona DriverLocationService.
    super.dispose();
  }

  // _initDriverTracking ya no es necesario — DriverLocationService
  // gestiona GPS, status y datos denormalizados de forma global.

  Future<void> _requestLocationPermission() async {
    final status = await Permission.locationWhenInUse.request();
    if (status.isGranted) {
      await _createAllCarIcons();
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 10),
          ),
        );
        if (mounted) {
          setState(() {
            _myPosition = LatLng(position.latitude, position.longitude);
          });
          if (_mapController.isCompleted) {
            final controller = await _mapController.future;
            controller.animateCamera(
              CameraUpdate.newLatLng(_myPosition!),
            );
          }
        }
      } catch (_) {
        // Si falla, se queda en la posición base
      }
      _startLocationStream();
    }
  }

  /// Crea todos los íconos de auto: mi ubicación (ámbar) + uno por cada status
  Future<void> _createAllCarIcons() async {
    // Ícono para MI ubicación (ámbar)
    _myCarIcon = await _buildCarBitmap(
      const Color(0xFFF57F17), // ámbar oscuro
      borderColor: const Color(0xFFFFC107),
    );
    // Íconos para conductores según status
    _driverIcons[AppConstants.statusFree] = await _buildCarBitmap(
      AppTheme.statusFree,
      borderColor: AppTheme.statusFree,
    );
    _driverIcons[AppConstants.statusBusy] = await _buildCarBitmap(
      AppTheme.statusBusy,
      borderColor: AppTheme.statusBusy,
    );
    _driverIcons[AppConstants.statusReturning] = await _buildCarBitmap(
      const Color(0xFF1976D2),
      borderColor: const Color(0xFF1976D2),
    );
    if (mounted) setState(() {});
  }

  /// Genera un BitmapDescriptor con un carrito pequeño estilo Uber
  Future<BitmapDescriptor> _buildCarBitmap(
    Color iconColor, {
    Color borderColor = Colors.white,
  }) async {
    const double size = 36; // tamaño compacto
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const center = Offset(size / 2, size / 2);
    const radius = size / 2.4;

    // Sombra sutil
    canvas.drawCircle(
      Offset(center.dx, center.dy + 1),
      radius,
      Paint()
        ..color = const Color(0x30000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );

    // Fondo blanco relleno
    canvas.drawCircle(center, radius, Paint()..color = Colors.white);

    // Borde de color
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Ícono de auto (Material Icons: directions_car)
    const icon = Icons.directions_car;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    textPainter.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: 18,
        fontFamily: icon.fontFamily,
        color: iconColor,
      ),
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        (size - textPainter.width) / 2,
        (size - textPainter.height) / 2,
      ),
    );

    final image = await recorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(data!.buffer.asUint8List());
  }

  /// Genera ícono de auto con número de vehículo en ROJO debajo
  Future<BitmapDescriptor> _buildCarBitmapWithNumber(
    Color iconColor,
    String vehicleNumber, {
    Color borderColor = Colors.white,
  }) async {
    const double width = 90;
    const double circleY = 20.0;
    const double circleRadius = 15.0;
    const double height = 58;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(width / 2, circleY);

    // Sombra
    canvas.drawCircle(
      Offset(center.dx, center.dy + 1),
      circleRadius,
      Paint()
        ..color = const Color(0x30000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );

    // Fondo blanco
    canvas.drawCircle(center, circleRadius, Paint()..color = Colors.white);

    // Borde de color
    canvas.drawCircle(
      center,
      circleRadius,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Ícono de auto
    const icon = Icons.directions_car;
    final iconPainter = TextPainter(textDirection: TextDirection.ltr);
    iconPainter.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: 16,
        fontFamily: icon.fontFamily,
        color: iconColor,
      ),
    );
    iconPainter.layout();
    iconPainter.paint(
      canvas,
      Offset(
        (width - iconPainter.width) / 2,
        circleY - iconPainter.height / 2,
      ),
    );

    // Número de vehículo en ROJO debajo del círculo
    if (vehicleNumber.isNotEmpty) {
      // Fondo blanco para el texto
      final textPainter = TextPainter(
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      );
      textPainter.text = TextSpan(
        text: '#$vehicleNumber',
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color: Color(0xFFD50000), // Rojo intenso
          letterSpacing: 0.5,
        ),
      );
      textPainter.layout();
      final textX = (width - textPainter.width) / 2;
      final textY = circleY + circleRadius + 3;

      // Fondo semi-transparente blanco para legibilidad
      final bgRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          textX - 3,
          textY - 1,
          textPainter.width + 6,
          textPainter.height + 2,
        ),
        const Radius.circular(3),
      );
      canvas.drawRRect(bgRect, Paint()..color = const Color(0xDDFFFFFF));
      canvas.drawRRect(
        bgRect,
        Paint()
          ..color = const Color(0xFFD50000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5,
      );
      textPainter.paint(canvas, Offset(textX, textY));
    }

    final image = await recorder.endRecording().toImage(
      width.toInt(),
      height.toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(data!.buffer.asUint8List());
  }

  /// Genera y cachea ícono personalizado con número de vehículo
  Future<void> _ensureDriverNumberIcon(DriverModel driver) async {
    final key = '${driver.vehicleNumber}_${driver.status}';
    if (_driverNumberIcons.containsKey(key)) return;
    final color = _statusColor(driver.status);
    final icon = await _buildCarBitmapWithNumber(
      color,
      driver.vehicleNumber,
      borderColor: color,
    );
    if (mounted) {
      setState(() {
        _driverNumberIcons[key] = icon;
      });
    }
  }

  /// Inicia el stream de posición GPS en tiempo real (solo para display local)
  void _startLocationStream() {
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5, // actualizar cada 5 metros
      ),
    ).listen((position) {
      if (mounted) {
        final newPos = LatLng(position.latitude, position.longitude);
        _animateMarkerTo(newPos);
        // GPS push a Firestore lo hace DriverLocationService (global)
      }
    });
  }

  /// Anima el marcador suavemente desde la posición actual hasta [target]
  void _animateMarkerTo(LatLng target) {
    final from = _animatedPosition ?? _myPosition ?? target;

    // Calcular dirección (bearing) del movimiento
    _bearing = _calculateBearing(from, target);

    _moveController?.dispose();
    _moveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _moveAnimation = CurvedAnimation(
      parent: _moveController!,
      curve: Curves.easeInOut,
    );

    _moveController!.addListener(() {
      final t = _moveAnimation!.value;
      final lat = from.latitude + (target.latitude - from.latitude) * t;
      final lng = from.longitude + (target.longitude - from.longitude) * t;
      if (mounted) {
        setState(() {
          _animatedPosition = LatLng(lat, lng);
        });
      }
    });

    _moveController!.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _myPosition = target;
      }
    });

    _moveController!.forward();
  }

  /// Calcula el bearing (dirección en grados) entre dos puntos
  double _calculateBearing(LatLng from, LatLng to) {
    final dLng = _toRad(to.longitude - from.longitude);
    final lat1 = _toRad(from.latitude);
    final lat2 = _toRad(to.latitude);
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (_toDeg(math.atan2(y, x)) + 360) % 360;
  }

  double _toRad(double deg) => deg * math.pi / 180;
  double _toDeg(double rad) => rad * 180 / math.pi;

  Future<void> _goToMyLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      setState(() {
        _myPosition = LatLng(position.latitude, position.longitude);
      });
      final controller = await _mapController.future;
      controller.animateCamera(
        CameraUpdate.newLatLngZoom(_myPosition!, 16.0),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo obtener tu ubicación')),
        );
      }
    }
  }

  List<DriverModel> _filteredDrivers(List<DriverModel> drivers) {
    return drivers
        .where((d) => _activeFilters.contains(d.status) && d.isActive)
        .toList();
  }

  Color _statusColor(String status) {
    switch (status) {
      case AppConstants.statusFree:
        return AppTheme.statusFree;
      case AppConstants.statusBusy:
        return AppTheme.statusBusy;
      case AppConstants.statusReturning:
        return AppTheme.statusReturning;
      default:
        return Colors.grey;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case AppConstants.statusFree:
        return 'Libre';
      case AppConstants.statusBusy:
        return 'Con pasajero';
      case AppConstants.statusReturning:
        return 'En camino';
      default:
        return status;
    }
  }

  double _statusHue(String status) {
    switch (status) {
      case AppConstants.statusFree:
        return BitmapDescriptor.hueGreen;
      case AppConstants.statusBusy:
        return BitmapDescriptor.hueRed;
      case AppConstants.statusReturning:
        return BitmapDescriptor.hueBlue;
      default:
        return BitmapDescriptor.hueYellow;
    }
  }

  Set<Marker> _buildMarkers(
      List<DriverModel> drivers, List<TaxiStandModel> stands) {
    final markers = <Marker>{};
    final myDriverId = DriverLocationService.instance.driverId;

    // Driver markers — carritos de colores con número de vehículo
    for (final driver in drivers) {
      // Omitir mi propio driver (se muestra como "my_car" ámbar)
      if (myDriverId != null && driver.uid == myDriverId) continue;

      final lat = driver.currentLatitude;
      final lng = driver.currentLongitude;
      if (lat == null || lng == null) continue;

      // Usar ícono con número si está cacheado, sino ícono por status
      BitmapDescriptor? driverIcon;
      if (driver.vehicleNumber.isNotEmpty) {
        final key = '${driver.vehicleNumber}_${driver.status}';
        driverIcon = _driverNumberIcons[key];
        // Iniciar generación async si no está cacheado
        if (driverIcon == null) {
          _ensureDriverNumberIcon(driver);
          driverIcon = _driverIcons[driver.status];
        }
      } else {
        driverIcon = _driverIcons[driver.status];
      }

      markers.add(Marker(
        markerId: MarkerId('driver_${driver.uid}'),
        position: LatLng(lat, lng),
        icon: driverIcon ?? BitmapDescriptor.defaultMarkerWithHue(
            _statusHue(driver.status)),
        anchor: const Offset(0.5, 0.5),
        flat: true,
        // Sin InfoWindow — el tap abre directamente el sheet con datos
        onTap: () => _showDriverInfoSheet(driver, stands),
      ));
    }

    // Taxi stand markers
    for (final stand in stands) {
      if (!stand.isActive) continue;
      markers.add(Marker(
        markerId: MarkerId('stand_${stand.id}'),
        position: LatLng(stand.latitude, stand.longitude),
        icon:
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(
          title: '📍 ${stand.name}',
          snippet: stand.address ?? 'Parada',
        ),
      ));
    }

    // Mi ubicación — carrito ámbar (posición animada)
    final displayPos = _animatedPosition ?? _myPosition;
    if (displayPos != null && _myCarIcon != null) {
      markers.add(Marker(
        markerId: const MarkerId('my_car'),
        position: displayPos,
        icon: _myCarIcon!,
        rotation: _bearing,
        anchor: const Offset(0.5, 0.5),
        flat: true,
        zIndexInt: 10,
        infoWindow: const InfoWindow(title: '🚕 Mi ubicación'),
      ));
    }

    return markers;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mapa de Conductores')),
      body: BlocBuilder<MapBloc, MapState>(
        builder: (context, state) {
          final allDrivers =
              state is MapLoaded ? state.activeDrivers : <DriverModel>[];
          final taxiStands =
              state is MapLoaded ? state.taxiStands : <TaxiStandModel>[];
          final drivers = _filteredDrivers(allDrivers);
          final markers = _buildMarkers(drivers, taxiStands);

          return Stack(
            children: [
              // ── Google Map ──
              GoogleMap(
                initialCameraPosition: const CameraPosition(
                  target: _basePosition,
                  zoom: 14.0,
                ),
                markers: markers,
                polylines: _buildRoutePolylines(),
                myLocationEnabled: _myCarIcon == null,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                mapToolbarEnabled: false,
                onMapCreated: (controller) {
                  if (!_mapController.isCompleted) {
                    _mapController.complete(controller);
                  }
                },
              ),

              // Filter chips at top
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildFilterChip(AppConstants.statusFree, 'Libre', AppTheme.statusFree),
                          const SizedBox(width: 8),
                          _buildFilterChip(
                              AppConstants.statusBusy, 'Con pasajero', AppTheme.statusBusy),
                          const SizedBox(width: 8),
                          _buildFilterChip(
                              AppConstants.statusReturning, 'En camino', AppTheme.statusReturning),
                          const SizedBox(width: 8),
                          _buildStandLegendChip(taxiStands.where((s) => s.isActive).length),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildDestinationSelector(taxiStands),
                  ],
                ),
              ),

              // FAB to center on my location
              Positioned(
                bottom: 340,
                right: 16,
                child: FloatingActionButton.small(
                  heroTag: 'my_location',
                  backgroundColor: Colors.white,
                  onPressed: _goToMyLocation,
                  child: const Icon(Icons.my_location,
                      color: Colors.blue),
                ),
              ),

              // FAB to center on base
              Positioned(
                bottom: 290,
                right: 16,
                child: FloatingActionButton.small(
                  heroTag: 'center_map',
                  backgroundColor: Colors.white,
                  onPressed: () async {
                    final controller = await _mapController.future;
                    controller.animateCamera(
                      CameraUpdate.newLatLngZoom(_basePosition, 14.0),
                    );
                  },
                  child: const Icon(Icons.home,
                      color: AppTheme.primaryColor),
                ),
              ),

              // Loading indicator
              if (state is MapLoading)
                const Center(child: CircularProgressIndicator()),

              // Error
              if (state is MapError)
                Center(
                  child: Chip(
                    label: Text(state.message),
                    backgroundColor: AppTheme.errorColor.withValues(alpha: 0.1),
                  ),
                ),

              // Bottom driver list sheet
              DraggableScrollableSheet(
                initialChildSize: 0.3,
                minChildSize: 0.1,
                maxChildSize: 0.7,
                builder: (context, scrollController) {
                  return Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(16)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 8,
                          offset: Offset(0, -2),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        // Handle
                        Container(
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          child: Row(
                            children: [
                              const Text(
                                'Conductores Cercanos',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryColor
                                      .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${drivers.length}',
                                  style: const TextStyle(
                                      color: AppTheme.primaryColor,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: drivers.isEmpty
                              ? Center(
                                  child: Text(
                                    'Sin conductores con los filtros seleccionados',
                                    style: TextStyle(color: Colors.grey[500]),
                                  ),
                                )
                              : ListView.builder(
                                  controller: scrollController,
                                  itemCount: drivers.length,
                                  itemBuilder: (ctx, i) =>
                                      _buildDriverTile(drivers[i]),
                                ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilterChip(String status, String label, Color color) {
    final isActive = _activeFilters.contains(status);
    return FilterChip(
      selected: isActive,
      label: Text(label),
      selectedColor: color.withValues(alpha: 0.3),
      checkmarkColor: color,
      backgroundColor: Colors.white,
      side: BorderSide(color: isActive ? color : Colors.grey[300]!),
      onSelected: (selected) {
        setState(() {
          if (selected) {
            _activeFilters.add(status);
          } else {
            _activeFilters.remove(status);
          }
        });
      },
    );
  }

  Widget _buildStandLegendChip(int count) {
    return Chip(
      avatar: Icon(Icons.flag, color: Colors.orange[700], size: 18),
      label: Text('Paradas ($count)'),
      backgroundColor: Colors.orange.withValues(alpha: 0.15),
      side: BorderSide(color: Colors.orange[300]!),
    );
  }

  // ── Ruta al destino (polilínea punteada) ──
  Set<Polyline> _buildRoutePolylines() {
    final pos = _animatedPosition ?? _myPosition;
    if (pos == null || _selectedDestinationName.isEmpty) return {};
    return {
      Polyline(
        polylineId: const PolylineId('route_to_dest'),
        points: [pos, _selectedDestination],
        color: const Color(0xFFFFA000),
        width: 4,
        patterns: [PatternItem.dash(20), PatternItem.gap(10)],
      ),
    };
  }

  // ── Selector de destino configurable ──
  Widget _buildDestinationSelector(List<TaxiStandModel> stands) {
    return GestureDetector(
      onTap: () => _showDestinationPicker(stands),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 4),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.flag, color: Colors.amber[700], size: 18),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Destino: $_selectedDestinationName',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }

  void _showDestinationPicker(List<TaxiStandModel> stands) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Seleccionar Destino',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.home, color: AppTheme.primaryColor),
                title: const Text('Estación Base'),
                subtitle: Text(AppConstants.baseAddress),
                selected: _selectedDestinationName == 'Estación Base',
                selectedTileColor:
                    AppTheme.primaryColor.withValues(alpha: 0.08),
                onTap: () {
                  setState(() {
                    _selectedDestination = _basePosition;
                    _selectedDestinationName = 'Estación Base';
                  });
                  Navigator.pop(ctx);
                },
              ),
              ...stands.where((s) => s.isActive).map(
                    (stand) => ListTile(
                      leading:
                          Icon(Icons.flag, color: Colors.orange[700]),
                      title: Text(stand.name),
                      subtitle: Text(stand.address ?? ''),
                      selected: _selectedDestinationName == stand.name,
                      selectedTileColor:
                          Colors.orange.withValues(alpha: 0.08),
                      onTap: () {
                        setState(() {
                          _selectedDestination =
                              LatLng(stand.latitude, stand.longitude);
                          _selectedDestinationName = stand.name;
                        });
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
              ListTile(
                leading: const Icon(Icons.block, color: Colors.grey),
                title: const Text('Sin destino'),
                subtitle: const Text('Ocultar ruta'),
                selected: _selectedDestinationName == '',
                onTap: () {
                  setState(() {
                    _selectedDestinationName = '';
                  });
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDriverTile(DriverModel driver) {
    // Obtenemos las paradas del estado actual del bloc
    final state = context.read<MapBloc>().state;
    final stands = state is MapLoaded ? state.taxiStands : <TaxiStandModel>[];
    final color = _statusColor(driver.status);
    final label = _statusLabel(driver.status);
    final displayName = driver.vehicleNumber.isNotEmpty
        ? 'Unidad ${driver.vehicleNumber}'
        : 'Conductor ${driver.licenseNumber}';

    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.15),
            child: const Icon(Icons.directions_car, size: 22),
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        displayName,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        '$label${driver.plate.isNotEmpty ? " • ${driver.plate}" : ""} • ★ ${driver.rating.toStringAsFixed(1)}',
        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: color),
            ),
          ),
        ],
      ),
      onTap: () async {
        // Centrar mapa en este conductor
        final lat = driver.currentLatitude;
        final lng = driver.currentLongitude;
        if (lat != null && lng != null) {
          final controller = await _mapController.future;
          controller.animateCamera(
            CameraUpdate.newLatLngZoom(LatLng(lat, lng), 16.0),
          );
        }
        // Mostrar info sheet
        if (mounted) _showDriverInfoSheet(driver, stands);
      },
    );
  }

  // ── Haversine distance (km) ──
  double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const double r = 6371; // radio tierra km
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) *
        math.sin(dLon / 2) * math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  String _formatDistance(double km) {
    if (km < 1) {
      return '${(km * 1000).round()} m';
    }
    return '${km.toStringAsFixed(1)} km';
  }

  /// Bottom sheet con info del conductor y distancias a bases
  void _showDriverInfoSheet(DriverModel driver, List<TaxiStandModel> stands) {
    final lat = driver.currentLatitude;
    final lng = driver.currentLongitude;
    if (lat == null || lng == null) return;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final color = _statusColor(driver.status);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Encabezado: número + placa + nombre
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: color.withValues(alpha: 0.15),
                      child: Icon(Icons.directions_car, color: color),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            driver.vehicleNumber.isNotEmpty
                                ? 'Unidad #${driver.vehicleNumber}'
                                : 'Conductor ${driver.licenseNumber}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          if (driver.plate.isNotEmpty)
                            Text(
                              'Placa: ${driver.plate}',
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          if (driver.driverName.isNotEmpty)
                            Text(
                              driver.driverName,
                              style: const TextStyle(fontSize: 13),
                            ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _statusLabel(driver.status),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: color,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                // Distancias a bases
                const Text(
                  'Distancia a bases:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 8),
                // Estación Base principal
                _buildDistanceRow(
                  Icons.home,
                  'Estación Base',
                  _haversineKm(lat, lng,
                      AppConstants.baseLatitude, AppConstants.baseLongitude),
                ),
                // Paradas de taxi registradas
                ...stands.where((s) => s.isActive).map(
                  (stand) => _buildDistanceRow(
                    Icons.flag,
                    stand.name,
                    _haversineKm(lat, lng, stand.latitude, stand.longitude),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDistanceRow(IconData icon, String name, double distKm) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.orange[700]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(name, style: const TextStyle(fontSize: 13)),
          ),
          Text(
            _formatDistance(distKm),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: AppTheme.primaryColor,
            ),
          ),
        ],
      ),
    );
  }
}
