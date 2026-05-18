import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
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
    // Pre-check de cédula ANTES de crear la cuenta Auth.
    //
    // Antes hacíamos `users where cedula == X` directo desde Flutter
    // pero las reglas de Firestore lo niegan: el usuario recién creado
    // NO es owner ni active ni same-tenant → PERMISSION_DENIED. Por eso
    // movemos la validación a una Cloud Function (Admin SDK ignora
    // reglas) que además considera "disponibles" las cédulas que solo
    // pertenecen a usuarios soft-deleted.
    try {
      final functions =
          FirebaseFunctions.instanceFor(region: 'us-central1');
      final res = await functions
          .httpsCallable('checkCedulaAvailable')
          .call({'cedula': cedula});
      final available = (res.data as Map?)?['available'] as bool? ?? false;
      if (!available) {
        throw Exception('Ya existe un usuario con esta cédula');
      }
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'No pudimos validar la cédula.');
    }

    // Crear cuenta en Firebase Auth.
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );

    if (credential.user == null) {
      throw Exception('No se pudo registrar el usuario');
    }

    try {

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

  /// Recuperar contraseña.
  ///
  /// Llama a la Cloud Function `sendPasswordResetEmail` (no al SDK web)
  /// para que el correo se envíe vía Gmail SMTP propio. Mejor entrega
  /// que `noreply@taxis-f0f51.firebaseapp.com` que terminaba en spam.
  Future<void> resetPassword(String email) async {
    final functions =
        FirebaseFunctions.instanceFor(region: 'us-central1');
    try {
      await functions
          .httpsCallable('sendPasswordResetEmail')
          .call({'email': email});
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'No pudimos enviar el correo.');
    }
  }

  /// Cambiar contraseña del usuario actual.
  ///
  /// Re-autentica con la contraseña actual antes de actualizar (Firebase
  /// lo exige por seguridad: si el usuario lleva mucho tiempo logueado,
  /// `updatePassword` falla con `requires-recent-login` si no se hace
  /// reauth primero).
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _auth.currentUser;
    if (user == null || user.email == null) {
      throw Exception('No hay sesión activa.');
    }
    final cred = EmailAuthProvider.credential(
      email: user.email!,
      password: currentPassword,
    );
    await user.reauthenticateWithCredential(cred);
    await user.updatePassword(newPassword);
  }

  /// Actualizar perfil de usuario
  Future<void> updateUserProfile(UserModel user) async {
    await _firestore
        .collection('users')
        .doc(user.uid)
        .update(user.toFirestore());
  }
}
