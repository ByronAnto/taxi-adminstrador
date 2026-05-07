import '../../domain/repositories/map_repository.dart';
import '../datasources/map_remote_datasource.dart';
import '../../../users/data/models/driver_model.dart';
import '../models/taxi_stand_model.dart';

class MapRepositoryImpl implements MapRepository {
  final MapRemoteDatasource _datasource;

  MapRepositoryImpl(this._datasource);

  @override
  Stream<List<DriverModel>> watchActiveDriverLocations() =>
      _datasource.watchActiveDriverLocations();

  @override
  Future<void> updateDriverLocation(String driverId, double latitude, double longitude) =>
      _datasource.updateDriverLocation(driverId, latitude, longitude);

  @override
  Future<void> updateDriverStatus(String driverId, String status) =>
      _datasource.updateDriverStatus(driverId, status);

  @override
  Future<DriverModel> getDriverById(String driverId) =>
      _datasource.getDriverById(driverId);

  @override
  Future<List<DriverModel>> getNearbyDrivers(double latitude, double longitude, double radiusKm) =>
      _datasource.getNearbyDrivers(latitude, longitude, radiusKm);

  @override
  Future<void> setActiveVehicle(String driverId, String vehicleId) =>
      _datasource.setActiveVehicle(driverId, vehicleId);

  // ─── Paradas ───

  @override
  Stream<List<TaxiStandModel>> watchTaxiStands() =>
      _datasource.watchTaxiStands();

  @override
  Future<List<TaxiStandModel>> getAllTaxiStands() =>
      _datasource.getAllTaxiStands();

  @override
  Future<TaxiStandModel> createTaxiStand(TaxiStandModel stand) =>
      _datasource.createTaxiStand(stand);

  @override
  Future<void> updateTaxiStand(TaxiStandModel stand) =>
      _datasource.updateTaxiStand(stand);

  @override
  Future<void> deleteTaxiStand(String standId) =>
      _datasource.deleteTaxiStand(standId);
}
