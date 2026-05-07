import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../constants/app_constants.dart';

/// Servicio global de ubicación del conductor.
///
/// Gestiona el GPS y push a Firestore independiente de la página de mapa.
/// - **Online** → GPS activo, status visible, operadora ve ubicación.
/// - **Offline** → GPS parado, status = desconectado.
///
/// Se inicializa tras login del conductor y persiste mientras la app vive.
///
/// Extiende [ChangeNotifier] para que otros módulos (walkie-talkie, etc.)
/// puedan suscribirse a cambios de online/offline.
class DriverLocationService extends ChangeNotifier {
  DriverLocationService._();
  static final DriverLocationService instance = DriverLocationService._();

  String? _driverId;
  String? _userId;
  bool _isOnline = false;
  String _currentStatus = AppConstants.statusOffline;
  StreamSubscription<Position>? _positionSub;
  DateTime? _lastPush;
  double? _lastLatitude;
  double? _lastLongitude;

  /// ¿Está el conductor en línea?
  bool get isOnline => _isOnline;

  /// ID del documento driver en Firestore (null si no hay driver doc).
  String? get driverId => _driverId;

  /// Estado actual del conductor.
  String get currentStatus => _currentStatus;

  /// Última coordenada conocida.
  double? get lastLatitude => _lastLatitude;
  double? get lastLongitude => _lastLongitude;

  final _firestore = FirebaseFirestore.instance;

  // ─── Inicialización ──────────────────────────────────────

  /// Inicializa para un conductor autenticado.
  /// Busca el driver doc, sincroniza datos denormalizados y pone online.
  Future<void> initialize({
    required String userId,
    String? displayName,
    String? vehicleNumber,
    String? plate,
  }) async {
    // Si ya está inicializado para el mismo usuario, no repetir
    if (_driverId != null && _userId == userId && _isOnline) return;
    _userId = userId;

    try {
      final snapshot = await _firestore
          .collection(AppConstants.driversCollection)
          .where('userId', isEqualTo: userId)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        debugPrint(
            '📍 [LocationService] No driver doc para userId=$userId → creando…');
        // Auto-crear el documento de driver para este conductor
        final now = Timestamp.fromDate(DateTime.now());
        final newDocRef =
            _firestore.collection(AppConstants.driversCollection).doc();
        await newDocRef.set({
          'userId': userId,
          'licenseNumber': '',
          'licenseType': '',
          'licenseExpiry': now,
          'status': AppConstants.statusFree,
          'currentLatitude': null,
          'currentLongitude': null,
          'rating': 5.0,
          'totalTrips': 0,
          'totalPoints': 0,
          'vehicleIds': <String>[],
          'activeVehicleId': null,
          'isActive': true,
          'createdAt': now,
          'updatedAt': now,
          'vehicleNumber': vehicleNumber ?? '',
          'plate': plate ?? '',
          'driverName': displayName ?? '',
        });
        _driverId = newDocRef.id;
        debugPrint(
            '📍 [LocationService] Driver doc CREADO → $_driverId');
      } else {
        _driverId = snapshot.docs.first.id;
        debugPrint('📍 [LocationService] Driver ID: $_driverId');
      }

      // Sincronizar campos denormalizados (nombre, placa, nro. vehículo)
      final updates = <String, dynamic>{};
      if (vehicleNumber != null && vehicleNumber.isNotEmpty) {
        updates['vehicleNumber'] = vehicleNumber;
      }
      if (plate != null && plate.isNotEmpty) {
        updates['plate'] = plate;
      }
      if (displayName != null && displayName.isNotEmpty) {
        updates['driverName'] = displayName;
      }
      if (updates.isNotEmpty) {
        await _firestore
            .collection(AppConstants.driversCollection)
            .doc(_driverId!)
            .update(updates);
        debugPrint('📍 [LocationService] Datos denormalizados: $updates');
      }

      // Auto-poner online
      await goOnline();
    } catch (e) {
      debugPrint('📍 [LocationService] Error initialize: $e');
    }
  }

  // ─── Online / Offline ────────────────────────────────────

  /// Pone al conductor EN LÍNEA: actualiza status y arranca GPS.
  Future<void> goOnline({String? status}) async {
    if (_driverId == null) return;
    _isOnline = true;
    _currentStatus = status ?? AppConstants.statusFree;

    try {
      await _firestore
          .collection(AppConstants.driversCollection)
          .doc(_driverId!)
          .update({
        'status': _currentStatus,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });
    } catch (e) {
      debugPrint('📍 [LocationService] Error goOnline: $e');
    }

    await _requestPermissionAndStartGps();
    notifyListeners();
    debugPrint(
        '📍 [LocationService] ✅ ONLINE → status=$_currentStatus, GPS activo');
  }

  /// Pone al conductor FUERA DE LÍNEA: para GPS, marca desconectado.
  Future<void> goOffline() async {
    if (_driverId == null) return;
    _isOnline = false;
    _currentStatus = AppConstants.statusOffline;
    _stopGps();

    try {
      await _firestore
          .collection(AppConstants.driversCollection)
          .doc(_driverId!)
          .update({
        'status': AppConstants.statusOffline,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });
    } catch (e) {
      debugPrint('📍 [LocationService] Error goOffline: $e');
    }

    notifyListeners();
    debugPrint('📍 [LocationService] ⛔ OFFLINE → GPS detenido');
  }

  /// Cambia el estado del conductor.
  /// Si es [statusOffline] → pasa a offline (para GPS).
  /// Si es cualquier otro estado → garantiza online + GPS activo.
  Future<void> updateStatus(String status) async {
    if (_driverId == null) return;

    if (status == AppConstants.statusOffline) {
      await goOffline();
      return;
    }

    _currentStatus = status;

    if (!_isOnline) {
      // Si estaba offline y pide un status online → encender todo
      await goOnline(status: status);
    } else {
      // Ya online → solo actualizar el status en Firestore
      try {
        await _firestore
            .collection(AppConstants.driversCollection)
            .doc(_driverId!)
            .update({
          'status': status,
          'updatedAt': Timestamp.fromDate(DateTime.now()),
        });
        debugPrint('📍 [LocationService] status → $status');
      } catch (e) {
        debugPrint('📍 [LocationService] Error updateStatus: $e');
      }
    }
  }

  // ─── GPS interno ─────────────────────────────────────────

  Future<void> _requestPermissionAndStartGps() async {
    final perm = await Permission.locationWhenInUse.request();
    if (perm.isGranted) {
      _startGps();
    } else {
      debugPrint('📍 [LocationService] Permiso de ubicación DENEGADO');
    }
  }

  void _startGps() {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5, // metros mínimos para nueva posición
      ),
    ).listen(
      (position) {
        if (!_isOnline || _driverId == null) return;
        _lastLatitude = position.latitude;
        _lastLongitude = position.longitude;

        // Throttle: push cada N segundos (definido en AppConstants)
        final now = DateTime.now();
        if (_lastPush == null ||
            now.difference(_lastPush!).inSeconds >=
                AppConstants.locationUpdateSeconds) {
          _lastPush = now;
          _pushLocation(position.latitude, position.longitude);
        }
      },
      onError: (e) {
        debugPrint('📍 [LocationService] GPS stream error: $e');
      },
    );
    debugPrint('📍 [LocationService] GPS stream iniciado');
  }

  Future<void> _pushLocation(double lat, double lng) async {
    try {
      await _firestore
          .collection(AppConstants.driversCollection)
          .doc(_driverId!)
          .update({
        'currentLatitude': lat,
        'currentLongitude': lng,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });
      debugPrint('📍 [LocationService] GPS push → ($lat, $lng)');
    } catch (e) {
      debugPrint('📍 [LocationService] Error push GPS: $e');
    }
  }

  void _stopGps() {
    _positionSub?.cancel();
    _positionSub = null;
    _lastPush = null;
    debugPrint('📍 [LocationService] GPS stream detenido');
  }

  // ─── Limpieza ────────────────────────────────────────────

  /// Reset total: se usa al hacer logout.
  Future<void> reset() async {
    if (_isOnline) await goOffline();
    _driverId = null;
    _userId = null;
    _lastLatitude = null;
    _lastLongitude = null;
  }

  /// Limpieza al cerrar la app.
  @override
  void dispose() {
    _stopGps();
    _driverId = null;
    _userId = null;
    super.dispose();
  }
}
