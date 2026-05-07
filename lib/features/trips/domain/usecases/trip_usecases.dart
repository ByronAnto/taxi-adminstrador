import '../../data/models/trip_model.dart';
import '../repositories/trip_repository.dart';

/// Caso de uso: Observar viajes activos
class WatchActiveTripsUseCase {
  final TripRepository repository;

  WatchActiveTripsUseCase(this.repository);

  Stream<List<TripModel>> call() => repository.watchActiveTrips();
}

/// Caso de uso: Observar viajes de un conductor
class WatchDriverTripsUseCase {
  final TripRepository repository;

  WatchDriverTripsUseCase(this.repository);

  Stream<List<TripModel>> call(String driverId) =>
      repository.watchTripsByDriver(driverId);
}

/// Caso de uso: Crear viaje
class CreateTripUseCase {
  final TripRepository repository;

  CreateTripUseCase(this.repository);

  Future<TripModel> call(TripModel trip) => repository.createTrip(trip);
}

/// Caso de uso: Completar viaje
class CompleteTripUseCase {
  final TripRepository repository;

  CompleteTripUseCase(this.repository);

  Future<void> call(CompleteTripParams params) => repository.completeTrip(
        tripId: params.tripId,
        dropoffLatitude: params.dropoffLatitude,
        dropoffLongitude: params.dropoffLongitude,
        dropoffAddress: params.dropoffAddress,
        fare: params.fare,
        durationMinutes: params.durationMinutes,
        distanceKm: params.distanceKm,
      );
}

class CompleteTripParams {
  final String tripId;
  final double dropoffLatitude;
  final double dropoffLongitude;
  final String dropoffAddress;
  final double fare;
  final int durationMinutes;
  final double distanceKm;

  CompleteTripParams({
    required this.tripId,
    required this.dropoffLatitude,
    required this.dropoffLongitude,
    required this.dropoffAddress,
    required this.fare,
    required this.durationMinutes,
    required this.distanceKm,
  });
}

/// Caso de uso: Cancelar viaje
class CancelTripUseCase {
  final TripRepository repository;

  CancelTripUseCase(this.repository);

  Future<void> call(String tripId, {String? reason}) =>
      repository.cancelTrip(tripId, reason: reason);
}

/// Caso de uso: Obtener historial de viajes
class GetTripsHistoryUseCase {
  final TripRepository repository;

  GetTripsHistoryUseCase(this.repository);

  Future<List<TripModel>> call({
    String? driverId,
    DateTime? fromDate,
    DateTime? toDate,
    int limit = 20,
    String? lastDocId,
  }) =>
      repository.getTripsHistory(
        driverId: driverId,
        fromDate: fromDate,
        toDate: toDate,
        limit: limit,
        lastDocId: lastDocId,
      );
}

/// Caso de uso: Estadísticas del conductor
class GetDriverTripStatsUseCase {
  final TripRepository repository;

  GetDriverTripStatsUseCase(this.repository);

  Future<Map<String, dynamic>> call(String driverId) =>
      repository.getDriverTripStats(driverId);
}
