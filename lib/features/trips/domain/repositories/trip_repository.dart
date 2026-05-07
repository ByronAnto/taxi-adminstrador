import '../../data/models/trip_model.dart';

/// Contrato del repositorio de viajes
abstract class TripRepository {
  /// Obtener viajes activos (asignado, en_progreso) en tiempo real
  Stream<List<TripModel>> watchActiveTrips();

  /// Obtener viajes por conductor en tiempo real
  Stream<List<TripModel>> watchTripsByDriver(String driverId);

  /// Obtener historial de viajes paginado
  Future<List<TripModel>> getTripsHistory({
    String? driverId,
    DateTime? fromDate,
    DateTime? toDate,
    int limit = 20,
    String? lastDocId,
  });

  /// Obtener un viaje por ID
  Future<TripModel> getTripById(String tripId);

  /// Crear un nuevo viaje (operadora asigna carrera)
  Future<TripModel> createTrip(TripModel trip);

  /// Actualizar estado del viaje
  Future<void> updateTripStatus(String tripId, String newStatus);

  /// Completar viaje con datos finales
  Future<void> completeTrip({
    required String tripId,
    required double dropoffLatitude,
    required double dropoffLongitude,
    required String dropoffAddress,
    required double fare,
    required int durationMinutes,
    required double distanceKm,
  });

  /// Cancelar viaje
  Future<void> cancelTrip(String tripId, {String? reason});

  /// Obtener estadísticas de viajes de un conductor
  Future<Map<String, dynamic>> getDriverTripStats(String driverId);
}
