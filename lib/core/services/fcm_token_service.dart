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

  /// Llamar tras login para suscribir el dispositivo a tokens FCM y
  /// persistirlos en `users/{uid}`.
  Future<void> bind(String uid) async {
    if (_currentUid == uid) return; // Ya enlazado para este user
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
      final token = await _messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _persist(uid, token);
        debugPrint('FCM: token registrado (len=${token.length})');
      } else {
        debugPrint('FCM: getToken devolvió null/vacío — sin token');
      }

      // Listener de rotación de token
      await _refreshSub?.cancel();
      _refreshSub = _messaging.onTokenRefresh.listen((newToken) async {
        if (_currentUid != null) {
          await _persist(_currentUid!, newToken);
          debugPrint('FCM: token rotado y actualizado');
        }
      });
    } catch (e) {
      debugPrint('FcmTokenService.bind error: $e');
    }
  }

  /// Llamar al logout para limpiar el token de `users/{uid}` (evita push a
  /// un dispositivo que ya no debería recibir avisos del usuario anterior).
  Future<void> unbind() async {
    final uid = _currentUid;
    _currentUid = null;
    await _refreshSub?.cancel();
    _refreshSub = null;
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
