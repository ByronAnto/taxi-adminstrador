import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/driver_location_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../associations/data/models/association_model.dart';
import '../../../auth/data/models/user_model.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
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
  /// Controlador del sheet de "Conductores Cercanos" — permite expandirlo
  /// programáticamente cuando el usuario toca el handle.
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  static const double _sheetMin = 0.12;
  static const double _sheetMid = 0.4;
  static const double _sheetMax = 0.7;
  final Set<String> _activeFilters = {
    AppConstants.statusFree,
    AppConstants.statusBusy,
    AppConstants.statusReturning,
  };
  LatLng? _myPosition;
  LatLng? _animatedPosition; // posición interpolada para el marcador
  double _bearing = 0; // dirección del movimiento
  BitmapDescriptor? _myCarIcon; // ícono ámbar para mi ubicación
  BitmapDescriptor? _operatorIcon; // ícono de persona "OP" para operadoras
  final Map<String, BitmapDescriptor> _driverIcons = {}; // íconos por status
  final Map<String, BitmapDescriptor> _driverNumberIcons = {}; // íconos con número
  StreamSubscription<Position>? _positionStream;
  AnimationController? _moveController;
  Animation<double>? _moveAnimation;
  /// Destino seleccionado en el dropdown. Inicialmente vacío hasta
  /// que cargue la `standLocation` configurada por el admin.
  LatLng? _selectedDestination;
  String _selectedDestinationName = '';

  /// Parada principal de la asociación (configurada por el admin en
  /// "Ubicación parada"). Si no está configurada, queda null y no
  /// aparece en el dropdown.
  StandLocation? _associationStand;

  /// Centro inicial del mapa. Cuando cargue la standLocation se
  /// actualiza; mientras tanto usa Quito como fallback.
  LatLng _initialCameraTarget = const LatLng(-0.1807, -78.4678);

  @override
  void initState() {
    super.initState();
    final bloc = context.read<MapBloc>();
    bloc.add(MapDriversWatchStarted());
    bloc.add(MapTaxiStandsWatchStarted());
    _requestLocationPermission();
    _loadAssociationStand();
  }

  /// Carga la `standLocation` que el admin configuró en
  /// "Ubicación parada". Reemplaza la base hardcoded por la real.
  Future<void> _loadAssociationStand() async {
    final auth = context.read<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return;
    final aid = auth.user.associationId;
    if (aid.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .get();
      if (!snap.exists || !mounted) return;
      final stand = AssociationModel.fromFirestore(snap).standLocation;
      if (!stand.isConfigured) return;
      final point = LatLng(stand.lat!, stand.lng!);
      setState(() {
        _associationStand = stand;
        _initialCameraTarget = point;
        // Si el usuario aún no eligió destino, lo dejamos en la parada
        // de la asociación.
        if (_selectedDestinationName.isEmpty &&
            _selectedDestination == null) {
          _selectedDestination = point;
          _selectedDestinationName =
              stand.label?.isNotEmpty == true ? stand.label! : 'Parada';
        }
      });
    } catch (_) {}
  }

  /// Tap en el handle/header del sheet de conductores: alterna entre
  /// minimizado y expandido. Si está al mínimo, expande al medio; si
  /// está expandido (o entre medio y máximo), minimiza.
  void _toggleSheet() {
    if (!_sheetController.isAttached) return;
    final size = _sheetController.size;
    final target = size <= _sheetMin + 0.02 ? _sheetMid : _sheetMin;
    _sheetController.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _moveController?.dispose();
    _sheetController.dispose();
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
    // Operadora: persona en círculo morado con etiqueta "OP".
    _operatorIcon = await _buildOperatorBitmap();
    if (mounted) setState(() {});
  }

  /// Genera el ícono de la operadora: círculo blanco con borde morado,
  /// silueta de persona y etiqueta "OP" debajo. Se usa para los users
  /// de rol operadora que aparecen en el mapa (los que no tienen
  /// vehículo asignado).
  Future<BitmapDescriptor> _buildOperatorBitmap() async {
    const double size = 44;
    const double labelHeight = 14;
    const double totalHeight = size + labelHeight;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const center = Offset(size / 2, size / 2);
    const radius = size / 2.4;
    const purple = Color(0xFF7B1FA2);

    // Sombra sutil
    canvas.drawCircle(
      Offset(center.dx, center.dy + 1),
      radius,
      Paint()
        ..color = const Color(0x30000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );

    // Fondo blanco
    canvas.drawCircle(center, radius, Paint()..color = Colors.white);

    // Borde morado
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = purple
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Ícono de persona
    const personIcon = Icons.person;
    final iconPainter = TextPainter(textDirection: TextDirection.ltr);
    iconPainter.text = TextSpan(
      text: String.fromCharCode(personIcon.codePoint),
      style: TextStyle(
        fontSize: 22,
        fontFamily: personIcon.fontFamily,
        color: purple,
      ),
    );
    iconPainter.layout();
    iconPainter.paint(
      canvas,
      Offset(
        (size - iconPainter.width) / 2,
        (size - iconPainter.height) / 2,
      ),
    );

    // Etiqueta "OP" en píldora morada bajo el círculo
    final labelPainter = TextPainter(textDirection: TextDirection.ltr);
    labelPainter.text = const TextSpan(
      text: 'OP',
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w900,
        color: Colors.white,
        height: 1.0,
      ),
    );
    labelPainter.layout();
    final labelW = labelPainter.width + 10;
    final labelRect = Rect.fromLTWH(
      (size - labelW) / 2,
      size,
      labelW,
      labelHeight,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(7)),
      Paint()..color = purple,
    );
    labelPainter.paint(
      canvas,
      Offset(
        (size - labelPainter.width) / 2,
        size + (labelHeight - labelPainter.height) / 2,
      ),
    );

    final image = await recorder.endRecording().toImage(
      size.toInt(),
      totalHeight.toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(data!.buffer.asUint8List());
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

  /// Círculos de incertidumbre del GPS para cada conductor con
  /// `locationAccuracy` reportada. Solo se muestran cuando el radio es
  /// > 25 m (no contaminar visualmente con fixes precisos).
  /// Cuando dos vehículos en el mismo lugar aparecen distantes en el
  /// mapa, los círculos ayudan a entender que es jitter de GPS y no
  /// que realmente estén separados.
  Set<Circle> _buildAccuracyCircles(List<DriverModel> drivers) {
    final circles = <Circle>{};
    for (final d in drivers) {
      final lat = d.currentLatitude;
      final lng = d.currentLongitude;
      final acc = d.locationAccuracy;
      if (lat == null || lng == null || acc == null || acc < 25) continue;
      circles.add(Circle(
        circleId: CircleId('acc_${d.uid}'),
        center: LatLng(lat, lng),
        radius: acc,
        strokeWidth: 1,
        strokeColor: Colors.blue.withValues(alpha: 0.4),
        fillColor: Colors.blue.withValues(alpha: 0.08),
      ));
    }
    return circles;
  }

  Set<Marker> _buildMarkers(
      List<DriverModel> drivers, List<TaxiStandModel> stands,
      {bool isOpOrAdmin = false}) {
    final markers = <Marker>{};
    final myDriverId = DriverLocationService.instance.driverId;

    // Driver markers — carritos de colores con número de vehículo
    for (final driver in drivers) {
      // Omitir mi propio driver (se muestra como "my_car" ámbar)
      if (myDriverId != null && driver.uid == myDriverId) continue;

      // Conductor: no ve marcadores de otros conductores.
      // Admin/operadora sí ve todos.
      if (!isOpOrAdmin) continue;

      final lat = driver.currentLatitude;
      final lng = driver.currentLongitude;
      if (lat == null || lng == null) continue;

      // Usar ícono con número si está cacheado, sino ícono por status.
      // Si no hay vehicleNumber, asumimos que es operadora (los conductores
      // siempre tienen unidad asignada) y mostramos icono de persona "OP".
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
        driverIcon = _operatorIcon ?? _driverIcons[driver.status];
      }

      markers.add(Marker(
        markerId: MarkerId('driver_${driver.uid}'),
        position: LatLng(lat, lng),
        icon: driverIcon ?? BitmapDescriptor.defaultMarkerWithHue(
            _statusHue(driver.status)),
        anchor: const Offset(0.5, 0.5),
        flat: true,
        // Admin/op: tap abre el sheet completo con fotos del vehículo.
        // Conductor: nunca llega aquí (filtro de arriba), pero por las
        // dudas se deja la rama compacta como fallback.
        onTap: () => isOpOrAdmin
            ? _showDriverInfoSheet(driver, stands)
            : _showDriverInfoCompact(driver),
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
          final auth = context.watch<AuthBloc>().state;
          final isOpOrAdmin = auth is AuthAuthenticated &&
              (auth.user.role == AppConstants.roleOperator ||
                  auth.user.role == AppConstants.roleAdmin);

          final allDrivers =
              state is MapLoaded ? state.activeDrivers : <DriverModel>[];
          final taxiStands =
              state is MapLoaded ? state.taxiStands : <TaxiStandModel>[];
          final drivers = _filteredDrivers(allDrivers);
          final markers = _buildMarkers(drivers, taxiStands,
              isOpOrAdmin: isOpOrAdmin);
          final circles = _buildAccuracyCircles(drivers);

          return Stack(
            children: [
              // ── Google Map ──
              GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: _initialCameraTarget,
                  zoom: 14.0,
                ),
                markers: markers,
                circles: circles,
                polylines: _buildRoutePolylines(),
                myLocationEnabled: _myCarIcon == null,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                mapToolbarEnabled: false,
                onLongPress: (latLng) =>
                    _onMapLongPress(latLng, drivers, taxiStands),
                onMapCreated: (controller) {
                  if (!_mapController.isCompleted) {
                    _mapController.complete(controller);
                  }
                },
              ),

              // Filter chips at top — solo útil para admin/operadora
              // que filtra al asignar carrera. Para conductor son
              // ruido visual (solo quiere ver dónde están los demás).
              Builder(builder: (ctx) {
                final auth = ctx.read<AuthBloc>().state;
                final isOpOrAdmin = auth is AuthAuthenticated &&
                    (auth.user.role == AppConstants.roleOperator ||
                        auth.user.role == AppConstants.roleAdmin);
                return Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isOpOrAdmin)
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _buildFilterChip(AppConstants.statusFree,
                                  'Libre', AppTheme.statusFree),
                              const SizedBox(width: 8),
                              _buildFilterChip(AppConstants.statusBusy,
                                  'Con pasajero', AppTheme.statusBusy),
                              const SizedBox(width: 8),
                              _buildFilterChip(
                                  AppConstants.statusReturning,
                                  'En camino',
                                  AppTheme.statusReturning),
                              const SizedBox(width: 8),
                              _buildStandLegendChip(
                                  taxiStands.where((s) => s.isActive).length),
                            ],
                          ),
                        ),
                      if (isOpOrAdmin) const SizedBox(height: 8),
                      _buildDestinationSelector(taxiStands),
                    ],
                  ),
                );
              }),

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
                    // Centrar en la parada de la asociación; si no hay
                    // configurada, usar el centro inicial (Quito).
                    controller.animateCamera(
                      CameraUpdate.newLatLngZoom(
                        _initialCameraTarget,
                        14.0,
                      ),
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

              // Bottom driver list sheet — solo admin/operadora
              if (isOpOrAdmin) DraggableScrollableSheet(
                controller: _sheetController,
                initialChildSize: _sheetMid,
                minChildSize: _sheetMin,
                maxChildSize: _sheetMax,
                snap: true,
                snapSizes: const [_sheetMin, _sheetMid, _sheetMax],
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
                        // Handle: tap → expande el sheet. Toda la zona
                        // del header es tocable para que minimizar y
                        // re-expandir sea trivial.
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _toggleSheet,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 4),
                            child: Center(
                              child: Container(
                                width: 48,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: Colors.grey[400],
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _toggleSheet,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            child: Row(
                              children: [
                                const Text(
                                  'Conductores Cercanos',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16),
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
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.keyboard_arrow_up,
                                  size: 20,
                                  color: Colors.grey[600],
                                ),
                              ],
                            ),
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
    final dest = _selectedDestination;
    if (pos == null || dest == null || _selectedDestinationName.isEmpty) {
      return {};
    }
    return {
      Polyline(
        polylineId: const PolylineId('route_to_dest'),
        points: [pos, dest],
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
              // Parada principal de la asociación (la que el admin
              // configura en "Ubicación parada"). Solo se muestra si
              // está configurada — antes era hardcoded a una dirección
              // de prueba.
              if (_associationStand != null && _associationStand!.isConfigured)
                ListTile(
                  leading:
                      const Icon(Icons.home, color: AppTheme.primaryColor),
                  title: Text(
                    _associationStand!.label?.isNotEmpty == true
                        ? _associationStand!.label!
                        : 'Parada principal',
                  ),
                  subtitle: Text(
                      'Radio: ${_associationStand!.radiusKm.toStringAsFixed(1)} km'),
                  selected: _selectedDestinationName ==
                      (_associationStand!.label ?? 'Parada principal'),
                  selectedTileColor:
                      AppTheme.primaryColor.withValues(alpha: 0.08),
                  onTap: () {
                    setState(() {
                      _selectedDestination = LatLng(
                          _associationStand!.lat!, _associationStand!.lng!);
                      _selectedDestinationName =
                          _associationStand!.label?.isNotEmpty == true
                              ? _associationStand!.label!
                              : 'Parada principal';
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
  /// Long-press en el mapa: busca el conductor cuyo marker está más cerca
  /// del punto presionado (radio ~120m al zoom típico) y abre el sheet
  /// completo con el botón "Ir aquí (Google Maps)".
  void _onMapLongPress(
    LatLng pressed,
    List<DriverModel> drivers,
    List<TaxiStandModel> stands,
  ) {
    DriverModel? closest;
    double bestKm = double.infinity;
    final filtered = _filteredDrivers(drivers);
    for (final d in filtered) {
      final lat = d.currentLatitude;
      final lng = d.currentLongitude;
      if (lat == null || lng == null) continue;
      final km = _haversineKm(pressed.latitude, pressed.longitude, lat, lng);
      if (km < bestKm) {
        bestKm = km;
        closest = d;
      }
    }
    // Tolerancia ~120 m a zoom típico.
    if (closest != null && bestKm <= 0.12) {
      _showDriverInfoSheet(closest, stands);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Mantén presionado sobre un conductor para usar "Ir aquí"'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// Sheet COMPACTO mostrado al tap rápido del marker: solo número de
  /// unidad, nombre y placa (sin distancias ni botón Ir).
  void _showDriverInfoCompact(DriverModel driver) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final color = _statusColor(driver.status);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
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
                                : 'Conductor',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 17),
                          ),
                          if (driver.driverName.isNotEmpty)
                            Text(
                              driver.driverName,
                              style: const TextStyle(fontSize: 14),
                            ),
                          if (driver.plate.isNotEmpty)
                            Text(
                              'Placa: ${driver.plate}',
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.textSecondary,
                              ),
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
                const SizedBox(height: 12),
                Text(
                  'Mantén presionado sobre la unidad en el mapa para ver "Ir aquí" con Google Maps.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showDriverInfoSheet(DriverModel driver, List<TaxiStandModel> stands) {
    final lat = driver.currentLatitude;
    final lng = driver.currentLongitude;
    if (lat == null || lng == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(driver.userId)
              .snapshots(),
          builder: (_, userSnap) {
            UserModel? userInfo;
            if (userSnap.hasData && userSnap.data!.exists) {
              userInfo = UserModel.fromFirestore(userSnap.data!);
            }

            final color = _statusColor(driver.status);
            return SafeArea(
              child: SingleChildScrollView(
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
                    const SizedBox(height: 12),
                    // Acción "Ir" — abre Google Maps con direcciones a este conductor.
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _openInGoogleMaps(lat, lng,
                              driver.vehicleNumber.isNotEmpty
                                  ? 'Unidad ${driver.vehicleNumber}'
                                  : driver.driverName);
                        },
                        icon: const Icon(Icons.directions),
                        label: const Text('Ir aquí (Google Maps)'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
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
                    // Distancia a la parada de la asociación (configurada).
                    if (_associationStand != null &&
                        _associationStand!.isConfigured)
                      _buildDistanceRow(
                        Icons.home,
                        _associationStand!.label?.isNotEmpty == true
                            ? _associationStand!.label!
                            : 'Parada principal',
                        _haversineKm(lat, lng, _associationStand!.lat!,
                            _associationStand!.lng!),
                      ),
                    // Paradas de taxi registradas
                    ...stands.where((s) => s.isActive).map(
                      (stand) => _buildDistanceRow(
                        Icons.flag,
                        stand.name,
                        _haversineKm(lat, lng, stand.latitude, stand.longitude),
                      ),
                    ),
                    // Fotos del vehículo y licencia
                    if (userInfo != null) _buildVehiclePhotosSection(userInfo),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Sección de fotos del vehículo y licencia para el sheet de conductor
  Widget _buildVehiclePhotosSection(UserModel user) {
    final photos = <_LabeledPhoto>[];
    if ((user.fotoVehiculo ?? '').isNotEmpty) {
      photos.add(_LabeledPhoto('Vehículo frontal', user.fotoVehiculo!));
    }
    if ((user.fotoLicenciaFrontal ?? '').isNotEmpty) {
      photos.add(_LabeledPhoto('Licencia frontal', user.fotoLicenciaFrontal!));
    }
    if ((user.fotoLicenciaTrasera ?? '').isNotEmpty) {
      photos.add(_LabeledPhoto('Licencia trasera', user.fotoLicenciaTrasera!));
    }
    if (photos.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Sin fotos registradas para este conductor',
          style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const Divider(),
        const SizedBox(height: 8),
        const Text(
          'Fotos del vehículo y licencia',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 110,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: photos.length,
            separatorBuilder: (ctx2, idx) => const SizedBox(width: 8),
            itemBuilder: (ctx2, i) {
              final p = photos[i];
              return GestureDetector(
                onTap: () => _showPhotoFullscreen(p.url, p.label),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        p.url,
                        width: 130,
                        height: 90,
                        fit: BoxFit.cover,
                        errorBuilder: (ctx3, err, stack) => Container(
                          width: 130,
                          height: 90,
                          color: Colors.grey.shade300,
                          child: const Icon(Icons.broken_image,
                              color: Colors.grey),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(p.label,
                        style: const TextStyle(fontSize: 10),
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showPhotoFullscreen(String url, String label) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: Center(
                child: Image.network(url),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 32),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                color: Colors.black54,
                child: Text(label,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Abre Google Maps (o el navegador) con direcciones desde la ubicación
  /// actual del usuario hacia las coordenadas dadas.
  Future<void> _openInGoogleMaps(
      double lat, double lng, String label) async {
    // El URL universal `?q=lat,lng` abre Google Maps con marker; con
    // `&travelmode=driving` y `?api=1&destination=lat,lng` abre la
    // navegación turn-by-turn directamente.
    final uri = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir Google Maps')),
      );
    }
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

/// Foto con etiqueta para la sección de fotos del conductor en el sheet.
class _LabeledPhoto {
  final String label;
  final String url;
  const _LabeledPhoto(this.label, this.url);
}
