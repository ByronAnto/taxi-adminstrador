import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Registra el token FCM del dispositivo en `users/{uid}.fcmToken` (y
/// `fcmTokens[]` si quieres soportar múltiples dispositivos en el futuro).
///
/// Necesario para que `dispatchScheduledNotifications` (Cloud Function)
/// pueda enviar notificaciones push a este dispositivo.
class FcmTokenService {
  FcmTokenService._();
  static final FcmTokenService instance = FcmTokenService._();

  final _firestore = FirebaseFirestore.instance;
  final _messaging = FirebaseMessaging.instance;
  StreamSubscription<String>? _refreshSub;
  String? _currentUid;
  // True solo cuando YA persistimos un token para `_currentUid`. Si el
  // primer getToken falló (null/excepción), queda en false y un `bind`
  // posterior (re-emisión de AuthAuthenticated, re-apertura, etc.) puede
  // reintentar en vez de quedar bloqueado por la guarda de uid.
  bool _tokenPersisted = false;

  /// Topics de rol a los que el server (eventos de Quito) envía push.
  /// DEBE coincidir con la convención del backend: `role_<rol>`.
  static const List<String> _roleTopics = [
    'role_conductor',
    'role_admin',
    'role_operadora',
  ];

  /// Normaliza el rol al string que el server espera (`conductor`, `admin`,
  /// `operadora`). Devuelve '' si no reconoce el rol (no se suscribe).
  String _normalizeRole(String? role) {
    final r = (role ?? '').trim().toLowerCase();
    switch (r) {
      case 'conductor':
      case 'admin':
      case 'operadora':
        return r;
      default:
        return '';
    }
  }

  /// Llamar tras login para suscribir el dispositivo a tokens FCM y
  /// persistirlos en `users/{uid}`. `role` se usa para suscribir el
  /// dispositivo al topic `role_<rol>` (eventos por topic del server).
  Future<void> bind(String uid, {String? role}) async {
    // La suscripción al topic es independiente del registro de token: se
    // intenta SIEMPRE (también si el bind se cortocircuita por token ya
    // persistido), por si una sesión previa no llegó a suscribir.
    await _subscribeRoleTopic(role);

    // Solo cortocircuitamos si YA enlazamos Y persistimos un token para
    // este user. Si antes falló getToken (token aún no persistido), dejamos
    // que el reintento corra: era la causa de "usuarios sin fcmToken".
    if (_currentUid == uid && _tokenPersisted) return;
    _currentUid = uid;

    try {
      // Permiso (iOS y Android 13+)
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      debugPrint(
          'FCM: authorizationStatus=${settings.authorizationStatus}');

      // IMPORTANTE: registramos el token SIEMPRE, incluso si el permiso
      // fue denegado o quedó indeterminado (típico en Xiaomi/MIUI, que
      // a veces auto-deniega el diálogo). El token FCM es válido aunque
      // las notifs no se muestren; el permiso sólo controla la
      // visualización. Si el usuario habilita las notifs después en
      // Ajustes, los push empiezan a llegar sin re-login.
      //
      // El bug anterior salía con `return` cuando el permiso era
      // `denied` → nunca se registraba el token → _sendFcmToUid no
      // tenía a quién enviar y fallaba en silencio.
      //
      // getToken puede devolver null o lanzar de forma TRANSITORIA en
      // arranque en frío (Google Play Services aún inicializando, sin red
      // —común en conductores con mala señal—). Sin reintento, el token no
      // se guardaba NUNCA en esa sesión → el cron no tenía a quién enviar.
      // Reintentamos con backoff corto.
      final token = await _getTokenWithRetry();
      if (token != null && token.isNotEmpty) {
        await _persist(uid, token);
        _tokenPersisted = true;
        debugPrint('FCM: token registrado (len=${token.length})');
      } else {
        debugPrint('FCM: getToken devolvió null/vacío — sin token (reintentará '
            'en próximo bind/onTokenRefresh)');
      }

      // Listener de rotación de token. También cubre el caso en que el
      // token llegue tarde (después de que getToken devolviera null): FCM
      // emite por onTokenRefresh cuando el token queda disponible.
      await _refreshSub?.cancel();
      _refreshSub = _messaging.onTokenRefresh.listen((newToken) async {
        if (_currentUid != null) {
          await _persist(_currentUid!, newToken);
          _tokenPersisted = true;
          debugPrint('FCM: token rotado y actualizado');
        }
      });
    } catch (e) {
      debugPrint('FcmTokenService.bind error: $e');
    }
  }

  /// Suscribe el dispositivo al topic `role_<rol>` del usuario. Una falla
  /// NO debe romper el login: se atrapa y se loguea. Si el rol no se
  /// reconoce, no se suscribe.
  Future<void> _subscribeRoleTopic(String? role) async {
    final normalized = _normalizeRole(role);
    if (normalized.isEmpty) {
      debugPrint('FCM: rol no reconocido ("$role") — sin suscripción a topic');
      return;
    }
    final topic = 'role_$normalized';
    try {
      await _messaging.subscribeToTopic(topic);
      debugPrint('FCM: suscrito al topic $topic');
    } catch (e) {
      debugPrint('FCM: error al suscribir a $topic: $e');
    }
  }

  /// getToken con reintentos cortos para tolerar fallos transitorios al
  /// arrancar en frío (Play Services no listo / sin red). Devuelve null si
  /// tras los intentos sigue sin haber token (se reintentará en el próximo
  /// bind o vía onTokenRefresh).
  Future<String?> _getTokenWithRetry() async {
    const delays = [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ];
    for (var attempt = 0; attempt <= delays.length; attempt++) {
      try {
        final token = await _messaging.getToken();
        if (token != null && token.isNotEmpty) return token;
      } catch (e) {
        debugPrint('FCM: getToken intento ${attempt + 1} falló: $e');
      }
      if (attempt < delays.length) {
        await Future<void>.delayed(delays[attempt]);
      }
    }
    return null;
  }

  /// Llamar al logout para limpiar el token de `users/{uid}` (evita push a
  /// un dispositivo que ya no debería recibir avisos del usuario anterior).
  Future<void> unbind() async {
    final uid = _currentUid;
    _currentUid = null;
    _tokenPersisted = false;
    await _refreshSub?.cancel();
    _refreshSub = null;

    // Desuscribir de TODOS los topics de rol. Como en `unbind` no siempre
    // tenemos el rol a mano (y un dispositivo compartido pudo loguear roles
    // distintos), desuscribimos de los 3 por seguridad: así nadie sigue
    // recibiendo push de un rol ajeno tras cerrar sesión. Cada falla se
    // atrapa de forma independiente para no bloquear las demás ni el logout.
    for (final topic in _roleTopics) {
      try {
        await _messaging.unsubscribeFromTopic(topic);
        debugPrint('FCM: desuscrito del topic $topic');
      } catch (e) {
        debugPrint('FCM: error al desuscribir de $topic: $e');
      }
    }

    if (uid == null) return;
    try {
      await _firestore.collection('users').doc(uid).update({
        'fcmToken': FieldValue.delete(),
        'fcmTokenUpdatedAt': FieldValue.delete(),
      });
    } catch (e) {
      debugPrint('FcmTokenService.unbind error: $e');
    }
  }

  Future<void> _persist(String uid, String token) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'fcmToken': token,
        'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Si el doc no existe todavía (raro), set con merge.
      try {
        await _firestore.collection('users').doc(uid).set({
          'fcmToken': token,
          'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e2) {
        debugPrint('FcmTokenService._persist error: $e2');
      }
    }
  }
}
