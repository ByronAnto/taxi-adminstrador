import '../../data/models/emergency_model.dart';

abstract class EmergencyRepository {
  /// Observa emergencias activas en tiempo real
  Stream<List<EmergencyModel>> watchActiveEmergencies();

  /// Crea una nueva alerta de emergencia
  Future<void> createEmergency(EmergencyModel emergency);

  /// Actualiza la ubicación de una emergencia activa
  Future<void> updateEmergencyLocation(
      String emergencyId, double latitude, double longitude);

  /// Resuelve una emergencia
  Future<void> resolveEmergency(
      String emergencyId, String resolvedBy, String? notes);

  /// Cancela una emergencia (el mismo conductor)
  Future<void> cancelEmergency(String emergencyId);

  /// Obtiene el historial de emergencias
  Future<List<EmergencyModel>> getEmergencyHistory({int limit = 50});

  /// Obtiene emergencias activas de un conductor específico
  Future<EmergencyModel?> getActiveEmergencyByDriver(String driverId);
}
