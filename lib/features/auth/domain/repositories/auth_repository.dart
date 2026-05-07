import '../../../auth/data/models/user_model.dart';

/// Contrato del repositorio de autenticación
abstract class AuthRepository {
  /// Usuario actual de Firebase Auth (puede ser null)
  Stream<bool> get authStateChanges;

  /// UID del usuario autenticado actual
  String? get currentUserId;

  /// Iniciar sesión con email/password
  Future<UserModel> signIn({
    required String email,
    required String password,
  });

  /// Registrar nuevo usuario.
  ///
  /// [associationId] es el slug de la asociación a la que se une.
  /// [requiresApproval] = true (default) crea el usuario en estado
  /// `pendingApproval` (Opción A: auto-registro con código).
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
  });

  /// Obtener datos del usuario actual
  Future<UserModel> getUserData(String uid);

  /// Actualizar perfil de usuario
  Future<void> updateProfile(UserModel user);

  /// Cerrar sesión
  Future<void> signOut();

  /// Recuperar contraseña
  Future<void> resetPassword(String email);
}
