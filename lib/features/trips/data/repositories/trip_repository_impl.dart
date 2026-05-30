import '../../domain/repositories/trip_repository.dart';
import '../datasources/trip_remote_datasource.dart';
import '../models/trip_model.dart';

/// Implementación del repositorio de viajes
class TripRepositoryImpl implements TripRepository {
  final TripRemoteDatasource remoteDatasource;

  TripRepositoryImpl({required this.remoteDatasource});

  @override
  Stream<List<TripModel>> watchActiveTrips() =>
      remoteDatasource.watchActiveTrips();

  @override
  Stream<List<TripModel>> watchTripsByDriver(String driverId) =>
      remoteDatasource.watchTripsByDriver(driverId);

  @override
  Future<List<TripModel>> getTripsHistory({
    String? driverId,
    DateTime? fromDate,
    DateTime? toDate,
    int limit = 20,
    String? lastDocId,
  }) =>
      remoteDatasource.getTripsHistory(
        driverId: driverId,
        fromDate: fromDate,
        toDate: toDate,
        limit: limit,
        lastDocId: lastDocId,
      );

  @override
  Future<TripModel> getTripById(String tripId) =>
      remoteDatasource.getTripById(tripId);

  @override
  Future<TripModel> createTrip(TripModel trip) =>
      remoteDatasource.createTrip(trip);

  @override
  Future<void> updateTripStatus(String tripId, String newStatus) =>
      remoteDatasource.updateTripStatus(tripId, newStatus);

  @override
  Future<void> completeTrip({
    required String tripId,
    required double dropoffLatitude,
    required double dropoffLongitude,
    required String dropoffAddress,
    required double fare,
    required int durationMinutes,
    required double distanceKm,
  }) =>
      remoteDatasource.completeTrip(
        tripId: tripId,
        dropoffLatitude: dropoffLatitude,
        dropoffLongitude: dropoffLongitude,
        dropoffAddress: dropoffAddress,
        fare: fare,
        durationMinutes: durationMinutes,
        distanceKm: distanceKm,
      );

  @override
  Future<void> finalizeTrip(String tripId, {String? tripRequestId}) =>
      remoteDatasource.finalizeTrip(tripId, tripRequestId: tripRequestId);

  @override
  Future<void> cancelTrip(String tripId, {String? reason, String? tripRequestId}) =>
      remoteDatasource.cancelTrip(tripId, reason: reason, tripRequestId: tripRequestId);

  @override
  Future<Map<String, dynamic>> getDriverTripStats(String driverId) =>
      remoteDatasource.getDriverTripStats(driverId);
}
