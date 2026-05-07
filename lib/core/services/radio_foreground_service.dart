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
  /// Causas comunes de `ServiceRequestFailure` y cómo las manejamos:
  ///  1. POST_NOTIFICATIONS denegado (Android 13+) → pedimos el permiso
  ///     y si está denegado permanentemente, abrimos Settings.
  ///  2. App en estado "transitorio" (hot reload o recién arrancada) →
  ///     reintentamos 1 vez con delay 500ms.
  ///  3. Doze/optimización batería bloqueando background-start →
  ///     pedimos ignorar optimizaciones (silenciosamente — el usuario
  ///     ya tendrá la notificación de permiso si Android la requiere).
  Future<void> startService(String channelName) async {
    if (_isRunning || _isStarting) {
      // Ya corriendo o en proceso, solo actualizar notificación
      if (_isRunning) await _safeUpdateNotification(channelName);
      return;
    }

    _isStarting = true;
    _activeChannelName = channelName;

    try {
      // ─── Permiso 1: POST_NOTIFICATIONS (Android 13+) ───
      try {
        var notifPerm =
            await FlutterForegroundTask.checkNotificationPermission();
        if (notifPerm != NotificationPermission.granted) {
          notifPerm =
              await FlutterForegroundTask.requestNotificationPermission();
        }
        if (notifPerm == NotificationPermission.permanently_denied) {
          // El usuario tocó "No volver a preguntar". El servicio NUNCA va
          // a poder mostrar notificación → fail garantizado. Abrir Settings.
          _logger.e(
              'Permiso de notificaciones denegado permanentemente. '
              'Abriendo configuración de la app...');
          try {
            await FlutterForegroundTask.openSystemAlertWindowSettings();
          } catch (_) {}
          return;
        }
        if (notifPerm != NotificationPermission.granted) {
          _logger.e(
              'Permiso de notificaciones no concedido — el radio no '
              'puede correr en background.');
          return;
        }
      } catch (e) {
        _logger.w('No se pudo verificar permiso de notificaciones: $e');
      }

      // ─── Permiso 2: ignorar optimizaciones de batería (best-effort) ───
      try {
        final ignoring =
            await FlutterForegroundTask.isIgnoringBatteryOptimizations;
        if (!ignoring) {
          // No bloqueamos: el usuario puede negarlo y el radio funciona
          // mientras la app esté en foreground. Solo background sufre.
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        }
      } catch (_) {}

      // ─── Intentar arrancar (con 1 retry tras 500ms si falla) ───
      var result = await _tryStartService(channelName);
      if (result is! ServiceRequestSuccess) {
        _logger.w('startService falló al primer intento, reintentando...');
        await Future.delayed(const Duration(milliseconds: 500));
        result = await _tryStartService(channelName);
      }

      if (result is ServiceRequestSuccess) {
        _isRunning = true;
        _logger.i('Radio foreground service started for channel: $channelName');
      } else {
        _logger.e(
            'Failed to start radio foreground service tras retry: $result');
      }
    } catch (e) {
      _logger.e('Exception starting foreground service: $e');
    } finally {
      _isStarting = false;
    }
  }

  Future<ServiceRequestResult> _tryStartService(String channelName) async {
    try {
      return await FlutterForegroundTask.startService(
        notificationTitle: '📻 Radio Activo',
        notificationText: 'Canal: $channelName — Escuchando...',
        callback: _radioTaskCallback,
      );
    } catch (e) {
      _logger.e('Exception en _tryStartService: $e');
      return ServiceRequestFailure(error: e);
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
