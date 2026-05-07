import '../../../users/data/models/driver_model.dart';
import '../../data/models/taxi_stand_model.dart';

/// Interfaz abstracta del repositorio de mapa/ubicación
abstract class MapRepository {
  /// Observar ubicaciones de conductores activos en tiempo real
  Stream<List<DriverModel>> watchActiveDriverLocations();

  /// Actualizar ubicación del conductor
  Future<void> updateDriverLocation(String driverId, double latitude, double longitude);

  /// Actualizar estado del conductor
  Future<void> updateDriverStatus(String driverId, String status);

  /// Obtener conductor por ID
  Future<DriverModel> getDriverById(String driverId);

  /// Obtener conductores cercanos a un punto
  Future<List<DriverModel>> getNearbyDrivers(double latitude, double longitude, double radiusKm);

  /// Actualizar vehículo activo del conductor
  Future<void> setActiveVehicle(String driverId, String vehicleId);

  // ─── Paradas ───
  Stream<List<TaxiStandModel>> watchTaxiStands();
  Future<List<TaxiStandModel>> getAllTaxiStands();
  Future<TaxiStandModel> createTaxiStand(TaxiStandModel stand);
  Future<void> updateTaxiStand(TaxiStandModel stand);
  Future<void> deleteTaxiStand(String standId);
}
