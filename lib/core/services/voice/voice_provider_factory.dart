import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../agora_service.dart';
import 'livekit_voice_provider.dart';
import 'voice_provider.dart';

/// Selector del proveedor de audio en tiempo real para la sesión actual.
///
/// El campo `voiceProvider` en `associations/{associationId}` decide cuál
/// se usa por cooperativa: `"agora"` (default) o `"livekit"`. Cambiar el
/// campo en Firestore + reiniciar la app es suficiente para swichear —
/// **rollback sin redeploy**.
///
/// **Hoy** sólo hay un provider (`AgoraService`). El `LiveKitVoiceProvider`
/// se agrega en Fase 3 de la migración; al aterrizar se incorporará en el
/// switch de [selectFor] y este código activará uno u otro según el flag.
///
/// **Llamar** [selectFor] una vez tras login, cuando ya tenemos el
/// `associationId` y los custom claims. Antes de eso, [current] devuelve
/// el provider por defecto (Agora).
///
/// Referencia completa: `docs/superpowers/specs/2026-05-19-livekit-hybrid-migration.md`.
class VoiceProviderFactory {
  VoiceProviderFactory._();

  static const String _agora = 'agora';
  static const String _livekit = 'livekit';

  static VoiceProvider _current = AgoraService.instance;
  static String _currentKey = _agora;

  /// Provider activo para esta sesión. Default: Agora.
  static VoiceProvider get current => _current;

  /// Identificador del provider activo (`"agora"` / `"livekit"`). Útil
  /// para telemetría y para que la UI muestre el modo en debug.
  static String get currentKey => _currentKey;

  /// Lee `associations/{associationId}.voiceProvider` y selecciona el
  /// provider correspondiente. Si el provider cambia respecto del actual,
  /// se llama a `destroyEngine()` en el anterior para liberar mic + audio
  /// del SO antes de swichear.
  ///
  /// Idempotente: si el flag no cambió, no toca nada.
  static Future<void> selectFor(String associationId) async {
    if (associationId.isEmpty) return;
    String flag = _agora;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('associations')
          .doc(associationId)
          .get();
      final raw = doc.data()?['voiceProvider'];
      if (raw is String && raw.isNotEmpty) {
        flag = raw.toLowerCase();
      }
    } catch (e) {
      debugPrint(
          '[VoiceProviderFactory] error leyendo voiceProvider: $e — usando $_agora');
    }
    await _activate(flag);
  }

  /// Forza la selección de un provider por su key sin tocar Firestore.
  /// Útil en tests o para QA cambiando providers en runtime.
  static Future<void> forceUse(String key) async {
    await _activate(key);
  }

  /// BUG 1 — Resetea la sesión de voz al cambiar de cuenta SIN reiniciar la
  /// app. Llamar en logout (AuthUnauthenticated) y cuando se autentica un uid
  /// distinto al de la sesión de voz activa. Desconecta la Room viva e invalida
  /// los tokens cacheados del provider activo (cada token embebe la identidad/
  /// uid del usuario anterior), dejándolo listo para pedir un token fresco con
  /// la nueva identidad en el próximo joinChannel.
  ///
  /// Si el provider activo es LiveKit usa su `resetForUserChange` (purga
  /// tokens + identidad además del teardown); para Agora (sin token cacheado de
  /// identidad) basta `destroyEngine`, que ya libera el engine del SO.
  static Future<void> resetForUserChange() async {
    final provider = _current;
    try {
      if (provider is LiveKitVoiceProvider) {
        await provider.resetForUserChange();
      } else {
        await provider.destroyEngine();
      }
    } catch (e) {
      debugPrint('[VoiceProviderFactory] resetForUserChange fail: $e');
    }
  }

  static Future<void> _activate(String key) async {
    final normalized = (key == _livekit) ? _livekit : _agora;
    if (normalized == _currentKey) return;
    final previous = _current;
    // Fijar el nuevo provider PRIMERO (síncrono), antes de cualquier await:
    // así `current` lo devuelve de inmediato y la página walkie (que lee el
    // getter) nunca ve el provider viejo durante el switch.
    _current = _providerFor(normalized);
    _currentKey = normalized;
    debugPrint('[VoiceProviderFactory] provider activo → $normalized');
    // Liberar el audio del SO del provider saliente (no bloquea el switch).
    try {
      await previous.destroyEngine();
    } catch (e) {
      debugPrint('[VoiceProviderFactory] destroyEngine fail al swichear: $e');
    }
  }

  static VoiceProvider _providerFor(String key) {
    switch (key) {
      case _livekit:
        // Fase 3 (2026-05-29): LiveKitVoiceProvider implementado.
        return LiveKitVoiceProvider.instance;
      case _agora:
      default:
        return AgoraService.instance;
    }
  }
}
