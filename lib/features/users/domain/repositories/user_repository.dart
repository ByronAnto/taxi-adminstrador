import '../../../auth/data/models/user_model.dart';
import '../../data/models/driver_model.dart';

/// Interfaz abstracta del repositorio de gestión de usuarios
abstract class UserRepository {
  /// Obtener todos los usuarios
  Future<List<UserModel>> getAllUsers();

  /// Obtener usuarios por rol
  Future<List<UserModel>> getUsersByRole(String role);

  /// Activar/desactivar usuario
  Future<void> toggleUserActive(String userId, bool isActive);

  /// Obtener todos los conductores
  Future<List<DriverModel>> getAllDrivers();

  /// Obtener conductor por userId
  Future<DriverModel?> getDriverByUserId(String userId);

  /// Crear perfil de conductor
  Future<void> createDriver(DriverModel driver);

  /// Actualizar perfil de conductor
  Future<void> updateDriver(DriverModel driver);

  /// Obtener ranking de conductores
  Future<List<DriverModel>> getDriverRanking({int limit = 20});

  /// Buscar usuarios por nombre o cédula
  Future<List<UserModel>> searchUsers(String query);
}
