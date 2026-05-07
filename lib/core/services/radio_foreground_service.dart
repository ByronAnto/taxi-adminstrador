import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logger/logger.dart';

/// Servicio singleton que gestiona el foreground service para el Radio
/// (walkie-talkie) en segundo plano, similar a Zello.
///
/// Cuando un canal está activo, muestra una notificación persistente
/// y evita que Android mate la app, permitiendo recibir audio
/// en tiempo real (Agora) en background.
class RadioForegroundService {
  RadioForegroundService._();
  static final RadioForegroundService instance = RadioForegroundService._();

  final Logger _logger = Logger();
  bool _isRunning = false;
  bool _isStarting = false;
  String? _activeChannelName;

  bool get isRunning => _isRunning;
  String? get activeChannelName => _activeChannelName;

  /// Inicializa la configuración del foreground task.
  /// Llamar una sola vez, en initState de WalkieTalkiePage o en main().
  void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'radio_foreground_channel',
        channelName: 'Radio Activo',
        channelDescription: 'Mantiene el radio walkie-talkie activo en segundo plano',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _logger.i('RadioForegroundService initialized');
  }

  /// Inicia el foreground service cuando se activa un canal.
  /// [channelName] es el nombre del canal activo para la notificación.
  ///
  /// En Android 13+ el servicio falla con `ServiceRequestFailure` si la app
  /// no tiene permiso `POST_NOTIFICATIONS`. Pedimos el permiso antes de
  /// arrancar para evitar el error silencioso.
  Future<void> startService(String channelName) async {
    if (_isRunning || _isStarting) {
      // Ya corriendo o en proceso, solo actualizar notificación
      if (_isRunning) await _safeUpdateNotification(channelName);
      return;
    }

    _isStarting = true;
    _activeChannelName = channelName;

    try {
      // Permisos runtime requeridos por flutter_foreground_task en Android 13+:
      //   - POST_NOTIFICATIONS (Android 13+)
      //   - Ignorar optimizaciones de batería (opcional pero recomendado)
      try {
        final notifPerm =
            await FlutterForegroundTask.checkNotificationPermission();
        if (notifPerm != NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
      } catch (e) {
        _logger.w('No se pudo verificar permiso de notificaciones: $e');
      }

      final result = await FlutterForegroundTask.startService(
        notificationTitle: '📻 Radio Activo',
        notificationText: 'Canal: $channelName — Escuchando...',
        callback: _radioTaskCallback,
      );

      if (result is ServiceRequestSuccess) {
        _isRunning = true;
        _logger.i('Radio foreground service started for channel: $channelName');
      } else {
        _logger.e('Failed to start radio foreground service: $result');
      }
    } catch (e) {
      _logger.e('Exception starting foreground service: $e');
    } finally {
      _isStarting = false;
    }
  }

  /// Actualiza la notificación del foreground service (e.g. cambio de canal).
  Future<void> updateNotification(String channelName) async {
    if (!_isRunning) return;
    await _safeUpdateNotification(channelName);
  }

  /// Muestra en la notificación que alguien está transmitiendo.
  Future<void> showSpeaking(String channelName, String speakerName) async {
    if (!_isRunning) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: '📻 $speakerName está hablando',
        notificationText: 'Canal: $channelName',
      );
    } catch (e) {
      _logger.e('Error updating notification (speaking): $e');
    }
  }

  /// Restaura la notificación a "Escuchando" cuando termina la transmisión.
  Future<void> showListening(String channelName) async {
    if (!_isRunning) return;
    await _safeUpdateNotification(channelName);
  }

  /// Detiene el foreground service al salir del radio o cerrar sesión.
  Future<void> stopService() async {
    if (!_isRunning) return;

    try {
      final result = await FlutterForegroundTask.stopService();
      if (result is ServiceRequestSuccess) {
        _isRunning = false;
        _activeChannelName = null;
        _logger.i('Radio foreground service stopped');
      } else {
        _logger.e('Failed to stop radio foreground service: $result');
        // Force reset state
        _isRunning = false;
        _activeChannelName = null;
      }
    } catch (e) {
      _logger.e('Exception stopping foreground service: $e');
      _isRunning = false;
      _activeChannelName = null;
    }
  }

  /// Safe wrapper for updating the foreground notification.
  Future<void> _safeUpdateNotification(String channelName) async {
    _activeChannelName = channelName;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: '📻 Radio Activo',
        notificationText: 'Canal: $channelName — Escuchando...',
      );
    } catch (e) {
      _logger.e('Error updating notification: $e');
    }
  }

  /// Widget wrapper que permite volver a la app al tocar la notificación.
  /// Envolver el MaterialApp o la página principal con esto.
  static Widget withForegroundTask({required Widget child}) {
    return WithForegroundTask(child: child);
  }
}

// Top-level callback requerido por flutter_foreground_task.
// Se ejecuta cuando el servicio está en segundo plano.
// No necesita lógica compleja porque el Dart engine ya sigue vivo
// y Firestore streams siguen funcionando.
@pragma('vm:entry-point')
void _radioTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_RadioTaskHandler());
}

/// Task handler mínimo — la lógica real la maneja el BLoC/Firestore
/// que ya está corriendo en el main isolate.
class _RadioTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // El servicio arrancó. Los streams de Firestore siguen activos.
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // No usamos repeat events — Firestore push ya maneja los updates.
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // Limpieza al detener el servicio.
  }

  @override
  void onReceiveData(Object data) {
    // Comunicación desde el main isolate (no necesaria por ahora).
  }

  @override
  void onNotificationButtonPressed(String id) {
    // El usuario tocó un botón en la notificación (no lo usamos).
  }

  @override
  void onNotificationPressed() {
    // El usuario tocó la notificación — la app vuelve al frente.
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {
    // Notificación descartada (no debería pasar con isSticky: true).
  }
}
