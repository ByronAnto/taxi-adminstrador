import 'package:flutter/foundation.dart';

import 'voice/voice_provider_factory.dart';
import 'claims_refresh_service.dart';
import 'driver_location_service.dart';
import 'fcm_token_service.dart';
import 'overlay_ptt_service.dart';
import 'radio_foreground_service.dart';
import 'radio_power_service.dart';
import 'single_session_service.dart';

/// Coordina el cierre limpio de la sesión del usuario antes del signOut.
///
/// Sin este servicio, al hacer logout quedaba como zombi:
/// - El doc en `drivers/{}` con `isActive=true` y última posición → la
///   operadora seguía viendo al conductor en el mapa.
/// - El engine de Agora vivo dentro del canal → consumía billing y
///   "publicaba" desde un user que ya no debería transmitir.
/// - El RadioForegroundService corriendo → notificación persistente.
/// - El FCM token aún ligado al user → recibía notifs de la sesión vieja.
/// - SharedPreferences con `radio.power.isOn=true` → el próximo login
///   reactivaba el radio sin que el nuevo usuario lo pidiera.
///
/// Esta clase llama a todos los teardowns en el orden correcto y NO
/// tira excepciones — si una etapa falla seguimos con la siguiente
/// (best-effort cleanup; el `signOut` final corre siempre).
class SessionTeardownService {
  SessionTeardownService._();

  /// Llamar antes de `FirebaseAuth.instance.signOut()`. El `uid` se
  /// pasa para los servicios que lo necesiten (FcmTokenService).
  static Future<void> disposeAll({String? uid}) async {
    debugPrint('🧹 SessionTeardown: iniciando cleanup para uid=$uid');

    // 1. Si hay PTT flotante activo, cerrarlo primero (libera mic + FGS).
    await _safe('overlayPtt.stop', () async {
      if (OverlayPttService.instance.isActive) {
        await OverlayPttService.instance.stop();
      }
    });

    // 2. Destruir engine Agora — sale del canal, libera mic, corta
    //    billing por minuto. CRÍTICO para que un user que cerró sesión
    //    no siga "ocupando" el canal del lado del proveedor.
    await _safe('voice.dispose', () async {
      await VoiceProviderFactory.current.dispose();
    });

    // 3. Detener el FGS del radio principal (notificación "Radio
    //    Activo - Escuchando..."). Sin esto la notificación queda
    //    aunque el usuario ya no esté logueado.
    await _safe('radioForeground.stop', () async {
      await RadioForegroundService.instance.stopService();
    });

    // 4. Reset del DriverLocationService: para GPS, marca offline +
    //    isActive=false + limpia ubicación. Ahora la op deja de verlo.
    await _safe('driverLocation.reset', () async {
      await DriverLocationService.instance.reset();
    });

    // 5. Apagar el flag persistido del radio. Sin esto, el próximo
    //    login en el mismo dispositivo (incluso si es OTRO user)
    //    leía isOn=true y reanimaba el radio.
    await _safe('radioPower.turnOff', () async {
      await RadioPowerService.instance.turnOff();
    });

    // 6. Retirar el FCM token del doc del user — evita push fantasma.
    await _safe('fcmToken.unbind', () async {
      await FcmTokenService.instance.unbind();
    });

    // 7. Desuscribir el listener de claims y el de single-session.
    await _safe('claimsRefresh.unbind', () async {
      await ClaimsRefreshService.instance.unbind();
    });
    await _safe('singleSession.unbind', () async {
      await SingleSessionService.instance.unbind();
    });

    debugPrint('🧹 SessionTeardown: cleanup completo');
  }

  /// Wrapper que ejecuta una etapa y silencia errores (no aborta el
  /// resto del teardown).
  static Future<void> _safe(String label, Future<void> Function() fn) async {
    try {
      await fn();
      debugPrint('🧹 ✓ $label');
    } catch (e) {
      debugPrint('🧹 ✗ $label: $e');
    }
  }
}
