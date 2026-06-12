import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../../core/services/agora_service.dart';
import '../../../../core/services/voice/voice_provider.dart';
import '../../../../core/services/voice/voice_provider_factory.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../core/services/driver_location_service.dart';
import '../../../../core/services/local_audio_history_service.dart';
import '../../../../core/services/ptt_beep_service.dart';
import '../../../../core/services/radio_foreground_service.dart';
import '../../../../core/services/radio_power_service.dart';
import '../../../../core/services/overlay_ptt_service.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/data/models/user_model.dart';
import '../../../trips/presentation/widgets/assign_trip_modal.dart';
import '../../../trips/presentation/widgets/quick_street_assign_modal.dart';
import '../../data/models/channel_model.dart';
import '../bloc/communication_bloc.dart';
import '../widgets/channel_settings_sheet.dart';
import '../widgets/stand_queue_bar.dart';

/// Página de walkie-talkie con PTT estilo Zello.
/// Canal bloqueado: solo un usuario puede hablar a la vez.
class WalkieTalkiePage extends StatefulWidget {
  const WalkieTalkiePage({super.key});

  @override
  State<WalkieTalkiePage> createState() => _WalkieTalkiePageState();
}

class _WalkieTalkiePageState extends State<WalkieTalkiePage>
    with WidgetsBindingObserver {
  bool _isRecording = false;
  bool _isMuted = false;
  Timer? _recordingTimer;
  Timer? _durationTimer;
  int _recordingSeconds = 0;

  /// Anti-PTT-pegado: si el transmisor mantiene el lock pero no genera
  /// voz por [_maxSilenceSeconds] consecutivos, soltamos el PTT solo.
  /// Evita que un dedo pegado / botón atascado bloquee el canal para todos.
  static const int _maxSilenceSeconds = 10;
  Timer? _silenceTimer;
  DateTime? _lastVoiceAt;

  // Provider de voz activo (Agora o LiveKit) según el feature flag de la
  // asociación. GETTER (no campo): lee SIEMPRE el provider actual del factory.
  // Si se cacheara en un `final`, la página podría capturar el provider por
  // defecto (Agora) ANTES de que el login corriera selectFor()/forceUse() —
  // race que dejaba el walkie en Agora aunque el flag fuese LiveKit.
  // Los `AgoraService.playbackVolumeMin/Max` (consts estáticas del slider)
  // se siguen referenciando directo — son límites de UI, provider-agnósticos.
  VoiceProvider get _voice => VoiceProviderFactory.current;
  final _radioService = RadioForegroundService.instance;
  final _connectivity = ConnectivityService.instance;
  final _overlayService = OverlayPttService.instance;
  final _locationService = DriverLocationService.instance;
  final _radioPower = RadioPowerService.instance;

  /// true cuando no hay internet O el conductor está en modo Desconectado
  bool _isOffline = false;

  /// true cuando falta el permiso de micrófono. Es el bloqueo REAL para
  /// transmitir por PTT, así que su banner tiene prioridad sobre el de
  /// "Sin conexión". Se chequea en initState y al volver de Ajustes
  /// (didChangeAppLifecycleState.resumed).
  bool _micPermissionMissing = false;

  /// true solo cuando el conductor está en modo Desconectado (estado manual)
  bool _isDriverOffline = false;

  /// true cuando hay red del SO pero la Room está reconectándose (la
  /// auto-reconexión de LiveKit está en curso). NO es "sin conexión": el
  /// radio se resuelve solo, así que mostramos "Reconectando…" en vez de
  /// "Sin red" y no bloqueamos agresivamente el PTT.
  bool _isRadioReconnecting = false;

  /// Último channelId al que nos unimos en Agora (para detectar cambios)
  String? _lastAgoraChannelId;

  // ─── Auto-disconnect por inactividad ───
  /// Última vez que vimos a alguien hablando en el canal. Si pasa más de
  /// [_idleParkAfterSeconds] sin actividad, hacemos `parkChannel()` para
  /// dejar de quemar minutos Agora mientras el canal está mudo. El engine
  /// sigue vivo así que `resumeFromPark()` reconecta en ~300 ms cuando
  /// alguien arranca de nuevo.
  DateTime? _lastChannelActivityAt;
  Timer? _idleParkTimer;

  /// Segundos sin actividad de speaker antes de auto-park. 30 s es buen
  /// balance: corto para ahorrar costos, largo para no reconectar cada
  /// pausa breve en una conversación viva.
  static const int _idleParkAfterSeconds = 30;

  /// Pausa adicional tras `resumeFromPark()` antes de soltar el beep +
  /// unmuteMic. Los listeners también están parked: ven el lock de
  /// Firestore en su snapshot stream y arrancan su propio
  /// `resumeFromPark()` en paralelo. Necesitan ~800-1500 ms para estar
  /// listos. Sin este grace el hablante transmite a un canal vacío y
  /// pierde los primeros ~2 s de audio.
  static const int _listenerCatchupMs = 1200;

  /// Guard para que el denial chirp NO se re-dispare en cada rebuild
  /// del bloc. `pttLockDenied` queda sticky=true hasta el siguiente
  /// update del stream; sin este flag tocaríamos el beep varias veces.
  bool _lastDeniedSeen = false;

  /// Flag para abortar la transmisión si el usuario suelta el PTT
  /// DURANTE el grace de reconexión (parked). Sin esto, el flow seguía
  /// hasta unmuteMic aunque el dedo ya no estaba apretando — la otra
  /// punta recibía audio sin razón y el speaker no sabía que había
  /// transmitido.
  bool _pttCancelled = false;

  // ── Anti-spam del PTT (estilo Zello) ──
  // Bug 2026-06-12: clicks rápidos al botón encimaban unmute/mute + beeps y
  // el mic quedaba PEGADO (logs: 60 beeps en 8 s + TimeoutException 30 s).
  // Dos defensas:
  //  1. `_pttOpsInFlight`: un press nuevo se IGNORA mientras el press o el
  //     release anterior siguen procesándose (guard en vuelo). El release
  //     nunca se bloquea — soltar SIEMPRE libera el mic.
  //  2. Rate-limit: una transmisión que dura < [_pttEmptyMax] es un "mensaje
  //     vacío"; [_pttEmptyLimit] vacíos dentro de la ventana deslizante
  //     [_pttSpamWindow] bloquean el PTT por [_pttBlockTime] con aviso
  //     (igual que Zello). Una transmisión válida limpia el contador.
  int _pttOpsInFlight = 0;
  DateTime? _pttPressedAt;
  final List<DateTime> _emptyPttPresses = [];
  DateTime? _pttBlockedUntil;
  static const Duration _pttSpamWindow = Duration(seconds: 8);
  static const Duration _pttEmptyMax = Duration(seconds: 1);
  static const int _pttEmptyLimit = 4;
  static const Duration _pttBlockTime = Duration(seconds: 15);

  /// Estado de la grabación local del audio del canal (historial 24h).
  String? _recordingEntryId;
  DateTime? _recordingStartedAt;
  String? _lastSpeakerLockKey; // "channelId|speakerId"

  /// Duración máxima de grabación en segundos (seguridad anti-mic abierto)
  static const int _maxRecordingSeconds = 60;

  UserModel? get _currentUser {
    final authState = context.read<AuthBloc>().state;
    if (authState is AuthAuthenticated) return authState.user;
    return null;
  }

  /// True si el rol del usuario depende del GPS (conductor o admin con
  /// vehículo). Para operadoras y admin sin vehículo, el estado online
  /// del DriverLocationService es irrelevante: el radio funciona aunque
  /// no haya GPS. Sin esto, la operadora se quedaba con `_isOffline=true`
  /// permanente y NO podía mandar audios por el radio.
  bool _userDependsOnGps() {
    final u = _currentUser;
    if (u == null) return false;
    if (u.role == AppConstants.roleDriver) return true;
    if (u.role == AppConstants.roleAdmin && u.numeroVehiculo.isNotEmpty) {
      return true;
    }
    return false;
  }

  /// Recalcula `_isOffline` y `_isDriverOffline` aplicando el gate de
  /// rol — para que la operadora no quede bloqueada del PTT por no
  /// enviar GPS.
  void _refreshOfflineFlags() {
    final dependsOnGps = _userDependsOnGps();
    // Mientras el DriverLocationService NO terminó de inicializar (resolver
    // el driver doc + goOnline), su `isOnline` todavía vale el `false`
    // inicial — NO es una señal real de "Desconectado". Tratarlo como
    // offline en esa ventana es lo que congelaba el banner naranja en el
    // Pixel con datos móviles lentos: la página se construía antes de que
    // goOnline() terminara y nunca se "des-bloqueaba" si el init fallaba.
    // Solo consideramos al conductor desconectado una vez que el servicio
    // se inicializó y reporta isOnline=false explícitamente.
    _isDriverOffline = dependsOnGps &&
        _locationService.isInitialized &&
        !_locationService.isOnline;
    // "Sin conexión" REAL solo cuando NO hay red del SO (o modo Desconectado
    // manual). La fuente de verdad de la red la da ConnectivityService, que
    // ahora prueba nuestro backend LiveKit primero (B1) — si LiveKit es
    // alcanzable nunca marcamos offline aunque Google esté bloqueado.
    _isOffline = !_connectivity.isConnected || _isDriverOffline;
    // Estado "Reconectando…": hay red del SO y no estamos en modo
    // Desconectado, pero la Room está reestableciéndose (auto-reconexión
    // LiveKit). Distinto de offline: el radio se resuelve solo. Agora siempre
    // devuelve isReconnecting=false, así que esto solo aplica a LiveKit.
    _isRadioReconnecting = !_isOffline &&
        _radioPower.isOn &&
        _voice.isReconnecting &&
        !_voice.isInChannel;
  }

  /// Relee el estado del permiso de micrófono y actualiza `_micPermissionMissing`.
  Future<void> _refreshMicPermission() async {
    final granted = await Permission.microphone.isGranted;
    if (!mounted) return;
    if (_micPermissionMissing == !granted) return; // sin cambios
    setState(() => _micPermissionMissing = !granted);
  }

  /// Pide el permiso de micrófono. Si quedó denegado permanentemente, abre
  /// los Ajustes del sistema (el sistema ya no muestra el diálogo). El refresh
  /// real ocurre al volver a la app (didChangeAppLifecycleState.resumed).
  Future<void> _requestMicPermission() async {
    final status = await Permission.microphone.status;
    if (status.isPermanentlyDenied) {
      await openAppSettings();
      return;
    }
    await Permission.microphone.request();
    await _refreshMicPermission();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Estado inicial del permiso de micrófono (banner + gating del PTT).
    _refreshMicPermission();
    // Inicializar configuración del foreground task (sólo registro,
    // no arranca el servicio).
    _radioService.init();
    // Si el radio quedó ON de la sesión anterior, inicializar el provider.
    // Si quedó OFF, NO se inicializa nada — el mic queda libre para otras apps.
    //
    // CICLO BLOQUEO→REACTIVACIÓN: al bloquear al conductor, main.dart hace
    // `VoiceProviderFactory.current.dispose()` (engine destruido, room cerrado,
    // isInitialized=false). Al reactivar, el router remonta esta página y el
    // provider sigue siendo el MISMO singleton ya dispuesto. Re-inicializarlo
    // aquí lo deja sano de nuevo. Si quedó a medio inicializar, lo forzamos.
    if (_radioPower.isOn && !_voice.isInitialized) {
      _voice.initialize().catchError((e) {
        debugPrint('Error inicializando provider de voz: $e');
      });
    }
    // Monitorear conectividad
    _refreshOfflineFlags();
    _connectivity.addListener(_onConnectivityChanged);
    _locationService.addListener(_onDriverLocationChanged);
    _radioPower.addListener(_onRadioPowerChanged);
    // El overlay se puede cerrar desde la notificación nativa (botón "Cerrar"
    // o swipe). Escuchar para refrescar el icono del botón en la UI.
    _overlayService.onStateChanged = () {
      if (mounted) setState(() {});
    };
    // Iniciar la observación de canales (siempre — para mostrar la lista
    // aunque el radio esté apagado).
    context.read<CommunicationBloc>().add(ChannelsWatchStarted());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivity.removeListener(_onConnectivityChanged);
    _locationService.removeListener(_onDriverLocationChanged);
    _radioPower.removeListener(_onRadioPowerChanged);
    _overlayService.onStateChanged = null;
    _recordingTimer?.cancel();
    _durationTimer?.cancel();
    _idleParkTimer?.cancel();
    _idleParkTimer = null;
    // Si quedó una grabación abierta, cerrarla para no perder metadata.
    _stopLocalRecordingIfAny();
    // ⚠️ IMPORTANTE: NO destruimos el engine Agora ni el foreground
    // service acá. El walkie page se desmonta al cambiar de tab (Mapa,
    // Chat, etc.) pero el conductor sigue queriendo escuchar la radio
    // mientras maneja. El engine sobrevive a cambios de tab y solo se
    // destruye en:
    //   - Toggle OFF del radio (RadioPowerService.turnOff →
    //     _onRadioPowerChanged → destroyEngine + stopService)
    //   - Logout (SessionTeardownService.disposeAll)
    //   - Usuario suspendido / paymentBlocked (router redirect → logout)
    //   - App killed (App-level dispose en main.dart)
    super.dispose();
  }

  /// Maneja cambios de ciclo de vida: destruye el engine Agora cuando la app
  /// va a segundo plano para liberar la sesión de audio del SO.
  /// Esto es CRÍTICO para que Android no reporte "en llamada" a otras apps.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // Si estaba grabando PTT, forzar stop. La app pasa a background
      // — el engine se mantiene VIVO para que el conductor siga
      // ESCUCHANDO la radio. CRÍTICO: tenemos que liberar el mic AHORA
      // si quedó tomado (caso edge: el conductor mete la app al
      // background con el dedo todavía sobre el botón PTT → el
      // GestureDetector no recibe el release y el mic queda activo en
      // background bloqueando a Zello/WhatsApp/etc).
      if (_isRecording) {
        _recordingTimer?.cancel();
        _durationTimer?.cancel();
        _isRecording = false;
        _recordingSeconds = 0;
        // Mute Agora inmediato (no esperar al bloc). Esto llama
        // enableLocalAudio(false) que libera el mic hardware a nivel del SO.
        _voice.muteMic().catchError((e) {
          debugPrint('Error muteMic al pasar a background: $e');
        });
        final commState = context.read<CommunicationBloc>().state;
        if (commState is CommunicationLoaded &&
            commState.activeChannelId != null) {
          final user = _currentUser;
          if (user != null) {
            context.read<CommunicationBloc>().add(
                  PttUnlockRequested(
                    channelId: commState.activeChannelId!,
                    userId: user.uid,
                  ),
                );
          }
        }
      }
      debugPrint('📱 WalkieTalkie: App en background → engine vivo, MIC LIBRE');
    } else if (state == AppLifecycleState.resumed) {
      // El engine no se destruyó, pero Android suele sacar el audio
      // focus mientras estamos en background. Al volver hay que pedirle
      // a Agora explícito que: (a) deje de mutear el remoto, (b) fuerce
      // speaker (no earpiece), (c) re-aplique el volumen amplificado.
      // Sin esto el conductor escucha mudo hasta togglear OFF/ON.
      debugPrint('📱 WalkieTalkie: App resumed → resumeAudioReceive');
      if (_radioPower.isOn) {
        // Si el SO tumbó la Room en background (Doze/throttling), `resumeAudioReceive`
        // operaría sobre una sala muerta y el conductor quedaría sin radio hasta
        // togglear OFF/ON. Primero RECONECTAMOS si ya no estamos en el canal, y
        // solo después restauramos audio/mic sobre una Room viva.
        if (!_voice.isInChannel) {
          debugPrint(
              '📱 WalkieTalkie: Room caída en background → reconectando');
          _voice.resumeFromPark().then((_) {
            _voice.resumeAudioReceive().catchError((e) {
              debugPrint('Error resumeAudioReceive (post-reconnect): $e');
            });
            _voice.ensureMicReady().catchError((e) {
              debugPrint('Error ensureMicReady (post-reconnect): $e');
            });
          }).catchError((e) {
            debugPrint('Error reconectando Room en resumed: $e');
          });
        } else {
          // La Room sigue viva: solo restaurar audio focus + mic.
          _voice.resumeAudioReceive().catchError((e) {
            debugPrint('Error resumeAudioReceive: $e');
          });
          // Si el usuario acaba de conceder el permiso de mic en Ajustes y el
          // engine había entrado al canal SIN mic, re-inicializarlo proactivamente
          // para que el primer PTT ya transmita (sin reiniciar la app).
          _voice.ensureMicReady().catchError((e) {
            debugPrint('Error ensureMicReady (resumed): $e');
          });
        }
      }
      // Reflejar el permiso recién cambiado en Ajustes (banner + gating PTT).
      _refreshMicPermission();
      if (mounted) setState(() {});
    }
  }

  /// Reacciona a cambios de conectividad: desconecta/reconecta Agora.
  void _onConnectivityChanged() {
    if (!mounted) return;
    final wasOffline = _isOffline;
    _refreshOfflineFlags();

    setState(() {});

    if (_isOffline && !wasOffline) {
      // ── Se perdió la red del SO ──
      // NO derribamos la Room: LiveKit se auto-reconecta solo con backoff
      // (Parte A). Un `leaveChannel()` por un flap de red mataba una sala
      // sana y obligaba a togglear OFF/ON. Aquí solo soltamos la UI local.
      //
      // Si había PTT en curso, NO dependemos de una escritura de unlock a
      // Firestore (no completará sin red y dejaría el lock colgado para
      // todos): liberamos la UI localmente y dejamos que el lock expire
      // solo (auto-expire ~35 s). _releasePttLocalOnly() hace muteMic +
      // limpia el estado de grabación SIN escribir a Firestore.
      if (_isRecording) {
        _releasePttLocalOnly();
      }
      // (Sin teardown de Room ni reset de _lastAgoraChannelId.)
    } else if (!_isOffline && wasOffline) {
      // ── Red del SO restaurada ──
      // La Room ya se auto-reconectó (o lo está haciendo). Solo aseguramos
      // el canal si por alguna razón ya no estamos en él, sin forzar un
      // re-join agresivo que pelee con la auto-reconexión interna.
      if (!_radioPower.isOn) return;
      if (_voice.isInChannel || _voice.isReconnecting) return;
      final currentState = context.read<CommunicationBloc>().state;
      if (currentState is CommunicationLoaded &&
          currentState.activeChannelId != null) {
        _lastAgoraChannelId = currentState.activeChannelId;
        _voice
            .joinChannel(currentState.activeChannelId!)
            .catchError((e) {
          debugPrint('Error rejoin tras reconexión: $e');
        });
      }
    }
  }

  /// Libera el PTT SOLO localmente (mute mic + limpia timers/UI) sin escribir
  /// el unlock a Firestore. Se usa cuando la red se cae con PTT en curso: una
  /// escritura de unlock no completaría sin red y dejaría el canal bloqueado
  /// para todos. El lock de Firestore expira solo (~35 s) sin bloquear a nadie.
  void _releasePttLocalOnly() {
    _pttCancelled = true;
    _voice.muteMic().catchError((_) {});
    _cleanupRecordingState();
  }

  /// Detecta cambios en el speaker del canal y graba/cierra el audio local
  /// para que quede en el historial de 24h re-escuchable.
  ///
  /// Reglas:
  /// - Speaker cambia de null/X → Y: cierra grabación X (si había) y arranca
  ///   grabación Y.
  /// - Speaker cambia de Y → null: cierra grabación Y.
  /// - Si el speaker es el propio usuario, también grabamos (para que pueda
  ///   re-escuchar lo que dijo).
  Future<void> _handleSpeakerChangeForRecording(
    CommunicationLoaded state,
    String? channelName,
  ) async {
    final channelId = state.activeChannelId;
    if (channelId == null) {
      // Sin canal: si había grabación, cerrarla.
      await _stopLocalRecordingIfAny();
      _lastSpeakerLockKey = null;
      return;
    }

    final speakerId = state.isPttLocked ? state.pttSpeakerId : null;
    final speakerName = state.pttSpeakerName ?? 'Conductor';
    final newKey = speakerId == null ? null : '$channelId|$speakerId';

    if (newKey == _lastSpeakerLockKey) return;

    // Speaker cambió. Cerrar la grabación anterior (si hay).
    await _stopLocalRecordingIfAny();
    _lastSpeakerLockKey = newKey;

    // Si hay un nuevo speaker, iniciar grabación local.
    if (speakerId == null || speakerId.isEmpty) return;
    if (!_radioPower.isOn || !_voice.isInChannel) return;
    final history = LocalAudioHistoryService.instance;
    final entryId =
        '${DateTime.now().millisecondsSinceEpoch}_${speakerId.substring(0, speakerId.length.clamp(0, 6))}';
    final filePath = await history.reservePath(entryId);
    // Si el que habla soy yo, grabar mi micrófono (lo que mandé); si es otro,
    // grabar el audio remoto (lo que oí). En Agora este flag se ignora (graba
    // la mezcla completa). Así el historial cubre ambas direcciones.
    final isMe = speakerId == _currentUser?.uid;
    final ok = await _voice.startLocalRecording(filePath, recordMic: isMe);
    if (!ok) return;
    _recordingEntryId = entryId;
    _recordingStartedAt = DateTime.now();
    await history.startEntry(
      id: entryId,
      channelId: channelId,
      channelName: channelName ?? '',
      speakerId: speakerId,
      speakerName: speakerName,
      startedAt: _recordingStartedAt!,
      filePath: filePath,
    );
  }

  Future<void> _stopLocalRecordingIfAny() async {
    final id = _recordingEntryId;
    final startedAt = _recordingStartedAt;
    _recordingEntryId = null;
    _recordingStartedAt = null;
    if (id == null) return;
    await _voice.stopLocalRecording();
    final dur = startedAt == null
        ? 0
        : DateTime.now().difference(startedAt).inSeconds;
    await LocalAudioHistoryService.instance
        .finalizeEntry(id, durationSec: dur);
    if (mounted) setState(() {}); // Refrescar la lista del historial
  }

  // ─────────── Auto-park por inactividad (ahorro de costos Agora) ───────────

  /// Arranca (si no está corriendo) el timer que monitorea inactividad
  /// del canal. Sólo tiene efecto cuando estamos en canal Agora con el
  /// radio ON — el `parkChannel()` requiere ambos.
  void _armIdleTimer() {
    if (_idleParkTimer != null) return;
    // El "park" por inactividad solo tiene sentido en proveedores que cobran
    // por minuto (Agora). En LiveKit (self-hosted, conexión persistente)
    // parkChannel es no-op → el timer solo generaba spam cada 5s y gastaba
    // datos de logs. No lo armamos si el proveedor no soporta park.
    if (!_voice.supportsPark) return;
    _lastChannelActivityAt ??= DateTime.now();
    _idleParkTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (!_radioPower.isOn) return;
      if (_isOffline) return;
      if (_isRecording) return; // estoy hablando, claramente activo
      if (!_voice.isInChannel) return;
      // Si hay alguien hablando ahora mismo, refrescá la marca y salí.
      final commState = context.read<CommunicationBloc>().state;
      if (commState is CommunicationLoaded && commState.isPttLocked) {
        _lastChannelActivityAt = DateTime.now();
        return;
      }
      final last = _lastChannelActivityAt;
      if (last == null) {
        _lastChannelActivityAt = DateTime.now();
        return;
      }
      final idleSec = DateTime.now().difference(last).inSeconds;
      if (idleSec >= _idleParkAfterSeconds) {
        debugPrint(
            '🅿️ WalkieTalkie: $idleSec s sin speaker → parkChannel()');
        _voice.parkChannel().catchError((e) {
          debugPrint('Error parkChannel: $e');
        });
      }
    });
  }

  void _disarmIdleTimer() {
    _idleParkTimer?.cancel();
    _idleParkTimer = null;
    _lastChannelActivityAt = null;
  }

  /// Reacciona al toggle ON/OFF del walkie-talkie.
  ///
  /// - ON  → inicializa Agora, se une al canal activo (si hay), arranca el
  ///         foreground service.
  /// - OFF → libera mic 100%: destruye engine Agora, sale del canal, detiene
  ///         el foreground service. El SO ya no marca la app como "usando mic".
  Future<void> _onRadioPowerChanged() async {
    if (!mounted) return;
    if (_radioPower.isOn) {
      // ── ENCENDER ──
      // Capturar canal ANTES del primer await para evitar usar context tras gap
      String? channelToJoin;
      String? channelName;
      final commState = context.read<CommunicationBloc>().state;
      if (commState is CommunicationLoaded &&
          commState.activeChannelId != null &&
          !_isOffline) {
        channelToJoin = commState.activeChannelId;
        channelName = commState.activeChannel?.name;
      }
      try {
        await _voice.initialize();
        if (channelToJoin != null) {
          _lastAgoraChannelId = channelToJoin;
          await _voice.joinChannel(channelToJoin);
          if (channelName != null && !_radioService.isRunning) {
            await _radioService.startService(channelName);
          }
          // Empezar a monitorear inactividad del canal para auto-park.
          _armIdleTimer();
        }
      } catch (e) {
        debugPrint('Error encendiendo radio: $e');
      }
    } else {
      // ── APAGAR ──
      // Si está grabando PTT, detenerlo (lectura de bloc antes de awaits)
      if (_isRecording) {
        final currentState = context.read<CommunicationBloc>().state;
        if (currentState is CommunicationLoaded) {
          _stopPtt(currentState);
        }
      }
      // Frenar el monitor de inactividad antes de destruir el engine.
      _disarmIdleTimer();
      // Salir de Agora y destruir engine — libera mic hardware
      await _voice.destroyEngine();
      _lastAgoraChannelId = null;
      // Detener foreground service — libera el "tag" de microphone del SO
      await _radioService.stopService();
    }
    if (mounted) setState(() {});
  }

  /// Reacciona a cambios del estado online/offline del conductor
  /// (cuando el conductor elige "Desconectado" desde el diálogo de status).
  void _onDriverLocationChanged() {
    if (!mounted) return;
    final wasOffline = _isOffline;
    _refreshOfflineFlags();

    setState(() {});

    if (_isOffline && !wasOffline) {
      // ── Conductor pasó a modo Desconectado ──
      debugPrint('📻 WalkieTalkie: Conductor OFFLINE → desconectando Agora');
      if (_isRecording) {
        final currentState = context.read<CommunicationBloc>().state;
        if (currentState is CommunicationLoaded) {
          _stopPtt(currentState);
        }
      }
      _voice.leaveChannel().catchError((_) {});
      _lastAgoraChannelId = null;
    } else if (!_isOffline && wasOffline) {
      // ── Conductor volvió a estar online ──
      // Reconectar Agora SOLO si el radio está ON.
      if (!_radioPower.isOn) return;
      debugPrint('📻 WalkieTalkie: Conductor ONLINE → reconectando Agora');
      final currentState = context.read<CommunicationBloc>().state;
      if (currentState is CommunicationLoaded &&
          currentState.activeChannelId != null) {
        _lastAgoraChannelId = currentState.activeChannelId;
        _voice
            .joinChannel(currentState.activeChannelId!)
            .catchError((e) {
          debugPrint('Error Agora rejoin tras conductor online: $e');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<CommunicationBloc, CommunicationState>(
      listener: (context, state) {
        if (state is CommunicationError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: AppTheme.errorColor,
            ),
          );
        }
        if (state is CommunicationLoaded && state.pttLockDenied) {
          // Sólo disparar feedback en la transición false→true.
          // pttLockDenied queda sticky hasta el próximo update del stream.
          if (!_lastDeniedSeen) {
            _lastDeniedSeen = true;
            // Denial chirp Motorola — dos pips graves en 500 Hz.
            // Vibración fuerte como feedback paralelo (importante en
            // ambientes ruidosos donde no se oye el audio).
            HapticFeedback.heavyImpact();
            PttBeepService.instance.playDenied();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '${state.pttSpeakerName ?? "Alguien"} está hablando. Espera tu turno.',
                ),
                backgroundColor: AppTheme.warningColor,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        } else {
          // Reset el guard cuando ya no estamos en denied — la próxima
          // denegación volverá a tocar el beep.
          _lastDeniedSeen = false;
        }
        // === Pre-warm token Agora ===
        // Apenas el usuario selecciona un canal (radio aún apagado),
        // disparamos el fetch del token en background. Cuando luego
        // pulse "Encender", el token ya estará en cache → encendido
        // sin esperar la red.
        if (state is CommunicationLoaded &&
            state.activeChannelId != null &&
            !_radioPower.isOn) {
          _voice.prewarmToken(state.activeChannelId!);
        }
        // === Auto-reconexión al reabrir (comportamiento Zello) ===
        // Si el radio quedó ENCENDIDO de una sesión previa, al cargar los
        // canales seleccionamos el último para que el audio reconecte solo.
        // SEGURIDAD: `isOn` aquí solo es true si `restoreForUser(uid)` lo
        // restauró para ESTE conductor (no hereda entre usuarios). Por eso ya
        // no aplica el viejo "arranca siempre OFF": ahora persiste por uid.
        if (state is CommunicationLoaded &&
            _radioPower.isOn &&
            state.activeChannelId == null &&
            _radioPower.lastChannelId != null &&
            !_isOffline) {
          final exists = state.channels
              .any((c) => c.uid == _radioPower.lastChannelId);
          if (exists) {
            context.read<CommunicationBloc>().add(
                  ChannelSelected(_radioPower.lastChannelId),
                );
          }
        }
        // === Foreground service: mantener radio en segundo plano ===
        // Sólo si el radio está ENCENDIDO. Si está OFF, NO conectamos a
        // Agora ni arrancamos el foreground service "microphone" — eso es
        // lo que hacía que otras apps vieran el mic ocupado.
        if (state is CommunicationLoaded && _radioPower.isOn) {
          final channelName = state.activeChannel?.name;
          final channelId = state.activeChannelId;

          // === Agora: unirse/salir del canal de audio en tiempo real ===
          if (channelId != null && channelId != _lastAgoraChannelId) {
            _lastAgoraChannelId = channelId;
            // Persistir el canal para poder reanudar tras kill del isolate.
            _radioPower.setLastChannel(channelId, channelName);
            _voice.joinChannel(channelId).catchError((e) {
              debugPrint('Error Agora joinChannel: $e');
            });
            _armIdleTimer();
          } else if (channelId == null && _lastAgoraChannelId != null) {
            _lastAgoraChannelId = null;
            _disarmIdleTimer();
            _voice.leaveChannel().catchError((e) {
              debugPrint('Error Agora leaveChannel: $e');
            });
          }

          // === Auto-resume desde park / reconexión ===
          // Dos casos en que necesitamos reconectar antes de poder escuchar a
          // quien empezó a hablar:
          //  - Agora: el canal estaba "parked" por inactividad (isParked=true).
          //  - LiveKit: park es no-op (isParked SIEMPRE false), pero el SO pudo
          //    tumbar la Room en background → !isInChannel. Sin incluir este
          //    caso, el conductor no oía la transmisión hasta togglear OFF/ON.
          // resumeFromPark() es idempotente y reconecta al último canal conocido.
          if (state.isPttLocked &&
              (_voice.isParked || !_voice.isInChannel) &&
              !_isOffline) {
            _voice.resumeFromPark().catchError((e) {
              debugPrint('Error resumeFromPark: $e');
              return false;
            });
          }
          // Refrescar la marca de actividad cada vez que vemos a alguien
          // hablando → el timer de inactividad no nos sacará en medio
          // de una conversación.
          if (state.isPttLocked) {
            _lastChannelActivityAt = DateTime.now();
          }

          if (channelName != null) {
            // Iniciar o actualizar el servicio de segundo plano
            if (!_radioService.isRunning) {
              _radioService.startService(channelName);
            }
            // Actualizar notificación según estado PTT
            if (state.isPttLocked && state.pttSpeakerName != null) {
              _radioService.showSpeaking(channelName, state.pttSpeakerName!);
            } else {
              _radioService.showListening(channelName);
            }
          } else if (_radioService.isRunning) {
            // No hay canal activo, detener servicio
            _radioService.stopService();
          }

          // === Grabación local 24h: detectar cambio de speaker ===
          _handleSpeakerChangeForRecording(state, channelName);
        }
      },
      builder: (context, state) {
        if (state is CommunicationLoading) {
          return const LoadingState(message: 'Conectando al radio...');
        }

        if (state is! CommunicationLoaded) {
          return const EmptyState(
            icon: Icons.wifi_off,
            title: 'Conectando al radio...',
          );
        }

        // Recalcular en cada rebuild el estado "Reconectando…" leyendo los
        // getters LIVE del provider (isReconnecting/isInChannel). El bloc
        // reconstruye con frecuencia (snapshots Firestore), así el banner y el
        // label del PTT reflejan la auto-reconexión sin un listener extra.
        // Asignación simple (sin setState) — seguro durante build.
        _isRadioReconnecting = !_isOffline &&
            _radioPower.isOn &&
            _voice.isReconnecting &&
            !_voice.isInChannel;

        return Column(
          children: [
            // Banner de permiso de micrófono — PRIORIDAD sobre "Sin conexión":
            // sin mic no se puede transmitir, es el bloqueo real para hablar.
            if (_micPermissionMissing)
              _buildMicPermissionBanner()
            // Banner de sin conexión dentro del walkie-talkie
            else if (_isOffline)
              _buildOfflineBanner()
            // Reconectando: hay red del SO pero la Room se está
            // reestableciendo (auto-reconexión LiveKit). Distinto de "Sin
            // red" — no bloquea, solo informa.
            else if (_isRadioReconnecting)
              _buildReconnectingBanner(),
            _buildPowerToggle(state),
            _buildChannelSelector(state),
            // Cola de unidades cerca de la parada — clave para coordinar
            // despacho estilo cooperativa.
            const StandQueueBar(),
            // Banner "Estás hablando…" / "X está hablando…". Para MÍ se ata a
            // _isRecording (estado local) — así no queda colgado si el unlock
            // a Firestore no completa sin red (el lock expira solo ~35 s).
            // Para OTROS speakers seguimos con el lock de Firestore (bloc).
            if (_radioPower.isOn && _shouldShowSpeakerBanner(state))
              _buildSpeakerBanner(state),
            // El botón PTT ocupa todo el espacio disponible. El historial
            // vive en el tab "Chat".
            Expanded(child: _buildAudioControls(state)),
          ],
        );
      },
    );
  }

  /// Toggle ON/OFF prominente del walkie-talkie.
  ///
  /// Cuando OFF: el mic queda libre para otras apps (Zello, WhatsApp, etc.).
  /// Cuando ON: la app se conecta al canal seleccionado y empieza a escuchar.
  Widget _buildPowerToggle(CommunicationLoaded state) {
    final isOn = _radioPower.isOn;
    final hasChannel = state.activeChannelId != null;
    final channelName = state.activeChannel?.name;

    final primary = Theme.of(context).colorScheme.primary;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: isOn
            ? primary.withValues(alpha: 0.08)
            : Colors.grey.shade100,
        border: Border(
          bottom: BorderSide(
            color: isOn
                ? primary.withValues(alpha: 0.3)
                : Colors.grey.shade300,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isOn ? Icons.radio : Icons.power_settings_new,
            color: isOn ? primary : Colors.grey.shade500,
            size: 28,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isOn ? 'Radio encendido' : 'Radio apagado',
                  style: textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isOn ? primary : Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isOn
                      ? (hasChannel
                          ? 'Conectado a: ${channelName ?? "..."}'
                          : 'Selecciona un canal abajo')
                      : 'Micrófono libre — otras apps pueden usarlo',
                  style: textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Volumen del radio',
            icon: Icon(
              Icons.volume_up,
              color: isOn ? primary : Colors.grey.shade500,
            ),
            onPressed: _showVolumeDialog,
          ),
          Switch.adaptive(
            value: isOn,
            activeThumbColor: primary,
            onChanged: _isOffline && !isOn
                ? null
                : (v) async {
                    HapticFeedback.selectionClick();
                    if (v) {
                      // Encendido manual: si el bloc todavía no tiene
                      // canal activo pero recordamos el último, lo
                      // seleccionamos para que el ON conecte al canal
                      // por defecto. Esto es interactivo (no sucede
                      // sin que el user toque el switch).
                      final s = context.read<CommunicationBloc>().state;
                      String? cid;
                      String? cname;
                      if (s is CommunicationLoaded) {
                        cid = s.activeChannelId;
                        cname = s.activeChannel?.name;
                        if (cid == null && _radioPower.lastChannelId != null) {
                          final exists = s.channels.any(
                              (c) => c.uid == _radioPower.lastChannelId);
                          if (exists) {
                            context.read<CommunicationBloc>().add(
                                  ChannelSelected(_radioPower.lastChannelId),
                                );
                            cid = _radioPower.lastChannelId;
                            cname = _radioPower.lastChannelName;
                          }
                        }
                      }
                      await _radioPower.turnOn(
                        channelId: cid,
                        channelName: cname,
                      );
                    } else {
                      await _radioPower.turnOff();
                    }
                  },
          ),
        ],
      ),
    );
  }

  /// Diálogo con slider de volumen amplificable (100-400).
  /// 100 = 1x (volumen normal), 400 = 4x (amplificado al máximo).
  /// El cambio es inmediato sobre el engine Agora y se persiste para
  /// cold-starts futuros.
  Future<void> _showVolumeDialog() async {
    int current = _voice.playbackVolume;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final pct = ((current - AgoraService.playbackVolumeMin) /
                    (AgoraService.playbackVolumeMax -
                        AgoraService.playbackVolumeMin) *
                    100)
                .round();
            final primary = Theme.of(ctx).colorScheme.primary;
            final textTheme = Theme.of(ctx).textTheme;
            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.volume_up, color: primary),
                  const SizedBox(width: AppSpacing.sm),
                  const Text('Volumen del radio'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ganancia: ${(current / 100).toStringAsFixed(1)}x  ·  $pct%',
                    style: textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    current <= 100
                        ? 'Volumen normal'
                        : current <= 200
                            ? 'Amplificado moderado'
                            : current <= 300
                                ? 'Amplificado fuerte'
                                : 'Amplificado al máximo',
                    style: textTheme.bodySmall?.copyWith(
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Slider(
                    value: current.toDouble(),
                    min: AgoraService.playbackVolumeMin.toDouble(),
                    max: AgoraService.playbackVolumeMax.toDouble(),
                    divisions: (AgoraService.playbackVolumeMax -
                            AgoraService.playbackVolumeMin) ~/
                        10,
                    label: '${current ~/ 1}',
                    activeColor: primary,
                    onChanged: (v) {
                      setLocal(() => current = v.round());
                      // Aplicar EN VIVO: si alguien está hablando, el cambio
                      // de volumen se oye al instante mientras arrastras.
                      _voice.setPlaybackVolume(current);
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('1x',
                          style: textTheme.labelSmall
                              ?.copyWith(color: Colors.grey.shade600)),
                      Text('4x',
                          style: textTheme.labelSmall
                              ?.copyWith(color: Colors.grey.shade600)),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Sube el volumen del altavoz del celular al máximo '
                    'antes de amplificar acá. Valores >300 pueden saturar '
                    'la voz en bocinas pequeñas.',
                    style: textTheme.labelSmall?.copyWith(
                      color: Colors.grey.shade600,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final navigator = Navigator.of(ctx);
                    await _voice.setPlaybackVolume(current);
                    if (!mounted) return;
                    navigator.pop();
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                            'Volumen: ${(current / 100).toStringAsFixed(1)}x'),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  child: const Text('Aplicar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Banner accionable cuando falta el permiso de micrófono. Tiene prioridad
  /// visual sobre el banner de "Sin conexión" porque el mic es el bloqueo real
  /// para hablar. Al tocar → pide el permiso (o abre Ajustes si está denegado
  /// permanentemente). Reusa el estilo del banner offline.
  Widget _buildMicPermissionBanner() {
    return GestureDetector(
      onTap: _requestMicPermission,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.sm, horizontal: AppSpacing.lg),
        color: AppTheme.errorColor,
        child: Row(
          children: [
            const Icon(Icons.mic_off_rounded, color: Colors.white, size: 20),
            const SizedBox(width: AppSpacing.sm),
            const Expanded(
              child: Text(
                'Falta permiso de micrófono · toca para conceder',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white70, size: 20),
          ],
        ),
      ),
    );
  }

  /// Banner de sin conexión / modo desconectado en el walkie-talkie.
  Widget _buildOfflineBanner() {
    final bool noInternet = !_connectivity.isConnected;
    final String message = _isDriverOffline && !noInternet
        ? 'Modo Desconectado · Radio deshabilitado'
        : 'Sin conexión · Radio deshabilitado';
    final IconData icon = _isDriverOffline && !noInternet
        ? Icons.power_settings_new
        : Icons.wifi_off_rounded;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          vertical: AppSpacing.sm, horizontal: AppSpacing.lg),
      color: _isDriverOffline && !noInternet
          ? AppTheme.warningColor
          : AppTheme.errorColor,
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          if (noInternet)
            GestureDetector(
              onTap: () => _connectivity.retry(),
              child: const Icon(Icons.refresh, color: Colors.white70, size: 20),
            ),
        ],
      ),
    );
  }

  /// Banner "Reconectando…" — hay red del SO pero la Room LiveKit se está
  /// reestableciendo sola (backoff interno). NO es "sin conexión": no
  /// deshabilitamos el radio, solo informamos que se resuelve solo.
  Widget _buildReconnectingBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      color: Colors.blueGrey.shade700,
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Reconectando al canal…',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Decide si mostrar el banner de "alguien está hablando".
  ///
  /// - Si YO estoy transmitiendo (_isRecording local), mostrar siempre —
  ///   independiente del lock de Firestore (que puede no haberse escrito aún
  ///   o no haberse liberado por falta de red).
  /// - Si OTRO tiene el lock en Firestore, mostrar (estado del bloc).
  bool _shouldShowSpeakerBanner(CommunicationLoaded state) {
    if (_isRecording) return true;
    final user = _currentUser;
    final lockedByOther = state.isPttLocked && state.pttSpeakerId != user?.uid;
    return lockedByOther;
  }

  /// Banner que muestra quién está hablando (estilo Zello)
  Widget _buildSpeakerBanner(CommunicationLoaded state) {
    final user = _currentUser;
    // "Soy yo el hablante" se decide por el estado LOCAL de grabación, no por
    // el lock de Firestore — así el banner verde aparece/desaparece con mi PTT
    // real y no queda pegado si el unlock no llegó a Firestore (sin red).
    final isMe = _isRecording || state.pttSpeakerId == user?.uid;
    final isModerator = user != null &&
        (user.role == AppConstants.roleAdmin ||
            user.role == AppConstants.roleOperator);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          vertical: AppSpacing.sm, horizontal: AppSpacing.lg),
      color: isMe ? AppTheme.successColor : AppTheme.warningColor,
      child: Row(
        children: [
          const Icon(
            Icons.mic,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              isMe
                  ? 'Estás hablando...'
                  : '${state.pttSpeakerName ?? "Alguien"} está hablando...',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          // Botón "Liberar" para admin/operadora cuando OTRO tiene el
          // PTT. Cubre el caso "dedo pegado / botón atascado" — desbloquea
          // el canal para todos sin esperar el timeout de 35s.
          if (!isMe && isModerator && state.activeChannelId != null)
            TextButton.icon(
              onPressed: () => _confirmForceUnlock(state),
              icon: const Icon(Icons.lock_open,
                  color: Colors.white, size: 16),
              label: const Text(
                'Liberar',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            )
          else if (!isMe)
            const Icon(Icons.lock, color: Colors.white, size: 16),
        ],
      ),
    );
  }

  Future<void> _confirmForceUnlock(CommunicationLoaded state) async {
    final user = _currentUser;
    if (user == null || state.activeChannelId == null) return;
    final speakerName = state.pttSpeakerName ?? 'Alguien';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Liberar micrófono'),
        content: Text(
            '¿Forzar el corte de la transmisión de $speakerName? Úsalo si su PTT quedó pegado.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Liberar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    context.read<CommunicationBloc>().add(
          PttUnlockRequested(
            channelId: state.activeChannelId!,
            userId: user.uid,
            force: true,
          ),
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Micrófono liberado ($speakerName)'),
        backgroundColor: AppTheme.successColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildChannelSelector(CommunicationLoaded state) {
    final user = _currentUser;
    if (user == null) return const SizedBox(height: 56);
    final role = user.role;
    final canManage = role == AppConstants.roleAdmin ||
        role == AppConstants.roleOperator;

    // Filtro: el conductor solo ve los canales públicos + privados donde
    // está en memberIds. Admin/operadora ven todos.
    final visibleChannels = canManage
        ? state.channels
        : state.channels
            .where((c) => c.isAccessibleBy(userId: user.uid, role: role))
            .toList();

    // Empty state crítico: el conductor no tiene NINGÚN canal visible.
    // Sin esto, solo veía un PTT gris y no entendía por qué.
    if (!canManage && state.channels.isNotEmpty && visibleChannels.isEmpty) {
      return Container(
        height: 56,
        color: AppTheme.warningColor.withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.xs + 2),
        child: Row(
          children: [
            const Icon(Icons.info_outline,
                color: AppTheme.warningColor, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                'No tienes canales asignados. Pídele al admin que te '
                'agregue al canal de la cooperativa.',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppTheme.warningColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Ordenar: default-para-mi-rol primero, luego públicos, luego privados.
    visibleChannels.sort((a, b) {
      final aIsDef = a.isDefaultForRole(role) ? 0 : 1;
      final bIsDef = b.isDefaultForRole(role) ? 0 : 1;
      if (aIsDef != bIsDef) return aIsDef.compareTo(bIsDef);
      final aType = a.type == 'publico' ? 0 : 1;
      final bType = b.type == 'publico' ? 0 : 1;
      if (aType != bType) return aType.compareTo(bType);
      return a.name.compareTo(b.name);
    });

    // Auto-select del default si todavía no hay canal activo y existe un
    // default para el rol (o solo hay 1 canal visible).
    if (state.activeChannelId == null && visibleChannels.isNotEmpty) {
      ChannelModel? toSelect;
      try {
        toSelect = visibleChannels.firstWhere(
          (c) => c.isDefaultForRole(role),
        );
      } catch (_) {
        // Sin default: solo auto-seleccionamos si hay exactamente 1 canal,
        // así el conductor siempre tiene uno listo sin click extra.
        if (visibleChannels.length == 1) toSelect = visibleChannels.first;
      }
      if (toSelect != null) {
        final channelToJoin = toSelect.uid;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            context.read<CommunicationBloc>().add(
                  ChannelSelected(channelToJoin),
                );
          }
        });
      }
    }

    final itemCount = visibleChannels.length + (canManage ? 1 : 0);
    final hasMultiple = visibleChannels.length > 1;

    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      height: 56,
      color: Theme.of(context).colorScheme.secondary,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (canManage && index == visibleChannels.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: ActionChip(
                avatar: Icon(Icons.add, size: 18, color: primary),
                label: Text(
                  'Nuevo',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: primary, fontWeight: FontWeight.w600),
                ),
                backgroundColor: Colors.white,
                side: BorderSide(color: primary.withValues(alpha: 0.4)),
                onPressed: () => _showCreateChannelDialog(),
              ),
            );
          }

          final channel = visibleChannels[index];
          final isSelected = channel.uid == state.activeChannelId;
          final isLockedNow =
              channel.isLocked && !channel.isLockExpired;
          // Titilar: alguien está hablando, NO es el canal activo, y el
          // usuario tiene >1 canal visible (si es uno solo, no aplica).
          final shouldBlink = isLockedNow && !isSelected && hasMultiple;
          final isDefault = channel.isDefaultForRole(role);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onLongPress: canManage
                  ? () => _showChannelManageSheet(channel)
                  : null,
              child: _BlinkingChannelChip(
                blink: shouldBlink,
                child: ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (channel.type == 'privado')
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Icon(Icons.lock, size: 14),
                        ),
                      Text(channel.name,
                          style: const TextStyle(fontSize: 12)),
                      if (isDefault)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.star,
                              size: 12, color: Colors.amber),
                        ),
                      if (isLockedNow)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.mic,
                              size: 14, color: Colors.red),
                        ),
                      // ⚙️ visible solo para admin/op: abre directo el
                      // sheet completo de configuración (miembros +
                      // default por rol). Antes solo se llegaba con
                      // long-press, lo cual no era descubrible.
                      if (canManage) ...[
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: () {
                            final user = _currentUser;
                            if (user == null) return;
                            showChannelSettingsSheet(
                              context,
                              channel: channel,
                              aid: user.associationId,
                            );
                          },
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              Icons.settings,
                              size: 14,
                              color: isSelected ? Colors.white : primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  selected: isSelected,
                  selectedColor: primary,
                  onSelected: (selected) {
                    context.read<CommunicationBloc>().add(
                          ChannelSelected(selected ? channel.uid : null),
                        );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAudioControls(CommunicationLoaded state) {
    final user = _currentUser;
    final hasChannel = state.activeChannelId != null;
    final isOn = _radioPower.isOn;
    final isLockedByOther = state.isPttLocked &&
        state.pttSpeakerId != user?.uid;
    // Radio usable = hay red del SO (no _isOffline) Y la Room está conectada
    // (isInChannel) O reconectándose (isReconnecting). Permitimos PTT durante
    // la reconexión porque _startPtt ya tiene el camino de resume+grace
    // (espera a estar en canal antes de soltar el unmuteMic) — no bloqueamos
    // agresivamente; la auto-reconexión de LiveKit resuelve. Agora devuelve
    // isInChannel=true/isReconnecting=false → su comportamiento no cambia.
    final radioReachable = _voice.isInChannel || _voice.isReconnecting;
    final canPtt = isOn &&
        hasChannel &&
        !isLockedByOther &&
        !_isOffline &&
        radioReachable &&
        !_overlayService.isActive;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        // Reserva ~64 px para la fila de íconos secundarios + spacing.
        // El resto es para el botón PTT, que escala como círculo cuyo
        // diámetro = min(ancho disponible, alto disponible para PTT).
        const reservedForActions = 64.0;
        final maxPttSize = (constraints.maxHeight - reservedForActions)
            .clamp(180.0, double.infinity);
        final pttIdle =
            maxPttSize.clamp(220.0, constraints.maxWidth - 16).toDouble();
        final pttActive =
            (pttIdle * 1.10).clamp(0.0, constraints.maxWidth).toDouble();
        final iconSize = pttIdle * 0.42;
      return Column(
        mainAxisSize: MainAxisSize.max,
        children: [
          // PTT button grande estilo Zello — centrado, ocupa el espacio.
          Expanded(
            child: Center(
              child:
          // PTT (Push-to-Talk) Button — Zello style
          // Uses Listener instead of GestureDetector for INSTANT response
          // (0ms delay vs ~500ms long-press delay).
          Listener(
            onPointerDown: canPtt
                ? (_) => _startPtt(state)
                : !isOn
                    ? (_) => _turnOnFromBigButton()
                    : _isOffline
                        ? (_) => _showOfflineWarning()
                        : _isRadioReconnecting
                            ? (_) => _showReconnectingWarning()
                            : null,
            onPointerUp: hasChannel
                ? (_) => _stopPttSafe(state)
                : null,
            onPointerCancel: hasChannel
                ? (_) => _stopPttSafe(state)
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: _isRecording ? pttActive : pttIdle,
              height: _isRecording ? pttActive : pttIdle,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: !isOn
                      ? [Colors.grey[300]!, Colors.grey[400]!]
                      : !hasChannel || _isOffline
                          ? [Colors.grey[400]!, Colors.grey[500]!]
                          : _overlayService.isActive
                              ? [Colors.teal[600]!, Colors.teal[700]!]
                              : isLockedByOther
                                  ? [Colors.grey[600]!, Colors.grey[700]!]
                                  : _isRecording
                                      ? [AppTheme.errorColor, AppTheme.errorColor.withValues(alpha: 0.8)]
                                      : [AppTheme.primaryColor, AppTheme.primaryColor.withValues(alpha: 0.85)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: (_isRecording
                            ? AppTheme.errorColor
                            : AppTheme.primaryColor)
                        .withValues(alpha: _isRecording ? 0.6 : 0.3),
                    blurRadius: _isRecording ? 30 : 12,
                    spreadRadius: _isRecording ? 8 : 2,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    !isOn
                        ? Icons.power_settings_new
                        : _isOffline
                            ? Icons.wifi_off_rounded
                            : _overlayService.isActive
                                ? Icons.surround_sound
                                : isLockedByOther
                                    ? Icons.lock
                                    : _isRecording
                                        ? Icons.mic
                                        : Icons.mic_none,
                    color: !isOn || isLockedByOther
                        ? Colors.white70
                        : Colors.white,
                    size: iconSize,
                  ),
                  const SizedBox(height: 4),
                  if (!isOn)
                    const Text(
                      'Tocar para encender',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  else if (_overlayService.isActive)
                    const Text(
                      'PTT Flotante',
                      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
                    )
                  else if (_isOffline)
                    const Text(
                      'Sin red',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    )
                  else if (_isRadioReconnecting && !_isRecording)
                    const Text(
                      'Reconectando…',
                      style: TextStyle(color: Colors.white, fontSize: 11),
                    )
                  else if (isLockedByOther)
                    const Text(
                      'Ocupado',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    )
                  else if (_isRecording)
                    Text(
                      '${_recordingSeconds}s',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  else
                    const Text(
                      'Mantener',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),
          ),
            ),
          ),
          const SizedBox(height: 8),
          // Botones secundarios debajo
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Mute button — silenciar audio remoto (Agora)
              IconButton(
                onPressed: () {
                  setState(() => _isMuted = !_isMuted);
                  _voice.setRemoteAudioMuted(_isMuted);
                },
                icon: Icon(
                  _isMuted ? Icons.volume_off : Icons.volume_up,
                  color: _isMuted
                      ? AppTheme.errorColor
                      : Theme.of(context).colorScheme.secondary,
                ),
                iconSize: 28,
              ),
              // Overlay PTT — botón flotante sobre todas las apps
              IconButton(
                onPressed: hasChannel
                    ? () => _toggleOverlay(state)
                    : null,
                icon: Icon(
                  _overlayService.isActive
                      ? Icons.stop_circle_outlined
                      : Icons.surround_sound,
                  color: _overlayService.isActive
                      ? AppTheme.errorColor
                      : hasChannel
                          ? Theme.of(context).colorScheme.secondary
                          : Colors.grey,
                ),
                iconSize: 28,
                tooltip: _overlayService.isActive
                    ? 'Desactivar PTT flotante'
                    : 'Activar PTT flotante',
              ),
              // El botón de "enviar texto" se removió de aquí — el chat
              // 1-a-1 vive en el tab "Chat" del bottom nav. Ganamos espacio
              // para que el botón PTT principal sea más prominente.
              // Asignar carrera — operadora Y admin (en grupos chicos el
              // admin también opera el radio).
              if (user?.role == AppConstants.roleOperator ||
                  user?.role == AppConstants.roleAdmin) ...[
                // Carrera rápida (calle): 1-2 toques, solo # unidad +
                // opcional código cliente. Para contar clientes
                // direccionados por la operadora a las unidades.
                IconButton(
                  onPressed: !_isOffline
                      ? () => showQuickStreetAssignModal(context)
                      : () => _showOfflineWarning(),
                  icon: Icon(
                    Icons.bolt,
                    color: !_isOffline
                        ? Colors.amber.shade700
                        : Colors.grey,
                  ),
                  iconSize: 32,
                  tooltip: 'Carrera rápida (calle)',
                ),
                // Asignar carrera con detalles (cliente, dirección, notas).
                IconButton(
                  onPressed: !_isOffline
                      ? () => showAssignTripModal(context)
                      : () => _showOfflineWarning(),
                  icon: Icon(
                    Icons.assignment_ind,
                    color: !_isOffline
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey,
                  ),
                  iconSize: 32,
                  tooltip: 'Asignar carrera con datos',
                ),
              ],
            ],
          ),
        ],
      );
      }),
    );
  }

  // === PTT Actions ===

  /// Guard anti doble-toque: mientras un toggle de overlay está en curso,
  /// ignoramos toques subsecuentes. Sin esto, un segundo toque durante el
  /// delay activaba y luego cerraba el overlay (flip-flop reportado en logs:
  /// "Overlay iniciado" seguido ~4s después de "Overlay cerrado").
  bool _overlayBusy = false;

  /// Activa/desactiva el botón PTT flotante (wrapper con debounce).
  Future<void> _toggleOverlay(CommunicationLoaded state) async {
    if (_overlayBusy) {
      debugPrint('[Overlay] toggle ignorado — ya hay uno en curso (debounce)');
      return;
    }
    _overlayBusy = true;
    try {
      await _doToggleOverlay(state);
    } finally {
      _overlayBusy = false;
    }
  }

  /// Cuerpo real del toggle del overlay.
  ///
  /// Con timeout para evitar que la UI quede colgada si stop()/start()
  /// del overlay se traban (typical en Android 14+ con Doze mode).
  ///
  /// Reuso de conexión: si el provider mantiene conexión persistente
  /// (LiveKit, `hasPersistentConnection`), NO destruimos+reunimos el engine
  /// al activar/desactivar — la Room ya conectada se reusa → activación
  /// instantánea y el radio de la app sigue vivo al cerrar el overlay. Solo
  /// los providers efímeros (Agora) hacen el ciclo destroy/rejoin clásico.
  Future<void> _doToggleOverlay(CommunicationLoaded state) async {
    final persistent = _voice.hasPersistentConnection;
    if (_overlayService.isActive) {
      // ── Desactivar overlay ──
      // Timeout de 4s — si stop se cuelga, forzamos el flag local para que
      // la UI vuelva a mostrar el icono "activar".
      try {
        await _overlayService.stop().timeout(const Duration(seconds: 4));
      } catch (e) {
        debugPrint('Overlay stop colgado: $e — forzando reset');
      }
      // Re-inicializar engine para uso en esta página SOLO si el provider es
      // efímero (Agora destruyó el engine en stop()). Con conexión persistente
      // (LiveKit) la Room sigue conectada → no hay nada que reinicializar.
      if (!persistent) {
        try {
          await _voice.initialize();
          if (state.activeChannelId != null) {
            _lastAgoraChannelId = state.activeChannelId;
            await _voice.joinChannel(state.activeChannelId!);
          }
        } catch (e) {
          debugPrint('Error re-init voice tras stop overlay: $e');
        }
      }
      if (mounted) setState(() {});
      return;
    }

    // ── Activar overlay ──
    if (state.activeChannelId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Selecciona un canal primero'),
            backgroundColor: AppTheme.warningColor,
          ),
        );
      }
      return;
    }

    // Verificar permiso de overlay
    final hasPermission = await _overlayService.hasPermission();
    if (!hasPermission) {
      // Solicitar permiso (abre configuración de Android)
      await _overlayService.requestPermission();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Activa "Mostrar sobre otras apps" para ${AppConstants.appName} y vuelve.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }

    // Destruir engine actual SOLO para providers efímeros (Agora): el overlay
    // gestiona su propio ciclo y re-une desde cero. Con conexión persistente
    // (LiveKit) NO destruimos — el overlay reusa la Room ya conectada, lo que
    // hace la activación instantánea (sin rejoin de ~2s).
    if (!persistent) {
      await _voice.destroyEngine();
      _lastAgoraChannelId = null;
    }

    // Iniciar overlay (conecta/reusa el canal automáticamente según provider)
    final started = await _overlayService.start(state.activeChannelId!);
    if (!mounted) return;
    if (started) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '🎙️ PTT Flotante activado — conectado al canal, PTT instantáneo',
          ),
          backgroundColor: AppTheme.successColor,
          duration: Duration(seconds: 3),
        ),
      );
      setState(() {});
    } else {
      // Falló overlayActivate (timeout join channel, sin red, etc.). El
      // botón nativo NO se mostró (gracias al fix del start). Avisamos al
      // usuario y, si el provider es efímero (destruimos el engine arriba),
      // volvemos a inicializarlo en la página principal. Con conexión
      // persistente (LiveKit) la Room nunca se destruyó → nada que reiniciar.
      if (!persistent) {
        try {
          await _voice.initialize();
          if (state.activeChannelId != null) {
            _lastAgoraChannelId = state.activeChannelId;
            await _voice.joinChannel(state.activeChannelId!);
          }
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'No se pudo activar PTT flotante. Verifica internet y vuelve a intentar.',
            ),
            backgroundColor: AppTheme.errorColor,
            duration: const Duration(seconds: 4),
          ),
        );
        setState(() {});
      }
    }
  }

  /// Tap en el botón circular grande cuando el radio está apagado.
  /// Lo enciende directamente — es lo mismo que la acción "Encender" del
  /// banner naranja, pero sin tener que tocar dos veces.
  Future<void> _turnOnFromBigButton() async {
    HapticFeedback.mediumImpact();
    final s = context.read<CommunicationBloc>().state;
    String? cid;
    String? cname;
    if (s is CommunicationLoaded) {
      cid = s.activeChannelId;
      cname = s.activeChannel?.name;
      // Si no hay canal activo pero recordamos el último, lo
      // seleccionamos para que ON conecte al canal por defecto.
      if (cid == null && _radioPower.lastChannelId != null) {
        final exists =
            s.channels.any((c) => c.uid == _radioPower.lastChannelId);
        if (exists) {
          context
              .read<CommunicationBloc>()
              .add(ChannelSelected(_radioPower.lastChannelId));
          cid = _radioPower.lastChannelId;
          cname = _radioPower.lastChannelName;
        }
      }
    }
    await _radioPower.turnOn(channelId: cid, channelName: cname);
    if (!mounted) return;
    final hasChannel =
        (context.read<CommunicationBloc>().state is CommunicationLoaded) &&
            (context.read<CommunicationBloc>().state as CommunicationLoaded)
                    .activeChannelId !=
                null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          hasChannel
              ? 'Radio encendido. Mantén presionado para hablar.'
              : 'Radio encendido. Selecciona un canal arriba.',
        ),
        backgroundColor: AppTheme.successColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Muestra aviso cuando se intenta PTT sin internet o en modo desconectado.
  void _showOfflineWarning() {
    if (!mounted) return;
    final String msg = _isDriverOffline
        ? 'Estás en modo Desconectado. Cambia tu estado para usar el radio.'
        : 'Sin conexión a internet. Verifique su WiFi o datos móviles.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor:
            _isDriverOffline ? AppTheme.warningColor : AppTheme.errorColor,
        duration: const Duration(seconds: 3),
      ),
    );
    HapticFeedback.heavyImpact();
  }

  /// Aviso cuando el radio está reconectándose (auto-reconexión LiveKit en
  /// curso). No es "sin red": pedimos paciencia, no bloqueamos para siempre.
  void _showReconnectingWarning() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Reconectando al canal… intenta de nuevo en un momento.'),
        backgroundColor: Colors.blueGrey,
        duration: Duration(seconds: 2),
      ),
    );
    HapticFeedback.selectionClick();
  }

  /// Safe wrapper that guards against calling stop when not recording
  void _stopPttSafe(CommunicationLoaded state) {
    if (!_isRecording) return;
    _stopPtt(state);
  }

  Future<void> _startPtt(CommunicationLoaded state) async {
    // ── Rate-limit estilo Zello: ¿estamos en castigo? ──
    final blockedUntil = _pttBlockedUntil;
    if (blockedUntil != null) {
      if (DateTime.now().isBefore(blockedUntil)) {
        _showPttBlockedWarning(blockedUntil);
        return;
      }
      _pttBlockedUntil = null; // castigo cumplido
    }
    // ── Guard en vuelo: el press/release anterior sigue procesándose ──
    // (clicks rápidos encimaban unmute/mute + beeps → mic pegado).
    if (_pttOpsInFlight > 0) return;
    _pttOpsInFlight++;
    try {
      await _startPttInner(state);
    } finally {
      _pttOpsInFlight--;
    }
  }

  Future<void> _startPttInner(CommunicationLoaded state) async {
    final user = _currentUser;
    if (user == null || state.activeChannelId == null) return;
    if (_isRecording) return; // Prevent double-start

    // Verificar permiso de micrófono
    final hasPermission = await _voice.hasMicPermission();
    if (!hasPermission) {
      if (mounted) {
        // Marca el banner y ofrece una acción directa para conceder el permiso.
        setState(() => _micPermissionMissing = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Se requiere permiso de micrófono para hablar'),
            backgroundColor: AppTheme.warningColor,
            action: SnackBarAction(
              label: 'Conceder',
              textColor: Colors.white,
              onPressed: _requestMicPermission,
            ),
          ),
        );
      }
      return;
    }

    // El permiso ya está concedido. Si la app había entrado al canal SIN mic
    // (permiso concedido recién), re-inicializamos el engine para que tome el
    // micrófono ahora — sin reiniciar la app. La primera vez tras conceder el
    // permiso esto agrega un pequeño retardo; después es no-op rápido.
    await _voice.ensureMicReady();

    // Reconectar+grace si estamos parked O si aún no estamos en el canal
    // (caso típico al reabrir la app: el radio se restauró ON y la sala sigue
    // conectando — sin esto el primer PTT transmitía a una sala a medio
    // conectar y se perdía el audio).
    final wasParked = _voice.isParked || !_voice.isInChannel;

    // ⚡ Feedback INMEDIATO al apretar PTT — antes de cualquier await.
    // Esto le confirma al usuario que el botón registró el press.
    // Sin esto, el botón se sentía "muerto" durante los ~2s del grace.
    HapticFeedback.mediumImpact();
    _pttPressedAt = DateTime.now(); // para medir si la transmisión fue "vacía"
    setState(() {
      _isRecording = true;
      _recordingSeconds = 0;
      _pttCancelled = false;
    });

    // ── Auto-resume desde park ──
    // Si el canal está parked por inactividad, hay que volver a Agora.
    // Estrategia: disparamos el lock Firestore PRIMERO (no esperamos a
    // estar reconectados nosotros) — los listeners ven el lock en su
    // snapshot stream y arrancan su `resumeFromPark()` EN PARALELO con
    // el nuestro. Después agregamos un grace de ~1.2 s para garantizar
    // que cuando soltemos el unmuteMic los oyentes ya estén en canal.
    //
    // Si el usuario suelta el dedo mid-grace, _pttCancelled se setea
    // en _stopPtt y abortamos sin transmitir.
    if (wasParked) {
      if (!mounted) {
        _pttCancelled = true;
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Mantené presionado... conectando'),
          duration: Duration(milliseconds: 2000),
        ),
      );

      // 1️⃣ Disparar lock Firestore en paralelo — es la señal para que
      //    los listeners arranquen su propio resumeFromPark().
      context.read<CommunicationBloc>().add(
            PttLockRequested(
              channelId: state.activeChannelId!,
              userId: user.uid,
              userName: '${user.name} ${user.lastname}',
            ),
          );

      // 2️⃣ Reconectar nosotros mismos.
      final ok = await _voice.resumeFromPark();

      // Si el user soltó el dedo durante la reconexión, abortar.
      if (_pttCancelled) {
        if (mounted) {
          context.read<CommunicationBloc>().add(
                PttUnlockRequested(
                  channelId: state.activeChannelId!,
                  userId: user.uid,
                ),
              );
        }
        _cleanupRecordingState();
        return;
      }

      if (!ok && mounted) {
        // Liberar el lock que ya escribimos: si fallamos la reconexión,
        // que otro pueda hablar.
        context.read<CommunicationBloc>().add(
              PttUnlockRequested(
                channelId: state.activeChannelId!,
                userId: user.uid,
              ),
            );
        _cleanupRecordingState();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo reconectar al canal. Intentá de nuevo.'),
            backgroundColor: AppTheme.warningColor,
          ),
        );
        return;
      }

      // 3️⃣ Grace: esperar a que los listeners terminen su reconexión.
      await Future.delayed(
          const Duration(milliseconds: _listenerCatchupMs));

      // De nuevo, chequear cancelación tras el delay.
      if (_pttCancelled || !mounted) {
        if (mounted) {
          context.read<CommunicationBloc>().add(
                PttUnlockRequested(
                  channelId: state.activeChannelId!,
                  userId: user.uid,
                ),
              );
        }
        _cleanupRecordingState();
        return;
      }
    }

    // Contador de duración visible en el botón
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || !_isRecording) {
        timer.cancel();
        return;
      }
      setState(() => _recordingSeconds = timer.tick);
    });

    // Timeout de seguridad: auto-detener tras _maxRecordingSeconds
    _recordingTimer = Timer(Duration(seconds: _maxRecordingSeconds), () {
      if (_isRecording && mounted) {
        final currentState = context.read<CommunicationBloc>().state;
        if (currentState is CommunicationLoaded) {
          _stopPtt(currentState);
        }
      }
    });

    // Anti-pegado: registrar detector de voz y arrancar timer de silencio.
    // Si el VAD reporta actividad, refresca `_lastVoiceAt`. El timer
    // periódico checa cada segundo y, si pasaron más de
    // `_maxSilenceSeconds` sin voz, fuerza stopPtt para liberar el lock.
    _lastVoiceAt = DateTime.now();
    _voice.onLocalVoiceActivity = (active) {
      if (active) _lastVoiceAt = DateTime.now();
    };
    _silenceTimer?.cancel();
    _silenceTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!_isRecording || !mounted) {
        t.cancel();
        return;
      }
      final lastVoice = _lastVoiceAt;
      if (lastVoice == null) return;
      final silenceSec = DateTime.now().difference(lastVoice).inSeconds;
      if (silenceSec >= _maxSilenceSeconds) {
        debugPrint(
            '⏱️ PTT auto-release: $silenceSec s sin voz → soltando mic');
        t.cancel();
        final cs = context.read<CommunicationBloc>().state;
        if (cs is CommunicationLoaded) _stopPtt(cs);
      }
    });

    // 🔔 Beep tipo Motorola/Zello al iniciar PTT (talk-permit).
    // El háptico ya se disparó al inicio de _startPtt como feedback
    // inmediato del press — acá sólo va el beep, que arranca recién
    // cuando estamos listos para transmitir.
    PttBeepService.instance.playStart();

    // Intentar adquirir el lock PTT en Firestore — sólo si no veníamos
    // de parked. En el path parked ya escribimos el lock antes para
    // dispararle a los listeners el resumeFromPark() en paralelo.
    if (!mounted) return;
    if (!wasParked) {
      context.read<CommunicationBloc>().add(
            PttLockRequested(
              channelId: state.activeChannelId!,
              userId: user.uid,
              userName: '${user.name} ${user.lastname}',
            ),
          );
    }

    // ── AGORA: Desmutear mic → audio en tiempo real a todos ──
    try {
      await _voice.unmuteMic();
    } catch (e) {
      _recordingTimer?.cancel();
      _durationTimer?.cancel();
      setState(() {
        _isRecording = false;
        _recordingSeconds = 0;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al activar micrófono: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  /// Limpia los timers + el flag de grabación de UI. Usado tanto en
  /// _stopPtt normal como en abortos durante el grace de reconexión.
  void _cleanupRecordingState() {
    _recordingTimer?.cancel();
    _durationTimer?.cancel();
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _lastVoiceAt = null;
    _voice.onLocalVoiceActivity = null;
    if (mounted) {
      setState(() {
        _isRecording = false;
        _recordingSeconds = 0;
      });
    } else {
      _isRecording = false;
      _recordingSeconds = 0;
    }
  }

  Future<void> _stopPtt(CommunicationLoaded state) async {
    // El release NUNCA se bloquea (soltar siempre libera el mic), pero sí
    // cuenta como operación en vuelo para que un press inmediato no se
    // encime con el muteMic pendiente.
    final pressedAt = _pttPressedAt;
    _pttPressedAt = null;
    final wasEmpty = pressedAt != null &&
        DateTime.now().difference(pressedAt) < _pttEmptyMax;
    _pttOpsInFlight++;
    try {
      await _stopPttInner(state);
    } finally {
      _pttOpsInFlight--;
    }
    _registerPttUsage(wasEmpty);
  }

  /// Contabiliza el uso del PTT para el rate-limit estilo Zello: los
  /// "mensajes vacíos" (< [_pttEmptyMax]) se acumulan en una ventana
  /// deslizante; al llegar a [_pttEmptyLimit] se castiga con
  /// [_pttBlockTime]. Una transmisión válida limpia el contador.
  void _registerPttUsage(bool wasEmpty) {
    if (!wasEmpty) {
      _emptyPttPresses.clear(); // habló de verdad → redención
      return;
    }
    final now = DateTime.now();
    _emptyPttPresses.add(now);
    _emptyPttPresses
        .removeWhere((t) => now.difference(t) > _pttSpamWindow);
    if (_emptyPttPresses.length >= _pttEmptyLimit) {
      _emptyPttPresses.clear();
      _pttBlockedUntil = now.add(_pttBlockTime);
      debugPrint('🚫 PTT rate-limit: $_pttEmptyLimit mensajes vacíos en '
          '${_pttSpamWindow.inSeconds}s → bloqueado ${_pttBlockTime.inSeconds}s');
      _showPttBlockedWarning(_pttBlockedUntil!);
    }
  }

  /// Aviso de castigo del rate-limit (estilo Zello).
  void _showPttBlockedWarning(DateTime until) {
    if (!mounted) return;
    final secs = until.difference(DateTime.now()).inSeconds + 1;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
            '⏳ Muchos toques seguidos sin hablar. Espera $secs s para volver a transmitir.'),
        backgroundColor: AppTheme.warningColor,
        duration: const Duration(seconds: 3),
      ));
  }

  Future<void> _stopPttInner(CommunicationLoaded state) async {
    final user = _currentUser;
    if (user == null || state.activeChannelId == null) return;

    // Si _startPtt está en medio del grace de reconexión, esto le
    // dice que aborte cuando termine el await.
    _pttCancelled = true;

    // Inmediatamente marcamos como no transmitiendo
    _recordingTimer?.cancel();
    _durationTimer?.cancel();
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _lastVoiceAt = null;
    _voice.onLocalVoiceActivity = null;
    setState(() {
      _isRecording = false;
      _recordingSeconds = 0;
    });

    // ── AGORA: Mutear mic → dejar de transmitir ──
    try {
      await _voice.muteMic();
      // 🔔 Feedback háptico + beep "fin de transmisión" tipo Motorola
      HapticFeedback.lightImpact();
      PttBeepService.instance.playEnd();
    } catch (e) {
      // Silenciar error — ya dejamos de grabar en la UI
    }

    // NOTA: ya NO creamos aquí el mensaje de voz "solo metadatos".
    // El respaldo del audio del canal lo crea el bot grabador server-side,
    // que graba cada PTT y publica el MessageModel (type:'voz') CON su
    // `audioUrl` (.wav). Crearlo también acá duplicaría el mensaje en el chat.

    // Liberar el lock del canal en Firestore
    if (mounted) {
      context.read<CommunicationBloc>().add(
            PttUnlockRequested(
              channelId: state.activeChannelId!,
              userId: user.uid,
            ),
          );
    }
  }

  /// El audio de voz se transmite en tiempo real por el canal de voz.
  /// El respaldo re-escuchable del canal lo crea el bot grabador
  /// server-side: publica cada PTT como MessageModel (type:'voz') con su
  /// `audioUrl` (.wav), que el chat del canal reproduce desde la URL.

  /// Bottom sheet con opciones de manejo del canal (long-press en el chip).
  /// Solo visible para admin/operadora.
  void _showChannelManageSheet(ChannelModel channel) {
    final user = _currentUser;
    if (user == null) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.settings,
                  color: Theme.of(ctx).colorScheme.primary),
              title: const Text('Configurar miembros y default'),
              subtitle: const Text(
                  'Quién entra al canal y para qué roles es por defecto'),
              onTap: () {
                Navigator.pop(ctx);
                showChannelSettingsSheet(
                  context,
                  channel: channel,
                  aid: user.associationId,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Editar nombre'),
              onTap: () {
                Navigator.pop(ctx);
                _showEditChannelDialog(channel);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppTheme.errorColor),
              title: const Text('Borrar canal',
                  style: TextStyle(color: AppTheme.errorColor)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteChannel(channel);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEditChannelDialog(ChannelModel channel) {
    final nameCtrl = TextEditingController(text: channel.name);
    String type = channel.type;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Editar "${channel.name}"'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nombre del canal',
                  prefixIcon: Icon(Icons.tag),
                ),
              ),
              const SizedBox(height: 12),
              RadioGroup<String>(
                groupValue: type,
                onChanged: (v) {
                  setLocal(() => type = v ?? type);
                },
                child: Row(
                  children: const [
                    Expanded(
                      child: RadioListTile<String>(
                        title:
                            Text('Público', style: TextStyle(fontSize: 14)),
                        value: 'publico',
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<String>(
                        title:
                            Text('Privado', style: TextStyle(fontSize: 14)),
                        value: 'privado',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                final newName = nameCtrl.text.trim();
                if (newName.isEmpty) return;
                try {
                  await FirebaseFirestore.instance
                      .collection('channels')
                      .doc(channel.uid)
                      .update({
                    'name': newName,
                    'type': type,
                    'updatedAt': FieldValue.serverTimestamp(),
                  });
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Error: $e')),
                    );
                  }
                }
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteChannel(ChannelModel channel) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar canal'),
        content: Text(
            '¿Borrar el canal "${channel.name}"? Los mensajes históricos no se eliminan automáticamente.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.errorColor),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    try {
      await FirebaseFirestore.instance
          .collection('channels')
          .doc(channel.uid)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Canal borrado')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _showCreateChannelDialog() {
    final user = _currentUser;
    if (user == null) return;

    final nameController = TextEditingController();
    String channelType = 'publico';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Nuevo Canal'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Nombre del canal',
                  prefixIcon: Icon(Icons.tag),
                ),
              ),
              const SizedBox(height: 16),
              RadioGroup<String>(
                groupValue: channelType,
                onChanged: (v) {
                  setDialogState(() => channelType = v ?? channelType);
                },
                child: Row(
                  children: [
                    Expanded(
                      child: RadioListTile<String>(
                        title: const Text('Público',
                            style: TextStyle(fontSize: 14)),
                        value: 'publico',
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<String>(
                        title: const Text('Privado',
                            style: TextStyle(fontSize: 14)),
                        value: 'privado',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm + 2),
                decoration: BoxDecoration(
                  color: AppTheme.infoColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppTheme.infoColor.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline,
                        size: 16, color: AppTheme.infoColor),
                    const SizedBox(width: AppSpacing.xs + 2),
                    Expanded(
                      child: Text(
                        'Después de crearlo se abre la configuración para '
                        'elegir miembros y si es el canal por defecto.',
                        style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                          color: AppTheme.infoColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                final newChannel = ChannelModel(
                  uid: const Uuid().v4(),
                  associationId: user.associationId,
                  name: name,
                  type: channelType,
                  createdBy: user.uid,
                  memberIds: [user.uid],
                  createdAt: DateTime.now(),
                );
                context
                    .read<CommunicationBloc>()
                    .add(ChannelCreateRequested(newChannel));
                Navigator.pop(ctx);
                // Auto-abrir el sheet de configuración para que el admin
                // termine de armarlo (miembros + default por rol) en un
                // solo flujo. Sin esto, los canales privados quedan sin
                // miembros y nadie los ve.
                Future.delayed(const Duration(milliseconds: 350), () {
                  if (!mounted) return;
                  showChannelSettingsSheet(
                    context,
                    channel: newChannel,
                    aid: user.associationId,
                  );
                });
              },
              child: const Text('Crear y configurar'),
            ),
          ],
        ),
      ),
    );
  }

}

/// Wrapper que titila (escala + cambia opacidad) cuando [blink] = true.
/// Se usa en los chips de canal para alertar al usuario que hay actividad
/// (alguien hablando) en un canal que NO está seleccionado, cuando hay
/// más de un canal visible.
class _BlinkingChannelChip extends StatefulWidget {
  final bool blink;
  final Widget child;
  const _BlinkingChannelChip({required this.blink, required this.child});

  @override
  State<_BlinkingChannelChip> createState() => _BlinkingChannelChipState();
}

class _BlinkingChannelChipState extends State<_BlinkingChannelChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scale = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _BlinkingChannelChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blink != widget.blink) _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.blink) {
      if (!_ctrl.isAnimating) _ctrl.repeat(reverse: true);
    } else {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.blink) return widget.child;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => Transform.scale(
        scale: _scale.value,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.red.withValues(alpha: 0.5 * _ctrl.value),
                blurRadius: 12 * _ctrl.value,
                spreadRadius: 2 * _ctrl.value,
              ),
            ],
          ),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
