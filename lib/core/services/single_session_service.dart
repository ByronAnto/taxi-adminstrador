import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Garantiza que un usuario tenga **una sola sesión activa** a la vez.
///
/// Modelo: el último login GANA. Si el usuario entra desde el celular B,
/// el celular A se entera por un listener en `users/{uid}` y muestra un
/// modal "Otro dispositivo inició sesión con sus credenciales", luego
/// hace signOut local.
///
/// **NO aplica a la web del cliente** (cliente puede entrar en PC + móvil).
/// Solo se usa en Flutter (admin/operadora/conductor).
class SingleSessionService {
  SingleSessionService._();
  static final instance = SingleSessionService._();

  static const _kDeviceIdKey = 'single_session_device_id';

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  String? _myDeviceId;
  String? _uid;

  /// Notifica a la UI cuando el usuario fue desplazado por otro dispositivo.
  /// El listener en main.dart escucha y muestra el modal + signOut.
  final ValueNotifier<bool> kicked = ValueNotifier<bool>(false);

  /// Llamar al hacer login (en main.dart cuando AuthAuthenticated).
  /// Genera un deviceId único, lo escribe en Firestore (queda como sesión
  /// activa) y arranca el listener.
  Future<void> bind(String uid) async {
    if (_uid == uid && _sub != null) return; // ya bind con este uid
    await unbind();

    _uid = uid;
    final prefs = await SharedPreferences.getInstance();
    // Siempre generamos un deviceId NUEVO al login para que este login
    // gane sobre cualquier otro dispositivo.
    final newId = const Uuid().v4();
    _myDeviceId = newId;
    await prefs.setString(_kDeviceIdKey, newId);

    final platform = _platformLabel();

    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'currentSession': {
          'deviceId': newId,
          'platform': platform,
          'loginAt': FieldValue.serverTimestamp(),
        },
      }, SetOptions(merge: true));
      debugPrint('🔐 [SingleSession] bound uid=$uid deviceId=$newId');
    } catch (e) {
      debugPrint('🔐 [SingleSession] error escribiendo currentSession: $e');
    }

    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen((snap) {
      final data = snap.data();
      final cs = data?['currentSession'] as Map<String, dynamic>?;
      final remoteId = cs?['deviceId'] as String?;
      if (remoteId == null) return;
      if (remoteId != _myDeviceId) {
        debugPrint(
            '🔐 [SingleSession] DESPLAZADO. remote=$remoteId mio=$_myDeviceId');
        kicked.value = true;
      }
    }, onError: (e) {
      debugPrint('🔐 [SingleSession] snapshot error: $e');
    });
  }

  /// Llamar al hacer signOut (manual o forzado).
  /// NO borra `currentSession` en Firestore (porque puede que ya pertenezca
  /// a otro dispositivo); solo desuscribe el listener local.
  Future<void> unbind() async {
    await _sub?.cancel();
    _sub = null;
    _uid = null;
    _myDeviceId = null;
    kicked.value = false;
  }

  /// Resetea solo el flag de kicked (para que el modal no salga 2 veces).
  void clearKicked() => kicked.value = false;

  String _platformLabel() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isLinux) return 'linux';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
    } catch (_) {}
    return 'unknown';
  }
}
