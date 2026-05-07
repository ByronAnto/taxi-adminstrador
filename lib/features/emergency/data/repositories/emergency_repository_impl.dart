import '../../domain/repositories/emergency_repository.dart';
import '../datasources/emergency_remote_datasource.dart';
import '../models/emergency_model.dart';

class EmergencyRepositoryImpl implements EmergencyRepository {
  final EmergencyRemoteDatasource _datasource;

  EmergencyRepositoryImpl(this._datasource);

  @override
  Stream<List<EmergencyModel>> watchActiveEmergencies() {
    return _datasource.watchActiveEmergencies();
  }

  @override
  Future<void> createEmergency(EmergencyModel emergency) {
    return _datasource.createEmergency(emergency);
  }

  @override
  Future<void> updateEmergencyLocation(
      String emergencyId, double latitude, double longitude) {
    return _datasource.updateEmergencyLocation(emergencyId, latitude, longitude);
  }

  @override
  Future<void> resolveEmergency(
      String emergencyId, String resolvedBy, String? notes) {
    return _datasource.resolveEmergency(emergencyId, resolvedBy, notes);
  }

  @override
  Future<void> cancelEmergency(String emergencyId) {
    return _datasource.cancelEmergency(emergencyId);
  }

  @override
  Future<List<EmergencyModel>> getEmergencyHistory({int limit = 50}) {
    return _datasource.getEmergencyHistory(limit: limit);
  }

  @override
  Future<EmergencyModel?> getActiveEmergencyByDriver(String driverId) {
    return _datasource.getActiveEmergencyByDriver(driverId);
  }
}
