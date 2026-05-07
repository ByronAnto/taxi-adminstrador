import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../users/data/models/driver_model.dart';
import '../models/taxi_stand_model.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/current_user_context.dart';

class MapRemoteDatasource {
  final FirebaseFirestore _firestore;

  MapRemoteDatasource({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference get _driversRef =>
      _firestore.collection(AppConstants.driversCollection);

  CollectionReference get _taxiStandsRef =>
      _firestore.collection(AppConstants.taxiStandsCollection);

  /// Stream de conductores activos. Si se pasa [associationId], filtra por
  /// tenant — necesario para cumplir las reglas Firestore (sameTenant).
  /// El filtro de status != 'desconectado' se hace client-side para evitar
  /// requerir un composite index manual.
  Stream<List<DriverModel>> watchActiveDriverLocations({
    String? associationId,
  }) {
    final aid = associationId ?? CurrentUserContext.instance.associationId;
    Query query = _driversRef.where('isActive', isEqualTo: true);
    if (aid != null && aid.isNotEmpty) {
      query = query.where('associationId', isEqualTo: aid);
    }
    return query.snapshots().map((snapshot) => snapshot.docs
        .map((doc) => DriverModel.fromFirestore(doc))
        .where((d) => d.status != AppConstants.statusOffline)
        .toList());
  }

  Future<void> updateDriverLocation(String driverId, double latitude, double longitude) async {
    await _driversRef.doc(driverId).update({
      'currentLatitude': latitude,
      'currentLongitude': longitude,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    });
  }

  Future<void> updateDriverStatus(String driverId, String status) async {
    await _driversRef.doc(driverId).update({
      'status': status,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    });
  }

  Future<DriverModel> getDriverById(String driverId) async {
    final doc = await _driversRef.doc(driverId).get();
    if (!doc.exists) throw Exception('Conductor no encontrado');
    return DriverModel.fromFirestore(doc);
  }

  Future<List<DriverModel>> getNearbyDrivers(
    double latitude,
    double longitude,
    double radiusKm,
  ) async {
    // Firestore no soporta geo queries nativamente, se obtienen activos y se filtran
    final snapshot = await _driversRef
        .where('isActive', isEqualTo: true)
        .where('status', isEqualTo: AppConstants.statusFree)
        .get();

    final drivers = snapshot.docs
        .map((doc) => DriverModel.fromFirestore(doc))
        .where((driver) {
      if (driver.currentLatitude == null || driver.currentLongitude == null) return false;
      final distance = _calculateDistance(
        latitude, longitude,
        driver.currentLatitude!, driver.currentLongitude!,
      );
      return distance <= radiusKm;
    }).toList();

    return drivers;
  }

  Future<void> setActiveVehicle(String driverId, String vehicleId) async {
    await _driversRef.doc(driverId).update({
      'activeVehicleId': vehicleId,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    });
  }

  /// Fórmula Haversine para calcular distancias
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const double earthRadius = 6371; // km
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
        sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  // ─── Taxi Stands (Paradas) ─────────────────────────────

  Stream<List<TaxiStandModel>> watchTaxiStands() {
    return _taxiStandsRef
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => TaxiStandModel.fromFirestore(doc))
            .toList());
  }

  Future<List<TaxiStandModel>> getAllTaxiStands() async {
    final snapshot = await _taxiStandsRef.orderBy('name').get();
    return snapshot.docs
        .map((doc) => TaxiStandModel.fromFirestore(doc))
        .toList();
  }

  Future<TaxiStandModel> createTaxiStand(TaxiStandModel stand) async {
    final docRef = await _taxiStandsRef.add(stand.toFirestore());
    return stand.copyWith(id: docRef.id);
  }

  Future<void> updateTaxiStand(TaxiStandModel stand) async {
    await _taxiStandsRef.doc(stand.id).update({
      'name': stand.name,
      'address': stand.address,
      'latitude': stand.latitude,
      'longitude': stand.longitude,
      'isActive': stand.isActive,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    });
  }

  Future<void> deleteTaxiStand(String standId) async {
    await _taxiStandsRef.doc(standId).delete();
  }
}
