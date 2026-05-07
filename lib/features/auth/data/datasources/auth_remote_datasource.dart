import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';

/// Fuente de datos remota para autenticación
class AuthRemoteDatasource {
  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  AuthRemoteDatasource({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Iniciar sesión con email y contraseña
  Future<UserModel> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );

    if (credential.user == null) {
      throw Exception('No se pudo iniciar sesión');
    }

    return await getUserData(credential.user!.uid);
  }

  /// Registrar nuevo usuario.
  ///
  /// [associationId] es el slug de la asociación a la que se une.
  /// [requiresApproval] = true crea el usuario en estado `pendingApproval`
  /// (Opción A: el admin debe aprobarlo). Cuando el admin crea cuentas
  /// directamente (Opción C), pasar `false`.
  Future<UserModel> registerWithEmailAndPassword({
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
  }) async {
    // Primero crear cuenta en Firebase Auth (necesario para estar autenticado)
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );

    if (credential.user == null) {
      throw Exception('No se pudo registrar el usuario');
    }

    try {
      // Verificar que la cédula no esté registrada (requiere autenticación)
      final existingUser = await _firestore
          .collection('users')
          .where('cedula', isEqualTo: cedula)
          .get();

      if (existingUser.docs.isNotEmpty) {
        // Si la cédula ya existe, eliminar la cuenta recién creada
        await credential.user!.delete();
        throw Exception('Ya existe un usuario con esta cédula');
      }

      final userModel = UserModel(
        uid: credential.user!.uid,
        associationId: associationId,
        name: name,
        lastname: lastname,
        cedula: cedula,
        email: email,
        phone: phone,
        role: role,
        status: requiresApproval
            ? UserStatus.pendingApproval
            : UserStatus.active,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        placa: placa,
        cooperativa: cooperativa,
        codigoCooperativa: codigoCooperativa,
        numeroVehiculo: numeroVehiculo,
        fotoVehiculo: fotoVehiculo,
        fotoLicenciaFrontal: fotoLicenciaFrontal,
        fotoLicenciaTrasera: fotoLicenciaTrasera,
      );

      await _firestore
          .collection('users')
          .doc(credential.user!.uid)
          .set(userModel.toFirestore());

      return userModel;
    } catch (e) {
      // Si algo falla después de crear la cuenta, eliminarla para no dejar huérfana
      if (e.toString().contains('Ya existe un usuario con esta cédula')) {
        rethrow;
      }
      await credential.user?.delete();
      rethrow;
    }
  }

  /// Obtener datos del usuario desde Firestore
  Future<UserModel> getUserData(String uid) async {
    final doc = await _firestore.collection('users').doc(uid).get();
    if (!doc.exists) {
      throw Exception('Usuario no encontrado');
    }
    return UserModel.fromFirestore(doc);
  }

  /// Cerrar sesión
  Future<void> signOut() async {
    await _auth.signOut();
  }

  /// Recuperar contraseña
  Future<void> resetPassword(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  /// Actualizar perfil de usuario
  Future<void> updateUserProfile(UserModel user) async {
    await _firestore
        .collection('users')
        .doc(user.uid)
        .update(user.toFirestore());
  }
}
