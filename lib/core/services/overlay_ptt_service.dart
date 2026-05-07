import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'agora_service.dart';

/// Servicio que gestiona el botón PTT flotante (overlay).
///
/// Comunica con el nativo Android OverlayPttService vía MethodChannel.
/// Estrategia "Canal Persistente" — PTT instantáneo (0ms):
/// - Al activar overlay: init Agora + join canal + mic OFF (escuchando)
/// - Al presionar PTT: solo unmuteMic → instantáneo
/// - Al soltar PTT: solo muteMic → instantáneo
/// - Al desactivar overlay: destroyEngine → mic 100% libre
class OverlayPttService {
  OverlayPttService._();
  static final OverlayPttService instance = OverlayPttService._();

  static const _channel = MethodChannel('com.taxijipijapa/overlay');

  bool _isActive = false;
  bool get isActive => _isActive;

  String? _activeChannelId;
  String? get activeChannelId => _activeChannelId;

  bool _isPttActive = false;
  bool get isPttActive => _isPttActive;

  final _agoraService = AgoraService.instance;

  /// Callback para notificar a la UI que el estado cambió
  VoidCallback? onStateChanged;

  void _log(String msg) => debugPrint('[OverlayPTT] $msg');

  // ─────────────────── Inicialización ───────────────────

  /// Configura el handler de MethodChannel para recibir eventos del nativo.
  void initialize() {
    _channel.setMethodCallHandler(_handleMethodCall);
    _log('Inicializado — escuchando eventos del overlay nativo');
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onPttDown':
        await _handlePttDown();
        break;
      case 'onPttUp':
        await _handlePttUp();
        break;
      case 'onOverlayClosed':
        _handleOverlayClosed();
        break;
    }
  }

  // ─────────────────── Permisos ───────────────────

  /// Verifica si la app tiene permiso de overlay (SYSTEM_ALERT_WINDOW)
  Future<bool> hasPermission() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('checkOverlayPermission');
      return result ?? false;
    } catch (e) {
      _log('Error verificando permiso: $e');
      return false;
    }
  }

  /// Solicita permiso de overlay (abre configuración de Android)
  Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod('requestOverlayPermission');
    } catch (e) {
      _log('Error solicitando permiso: $e');
    }
  }

  // ─────────────────── Start / Stop ───────────────────

  /// Inicia el botón PTT flotante sobre todas las apps.
  /// Conecta Agora al canal de forma persistente (escuchando, mic OFF).
  Future<bool> start(String channelId) async {
    try {
      _activeChannelId = channelId;

      // 1. Mostrar botón flotante nativo
      await _channel.invokeMethod('startOverlay');
      _isActive = true;
      onStateChanged?.call();

      // 2. Conectar Agora al canal (engine + join + mic OFF)
      await _updateButtonState('connecting');
      await _agoraService.overlayActivate(channelId);
      await _updateButtonState('idle');

      _log('Overlay iniciado + Agora conectado a canal: $channelId');
      return true;
    } catch (e) {
      _log('Error iniciando overlay: $e');
      _isActive = false;
      _activeChannelId = null;
      try { await _updateButtonState('idle'); } catch (_) {}
      return false;
    }
  }

  /// Detiene el botón PTT flotante y destruye engine Agora.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopOverlay');
    } catch (e) {
      _log('Error deteniendo overlay: $e');
    }
    // Destruir engine → mic 100% libre a nivel del SO
    await _agoraService.overlayDeactivate();
    _isActive = false;
    _activeChannelId = null;
    _isPttActive = false;
    onStateChanged?.call();
    _log('Overlay detenido + Agora destruido');
  }

  // ─────────────────── PTT Handlers ───────────────────

  /// Maneja el evento de botón presionado (desde overlay nativo).
  /// Canal Persistente: solo enciende el mic → instantáneo (0ms).
  Future<void> _handlePttDown() async {
    if (_activeChannelId == null) {
      _log('Sin canal activo, ignorando PTT');
      return;
    }

    _isPttActive = true;
    _log('PTT DOWN → unmute mic (instantáneo)');

    try {
      await _agoraService.quickPttStart(_activeChannelId!);
      await _updateButtonState('transmitting');
      _log('PTT activo — transmitiendo');
    } catch (e) {
      _log('Error iniciando PTT: $e');
      _isPttActive = false;
      await _updateButtonState('idle');
    }
  }

  /// Maneja el evento de botón soltado (desde overlay nativo).
  /// Canal Persistente: solo apaga el mic → instantáneo (0ms).
  Future<void> _handlePttUp() async {
    _log('PTT UP → mute mic (instantáneo)');
    _isPttActive = false;

    try {
      await _agoraService.quickPttStop();
      await _updateButtonState('idle');
      _log('PTT muted — sigue en canal, escuchando');
    } catch (e) {
      _log('Error deteniendo PTT: $e');
      try {
        await _updateButtonState('idle');
      } catch (_) {}
    }
  }

  /// Maneja el cierre del overlay (desde nativo, ej: notificación "Cerrar").
  /// Destruye engine completamente → mic 100% libre.
  void _handleOverlayClosed() {
    _isActive = false;
    _activeChannelId = null;
    _isPttActive = false;
    // Destruir engine → mic libre a nivel del SO
    _agoraService.overlayDeactivate().catchError((_) {});
    onStateChanged?.call();
    _log('Overlay cerrado — engine destruido, mic libre');
  }

  // ─────────────────── UI Bridge ───────────────────

  /// Actualiza el estado visual del botón flotante nativo
  Future<void> _updateButtonState(String state) async {
    try {
      await _channel.invokeMethod('updateButtonState', {'state': state});
    } catch (e) {
      _log('Error actualizando estado del botón: $e');
    }
  }

  // ─────────────────── Limpieza ───────────────────

  void dispose() {
    stop();
  }
}
