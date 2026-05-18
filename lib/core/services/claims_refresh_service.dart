import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Refresca el ID token de Firebase Auth cuando detecta que el doc
/// `users/{uid}` cambió en Firestore.
///
/// Las reglas Firestore evalúan el rol/status del usuario leyendo los
/// **custom claims del JWT** (`request.auth.token.role`,
/// `request.auth.token.status`). Cuando un admin aprueba o cambia el
/// status de un conductor:
///
/// 1. Server: el trigger `syncUserClaims` actualiza los claims en Auth.
/// 2. Cliente: sigue con el JWT viejo en RAM hasta que se refresque
///    (~1 hora normal o al hacer logout/login).
///
/// Sin esta clase, el conductor recién aprobado seguía viendo
/// PERMISSION_DENIED en TODAS sus queries hasta que reiniciaba la
/// sesión a mano.
///
/// Este servicio:
/// - Suscribe a `users/{uid}`.
/// - En cada cambio detectado en `status` o `role`, llama
///   `currentUser.getIdToken(true)` para forzar refresh.
/// - El próximo snapshot de Firestore ya viaja con los claims nuevos
///   y las reglas aceptan la query.
class ClaimsRefreshService {
  ClaimsRefreshService._();
  static final instance = ClaimsRefreshService._();

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  String? _lastKnownStatus;
  String? _lastKnownRole;
  String? _uid;

  /// Callback invocado cuando cambia el `status` o `role` del usuario en
  /// Firestore. El consumer (main.dart) lo usa para re-disparar la carga
  /// del UserModel en AuthBloc — necesario para que el router redirija
  /// (ej. usuario suspendido → /blocked) sin esperar a un refresh manual.
  void Function()? onProfileChanged;

  /// Llamar al login (en main.dart cuando AuthAuthenticated).
  void bind(String uid) {
    if (_uid == uid && _sub != null) return;
    unbind();
    _uid = uid;
    _lastKnownStatus = null;
    _lastKnownRole = null;
    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen(_onUserDocChange, onError: (e) {
      debugPrint('🔑 [ClaimsRefresh] error: $e');
    });
    debugPrint('🔑 [ClaimsRefresh] bind uid=$uid');
  }

  Future<void> unbind() async {
    await _sub?.cancel();
    _sub = null;
    _uid = null;
    _lastKnownStatus = null;
    _lastKnownRole = null;
  }

  Future<void> _onUserDocChange(
      DocumentSnapshot<Map<String, dynamic>> snap) async {
    // Si el doc del usuario desapareció (hard-delete), forzar signOut.
    // El celular zombi pierde sesión inmediatamente sin esperar a que
    // expire el ID token cacheado.
    if (!snap.exists) {
      debugPrint('🔑 [ClaimsRefresh] users/$_uid no existe → signOut');
      await _forceSignOut();
      return;
    }

    final data = snap.data();
    if (data == null) return;
    final status = data['status'] as String?;
    final role = data['role'] as String?;

    // Si el admin marcó al usuario como "deleted", también signOut. Esto
    // resuelve el caso de soft-delete: el celular sigue logueado con una
    // cuenta que ya no debería poder usar la app.
    if (status == 'deleted') {
      debugPrint('🔑 [ClaimsRefresh] users/$_uid status=deleted → signOut');
      await _forceSignOut();
      return;
    }

    // Primer snapshot: solo memoriza, no refresca.
    if (_lastKnownStatus == null && _lastKnownRole == null) {
      _lastKnownStatus = status;
      _lastKnownRole = role;
      return;
    }

    final statusChanged = status != _lastKnownStatus;
    final roleChanged = role != _lastKnownRole;
    if (!statusChanged && !roleChanged) return;

    debugPrint('🔑 [ClaimsRefresh] doc cambió '
        '(status: $_lastKnownStatus → $status, role: $_lastKnownRole → $role) → '
        'forzando getIdToken(true)');

    _lastKnownStatus = status;
    _lastKnownRole = role;

    try {
      // Forzar refresh del ID token. Esto pide a Firebase los claims
      // más nuevos (que el trigger syncUserClaims ya actualizó server-side).
      // Tras esto, las próximas queries Firestore viajan con los claims
      // correctos y las reglas las aceptan.
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
      debugPrint('🔑 [ClaimsRefresh] token refrescado OK');
    } catch (e) {
      debugPrint('🔑 [ClaimsRefresh] error refrescando token: $e');
    }

    // Notificar al AuthBloc (vía main.dart) para que recargue el UserModel
    // y el router pueda redirigir a /blocked si quedó suspendido.
    try {
      onProfileChanged?.call();
    } catch (e) {
      debugPrint('🔑 [ClaimsRefresh] error en onProfileChanged: $e');
    }
  }

  Future<void> _forceSignOut() async {
    await unbind();
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      debugPrint('🔑 [ClaimsRefresh] error en signOut: $e');
    }
  }
}
