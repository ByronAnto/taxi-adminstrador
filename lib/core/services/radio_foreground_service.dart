import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logger/logger.dart';

import 'connectivity_service.dart';

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
  // El FGS (flutter_foreground_task, único) se comparte entre dos motivos:
  // radio (microphone/mediaPlayback) y ubicación (location). Corre mientras
  // CUALQUIERA esté activo. Esto permite que "Activo General" mantenga el GPS
  // vivo en background aunque el radio esté apagado.
  bool _radioActive = false;
  bool _locationActive = false;
  VoidCallback? _connListener;
  bool _showingOfflineNotif = false;

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
    _attachConnectivityMonitor();
    _recoverIfZombie();
    _logger.i('RadioForegroundService initialized');
  }

  /// Si el FGS quedó corriendo de una sesión anterior (Android mató el
  /// isolate Flutter pero el servicio sobrevivió), resincronizar el flag
  /// `_isRunning` para que `stopService` pueda apagarlo correctamente.
  /// Sin esto, la notificación se queda zombi hasta reinicio del celular.
  Future<void> _recoverIfZombie() async {
    try {
      final running = await FlutterForegroundTask.isRunningService;
      if (running && !_isRunning) {
        _isRunning = true;
        _logger.w('FGS zombie detectado tras cold-start: resincronizando flag');
      }
    } catch (_) {}
  }

  /// Suscribe la notificación al estado de internet. Si la conexión se
  /// cae mientras el radio está activo, refleja "Sin conexión" en la
  /// notificación para que el usuario no vea estados contradictorios
  /// (app: "desconectado", notificación: "escuchando").
  void _attachConnectivityMonitor() {
    if (_connListener != null) return;
    void listener() {
      if (!_isRunning || _activeChannelName == null) return;
      final online = ConnectivityService.instance.isConnected;
      if (online) {
        if (_showingOfflineNotif) {
          _showingOfflineNotif = false;
          _safeUpdateNotification(_activeChannelName!);
        }
      } else {
        if (!_showingOfflineNotif) {
          _showingOfflineNotif = true;
          _showOfflineNotification();
        }
      }
    }
    ConnectivityService.instance.addListener(listener);
    _connListener = listener;
  }

  Future<void> _showOfflineNotification() async {
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: '📻 Radio sin conexión',
        notificationText: 'Reconectando…',
      );
    } catch (e) {
      _logger.e('Error mostrando notificación offline: $e');
    }
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
    _radioActive = true;
    _activeChannelName = channelName;
    await _ensureRunning();
  }

  /// Activa/desactiva el FGS por motivo "ubicación" (Activo General).
  /// Mientras esté activo, el foreground service (tipo location) mantiene la
  /// app viva y el GPS fluyendo en background — el admin/operadora siempre ven
  /// la unidad. Comparte el MISMO FGS con el radio.
  Future<void> setLocationTracking(bool active) async {
    if (_locationActive == active) return;
    _locationActive = active;
    if (active) {
      await _ensureRunning();
    } else {
      await _reconcile();
    }
  }

  /// Arranca el FGS si no corre (idempotente); si ya corre, refresca la
  /// notificación. Usado por radio y ubicación.
  Future<void> _ensureRunning() async {
    if (_isRunning) {
      await _refreshNotification();
      return;
    }
    if (_isStarting) return;

    _isStarting = true;

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
      var result = await _tryStartService();
      if (result is! ServiceRequestSuccess) {
        _logger.w('startService falló al primer intento, reintentando...');
        await Future.delayed(const Duration(milliseconds: 500));
        result = await _tryStartService();
      }

      if (result is ServiceRequestSuccess) {
        _isRunning = true;
        _logger.i('Foreground service started '
            '(radio=$_radioActive, location=$_locationActive)');
      } else {
        _logger.e('Failed to start foreground service tras retry: $result');
      }
    } catch (e) {
      _logger.e('Exception starting foreground service: $e');
    } finally {
      _isStarting = false;
    }
  }

  // Notificación según el motivo activo (radio tiene prioridad de texto).
  String get _notifTitle =>
      _radioActive ? '📻 Radio Activo' : '📍 Enviando ubicación';
  String get _notifText => _radioActive
      ? 'Canal: ${_activeChannelName ?? ""} — Escuchando...'
      : 'Tu ubicación es visible para la operadora';

  /// Refresca la notificación al estado actual (cambio de motivo radio↔ubicación).
  Future<void> _refreshNotification() async {
    if (!_isRunning) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: _notifTitle,
        notificationText: _notifText,
      );
    } catch (e) {
      _logger.e('Error refrescando notificación FGS: $e');
    }
  }

  Future<ServiceRequestResult> _tryStartService() async {
    try {
      return await FlutterForegroundTask.startService(
        notificationTitle: _notifTitle,
        notificationText: _notifText,
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

  /// El radio dejó de necesitar el FGS. NO apaga el servicio si la ubicación
  /// (Activo General) aún lo necesita — solo reconcilia.
  Future<void> stopService() async {
    _radioActive = false;
    _activeChannelName = null;
    await _reconcile();
  }

  /// Decide si el FGS debe seguir corriendo: corre si radio O ubicación están
  /// activos. Si ninguno → lo detiene; si sigue uno → refresca la notificación.
  Future<void> _reconcile() async {
    if (!_radioActive && !_locationActive) {
      await _doStop();
    } else if (_isRunning) {
      await _refreshNotification();
    }
  }

  /// Detiene realmente el foreground service.
  ///
  /// Si el plugin devuelve `ServiceRequestFailure` significa que Android
  /// ya consideraba el FGS detenido (típico tras hot-reload, cold-start
  /// con FGS huérfano, o pérdida de permisos en Android 14+). En ese
  /// caso no es un error crítico: forzamos reset de los flags internos
  /// para que el próximo `startService` funcione.
  Future<void> _doStop() async {
    if (!_isRunning) return;

    // Verificar primero si el FGS realmente está corriendo a nivel
    // nativo. Si no, solo limpiamos los flags y salimos sin pedir stop.
    bool nativeRunning = false;
    try {
      nativeRunning = await FlutterForegroundTask.isRunningService;
    } catch (_) {}

    if (!nativeRunning) {
      _isRunning = false;
      _activeChannelName = null;
      _showingOfflineNotif = false;
      _logger.i('FGS ya no estaba corriendo, solo limpio flags');
      return;
    }

    try {
      final result = await FlutterForegroundTask.stopService();
      if (result is ServiceRequestSuccess) {
        _logger.i('Radio foreground service stopped');
      } else {
        // ServiceRequestFailure: el plugin no pudo detener pero Android
        // suele limpiar la notificación poco después. Lo dejamos como
        // warning, no como error.
        _logger.w(
            'stopService no exitoso (probable FGS ya detenido por SO): $result');
      }
    } catch (e) {
      _logger.w('Exception stopping FGS (no crítico): $e');
    } finally {
      // Sea cual sea el resultado, los flags internos quedan limpios.
      _isRunning = false;
      _activeChannelName = null;
      _showingOfflineNotif = false;
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
