import '../../data/models/user_model.dart';
import '../repositories/auth_repository.dart';
import '../../../../core/usecases/usecase.dart';

/// Caso de uso: Iniciar sesión
class SignInUseCase extends UseCase<UserModel, SignInParams> {
  final AuthRepository repository;

  SignInUseCase(this.repository);

  @override
  Future<UserModel> call(SignInParams params) {
    return repository.signIn(email: params.email, password: params.password);
  }
}

class SignInParams {
  final String email;
  final String password;

  SignInParams({required this.email, required this.password});
}

/// Caso de uso: Registrar usuario
class SignUpUseCase extends UseCase<UserModel, SignUpParams> {
  final AuthRepository repository;

  SignUpUseCase(this.repository);

  @override
  Future<UserModel> call(SignUpParams params) {
    return repository.signUp(
      email: params.email,
      password: params.password,
      name: params.name,
      lastname: params.lastname,
      cedula: params.cedula,
      phone: params.phone,
      role: params.role,
      associationId: params.associationId,
      requiresApproval: params.requiresApproval,
      placa: params.placa,
      cooperativa: params.cooperativa,
      codigoCooperativa: params.codigoCooperativa,
      numeroVehiculo: params.numeroVehiculo,
      fotoVehiculo: params.fotoVehiculo,
      fotoLicenciaFrontal: params.fotoLicenciaFrontal,
      fotoLicenciaTrasera: params.fotoLicenciaTrasera,
    );
  }
}

class SignUpParams {
  final String email;
  final String password;
  final String name;
  final String lastname;
  final String cedula;
  final String phone;
  final String role;
  final String associationId;
  final bool requiresApproval;
  final String placa;
  final String cooperativa;
  final String codigoCooperativa;
  final String numeroVehiculo;
  final String? fotoVehiculo;
  final String? fotoLicenciaFrontal;
  final String? fotoLicenciaTrasera;

  SignUpParams({
    required this.email,
    required this.password,
    required this.name,
    required this.lastname,
    required this.cedula,
    required this.phone,
    required this.role,
    required this.associationId,
    this.requiresApproval = true,
    this.placa = '',
    this.cooperativa = '',
    this.codigoCooperativa = '',
    this.numeroVehiculo = '',
    this.fotoVehiculo,
    this.fotoLicenciaFrontal,
    this.fotoLicenciaTrasera,
  });
}

/// Caso de uso: Cerrar sesión
class SignOutUseCase extends UseCase<void, NoParams> {
  final AuthRepository repository;

  SignOutUseCase(this.repository);

  @override
  Future<void> call(NoParams params) {
    return repository.signOut();
  }
}

/// Caso de uso: Verificar sesión actual
class CheckAuthUseCase extends UseCase<UserModel?, NoParams> {
  final AuthRepository repository;

  CheckAuthUseCase(this.repository);

  @override
  Future<UserModel?> call(NoParams params) async {
    final uid = repository.currentUserId;
    if (uid == null) return null;
    return repository.getUserData(uid);
  }
}

/// Caso de uso: Recuperar contraseña
class ResetPasswordUseCase extends UseCase<void, String> {
  final AuthRepository repository;

  ResetPasswordUseCase(this.repository);

  @override
  Future<void> call(String email) {
    return repository.resetPassword(email);
  }
}

/// Caso de uso: Actualizar perfil
class UpdateProfileUseCase extends UseCase<void, UserModel> {
  final AuthRepository repository;

  UpdateProfileUseCase(this.repository);

  @override
  Future<void> call(UserModel user) {
    return repository.updateProfile(user);
  }
}

/// Caso de uso: Cambiar contraseña (re-auth + updatePassword).
class ChangePasswordParams {
  final String currentPassword;
  final String newPassword;
  ChangePasswordParams({
    required this.currentPassword,
    required this.newPassword,
  });
}

class ChangePasswordUseCase extends UseCase<void, ChangePasswordParams> {
  final AuthRepository repository;

  ChangePasswordUseCase(this.repository);

  @override
  Future<void> call(ChangePasswordParams params) {
    return repository.changePassword(
      currentPassword: params.currentPassword,
      newPassword: params.newPassword,
    );
  }
}
