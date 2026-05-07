import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'firebase_options.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'core/services/connectivity_service.dart';
import 'core/services/agora_service.dart';
import 'core/services/driver_location_service.dart';
import 'core/services/overlay_ptt_service.dart';
import 'core/services/radio_power_service.dart';
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

void main() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();

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

  // Cargar el último estado del walkie-talkie (ON/OFF persistido)
  await RadioPowerService.instance.initialize();

  // Inicializar servicio de overlay PTT (escuchar eventos del nativo)
  OverlayPttService.instance.initialize();

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
    // Destruir Agora al cerrar la app
    AgoraService.instance.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final agora = AgoraService.instance;
    final overlay = OverlayPttService.instance;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (!overlay.isActive) {
        // Solo destruir si el overlay PTT NO está activo.
        // El overlay gestiona su propio ciclo de vida del engine.
        agora.destroyEngine();
        debugPrint('🔥 [GLOBAL] App $state → Agora engine destruido, mic libre');
      } else {
        debugPrint('📱 [GLOBAL] App $state → overlay PTT activo, engine gestionado por overlay');
      }
    } else if (state == AppLifecycleState.resumed) {
      debugPrint('📱 [GLOBAL] App resumed → engine se recrea bajo demanda');
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
                locationService.reset();
              }
            },
            child: ConnectivityBanner(
              child: MaterialApp.router(
                title: AppConstants.appName,
                debugShowCheckedModeBanner: false,
                theme: AppTheme.lightTheme,
                darkTheme: AppTheme.darkTheme,
                themeMode: ThemeMode.light,
                routerConfig: router,
              ),
            ),
          );
        },
      ),
    );
  }
}
