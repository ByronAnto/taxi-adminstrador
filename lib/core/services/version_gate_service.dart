import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Resultado de la verificación contra `app_config/{platform}`.
enum VersionGateStatus {
  /// El check todavía no terminó. La UI muestra splash transparente.
  unknown,

  /// La build local es ≥ minRequiredBuild → app puede continuar normal.
  ok,

  /// La build local es < minRequiredBuild → bloquear UI con
  /// pantalla "Actualiza la app".
  forceUpdate,

  /// La build local es ≥ minRequired pero < latestBuild → opcional
  /// avisar al usuario sin bloquear.
  softUpdate,
}

/// Política de versionamiento simple del lado del cliente.
///
/// Modelo Firestore: `app_config/android` (y `app_config/ios` si quieres):
/// ```
/// {
///   minRequiredBuild: 12,   // si versionCode local < 12 → forceUpdate
///   latestBuild: 15,        // versión más reciente publicada
///   storeUrl: "https://play.google.com/store/apps/details?id=com.taxijipijapa.taxi_jipijapa",
///   message: "Mejoras en el walkie-talkie y nuevos cobros.",
///   updatedAt: <timestamp>
/// }
/// ```
///
/// Comparación basada en `versionCode` (entero monotónicamente creciente)
/// que sale de `package_info.buildNumber`. Más fiable que `versionName`
/// porque siempre incrementa por +1 en cada release.
///
/// El admin actualiza el doc cuando publica una nueva versión obligatoria.
class VersionGateService {
  VersionGateService._();
  static final instance = VersionGateService._();

  /// Estado actual. UI escucha y reacciona.
  final ValueNotifier<VersionGateStatus> status =
      ValueNotifier(VersionGateStatus.unknown);

  /// URL de la tienda (Play Store / App Store) para "Actualizar".
  String? storeUrl;

  /// Mensaje opcional del admin (changelog corto).
  String? message;

  /// Build local actual (memoizado).
  int? _localBuild;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  /// Llamar al boot. Lee la build local + suscribe al doc Firestore.
  /// Si más tarde el admin sube `minRequiredBuild`, el listener actualiza
  /// `status` y la UI bloquea automáticamente sin reiniciar la app.
  Future<void> start() async {
    if (_sub != null) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _localBuild = int.tryParse(info.buildNumber) ?? 0;
      debugPrint(
          '🔢 [VersionGate] Build local: $_localBuild (v${info.version})');
    } catch (e) {
      debugPrint('🔢 [VersionGate] No se pudo leer PackageInfo: $e');
      _localBuild = 0;
    }

    final platformId = _platformDocId();
    if (platformId == null) {
      // Plataforma no soportada (web/desktop) → siempre OK.
      status.value = VersionGateStatus.ok;
      return;
    }

    _sub = FirebaseFirestore.instance
        .collection('app_config')
        .doc(platformId)
        .snapshots()
        .listen((snap) {
      _evaluate(snap.data());
    }, onError: (e) {
      debugPrint('🔢 [VersionGate] Error escuchando app_config: $e');
      // Failsafe: si no podemos leer el doc, dejamos pasar (no bloquear
      // a usuarios por un problema de red transitorio).
      if (status.value == VersionGateStatus.unknown) {
        status.value = VersionGateStatus.ok;
      }
    });
  }

  void _evaluate(Map<String, dynamic>? data) {
    if (data == null) {
      status.value = VersionGateStatus.ok;
      return;
    }
    final minReq = (data['minRequiredBuild'] as num?)?.toInt() ?? 0;
    final latest = (data['latestBuild'] as num?)?.toInt() ?? minReq;
    storeUrl = data['storeUrl'] as String?;
    message = data['message'] as String?;
    final local = _localBuild ?? 0;
    debugPrint(
        '🔢 [VersionGate] local=$local minReq=$minReq latest=$latest');
    if (local < minReq) {
      status.value = VersionGateStatus.forceUpdate;
    } else if (local < latest) {
      status.value = VersionGateStatus.softUpdate;
    } else {
      status.value = VersionGateStatus.ok;
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  String? _platformDocId() {
    if (kIsWeb) return null;
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
    } catch (_) {}
    return null;
  }
}
