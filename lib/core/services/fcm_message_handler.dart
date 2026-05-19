import 'dart:async';
import 'dart:ui';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';

/// Maneja la entrega de mensajes FCM en runtime.
///
/// Android (igual que iOS) NO muestra la notificación del sistema cuando
/// la app está en foreground — entrega el RemoteMessage al onMessage y
/// la app decide qué hacer. Acá usamos `flutter_local_notifications` para
/// mostrar siempre el push, esté la app activa o no.
class FcmMessageHandler {
  FcmMessageHandler._();
  static final FcmMessageHandler instance = FcmMessageHandler._();

  final _flnp = FlutterLocalNotificationsPlugin();
  StreamSubscription<RemoteMessage>? _onMessageSub;
  StreamSubscription<RemoteMessage>? _onOpenedSub;
  GoRouter? _router;
  bool _initialized = false;

  /// Llamar UNA VEZ en main(), antes de runApp.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      // Canal Android obligatorio para Android 8+ (TargetSdk 33+).
      // Sonido + vibración + luz LED habilitados para que el conductor
      // se entere aunque la app esté en foreground o en bolsillo.
      const channel = AndroidNotificationChannel(
        'taxi_default',
        'Avisos generales',
        description:
            'Notificaciones de la cooperativa (avisos, pagos, asignaciones)',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        enableLights: true,
        ledColor: Color(0xFFFFA000), // ámbar
      );
      await _flnp
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
      await _flnp.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (resp) {
          _handleTap(resp.payload);
        },
      );
    } catch (e) {
      debugPrint('FcmMessageHandler.initialize error: $e');
    }
  }

  /// Llamar tras login para arrancar los listeners. `router` se usa para
  /// navegar a /notifications cuando el user toca un push.
  void attachRouter(GoRouter router) {
    _router = router;
    _onMessageSub ??= FirebaseMessaging.onMessage.listen(_handleForeground);
    _onOpenedSub ??=
        FirebaseMessaging.onMessageOpenedApp.listen(_handleOpened);
    // Si la app se abrió desde un push cuando estaba terminada (cold-start),
    // el mensaje queda en getInitialMessage. Lo procesamos también.
    FirebaseMessaging.instance.getInitialMessage().then((msg) {
      if (msg != null) _handleOpened(msg);
    });
  }

  void _handleForeground(RemoteMessage msg) {
    final notif = msg.notification;
    if (notif == null) return; // data-only, no mostrar
    _flnp.show(
      notif.hashCode,
      notif.title ?? 'Aviso',
      notif.body ?? '',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'taxi_default',
          'Avisos generales',
          importance: Importance.high,
          priority: Priority.high,
          // Sonido + vibración explícitos para foreground (algunos
          // Android no respetan el default del canal cuando la app
          // está activa — hay que pedirlo en cada show).
          playSound: true,
          enableVibration: true,
          // Heads-up notification: aparece como banner flotante arriba
          // de la app mientras el user está usando la app.
          channelShowBadge: true,
          fullScreenIntent: false,
          category: AndroidNotificationCategory.message,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: msg.data['type'] ?? '',
    );
  }

  void _handleOpened(RemoteMessage msg) {
    _handleTap(msg.data['type'] as String?);
  }

  void _handleTap(String? type) {
    final router = _router;
    if (router == null) return;
    // Por ahora todos los push administrativos van a /notifications.
    // Si querés ramificar por type ('payment_validated' → /my-payments,
    // 'queue_alert' → /home, etc.) este es el lugar.
    router.push('/notifications');
  }
}
