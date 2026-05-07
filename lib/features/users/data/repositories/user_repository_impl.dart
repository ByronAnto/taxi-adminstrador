import '../../../auth/data/models/user_model.dart';
import '../../domain/repositories/user_repository.dart';
import '../datasources/user_remote_datasource.dart';
import '../models/driver_model.dart';

class UserRepositoryImpl implements UserRepository {
  final UserRemoteDatasource _datasource;

  UserRepositoryImpl(this._datasource);

  @override
  Future<List<UserModel>> getAllUsers() => _datasource.getAllUsers();

  @override
  Future<List<UserModel>> getUsersByRole(String role) =>
      _datasource.getUsersByRole(role);

  @override
  Future<void> toggleUserActive(String userId, bool isActive) =>
      _datasource.toggleUserActive(userId, isActive);

  @override
  Future<List<DriverModel>> getAllDrivers() => _datasource.getAllDrivers();

  @override
  Future<DriverModel?> getDriverByUserId(String userId) =>
      _datasource.getDriverByUserId(userId);

  @override
  Future<void> createDriver(DriverModel driver) =>
      _datasource.createDriver(driver);

  @override
  Future<void> updateDriver(DriverModel driver) =>
      _datasource.updateDriver(driver);

  @override
  Future<List<DriverModel>> getDriverRanking({int limit = 20}) =>
      _datasource.getDriverRanking(limit: limit);

  @override
  Future<List<UserModel>> searchUsers(String query) =>
      _datasource.searchUsers(query);
}
