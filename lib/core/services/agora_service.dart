import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Servicio singleton para audio en tiempo real con Agora RTC.
///
/// Implementa el patrón walkie-talkie PTT (Push-to-Talk):
/// - Todos se unen al canal SIN publicar micrófono.
/// - Solo el usuario que mantiene PTT activa publishMicrophoneTrack.
/// - Todos los demás escuchan en tiempo real (como Zello).
///
/// Cambio clave v2: se usa [updateChannelMediaOptions] para alternar
/// `publishMicrophoneTrack` en vez de `muteLocalAudioStream`, que en
/// Agora SDK 6.x puede dejar el track en estado inconsistente.
///
/// Cambio v3 (seguridad): App Certificate ya NO está en el cliente.
/// Los tokens se obtienen de la Cloud Function `generateAgoraToken`,
/// que también devuelve el App ID. El cliente no conoce credenciales.
class AgoraService {
  AgoraService._();
  static final AgoraService instance = AgoraService._();

  static const String _tokenFunctionName = 'generateAgoraToken';
  static const Duration _tokenCallTimeout = Duration(seconds: 15);

  // appId se obtiene de la Cloud Function (junto con cada token).
  // Se cachea tras la primera llamada para que `initialize()` lo tenga.
  String? _appId;

  RtcEngine? _engine;
  RtcEngineEventHandler? _eventHandler;

  bool _isInitialized = false;
  bool _isInChannel = false;
  bool _isMicPublishing = false; // true = PTT activo, publicando mic
  bool _isRemoteAudioMuted = false;
  String? _currentChannelId;
  int _localUid = 0;

  // Cache de tokens por canal
  final Map<String, _CachedToken> _tokenCache = {};

  // Callbacks opcionales para la UI
  void Function(int remoteUid)? onRemoteUserJoined;
  void Function(int remoteUid)? onRemoteUserOffline;
  void Function(String message)? onError;

  bool get isInitialized => _isInitialized;
  bool get isInChannel => _isInChannel;
  bool get isMicMuted => !_isMicPublishing;
  bool get isRemoteAudioMuted => _isRemoteAudioMuted;
  String? get currentChannelId => _currentChannelId;

  void _log(String msg) => debugPrint('[AgoraService] $msg');

  // ─────────────────── Token Generation (server-side) ───────────────────

  /// Pide un token a la Cloud Function `generateAgoraToken`.
  /// La función devuelve `{appId, token, expiresAt}`. Cacheamos por canal.
  Future<String> _fetchToken(String channelId) async {
    final cached = _tokenCache[channelId];
    if (cached != null && !cached.isExpired) {
      return cached.token;
    }

    _log('Solicitando token al servidor para canal: $channelId');

    // Diagnóstico de auth: el SDK de cloud_functions adjunta el ID token
    // de FirebaseAuth.currentUser. Si el user es null o el token está
    // caducado, la function responde unauthenticated.
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _log('🔑 currentUser es NULL — Auth no listo aún');
      throw Exception('Usuario no autenticado al pedir token Agora');
    }
    try {
      // Forzar refresh del ID token para evitar tokens en caché caducados.
      final idToken = await user.getIdToken(true);
      _log('🔑 currentUser.uid=${user.uid}, idToken len=${idToken?.length ?? 0}');
    } catch (e) {
      _log('⚠️ No se pudo refrescar idToken: $e');
    }

    try {
      final callable = FirebaseFunctions.instance
          .httpsCallable(_tokenFunctionName)
          .call({'channelName': channelId, 'uid': 0});
      final result = await callable.timeout(_tokenCallTimeout);

      final data = (result.data as Map?) ?? const {};
      final token = data['token'] as String?;
      final appId = data['appId'] as String?;
      final expiresAt = (data['expiresAt'] as num?)?.toInt();

      if (token == null || token.isEmpty || appId == null || appId.isEmpty) {
        throw Exception('Respuesta inválida de generateAgoraToken');
      }

      _appId = appId;
      _tokenCache[channelId] = _CachedToken(token: token, expiresAt: expiresAt);
      _log('Token recibido OK (${token.length} chars)');
      return token;
    } on FirebaseFunctionsException catch (e) {
      _log('❌ Cloud Function error (${e.code}): ${e.message}');
      throw Exception('No se pudo obtener token Agora: ${e.message ?? e.code}');
    }
  }

  /// Asegura que tenemos un appId conocido (necesario para `initialize`).
  /// Si aún no se ha hecho ninguna petición de token, hace una petición
  /// usando un canal "dummy" para descubrir el appId. En la práctica
  /// `joinChannel` siempre se llama tras `initialize`, así que en el
  /// primer flujo real esto se evita: `initialize` se hace cuando se
  /// conoce el primer canal.
  Future<String> _ensureAppId(String channelHint) async {
    if (_appId != null && _appId!.isNotEmpty) return _appId!;
    await _fetchToken(channelHint);
    if (_appId == null || _appId!.isEmpty) {
      throw Exception('No se pudo resolver Agora App ID desde el servidor');
    }
    return _appId!;
  }

  // ─────────────────── Inicialización ───────────────────

  /// Inicializa el engine. Requiere un [channelHint] para obtener el
  /// App ID desde el servidor antes de crear el engine.
  Future<void> initialize({String? channelHint}) async {
    if (_isInitialized) return;

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      throw Exception('Se requiere permiso de micrófono para el walkie-talkie');
    }

    // Resolver App ID antes de crear el engine.
    // Si no hay hint usamos un nombre genérico — el token resultante igual
    // se cachea por ese nombre y no se reusa para canales reales.
    final hint = channelHint ?? '__bootstrap__';
    final appId = await _ensureAppId(hint);

    _engine = createAgoraRtcEngine();

    // Communication es el perfil más simple y fiable para PTT grupal
    await _engine!.initialize(RtcEngineContext(
      appId: appId,
      channelProfile: ChannelProfileType.channelProfileCommunication,
    ));

    // Solo audio — habilitar subsistema pero NO capturar mic todavía
    await _engine!.enableAudio();
    await _engine!.enableLocalAudio(false); // Mic apagado hasta PTT
    await _engine!.disableVideo();

    // Perfil de audio agresivo para PTT: bajo bitrate (~16kbps)
    // Menos datos = transmisión más rápida en redes lentas/rurales
    await _engine!.setAudioProfile(
      profile: AudioProfileType.audioProfileSpeechStandard,
      scenario: AudioScenarioType.audioScenarioChatroom,
    );
    // Forzar bitrate bajo (~16kbps) — suficiente para voz, como radio real
    try {
      await _engine!.setParameters('{"che.audio.custom_bitrate": 16000}');
    } catch (_) {}

    // Low-latency mode: reduce buffers de audio (~50-100ms menos de delay)
    try {
      await _engine!.setParameters('{"che.audio.lowlatency": true}');
    } catch (_) {}

    // Desactivar AEC (cancelación de eco) — innecesario en PTT half-duplex
    try {
      await _engine!.setParameters('{"che.audio.aec.enable": false}');
    } catch (_) {}

    // Altavoz por defecto
    try {
      await _engine!.setDefaultAudioRouteToSpeakerphone(true);
    } catch (_) {}

    // Indicador de volumen para debug
    await _engine!.enableAudioVolumeIndication(
      interval: 1000,
      smooth: 3,
      reportVad: true,
    );

    // Registrar handlers de eventos
    _eventHandler = RtcEngineEventHandler(
      onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
        _localUid = connection.localUid ?? 0;
        _isInChannel = true;
        _log(
          '✅ JOIN OK — canal: "${connection.channelId}", '
          'localUid: $_localUid, elapsed: ${elapsed}ms',
        );
        // Asegurar speaker + suscripción audio remoto
        _engine?.setEnableSpeakerphone(true);
        _engine?.muteAllRemoteAudioStreams(false);
      },
      onLeaveChannel: (RtcConnection connection, RtcStats stats) {
        _isInChannel = false;
        _isMicPublishing = false;
        _log('🔴 LEAVE — canal: "${connection.channelId}"');
      },
      onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
        _log('👤 REMOTE JOIN — uid: $remoteUid en "${connection.channelId}"');
        onRemoteUserJoined?.call(remoteUid);
      },
      onUserOffline: (
        RtcConnection connection,
        int remoteUid,
        UserOfflineReasonType reason,
      ) {
        _log('👤 REMOTE LEFT — uid: $remoteUid ($reason)');
        onRemoteUserOffline?.call(remoteUid);
      },
      onError: (ErrorCodeType err, String msg) {
        _log('❌ ERROR — $err: $msg');
        onError?.call('$err: $msg');
        // Si el token es inválido, limpiar cache para forzar regeneración
        if (err == ErrorCodeType.errInvalidToken ||
            err == ErrorCodeType.errTokenExpired) {
          _log('🔑 Token inválido/expirado, limpiando cache');
          _tokenCache.clear();
        }
      },
      onConnectionStateChanged: (
        RtcConnection connection,
        ConnectionStateType state,
        ConnectionChangedReasonType reason,
      ) {
        _log('🔗 CONNECTION — $state ($reason)');
      },
      onAudioPublishStateChanged: (
        String channel,
        StreamPublishState oldState,
        StreamPublishState newState,
        int elapseSinceLastState,
      ) {
        _log(
          '📡 AUDIO PUBLISH — canal: "$channel", '
          '$oldState → $newState (${elapseSinceLastState}ms)',
        );
      },
      onAudioSubscribeStateChanged: (
        String channel,
        int uid,
        StreamSubscribeState oldState,
        StreamSubscribeState newState,
        int elapseSinceLastState,
      ) {
        _log(
          '📥 AUDIO SUBSCRIBE — canal: "$channel", uid: $uid, '
          '$oldState → $newState (${elapseSinceLastState}ms)',
        );
      },
      onAudioVolumeIndication: (
        RtcConnection connection,
        List<AudioVolumeInfo> speakers,
        int totalVolume,
        int totalVolumeBeforeMixing,
      ) {
        for (final s in speakers) {
          if (s.volume! > 0) {
            final who = s.uid == 0 ? 'LOCAL' : 'REMOTE(${s.uid})';
            _log('🔊 VOL — $who vol=${s.volume} vad=${s.vad}');
          }
        }
      },
      onRemoteAudioStateChanged: (
        RtcConnection connection,
        int remoteUid,
        RemoteAudioState state,
        RemoteAudioStateReason reason,
        int elapsed,
      ) {
        _log(
          '🔈 REMOTE AUDIO STATE — uid: $remoteUid, '
          'state: $state, reason: $reason',
        );
      },
      onLocalAudioStateChanged: (
        RtcConnection connection,
        LocalAudioStreamState state,
        LocalAudioStreamReason reason,
      ) {
        _log('🎤 LOCAL AUDIO STATE — state: $state, reason: $reason');
      },
      onTokenPrivilegeWillExpire: (RtcConnection connection, String token) {
        _log('⏰ Token expirando, renovando...');
        _renewToken(connection.channelId ?? '');
      },
    );
    _engine!.registerEventHandler(_eventHandler!);

    _isInitialized = true;
    _log('🚀 Agora RTC Engine inicializado (Communication + Chatroom)');
  }

  Future<void> _renewToken(String channelId) async {
    if (channelId.isEmpty || _engine == null) return;
    _tokenCache.remove(channelId);
    try {
      final newToken = await _fetchToken(channelId);
      if (newToken.isNotEmpty) {
        await _engine!.renewToken(newToken);
        _log('Token renovado OK');
      }
    } catch (e) {
      _log('Error renovando token: $e');
    }
  }

  Future<void> _ensureInitialized({String? channelHint}) async {
    if (!_isInitialized) await initialize(channelHint: channelHint);
  }

  // ─────────────────── Canal ───────────────────

  /// Se une a un canal Agora. Todos entran SIN publicar micrófono.
  /// El mic se activa solo con PTT (unmuteMic → publishMicrophoneTrack: true).
  Future<void> joinChannel(String channelId) async {
    try {
      await _ensureInitialized(channelHint: channelId);

      if (_isInChannel && _currentChannelId == channelId) {
        _log('Ya en canal "$channelId", ignorando joinChannel');
        return;
      }

      if (_isInChannel) {
        _log('En otro canal ($_currentChannelId), saliendo primero...');
        await leaveChannel();
        await Future.delayed(const Duration(milliseconds: 300));
      }

      final token = await _fetchToken(channelId);

      _log('>>> JOINING canal: "$channelId"');

      await _engine!.joinChannel(
        token: token,
        channelId: channelId,
        uid: 0,
        options: const ChannelMediaOptions(
          autoSubscribeAudio: true,
          // NO publicar mic al entrar — solo con PTT
          publishMicrophoneTrack: false,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
        ),
      );

      _isMicPublishing = false;
      _currentChannelId = channelId;
      // _isInChannel se marca en onJoinChannelSuccess

      _log('joinChannel llamado para "$channelId" (esperando callback)');
    } on AgoraRtcException catch (e) {
      if (e.code == -17) {
        _log('⚠️ Error -17: ya en canal. Forzando leave + rejoin...');
        _isInChannel = false;
        try {
          await _engine!.leaveChannel();
        } catch (_) {}
        _currentChannelId = null;
        await Future.delayed(const Duration(milliseconds: 500));
        // Reintentar
        try {
          final token = await _fetchToken(channelId);
          await _engine!.joinChannel(
            token: token,
            channelId: channelId,
            uid: 0,
            options: const ChannelMediaOptions(
              autoSubscribeAudio: true,
              publishMicrophoneTrack: false,
              clientRoleType: ClientRoleType.clientRoleBroadcaster,
            ),
          );
          _isMicPublishing = false;
          _currentChannelId = channelId;
          _log('Rejoin OK tras error -17');
        } catch (e2) {
          _log('Rejoin falló: $e2');
          onError?.call('joinChannel retry: $e2');
        }
      } else {
        _log('Error Agora joinChannel: $e');
        onError?.call('joinChannel: $e');
      }
    } catch (e) {
      _log('Error joinChannel: $e');
      onError?.call('joinChannel: $e');
    }
  }

  /// Sale del canal Agora actual.
  /// Deshabilita local audio primero para liberar el micrófono hardware.
  Future<void> leaveChannel() async {
    if (_engine == null) return;
    try {
      // Liberar mic hardware ANTES de salir del canal
      await _engine!.enableLocalAudio(false);
      await _engine!.leaveChannel();
    } catch (e) {
      _log('Error leaveChannel: $e');
    }
    _isInChannel = false;
    _currentChannelId = null;
    _isMicPublishing = false;
    _log('Salió del canal Agora (mic liberado)');
  }

  /// Libera el micrófono hardware sin salir del canal.
  /// Útil cuando la app va a segundo plano.
  Future<void> releaseAudioCapture() async {
    if (_engine == null) return;
    try {
      await _engine!.updateChannelMediaOptions(
        const ChannelMediaOptions(publishMicrophoneTrack: false),
      );
      await _engine!.enableLocalAudio(false);
      _isMicPublishing = false;
      _log('🔇 Audio capture liberado (app en background)');
    } catch (e) {
      _log('Error releaseAudioCapture: $e');
    }
  }

  /// Re-habilita la recepción de audio remoto (al volver de background).
  /// NO habilita el mic local — eso solo ocurre con PTT.
  Future<void> resumeAudioReceive() async {
    if (_engine == null || !_isInChannel) return;
    try {
      // Solo asegurar que recibimos audio remoto; mic permanece apagado
      await _engine!.muteAllRemoteAudioStreams(false);
      _log('🔊 Audio remoto restaurado (app en foreground)');
    } catch (e) {
      _log('Error resumeAudioReceive: $e');
    }
  }

  /// Canal al que estaba conectado antes de destroy (para reconexión)
  String? _lastChannelBeforeDestroy;
  String? get lastChannelBeforeDestroy => _lastChannelBeforeDestroy;

  /// Destruye completamente el engine Agora para liberar la sesión de audio
  /// del sistema operativo. Esto es NECESARIO para que Android no reporte
  /// "en llamada" a otras apps (Zello, WhatsApp, etc.).
  /// Guarda el canal actual para poder reconectar al volver.
  Future<void> destroyEngine() async {
    _lastChannelBeforeDestroy = _currentChannelId;
    _log('🔥 destroyEngine — guardando canal: $_lastChannelBeforeDestroy');
    try {
      if (_isInChannel && _engine != null) {
        try { await _engine!.enableLocalAudio(false); } catch (_) {}
        try { await _engine!.leaveChannel(); } catch (_) {}
      }
      if (_engine != null) {
        if (_eventHandler != null) {
          _engine!.unregisterEventHandler(_eventHandler!);
          _eventHandler = null;
        }
        try { await _engine!.release(); } catch (_) {}
        _engine = null;
      }
    } catch (e) {
      _log('Error en destroyEngine: $e');
    }
    _isInitialized = false;
    _isInChannel = false;
    _isMicPublishing = false;
    _currentChannelId = null;
    // Token cache se mantiene para reconexión rápida del overlay PTT
    // (los tokens son válidos 24h, no dependen de la instancia del engine)
    _log('🔥 Engine completamente destruido — sesión de audio liberada');
  }

  // ─────────────────── Overlay PTT — Canal Persistente ───────────────────

  /// Activa el modo overlay: inicializa engine + se une al canal + mic OFF.
  /// El engine permanece conectado mientras el overlay esté activo.
  /// Esto permite PTT instantáneo (0ms) — solo alterna mic on/off.
  Future<void> overlayActivate(String channelId) async {
    _log('🟢 overlayActivate — conectando al canal: $channelId');

    if (!_isInitialized) {
      await initialize(channelHint: channelId);
    }

    if (!_isInChannel || _currentChannelId != channelId) {
      await joinChannel(channelId);

      // Esperar confirmación de join (máx 5 segundos)
      for (int i = 0; i < 50 && !_isInChannel; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (!_isInChannel) {
        throw Exception('Timeout al unirse al canal');
      }
    }

    // Mic apagado — se enciende solo al presionar PTT
    await muteMic();
    _log('🟢 overlayActivate LISTO — conectado a $channelId, mic OFF, escuchando');
  }

  /// Desactiva el modo overlay: destruye engine → mic 100% libre.
  Future<void> overlayDeactivate() async {
    _log('🔴 overlayDeactivate — destruyendo engine');
    await destroyEngine();
    _log('🔴 overlayDeactivate DONE — mic libre a nivel del SO');
  }

  /// PTT instantáneo: solo enciende el mic (engine ya conectado al canal).
  Future<void> quickPttStart(String channelId) async {
    _log('⚡ quickPttStart — unmute mic (canal persistente)');
    if (!_isInChannel) {
      _log('⚠️ quickPttStart: no está en canal, reconectando...');
      await overlayActivate(channelId);
    }
    await unmuteMic();
    _log('⚡ quickPttStart LISTO — transmitiendo');
  }

  /// PTT instantáneo: solo apaga el mic (engine sigue conectado).
  Future<void> quickPttStop() async {
    _log('⚡ quickPttStop — mute mic (canal persistente)');
    await muteMic();
    _log('⚡ quickPttStop DONE — mic apagado, sigue en canal');
  }

  // ─────────────────── PTT (Push-to-Talk) ───────────────────

  /// Activa la publicación del micrófono — llamar al PRESIONAR PTT.
  /// Usa [updateChannelMediaOptions] que es más fiable que muteLocalAudioStream.
  /// También habilita enableLocalAudio para capturar el micrófono hardware.
  Future<void> unmuteMic() async {
    if (_engine == null || !_isInChannel) {
      _log('unmuteMic ignorado: engine=$_engine isInChannel=$_isInChannel');
      return;
    }
    try {
      // Primero habilitar captura de audio local (adquiere mic hardware)
      await _engine!.enableLocalAudio(true);
      await _engine!.updateChannelMediaOptions(
        const ChannelMediaOptions(publishMicrophoneTrack: true),
      );
      _isMicPublishing = true;
      _log('🎙️ PTT ACTIVO — enableLocalAudio(true) + publishMicrophoneTrack: true');
    } catch (e) {
      _log('Error unmuteMic: $e');
    }
  }

  /// Detiene la publicación del micrófono — llamar al SOLTAR PTT.
  /// También deshabilita enableLocalAudio para LIBERAR el micrófono hardware,
  /// permitiendo que otras apps (Zello, WhatsApp) lo usen.
  Future<void> muteMic() async {
    if (_engine == null || !_isInChannel) return;
    try {
      await _engine!.updateChannelMediaOptions(
        const ChannelMediaOptions(publishMicrophoneTrack: false),
      );
      // Liberar captura de mic hardware para que otras apps puedan usarlo
      await _engine!.enableLocalAudio(false);
      _isMicPublishing = false;
      _log('🔇 PTT INACTIVO — publishMicrophoneTrack: false + enableLocalAudio(false)');
    } catch (e) {
      _log('Error muteMic: $e');
    }
  }

  // ─────────────────── Audio Remoto ───────────────────

  Future<void> setRemoteAudioMuted(bool muted) async {
    _isRemoteAudioMuted = muted;
    if (_engine == null || !_isInChannel) return;
    try {
      await _engine!.muteAllRemoteAudioStreams(muted);
      _log('Audio remoto ${muted ? "MUTEADO" : "ACTIVO"}');
    } catch (e) {
      _log('Error setRemoteAudioMuted: $e');
    }
  }

  // ─────────────────── Permisos ───────────────────

  Future<bool> hasMicPermission() async {
    return await Permission.microphone.isGranted;
  }

  // ─────────────────── Limpieza ───────────────────

  Future<void> dispose() async {
    _lastChannelBeforeDestroy = null; // dispose intencional, no guardar canal
    await destroyEngine();
    _log('Agora RTC Engine liberado (dispose completo)');
  }
}

/// Token cacheado con expiración real informada por el servidor.
class _CachedToken {
  _CachedToken({required this.token, int? expiresAt})
      : _expiresAt = expiresAt != null
            ? DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)
            : DateTime.now().add(const Duration(hours: 20));

  final String token;
  final DateTime _expiresAt;

  /// Considera expirado 1h antes del verdadero expiry para dejar margen.
  bool get isExpired =>
      DateTime.now().isAfter(_expiresAt.subtract(const Duration(hours: 1)));
}
