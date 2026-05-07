import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/trip_model.dart';
import '../../../../core/constants/app_constants.dart';

/// Fuente de datos remota para viajes (Firestore)
class TripRemoteDatasource {
  final FirebaseFirestore _firestore;

  TripRemoteDatasource({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference get _tripsRef =>
      _firestore.collection(AppConstants.tripsCollection);

  /// Stream de viajes activos
  Stream<List<TripModel>> watchActiveTrips() {
    return _tripsRef
        .where('status', whereIn: ['asignado', 'en_progreso'])
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => TripModel.fromFirestore(d)).toList());
  }

  /// Stream de viajes por conductor
  Stream<List<TripModel>> watchTripsByDriver(String driverId) {
    return _tripsRef
        .where('driverId', isEqualTo: driverId)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => TripModel.fromFirestore(d)).toList());
  }

  /// Historial paginado
  Future<List<TripModel>> getTripsHistory({
    String? driverId,
    DateTime? fromDate,
    DateTime? toDate,
    int limit = 20,
    String? lastDocId,
  }) async {
    Query query = _tripsRef.orderBy('createdAt', descending: true);

    if (driverId != null) {
      query = query.where('driverId', isEqualTo: driverId);
    }
    if (fromDate != null) {
      query = query.where('createdAt',
          isGreaterThanOrEqualTo: Timestamp.fromDate(fromDate));
    }
    if (toDate != null) {
      query = query.where('createdAt',
          isLessThanOrEqualTo: Timestamp.fromDate(toDate));
    }
    if (lastDocId != null) {
      final lastDoc = await _tripsRef.doc(lastDocId).get();
      query = query.startAfterDocument(lastDoc);
    }

    final snap = await query.limit(limit).get();
    return snap.docs.map((d) => TripModel.fromFirestore(d)).toList();
  }

  /// Obtener viaje por ID
  Future<TripModel> getTripById(String tripId) async {
    final doc = await _tripsRef.doc(tripId).get();
    if (!doc.exists) throw Exception('Viaje no encontrado');
    return TripModel.fromFirestore(doc);
  }

  /// Crear viaje
  Future<TripModel> createTrip(TripModel trip) async {
    final docRef = await _tripsRef.add(trip.toFirestore());
    final doc = await docRef.get();
    return TripModel.fromFirestore(doc);
  }

  /// Actualizar estado
  Future<void> updateTripStatus(String tripId, String newStatus) async {
    await _tripsRef.doc(tripId).update({'status': newStatus});
  }

  /// Completar viaje
  Future<void> completeTrip({
    required String tripId,
    required double dropoffLatitude,
    required double dropoffLongitude,
    required String dropoffAddress,
    required double fare,
    required int durationMinutes,
    required double distanceKm,
  }) async {
    await _tripsRef.doc(tripId).update({
      'status': 'completado',
      'dropoffLatitude': dropoffLatitude,
      'dropoffLongitude': dropoffLongitude,
      'dropoffAddress': dropoffAddress,
      'fare': fare,
      'durationMinutes': durationMinutes,
      'distanceKm': distanceKm,
      'endTime': Timestamp.fromDate(DateTime.now()),
    });
  }

  /// Cancelar viaje
  Future<void> cancelTrip(String tripId, {String? reason}) async {
    await _tripsRef.doc(tripId).update({
      'status': 'cancelado',
      'notes': reason,
      'endTime': Timestamp.fromDate(DateTime.now()),
    });
  }

  /// Estadísticas de conductor
  Future<Map<String, dynamic>> getDriverTripStats(String driverId) async {
    final completedSnap = await _tripsRef
        .where('driverId', isEqualTo: driverId)
        .where('status', isEqualTo: 'completado')
        .get();

    double totalFare = 0;
    double totalDistance = 0;
    int totalMinutes = 0;

    for (final doc in completedSnap.docs) {
      final data = doc.data() as Map<String, dynamic>;
      totalFare += (data['fare'] ?? 0.0).toDouble();
      totalDistance += (data['distanceKm'] ?? 0.0).toDouble();
      totalMinutes += (data['durationMinutes'] ?? 0) as int;
    }

    return {
      'totalTrips': completedSnap.docs.length,
      'totalFare': totalFare,
      'totalDistance': totalDistance,
      'totalMinutes': totalMinutes,
      'averageFare': completedSnap.docs.isEmpty
          ? 0.0
          : totalFare / completedSnap.docs.length,
    };
  }
}
