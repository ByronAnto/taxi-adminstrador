import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../../../core/usecases/usecase.dart';
import '../../../auth/data/models/user_model.dart';
import '../../data/models/driver_model.dart';
import '../../domain/usecases/user_usecases.dart';

// ============ EVENTS ============

abstract class UserManagementEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class UsersLoadRequested extends UserManagementEvent {}

class UsersByRoleRequested extends UserManagementEvent {
  final String role;
  UsersByRoleRequested(this.role);
  @override
  List<Object?> get props => [role];
}

class UserToggleActiveRequested extends UserManagementEvent {
  final String userId;
  final bool isActive;
  UserToggleActiveRequested(this.userId, this.isActive);
  @override
  List<Object?> get props => [userId, isActive];
}

class DriverRankingRequested extends UserManagementEvent {
  final int limit;
  DriverRankingRequested({this.limit = 20});
  @override
  List<Object?> get props => [limit];
}

class UserSearchRequested extends UserManagementEvent {
  final String query;
  UserSearchRequested(this.query);
  @override
  List<Object?> get props => [query];
}

class DriverCreateRequested extends UserManagementEvent {
  final DriverModel driver;
  DriverCreateRequested(this.driver);
  @override
  List<Object?> get props => [driver.uid];
}

class DriverUpdateRequested extends UserManagementEvent {
  final DriverModel driver;
  DriverUpdateRequested(this.driver);
  @override
  List<Object?> get props => [driver.uid];
}

// ============ STATES ============

abstract class UserManagementState extends Equatable {
  @override
  List<Object?> get props => [];
}

class UserManagementInitial extends UserManagementState {}

class UserManagementLoading extends UserManagementState {}

class UserManagementLoaded extends UserManagementState {
  final List<UserModel> users;
  final List<DriverModel> ranking;

  UserManagementLoaded({
    this.users = const [],
    this.ranking = const [],
  });

  @override
  List<Object?> get props => [users, ranking];

  UserManagementLoaded copyWith({
    List<UserModel>? users,
    List<DriverModel>? ranking,
  }) {
    return UserManagementLoaded(
      users: users ?? this.users,
      ranking: ranking ?? this.ranking,
    );
  }
}

class UserManagementActionSuccess extends UserManagementState {
  final String message;
  UserManagementActionSuccess(this.message);
  @override
  List<Object?> get props => [message];
}

class UserManagementError extends UserManagementState {
  final String message;
  UserManagementError(this.message);
  @override
  List<Object?> get props => [message];
}

// ============ BLOC ============

class UserManagementBloc extends Bloc<UserManagementEvent, UserManagementState> {
  final GetAllUsersUseCase getAllUsers;
  final GetUsersByRoleUseCase getUsersByRole;
  final ToggleUserActiveUseCase toggleUserActive;
  final GetDriverRankingUseCase getDriverRanking;
  final SearchUsersUseCase searchUsers;
  final CreateDriverUseCase createDriver;
  final UpdateDriverUseCase updateDriver;

  UserManagementBloc({
    required this.getAllUsers,
    required this.getUsersByRole,
    required this.toggleUserActive,
    required this.getDriverRanking,
    required this.searchUsers,
    required this.createDriver,
    required this.updateDriver,
  }) : super(UserManagementInitial()) {
    on<UsersLoadRequested>(_onLoadUsers);
    on<UsersByRoleRequested>(_onLoadByRole);
    on<UserToggleActiveRequested>(_onToggleActive);
    on<DriverRankingRequested>(_onLoadRanking);
    on<UserSearchRequested>(_onSearch);
    on<DriverCreateRequested>(_onCreateDriver);
    on<DriverUpdateRequested>(_onUpdateDriver);
  }

  Future<void> _onLoadUsers(
    UsersLoadRequested event,
    Emitter<UserManagementState> emit,
  ) async {
    emit(UserManagementLoading());
    try {
      final users = await getAllUsers(NoParams());
      emit(UserManagementLoaded(users: users));
    } catch (e) {
      emit(UserManagementError('Error al cargar usuarios: $e'));
    }
  }

  Future<void> _onLoadByRole(
    UsersByRoleRequested event,
    Emitter<UserManagementState> emit,
  ) async {
    emit(UserManagementLoading());
    try {
      final users = await getUsersByRole(event.role);
      final current = state;
      if (current is UserManagementLoaded) {
        emit(current.copyWith(users: users));
      } else {
        emit(UserManagementLoaded(users: users));
      }
    } catch (e) {
      emit(UserManagementError('Error al cargar usuarios: $e'));
    }
  }

  Future<void> _onToggleActive(
    UserToggleActiveRequested event,
    Emitter<UserManagementState> emit,
  ) async {
    try {
      await toggleUserActive(ToggleUserParams(userId: event.userId, isActive: event.isActive));
      emit(UserManagementActionSuccess(
        event.isActive ? 'Usuario activado' : 'Usuario desactivado',
      ));
    } catch (e) {
      emit(UserManagementError('Error al cambiar estado: $e'));
    }
  }

  Future<void> _onLoadRanking(
    DriverRankingRequested event,
    Emitter<UserManagementState> emit,
  ) async {
    try {
      final ranking = await getDriverRanking(event.limit);
      final current = state;
      if (current is UserManagementLoaded) {
        emit(current.copyWith(ranking: ranking));
      } else {
        emit(UserManagementLoaded(ranking: ranking));
      }
    } catch (e) {
      emit(UserManagementError('Error al cargar ranking: $e'));
    }
  }

  Future<void> _onSearch(
    UserSearchRequested event,
    Emitter<UserManagementState> emit,
  ) async {
    emit(UserManagementLoading());
    try {
      final users = await searchUsers(event.query);
      emit(UserManagementLoaded(users: users));
    } catch (e) {
      emit(UserManagementError('Error en la búsqueda: $e'));
    }
  }

  Future<void> _onCreateDriver(
    DriverCreateRequested event,
    Emitter<UserManagementState> emit,
  ) async {
    try {
      await createDriver(event.driver);
      emit(UserManagementActionSuccess('Conductor creado'));
    } catch (e) {
      emit(UserManagementError('Error al crear conductor: $e'));
    }
  }

  Future<void> _onUpdateDriver(
    DriverUpdateRequested event,
    Emitter<UserManagementState> emit,
  ) async {
    try {
      await updateDriver(event.driver);
      emit(UserManagementActionSuccess('Conductor actualizado'));
    } catch (e) {
      emit(UserManagementError('Error al actualizar conductor: $e'));
    }
  }
}
