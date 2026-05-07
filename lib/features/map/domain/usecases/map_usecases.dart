import 'package:equatable/equatable.dart';
import '../../../../core/usecases/usecase.dart';
import '../../../users/data/models/driver_model.dart';
import '../../data/models/taxi_stand_model.dart';
import '../repositories/map_repository.dart';

// ========== Watch Active Driver Locations ==========

class WatchActiveDriversUseCase {
  final MapRepository repository;
  WatchActiveDriversUseCase(this.repository);
  Stream<List<DriverModel>> call() => repository.watchActiveDriverLocations();
}

// ========== Update Driver Location ==========

class UpdateLocationParams extends Equatable {
  final String driverId;
  final double latitude;
  final double longitude;
  const UpdateLocationParams({required this.driverId, required this.latitude, required this.longitude});
  @override
  List<Object?> get props => [driverId, latitude, longitude];
}

class UpdateDriverLocationUseCase implements UseCase<void, UpdateLocationParams> {
  final MapRepository repository;
  UpdateDriverLocationUseCase(this.repository);
  @override
  Future<void> call(UpdateLocationParams params) =>
      repository.updateDriverLocation(params.driverId, params.latitude, params.longitude);
}

// ========== Update Driver Status ==========

class UpdateStatusParams extends Equatable {
  final String driverId;
  final String status;
  const UpdateStatusParams({required this.driverId, required this.status});
  @override
  List<Object?> get props => [driverId, status];
}

class UpdateDriverStatusUseCase implements UseCase<void, UpdateStatusParams> {
  final MapRepository repository;
  UpdateDriverStatusUseCase(this.repository);
  @override
  Future<void> call(UpdateStatusParams params) =>
      repository.updateDriverStatus(params.driverId, params.status);
}

// ========== Get Nearby Drivers ==========

class NearbyDriversParams extends Equatable {
  final double latitude;
  final double longitude;
  final double radiusKm;
  const NearbyDriversParams({required this.latitude, required this.longitude, required this.radiusKm});
  @override
  List<Object?> get props => [latitude, longitude, radiusKm];
}

class GetNearbyDriversUseCase implements UseCase<List<DriverModel>, NearbyDriversParams> {
  final MapRepository repository;
  GetNearbyDriversUseCase(this.repository);
  @override
  Future<List<DriverModel>> call(NearbyDriversParams params) =>
      repository.getNearbyDrivers(params.latitude, params.longitude, params.radiusKm);
}

// ========== Taxi Stands (Paradas) ==========

class WatchTaxiStandsUseCase {
  final MapRepository repository;
  WatchTaxiStandsUseCase(this.repository);
  Stream<List<TaxiStandModel>> call() => repository.watchTaxiStands();
}

class GetAllTaxiStandsUseCase {
  final MapRepository repository;
  GetAllTaxiStandsUseCase(this.repository);
  Future<List<TaxiStandModel>> call() => repository.getAllTaxiStands();
}

class CreateTaxiStandUseCase implements UseCase<TaxiStandModel, TaxiStandModel> {
  final MapRepository repository;
  CreateTaxiStandUseCase(this.repository);
  @override
  Future<TaxiStandModel> call(TaxiStandModel stand) => repository.createTaxiStand(stand);
}

class UpdateTaxiStandUseCase implements UseCase<void, TaxiStandModel> {
  final MapRepository repository;
  UpdateTaxiStandUseCase(this.repository);
  @override
  Future<void> call(TaxiStandModel stand) => repository.updateTaxiStand(stand);
}

class DeleteTaxiStandUseCase implements UseCase<void, String> {
  final MapRepository repository;
  DeleteTaxiStandUseCase(this.repository);
  @override
  Future<void> call(String standId) => repository.deleteTaxiStand(standId);
}
