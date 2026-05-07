import 'package:equatable/equatable.dart';
import '../../../../core/usecases/usecase.dart';
import '../../data/models/emergency_model.dart';
import '../repositories/emergency_repository.dart';

// ============ Watch Active Emergencies ============

class WatchActiveEmergenciesUseCase {
  final EmergencyRepository repository;
  WatchActiveEmergenciesUseCase(this.repository);

  Stream<List<EmergencyModel>> call() {
    return repository.watchActiveEmergencies();
  }
}

// ============ Create Emergency ============

class CreateEmergencyUseCase extends UseCase<void, EmergencyModel> {
  final EmergencyRepository repository;
  CreateEmergencyUseCase(this.repository);

  @override
  Future<void> call(EmergencyModel emergency) {
    return repository.createEmergency(emergency);
  }
}

// ============ Update Emergency Location ============

class UpdateEmergencyLocationParams extends Equatable {
  final String emergencyId;
  final double latitude;
  final double longitude;

  const UpdateEmergencyLocationParams({
    required this.emergencyId,
    required this.latitude,
    required this.longitude,
  });

  @override
  List<Object?> get props => [emergencyId, latitude, longitude];
}

class UpdateEmergencyLocationUseCase
    extends UseCase<void, UpdateEmergencyLocationParams> {
  final EmergencyRepository repository;
  UpdateEmergencyLocationUseCase(this.repository);

  @override
  Future<void> call(UpdateEmergencyLocationParams params) {
    return repository.updateEmergencyLocation(
        params.emergencyId, params.latitude, params.longitude);
  }
}

// ============ Resolve Emergency ============

class ResolveEmergencyParams extends Equatable {
  final String emergencyId;
  final String resolvedBy;
  final String? notes;

  const ResolveEmergencyParams({
    required this.emergencyId,
    required this.resolvedBy,
    this.notes,
  });

  @override
  List<Object?> get props => [emergencyId, resolvedBy, notes];
}

class ResolveEmergencyUseCase extends UseCase<void, ResolveEmergencyParams> {
  final EmergencyRepository repository;
  ResolveEmergencyUseCase(this.repository);

  @override
  Future<void> call(ResolveEmergencyParams params) {
    return repository.resolveEmergency(
        params.emergencyId, params.resolvedBy, params.notes);
  }
}

// ============ Cancel Emergency ============

class CancelEmergencyUseCase extends UseCase<void, String> {
  final EmergencyRepository repository;
  CancelEmergencyUseCase(this.repository);

  @override
  Future<void> call(String emergencyId) {
    return repository.cancelEmergency(emergencyId);
  }
}

// ============ Get Emergency History ============

class GetEmergencyHistoryUseCase extends UseCase<List<EmergencyModel>, int> {
  final EmergencyRepository repository;
  GetEmergencyHistoryUseCase(this.repository);

  @override
  Future<List<EmergencyModel>> call(int limit) {
    return repository.getEmergencyHistory(limit: limit);
  }
}

// ============ Get Active Emergency By Driver ============

class GetActiveEmergencyByDriverUseCase
    extends UseCase<EmergencyModel?, String> {
  final EmergencyRepository repository;
  GetActiveEmergencyByDriverUseCase(this.repository);

  @override
  Future<EmergencyModel?> call(String driverId) {
    return repository.getActiveEmergencyByDriver(driverId);
  }
}
