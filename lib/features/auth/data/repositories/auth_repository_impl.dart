import '../../domain/repositories/auth_repository.dart';
import '../datasources/auth_remote_datasource.dart';
import '../models/user_model.dart';

/// Implementación concreta del repositorio de autenticación
class AuthRepositoryImpl implements AuthRepository {
  final AuthRemoteDatasource remoteDatasource;

  AuthRepositoryImpl({required this.remoteDatasource});

  @override
  Stream<bool> get authStateChanges =>
      remoteDatasource.authStateChanges.map((user) => user != null);

  @override
  String? get currentUserId => remoteDatasource.currentUser?.uid;

  @override
  Future<UserModel> signIn({
    required String email,
    required String password,
  }) {
    return remoteDatasource.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  @override
  Future<UserModel> signUp({
    required String email,
    required String password,
    required String name,
    required String lastname,
    required String cedula,
    required String phone,
    required String role,
    required String associationId,
    bool requiresApproval = true,
    String placa = '',
    String cooperativa = '',
    String codigoCooperativa = '',
    String numeroVehiculo = '',
    String? fotoVehiculo,
    String? fotoLicenciaFrontal,
    String? fotoLicenciaTrasera,
  }) {
    return remoteDatasource.registerWithEmailAndPassword(
      email: email,
      password: password,
      name: name,
      lastname: lastname,
      cedula: cedula,
      phone: phone,
      role: role,
      associationId: associationId,
      requiresApproval: requiresApproval,
      placa: placa,
      cooperativa: cooperativa,
      codigoCooperativa: codigoCooperativa,
      numeroVehiculo: numeroVehiculo,
      fotoVehiculo: fotoVehiculo,
      fotoLicenciaFrontal: fotoLicenciaFrontal,
      fotoLicenciaTrasera: fotoLicenciaTrasera,
    );
  }

  @override
  Future<UserModel> getUserData(String uid) {
    return remoteDatasource.getUserData(uid);
  }

  @override
  Future<void> updateProfile(UserModel user) {
    return remoteDatasource.updateUserProfile(user);
  }

  @override
  Future<void> signOut() {
    return remoteDatasource.signOut();
  }

  @override
  Future<void> resetPassword(String email) {
    return remoteDatasource.resetPassword(email);
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) {
    return remoteDatasource.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }
}
