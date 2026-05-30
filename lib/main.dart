import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'firebase_options.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'core/services/connectivity_service.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'core/services/association_theme_service.dart';
import 'core/services/current_user_context.dart';
import 'core/services/driver_location_service.dart';
import 'core/services/fcm_message_handler.dart';
import 'core/services/fcm_token_service.dart';
import 'core/services/local_audio_history_service.dart';
import 'core/services/ptt_beep_service.dart';
import 'core/services/overlay_ptt_service.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'core/services/radio_power_service.dart';
import 'core/services/radio_foreground_service.dart';
import 'core/services/claims_refresh_service.dart';
import 'core/services/queue_alert_service.dart';
import 'core/services/remote_log_service.dart';
import 'core/services/single_session_service.dart';
import 'core/services/version_gate_service.dart';
import 'core/services/voice/voice_provider_factory.dart';
import 'core/widgets/force_update_screen.dart';
import 'core/widgets/connectivity_banner.dart';
import 'config/injection/injection.dart';
import 'config/router/app_router.dart';
import 'features/auth/presentation/bloc/auth_bloc.dart';
import 'features/trips/presentation/bloc/trip_bloc.dart';
import 'features/payments/presentation/bloc/payment_bloc.dart';
import 'features/chat/presentation/bloc/chat_bloc.dart';
import 'features/communication/presentation/bloc/communication_bloc.dart';
import 'features/map/presentation/bloc/map_bloc.dart';
import 'features/users/presentation/bloc/user_management_bloc.dart';
import 'features/emergency/presentation/bloc/emergency_bloc.dart';

void main() {
  // Logging remoto: envolvemos TODO el arranque en una zona que intercepta
  // `print`/`debugPrint`/el paquete `logger` y los reenvía al
  // RemoteLogService, además de capturar los errores no atrapados. Tanto
  // `WidgetsFlutterBinding.ensureInitialized()` como la inicialización de
  // Firebase quedan DENTRO de la zona (requerido por runZonedGuarded).
  runZonedGuarded<Future<void>>(
    () => _bootstrap(),
    (error, stack) {
      RemoteLogService.instance.captureError(error, stack);
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        RemoteLogService.instance.capture(line);
        parent.print(zone, line);
      },
    ),
  );
}

/// Arranque real de la app. Vive DENTRO de la zona de `runZonedGuarded`.
Future<void> _bootstrap() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();

  // Logging remoto: enganchar los errores del framework y los errores async
  // que escapan de la zona, y arrancar el timer de envío en lotes. NUNCA
  // debe romper el arranque si Oracle no responde (init es fire-and-forget
  // del POST; sólo arranca el timer).
  FlutterError.onError = (FlutterErrorDetails details) {
    RemoteLogService.instance.capture(
        'FlutterError: ${details.exceptionAsString()}\n${details.stack}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    RemoteLogService.instance.captureError(error, stack);
    return false;
  };
  // Arranca el timer periódico de flush. No await crítico: si falla, se
  // ignora para no bloquear el arranque.
  unawaited(RemoteLogService.instance.init());

  // Preservar splash screen mientras inicializa
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // Orientación vertical
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Inicializar Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // bypassVoiceProcessing=TRUE → MODE_NORMAL → el mic NO se reserva: otras apps
  // (WhatsApp, grabadora) pueden usar el micrófono con el radio encendido
  // (decisión de Byron: prioridad mic libre sobre cancelación de ruido). Sin
  // AGC/NS de WebRTC; se compensa con boost de volumen + altavoz forzado. La
  // cancelación de ruido queda como alternativa a evaluar (Krisp u otra).
  try {
    await lk.LiveKitClient.initialize(bypassVoiceProcessing: true);
  } catch (e) {
    debugPrint('LiveKitClient.initialize falló: $e');
  }

  // Inicializar handler de mensajes FCM (canal Android + listeners foreground)
  await FcmMessageHandler.instance.initialize();

  // Inicializar locale 'es' para DateFormat (fechas en español).
  // Sin esto, abrir páginas que usan DateFormat con locale 'es'
  // (ej. "Mis validaciones") lanzaba LocaleDataException.
  await initializeDateFormatting('es', null);

  // App Check desactivado temporalmente. Para activar:
  //  1. Habilitar la API en GCP:
  //     https://console.cloud.google.com/apis/library/firebaseappcheck.googleapis.com?project=taxis-f0f51
  //  2. Registrar app Android (Play Integrity) y iOS (DeviceCheck) en
  //     Firebase Console → App Check.
  //  3. Registrar el debug token (que imprime el SDK la primera vez en
  //     logcat) en Firebase Console → App Check → Manage debug tokens.
  //  4. Descomentar este bloque y poner enforceAppCheck: true en
  //     functions/index.js.
  // await FirebaseAppCheck.instance.activate(
  //   androidProvider:
  //       kReleaseMode ? AndroidProvider.playIntegrity : AndroidProvider.debug,
  //   appleProvider:
  //       kReleaseMode ? AppleProvider.deviceCheck : AppleProvider.debug,
  // );

  // Inicializar inyección de dependencias
  await initDependencies();

  // Inicializar monitoreo de conectividad
  await ConnectivityService.instance.initialize();

  // Inicializar Hive para storage local (audio history, chat local, etc.)
  await Hive.initFlutter();

  // Cargar el último estado del walkie-talkie (ON/OFF persistido)
  await RadioPowerService.instance.initialize();

  // Configurar el foreground service (flutter_foreground_task) al arrancar.
  // Antes solo se hacía al abrir el walkie; ahora la ubicación (Activo General)
  // también lo usa, así que debe estar listo aunque el conductor no entre al
  // walkie. Idempotente.
  RadioForegroundService.instance.init();

  // Inicializar historial de audios local (purga audios > 24h al iniciar)
  await LocalAudioHistoryService.instance.initialize();

  // Pre-generar los beeps tipo Motorola/Zello para el PTT (latencia 0ms)
  await PttBeepService.instance.initialize();

  // Inicializar servicio de overlay PTT (escuchar eventos del nativo)
  OverlayPttService.instance.initialize();

  // Versionamiento: lee app_config/{platform} y bloquea si la build local
  // está obsoleta. Fire-and-forget: si falla red, dejamos pasar.
  unawaited(VersionGateService.instance.start());

  // Remover splash screen — la app está lista
  FlutterNativeSplash.remove();

  runApp(const TaxiJipijapaApp());
}

class TaxiJipijapaApp extends StatefulWidget {
  const TaxiJipijapaApp({super.key});

  @override
  State<TaxiJipijapaApp> createState() => _TaxiJipijapaAppState();
}

class _TaxiJipijapaAppState extends State<TaxiJipijapaApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Marcar offline al cerrar la app
    DriverLocationService.instance.goOffline();
    // Destruir el provider de voz activo (Agora/LiveKit) al cerrar la app
    VoiceProviderFactory.current.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // ⚠️ NO destruimos el engine al ir a background — antes lo
      // hacíamos para liberar el mic, pero eso también cortaba el
      // audio ENTRANTE del canal. Ahora aprovechamos que ya tenemos
      // `enableLocalAudio(false)` (al soltar PTT) que libera el mic
      // a nivel del SO sin destruir el engine. Resultado: el conductor
      // sigue ESCUCHANDO la radio aunque la app esté en background, y
      // otras apps (WhatsApp, Zello) pueden usar el mic libremente
      // mientras él no presione PTT.
      //
      // El RadioForegroundService con foregroundServiceType=mediaPlayback
      // ya autoriza al SO a mantener el audio reproduciéndose en
      // background.
      debugPrint('📱 [GLOBAL] App $state → engine vivo (audio entrante OK)');
      DriverLocationService.instance.setAppBackgrounded(true);
      // Logging remoto: vaciar el buffer al ir a background/cerrar para no
      // perder los últimos logs (fire-and-forget).
      unawaited(RemoteLogService.instance.flush());
    } else if (state == AppLifecycleState.resumed) {
      debugPrint('📱 [GLOBAL] App resumed');
      DriverLocationService.instance.setAppBackgrounded(false);
      // Revivir el pipeline GPS si el SO lo mató en background (Doze/throttling
      // del FGS): sin esto el conductor desaparecía del mapa de la operadora a
      // los ~6 min. ensureAlive() es idempotente y solo actúa si está online.
      DriverLocationService.instance.ensureAlive();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>(
          create: (_) => sl<AuthBloc>()..add(AuthCheckRequested()),
        ),
        BlocProvider<TripBloc>(
          create: (_) => sl<TripBloc>(),
        ),
        BlocProvider<PaymentBloc>(
          create: (_) => sl<PaymentBloc>(),
        ),
        BlocProvider<ChatBloc>(
          create: (_) => sl<ChatBloc>(),
        ),
        BlocProvider<CommunicationBloc>(
          create: (_) => sl<CommunicationBloc>(),
        ),
        BlocProvider<MapBloc>(
          create: (_) => sl<MapBloc>(),
        ),
        BlocProvider<UserManagementBloc>(
          create: (_) => sl<UserManagementBloc>(),
        ),
        BlocProvider<EmergencyBloc>(
          create: (_) => sl<EmergencyBloc>(),
        ),
      ],
      child: Builder(
        builder: (context) {
          final authBloc = context.read<AuthBloc>();
          final router = AppRouter.router(authBloc);
          FcmMessageHandler.instance.attachRouter(router);

          return BlocListener<AuthBloc, AuthState>(
            listener: (context, state) {
              debugPrint(
                  '📍 [Main] AuthState → ${state.runtimeType}');
              final locationService = DriverLocationService.instance;
              if (state is AuthAuthenticated) {
                final user = state.user;
                debugPrint(
                    '📍 [Main] User: ${user.uid}, role=${user.role}, '
                    'numVeh=${user.numeroVehiculo}, placa=${user.placa}');
                // Mantener contexto global del usuario actual para filtrar
                // queries multi-tenant en datasources sin pasar AuthBloc.
                CurrentUserContext.instance.set(
                  uid: user.uid,
                  associationId: user.associationId,
                  role: user.role,
                );
                // Logging remoto: etiquetar los logs con uid/rol reales.
                RemoteLogService.instance.setUser(user.uid, user.role);
                // 🚫 Usuario suspendido/bloqueado: el bloqueo debe ser
                // FUNCIONAL, no solo visual. Cortar voz + radio + FGS + overlay
                // + ubicación, sin depender del desmontaje del walkie (que vive
                // en un IndexedStack y no se desmonta). Mantenemos claims y
                // single-session ligados para detectar si lo des-bloquean.
                if (user.isBlocked) {
                  debugPrint(
                      '🚫 [Main] Usuario BLOQUEADO → teardown voz/radio/ubicación');
                  SingleSessionService.instance.bind(user.uid);
                  ClaimsRefreshService.instance.bind(user.uid);
                  ClaimsRefreshService.instance.onProfileChanged = () {
                    if (!context.mounted) return;
                    context.read<AuthBloc>().add(AuthCheckRequested());
                  };
                  RadioPowerService.instance.turnOff();
                  VoiceProviderFactory.current.dispose();
                  RadioForegroundService.instance.stopService();
                  RadioForegroundService.instance.setLocationTracking(false);
                  OverlayPttService.instance.stop();
                  DriverLocationService.instance.goOffline(hardOffline: true);
                  return;
                }
                // Seleccionar el provider de voz (Agora/LiveKit). Por defecto
                // se lee el feature flag `voiceProvider` de la asociación.
                // Override de pruebas: `--dart-define=VOICE_PROVIDER=livekit`
                // (o `agora`) fuerza el provider SIN tocar Firestore — útil
                // para probar LiveKit en un dispositivo sin migrar la coop.
                const voiceOverride =
                    String.fromEnvironment('VOICE_PROVIDER');
                // Restaurar el radio PTT si ESTE conductor lo dejó encendido
                // (comportamiento Zello). Scoped por uid → no hereda entre
                // conductores. Si queda ON, el walkie une el último canal.
                //
                // ⚠️ ORDEN CRÍTICO: el radio se enciende (restoreForUser, que
                // dispara el join del canal) SOLO DESPUÉS de seleccionar el
                // provider correcto. `selectFor` lee el flag en Firestore y es
                // ASYNC; si encendiéramos el radio antes, el walkie se uniría
                // con el provider por defecto (Agora) y, al cambiar a LiveKit,
                // la Room quedaba SIN unir → al arrancar en frío el PTT no
                // agarraba el mic (había que togglear el radio). Por eso
                // esperamos a que el provider quede fijado y recién ahí
                // restauramos el radio.
                void restoreRadio() =>
                    RadioPowerService.instance.restoreForUser(user.uid);
                if (voiceOverride == 'livekit' || voiceOverride == 'agora') {
                  debugPrint(
                      '🎙️ [Main] VOICE_PROVIDER override → $voiceOverride');
                  VoiceProviderFactory.forceUse(voiceOverride); // síncrono
                  restoreRadio();
                } else {
                  // selectFor es async (lee Firestore): restauramos el radio
                  // al COMPLETAR, con el provider ya fijado.
                  VoiceProviderFactory.selectFor(user.associationId)
                      .whenComplete(restoreRadio);
                }
                // Garantizar 1 sola sesión activa: este login GANA, los
                // demás dispositivos verán el mismatch y se cerrarán.
                SingleSessionService.instance.bind(user.uid);
                // Auto-refresh del JWT cuando el admin cambia status/rol
                // del usuario. Sin esto, un conductor recién aprobado
                // sigue viendo PERMISSION_DENIED en todas sus queries.
                ClaimsRefreshService.instance.bind(user.uid);
                // Tras un cambio de status/role en Firestore, recargar el
                // UserModel en AuthBloc para que el router redirija
                // (ej. suspendido → /blocked, lo cual desmonta walkie y
                // libera Agora).
                ClaimsRefreshService.instance.onProfileChanged = () {
                  if (!context.mounted) return;
                  context.read<AuthBloc>().add(AuthCheckRequested());
                };
                // Operadora/admin reciben ding-ding cuando un conductor
                // entra a la cola de la parada.
                QueueAlertService.instance.bind(
                  role: user.role,
                  associationId: user.associationId,
                );
                // Registrar el token FCM en users/{uid} para recibir
                // notificaciones del cron dispatchScheduledNotifications.
                FcmTokenService.instance.bind(user.uid);
                // Cargar theme custom de la asociación (logo + colores).
                AssociationThemeService.instance.loadFor(user.associationId);
                // (La selección del provider de voz se hace arriba, con
                // soporte de override por --dart-define. No duplicar aquí:
                // un segundo selectFor pisaba el override → volvía a Agora.)
                // Inicializar GPS para conductores y admins con vehículo
                if (user.role == AppConstants.roleDriver ||
                    (user.role == AppConstants.roleAdmin &&
                        user.numeroVehiculo.isNotEmpty)) {
                  locationService.initialize(
                    userId: user.uid,
                    associationId: user.associationId,
                    displayName:
                        '${user.name} ${user.lastname}'.trim(),
                    vehicleNumber: user.numeroVehiculo,
                    plate: user.placa,
                  );
                }
              } else if (state is AuthUnauthenticated) {
                CurrentUserContext.instance.clear();
                // Logging remoto: volver a "anon" tras cerrar sesión.
                RemoteLogService.instance.clearUser();
                // BUG 1 — al cerrar sesión, resetear la sesión de voz:
                // desconectar la Room viva e invalidar el token cacheado (que
                // embebe la identidad/uid del usuario saliente). Sin esto, al
                // entrar otra cuenta SIN reiniciar la app el dispositivo seguía
                // conectado a LiveKit con la identidad anterior y reusaba su
                // token. resetForUserChange deja el provider listo para pedir
                // un token fresco con la nueva identidad en el próximo join.
                VoiceProviderFactory.resetForUserChange();
                FcmTokenService.instance.unbind();
                SingleSessionService.instance.unbind();
                ClaimsRefreshService.instance.onProfileChanged = null;
                ClaimsRefreshService.instance.unbind();
                QueueAlertService.instance.unbind();
                AssociationThemeService.instance.clear();
                locationService.reset();
              }
            },
            child: ConnectivityBanner(
              child: ListenableBuilder(
                listenable: AssociationThemeService.instance,
                builder: (context, _) {
                  final svc = AssociationThemeService.instance;
                  return MaterialApp.router(
                title: AppConstants.appName,
                debugShowCheckedModeBanner: false,
                theme: svc.applyToThemeData(AppTheme.lightTheme),
                darkTheme: svc.applyToThemeData(AppTheme.darkTheme),
                themeMode: ThemeMode.light,
                routerConfig: router,
                builder: (context, child) {
                  return _VersionGate(
                    child: _SingleSessionGate(
                      child: child ?? const SizedBox(),
                    ),
                  );
                },
              );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Escucha el ValueNotifier de VersionGateService. Cuando el estado es
/// `forceUpdate`, reemplaza el árbol entero por la [ForceUpdateScreen],
/// bloqueando cualquier interacción con la app hasta que el usuario
/// instale la versión nueva. El estado se evalúa en boot y se mantiene
/// sub-suscrito al doc Firestore: si el admin sube `minRequiredBuild`
/// mientras la app está abierta, también bloquea.
class _VersionGate extends StatefulWidget {
  final Widget child;
  const _VersionGate({required this.child});

  @override
  State<_VersionGate> createState() => _VersionGateState();
}

class _VersionGateState extends State<_VersionGate> {
  @override
  void initState() {
    super.initState();
    VersionGateService.instance.status.addListener(_onChanged);
  }

  @override
  void dispose() {
    VersionGateService.instance.status.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = VersionGateService.instance.status.value;
    if (s == VersionGateStatus.forceUpdate) {
      return const ForceUpdateScreen();
    }
    return widget.child;
  }
}

/// Escucha el flag `kicked` del SingleSessionService. Cuando otro
/// dispositivo inició sesión con las mismas credenciales, muestra un
/// modal modal-bloqueante y luego dispara signOut.
class _SingleSessionGate extends StatefulWidget {
  final Widget child;
  const _SingleSessionGate({required this.child});

  @override
  State<_SingleSessionGate> createState() => _SingleSessionGateState();
}

class _SingleSessionGateState extends State<_SingleSessionGate> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    SingleSessionService.instance.kicked.addListener(_onKickedChanged);
  }

  @override
  void dispose() {
    SingleSessionService.instance.kicked.removeListener(_onKickedChanged);
    super.dispose();
  }

  void _onKickedChanged() {
    if (!mounted) return;
    if (SingleSessionService.instance.kicked.value && !_shown) {
      _shown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showModal());
    } else if (!SingleSessionService.instance.kicked.value) {
      _shown = false;
    }
  }

  Future<void> _showModal() async {
    final ctx = context;
    if (!ctx.mounted) return;
    // `_SingleSessionGate` vive en el `builder` de MaterialApp.router, POR
    // ENCIMA del Navigator de go_router → `showDialog(context: ctx)` hacía
    // `Navigator.of()` → null → crash (pantalla gris). Usamos el context del
    // Navigator raíz (expuesto vía rootNavigatorKey) para abrir el diálogo
    // dentro del overlay correcto. Si el Navigator aún no está montado,
    // abortamos sin romper (se reintenta en el próximo cambio de `kicked`).
    final navState = rootNavigatorKey.currentState;
    final dialogContext = navState?.overlay?.context ?? navState?.context;
    if (navState == null || dialogContext == null) {
      _shown = false; // permitir reintento
      return;
    }
    await showDialog<void>(
      context: dialogContext,
      barrierDismissible: false,
      builder: (dCtx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded,
            color: Colors.orange, size: 48),
        title: const Text('Sesión cerrada'),
        content: const Text(
          'Otro dispositivo inició sesión con sus credenciales.\n\n'
          'Si no fuiste tú, te recomendamos cambiar tu contraseña '
          'cuanto antes.',
          textAlign: TextAlign.center,
        ),
        actions: [
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(dCtx).pop();
            },
            icon: const Icon(Icons.login),
            label: const Text('Volver a iniciar sesión'),
          ),
        ],
      ),
    );
    // Importante: signOut DESPUÉS de cerrar el modal para que el AuthBloc
    // limpie todo (radio, GPS, fcm, single-session).
    if (ctx.mounted) {
      ctx.read<AuthBloc>().add(AuthSignOutRequested());
      SingleSessionService.instance.clearKicked();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
