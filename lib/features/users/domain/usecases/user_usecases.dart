import 'package:equatable/equatable.dart';
import '../../../../core/usecases/usecase.dart';
import '../../../auth/data/models/user_model.dart';
import '../../data/models/driver_model.dart';
import '../repositories/user_repository.dart';

// ========== Get All Users ==========

class GetAllUsersUseCase implements UseCase<List<UserModel>, NoParams> {
  final UserRepository repository;
  GetAllUsersUseCase(this.repository);
  @override
  Future<List<UserModel>> call(NoParams params) => repository.getAllUsers();
}

// ========== Get Users By Role ==========

class GetUsersByRoleUseCase implements UseCase<List<UserModel>, String> {
  final UserRepository repository;
  GetUsersByRoleUseCase(this.repository);
  @override
  Future<List<UserModel>> call(String role) => repository.getUsersByRole(role);
}

// ========== Toggle User Active ==========

class ToggleUserParams extends Equatable {
  final String userId;
  final bool isActive;
  const ToggleUserParams({required this.userId, required this.isActive});
  @override
  List<Object?> get props => [userId, isActive];
}

class ToggleUserActiveUseCase implements UseCase<void, ToggleUserParams> {
  final UserRepository repository;
  ToggleUserActiveUseCase(this.repository);
  @override
  Future<void> call(ToggleUserParams params) =>
      repository.toggleUserActive(params.userId, params.isActive);
}

// ========== Get Driver Ranking ==========

class GetDriverRankingUseCase implements UseCase<List<DriverModel>, int> {
  final UserRepository repository;
  GetDriverRankingUseCase(this.repository);
  @override
  Future<List<DriverModel>> call(int limit) =>
      repository.getDriverRanking(limit: limit);
}

// ========== Search Users ==========

class SearchUsersUseCase implements UseCase<List<UserModel>, String> {
  final UserRepository repository;
  SearchUsersUseCase(this.repository);
  @override
  Future<List<UserModel>> call(String query) => repository.searchUsers(query);
}

// ========== Create Driver ==========

class CreateDriverUseCase implements UseCase<void, DriverModel> {
  final UserRepository repository;
  CreateDriverUseCase(this.repository);
  @override
  Future<void> call(DriverModel driver) => repository.createDriver(driver);
}

// ========== Update Driver ==========

class UpdateDriverUseCase implements UseCase<void, DriverModel> {
  final UserRepository repository;
  UpdateDriverUseCase(this.repository);
  @override
  Future<void> call(DriverModel driver) => repository.updateDriver(driver);
}
