import 'dart:async';
import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice/voice_provider.dart';

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
class AgoraService implements VoiceProvider {
  AgoraService._();
  static final AgoraService instance = AgoraService._();

  static const String _tokenFunctionName = 'generateAgoraToken';
  static const Duration _tokenCallTimeout = Duration(seconds: 15);

  // Claves SharedPreferences para cache persistente. Sobreviven kill de
  // la app → cold-start del radio NO requiere red si el token sigue vivo.
  static const String _kPrefsAppId = 'agora_app_id';
  static const String _kPrefsTokenPrefix = 'agora_token_';
  static const String _kPrefsPlaybackVolume = 'agora_playback_volume';

  /// Volumen de reproducción amplificable.
  /// Agora soporta `adjustPlaybackSignalVolume` en el rango [0, 400], donde
  /// 100 = ganancia 1x y 400 = ganancia 4x. Útil cuando el volumen del SO
  /// está al máximo pero la voz remota se oye muy baja (caso típico en
  /// taxis con ruido ambiente y bocinas pequeñas).
  static const int playbackVolumeMin = 100;
  static const int playbackVolumeMax = 400;
  static const int playbackVolumeDefault = 200;
  int _playbackVolume = playbackVolumeDefault;
  int get playbackVolume => _playbackVolume;

  // appId se obtiene de la Cloud Function (junto con cada token).
  // Se cachea tras la primera llamada para que `initialize()` lo tenga.
  String? _appId;
  // Indica si ya hidratamos el cache desde SharedPreferences.
  bool _prefsHydrated = false;

  RtcEngine? _engine;
  RtcEngineEventHandler? _eventHandler;

  bool _isInitialized = false;
  bool _isInChannel = false;
  bool _isMicPublishing = false; // true = PTT activo, publicando mic
  bool _isRemoteAudioMuted = false;
  String? _currentChannelId;
  int _localUid = 0;

  /// Canal "estacionado": cuando hacemos `parkChannel()` (auto-disconnect
  /// por inactividad) guardamos acá el canal del que salimos. El engine
  /// sigue vivo, sólo dejamos de pagar minutos en Agora. `resumeFromPark()`
  /// re-une al mismo canal cuando alguien empieza a hablar.
  String? _parkedChannelId;

  // Cache de tokens por canal
  final Map<String, _CachedToken> _tokenCache = {};

  // Callbacks opcionales para la UI
  void Function(int remoteUid)? onRemoteUserJoined;
  void Function(int remoteUid)? onRemoteUserOffline;
  void Function(String message)? onError;

  /// Callback con actividad de voz local. `active=true` cuando se detecta
  /// voz (VAD=1 o vol>10) en el mic local; `false` si no. La página del
  /// walkie lo usa para auto-soltar el PTT si nadie habla por X segundos.
  void Function(bool active)? onLocalVoiceActivity;

  @override
  bool get isInitialized => _isInitialized;
  @override
  bool get isInChannel => _isInChannel;
  @override
  bool get isMicMuted => !_isMicPublishing;
  bool get isRemoteAudioMuted => _isRemoteAudioMuted;
  @override
  String? get currentChannelId => _currentChannelId;

  /// true cuando el canal está "parked" — engine vivo pero fuera del
  /// canal Agora por inactividad. Listo para `resumeFromPark()` instantáneo.
  @override
  bool get isParked => _parkedChannelId != null;
  @override
  String? get parkedChannelId => _parkedChannelId;

  void _log(String msg) => debugPrint('[AgoraService] $msg');

  // ─────────────────── Token Generation (server-side) ───────────────────

  /// Hidrata el cache en memoria desde SharedPreferences. Se llama una
  /// vez por sesión, en el primer `_fetchToken` o `_ensureAppId`.
  /// Permite que un cold-start de la app reuse tokens fetched en sesiones
  /// anteriores → encendido del radio sin hit de red en el caso ideal.
  Future<void> _hydrateFromPrefs() async {
    if (_prefsHydrated) return;
    _prefsHydrated = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _appId ??= prefs.getString(_kPrefsAppId);
      final savedVol = prefs.getInt(_kPrefsPlaybackVolume);
      if (savedVol != null) {
        _playbackVolume = savedVol.clamp(playbackVolumeMin, playbackVolumeMax);
      }
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(_kPrefsTokenPrefix)) continue;
        final raw = prefs.getString(key);
        if (raw == null) continue;
        try {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          final token = m['token'] as String?;
          final expiresAt = (m['expiresAt'] as num?)?.toInt();
          if (token == null || token.isEmpty) continue;
          final cached = _CachedToken(token: token, expiresAt: expiresAt);
          if (cached.isExpired) {
            await prefs.remove(key);
            continue;
          }
          final channelId = key.substring(_kPrefsTokenPrefix.length);
          _tokenCache[channelId] = cached;
        } catch (_) {
          await prefs.remove(key);
        }
      }
      _log('Cache hidratado: appId=${_appId != null}, '
          'tokens=${_tokenCache.length}');
    } catch (e) {
      _log('Error hidratando cache: $e');
    }
  }

  /// Ajusta el volumen de reproducción amplificable y lo persiste.
  /// [volume] se acota a [playbackVolumeMin]..[playbackVolumeMax] (100..400).
  /// Aplica inmediatamente al engine si está vivo; en cold-starts futuros
  /// se reinstaura desde SharedPreferences vía `_hydrateFromPrefs`.
  Future<void> setPlaybackVolume(int volume) async {
    final v = volume.clamp(playbackVolumeMin, playbackVolumeMax);
    _playbackVolume = v;
    try {
      await _engine?.adjustPlaybackSignalVolume(v);
    } catch (e) {
      _log('Error setPlaybackVolume: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPrefsPlaybackVolume, v);
    } catch (_) {}
    _log('🔊 Volumen reproducción = $v (rango 100-400)');
  }

  /// Persiste appId + token de un canal a SharedPreferences.
  Future<void> _persistToken(String channelId, _CachedToken cached) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_appId != null) {
        await prefs.setString(_kPrefsAppId, _appId!);
      }
      await prefs.setString(
        '$_kPrefsTokenPrefix$channelId',
        jsonEncode({
          'token': cached.token,
          'expiresAt': cached.expiresAtEpoch,
        }),
      );
    } catch (e) {
      _log('Error persistiendo token: $e');
    }
  }

  /// Pre-warm: pide el token de un canal en background. Útil cuando el
  /// usuario seleccionó un canal pero todavía no encendió el radio —
  /// el token está listo para cuando lo haga (encendido instantáneo).
  /// No bloquea ni propaga errores.
  void prewarmToken(String channelId) {
    if (channelId.isEmpty) return;
    // Si ya está cacheado y vivo, no hace nada.
    final cached = _tokenCache[channelId];
    if (cached != null && !cached.isExpired) return;
    unawaited(
      _fetchToken(channelId).catchError((e) {
        _log('prewarm fallido para $channelId: $e');
        return '';
      }),
    );
  }

  /// Pide un token a la Cloud Function `generateAgoraToken`.
  /// La función devuelve `{appId, token, expiresAt}`. Cacheamos por canal.
  Future<String> _fetchToken(String channelId) async {
    await _hydrateFromPrefs();
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
      final cached = _CachedToken(token: token, expiresAt: expiresAt);
      _tokenCache[channelId] = cached;
      // Persistir en background — no bloqueamos el join.
      unawaited(_persistToken(channelId, cached));
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
    // Intento 1: hidratar desde SharedPreferences (sin red).
    await _hydrateFromPrefs();
    if (_appId != null && _appId!.isNotEmpty) return _appId!;
    // Intento 2: pedir un token (que también nos da el appId).
    await _fetchToken(channelHint);
    if (_appId == null || _appId!.isEmpty) {
      throw Exception('No se pudo resolver Agora App ID desde el servidor');
    }
    return _appId!;
  }

  // ─────────────────── Inicialización ───────────────────

  /// Inicializa el engine. Requiere un [channelHint] para obtener el
  /// App ID desde el servidor antes de crear el engine.
  @override
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
    // Paralelizar: el AppId puede venir del cache (instant) o del server
    // (~300ms). Mientras la primera espera de _ensureAppId está pendiente
    // (cuando hay red), instanciamos el bridge nativo. Ahorra ~50-200ms
    // en cold-start.
    final appIdFuture = _ensureAppId(hint);
    _engine = createAgoraRtcEngine();
    final appId = await appIdFuture;

    // LiveBroadcasting permite alternar audience↔broadcaster en runtime.
    // Audience NO acapara el micrófono ni pone Android en MODE_IN_COMMUNICATION,
    // que es lo que bloquea WhatsApp/Zello al estar el radio "escuchando".
    await _engine!.initialize(RtcEngineContext(
      appId: appId,
      channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
    ));

    // Solo audio — habilitar subsistema pero NO capturar mic todavía
    await _engine!.enableAudio();
    await _engine!.enableLocalAudio(false); // Mic apagado hasta PTT
    await _engine!.disableVideo();

    // gameStreaming evita que el SO marque "llamada activa" mientras
    // estamos en role audience. speechStandard mantiene calidad de voz.
    await _engine!.setAudioProfile(
      profile: AudioProfileType.audioProfileSpeechStandard,
      scenario: AudioScenarioType.audioScenarioGameStreaming,
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

    // Forzar enrutamiento a speakerphone también de forma activa (no solo
    // como default). Sin esto, en algunos celulares con LiveBroadcasting
    // el audio remoto sale por el earpiece o no se escucha al recibir
    // del Broadcaster recién promovido.
    try {
      await _engine!.setEnableSpeakerphone(true);
    } catch (_) {}

    // Asegurar volumen de reproducción al máximo. Si por alguna razón
    // quedó en 0 (raro pero posible al cambiar de scenario), el receptor
    // queda mudo aunque el Broadcaster transmita correctamente.
    try {
      await _engine!.adjustPlaybackSignalVolume(_playbackVolume);
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
        // Asegurar speaker, suscripción audio remoto y volumen guardado.
        _engine?.setEnableSpeakerphone(true);
        _engine?.muteAllRemoteAudioStreams(false);
        _engine?.adjustPlaybackSignalVolume(_playbackVolume);
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
        // Cuando alguien empieza a transmitir y nos suscribimos a su
        // audio, forzar speakerphone + volumen guardado. Sin esto, en
        // algunos celulares (Pixel) el audio remoto va al earpiece o
        // queda mudo tras cambios de role en LiveBroadcasting.
        if (newState == StreamSubscribeState.subStateSubscribed) {
          _engine?.setEnableSpeakerphone(true);
          _engine?.adjustPlaybackSignalVolume(_playbackVolume);
          _engine?.muteRemoteAudioStream(uid: uid, mute: false);
        }
      },
      onAudioVolumeIndication: (
        RtcConnection connection,
        List<AudioVolumeInfo> speakers,
        int totalVolume,
        int totalVolumeBeforeMixing,
      ) {
        bool localActive = false;
        for (final s in speakers) {
          if (s.volume! > 0) {
            final who = s.uid == 0 ? 'LOCAL' : 'REMOTE(${s.uid})';
            _log('🔊 VOL — $who vol=${s.volume} vad=${s.vad}');
          }
          // uid == 0 es el speaker local. Considerar "actividad" si el
          // VAD reporta voz O el volumen supera un umbral mínimo.
          if (s.uid == 0 && ((s.vad ?? 0) > 0 || (s.volume ?? 0) > 10)) {
            localActive = true;
          }
        }
        onLocalVoiceActivity?.call(localActive);
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
    _log('🚀 Agora RTC Engine inicializado (LiveBroadcasting + GameStreaming)');
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
  @override
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
          // Entramos como AUDIENCE — solo escuchamos, no acaparamos mic.
          // Cambiamos a Broadcaster solo cuando se presiona PTT.
          publishMicrophoneTrack: false,
          clientRoleType: ClientRoleType.clientRoleAudience,
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
              clientRoleType: ClientRoleType.clientRoleAudience,
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
  @override
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
    // leaveChannel() es desconexión intencional (radio OFF / cambio de canal):
    // limpiamos también el park para que un siguiente resumeFromPark() no
    // intente reconectar a un canal viejo.
    _parkedChannelId = null;
    _log('Salió del canal Agora (mic liberado)');
  }

  /// "Estaciona" el canal: sale de Agora (deja de facturar minutos) pero
  /// recuerda el canal para reconexión rápida. El engine sigue vivo.
  ///
  /// Pensado para auto-disconnect por inactividad: nadie habla por X
  /// segundos → llamamos a `parkChannel()` para no quemar minutos Agora
  /// mientras el canal está mudo. Cuando alguien arranca a hablar
  /// (currentSpeakerId cambia de null → uid) llamamos a `resumeFromPark()`.
  ///
  /// **Mic release invariant:** `enableLocalAudio(false)` se llama antes
  /// del `leaveChannel()` interno, así que el mic hardware queda libre
  /// para otras apps mientras estamos parked.
  @override
  Future<void> parkChannel() async {
    if (_engine == null || !_isInChannel) return;
    final cid = _currentChannelId;
    if (cid == null) return;
    try {
      await _engine!.enableLocalAudio(false);
      await _engine!.leaveChannel();
    } catch (e) {
      _log('Error parkChannel: $e');
      return;
    }
    _isInChannel = false;
    _currentChannelId = null;
    _isMicPublishing = false;
    _parkedChannelId = cid;
    _log('🅿️ Canal "$cid" PARKED (engine vivo, no facturando minutos)');
  }

  /// Reconecta al canal parked. Idempotente: si ya estamos en canal o no
  /// hay nada parked, no hace nada.
  ///
  /// Devuelve `true` si se reconectó (o si ya estaba en canal); `false` si
  /// no había canal parked.
  @override
  Future<bool> resumeFromPark() async {
    if (_isInChannel) return true;
    final cid = _parkedChannelId;
    if (cid == null) return false;
    _log('🅿️▶️ resumeFromPark — reuniéndome a "$cid"');
    _parkedChannelId = null; // limpiamos antes del join para evitar bucles
    try {
      await joinChannel(cid);
      // joinChannel actualiza _isInChannel vía callback async, esperamos
      // brevemente para que la UI vea el estado actualizado.
      for (int i = 0; i < 60 && !_isInChannel; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return _isInChannel;
    } catch (e) {
      _log('Error resumeFromPark: $e');
      return false;
    }
  }

  /// Libera el micrófono hardware sin salir del canal.
  /// Útil cuando la app va a segundo plano.
  @override
  Future<void> releaseAudioCapture() async {
    if (_engine == null) return;
    try {
      await _engine!.updateChannelMediaOptions(
        const ChannelMediaOptions(
          publishMicrophoneTrack: false,
          clientRoleType: ClientRoleType.clientRoleAudience,
        ),
      );
      await _engine!.enableLocalAudio(false);
      _isMicPublishing = false;
      _log('🔇 Audio capture liberado (app en background, role=Audience)');
    } catch (e) {
      _log('Error releaseAudioCapture: $e');
    }
  }

  /// Re-habilita la recepción de audio remoto (al volver de background).
  /// NO habilita el mic local — eso solo ocurre con PTT.
  ///
  /// Forza speakerphone + mute off + volumen guardado para resolver
  /// el bug "al volver del background no se escucha". Android frecuentemente
  /// le saca el audio focus a la app cuando pasa a background y al volver
  /// no lo reclama solo — hay que pedirlo explícito.
  @override
  Future<void> resumeAudioReceive() async {
    if (_engine == null || !_isInChannel) return;
    try {
      await _engine!.muteAllRemoteAudioStreams(false);
      await _engine!.setEnableSpeakerphone(true);
      await _engine!.adjustPlaybackSignalVolume(_playbackVolume);
      _log('🔊 Audio remoto restaurado (foreground) — '
          'speaker=on, volumen=$_playbackVolume');
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
  @override
  Future<void> destroyEngine() async {
    // Si estamos parked, preferir el canal parked como "último" — así si
    // alguien llama a destroy estando parked y luego rearma, sabe a dónde
    // volver.
    _lastChannelBeforeDestroy = _currentChannelId ?? _parkedChannelId;
    _parkedChannelId = null;
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

    // Si _engine quedó null pero _isInitialized true (estado inconsistente
    // tras un crash/destroy parcial), forzar reset para volver a init bien.
    if (_isInitialized && _engine == null) {
      _log('⚠️ Estado inconsistente: _isInitialized=true pero _engine=null. Reset.');
      _isInitialized = false;
      _isInChannel = false;
    }

    if (!_isInitialized) {
      await initialize(channelHint: channelId);
    }

    if (!_isInChannel || _currentChannelId != channelId) {
      await joinChannel(channelId);

      // Esperar confirmación de join. Aumentado a 8s porque el callback
      // onJoinChannelSuccess puede tardar más cuando la app está en
      // background o la red es lenta (modo rural).
      for (int i = 0; i < 80 && !_isInChannel; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (!_isInChannel) {
        throw Exception('Timeout (8s) al unirse al canal');
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
  /// Si por alguna razón perdimos la conexión al canal, intentamos
  /// reconectar antes de unmute. Si falla, lanza excepción para que la UI
  /// muestre feedback al usuario (botón rojo de error).
  Future<void> quickPttStart(String channelId) async {
    _log('⚡ quickPttStart — unmute mic (canal persistente)');
    if (!_isInChannel || _engine == null) {
      _log('⚠️ quickPttStart: no está en canal (engine=$_engine, '
          'isInChannel=$_isInChannel), reconectando...');
      try {
        await overlayActivate(channelId);
      } catch (e) {
        _log('❌ quickPttStart: reconexión falló: $e');
        rethrow;
      }
    }
    await unmuteMic();
    if (!_isMicPublishing) {
      throw Exception('No se pudo activar el micrófono');
    }
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
  /// Pasa el role a Broadcaster para poder publicar audio. Esto es lo que
  /// activa la sesión de captura del SO, así que solo ocurre durante PTT.
  @override
  Future<void> unmuteMic() async {
    if (_engine == null || !_isInChannel) {
      _log('unmuteMic ignorado: engine=$_engine isInChannel=$_isInChannel');
      return;
    }
    try {
      // Primero habilitar captura de audio local (adquiere mic hardware)
      await _engine!.enableLocalAudio(true);
      await _engine!.updateChannelMediaOptions(
        const ChannelMediaOptions(
          publishMicrophoneTrack: true,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
        ),
      );
      _isMicPublishing = true;
      _log('🎙️ PTT ACTIVO — role=Broadcaster + publishMicrophoneTrack: true');
    } catch (e) {
      _log('Error unmuteMic: $e');
    }
  }

  /// Detiene la publicación del micrófono — llamar al SOLTAR PTT.
  /// Vuelve el role a Audience: deja de capturar el mic y libera la sesión
  /// de audio del SO, así WhatsApp/Zello pueden usar el micrófono.
  @override
  Future<void> muteMic() async {
    if (_engine == null || !_isInChannel) return;
    try {
      await _engine!.updateChannelMediaOptions(
        const ChannelMediaOptions(
          publishMicrophoneTrack: false,
          clientRoleType: ClientRoleType.clientRoleAudience,
        ),
      );
      // Liberar captura de mic hardware para que otras apps puedan usarlo
      await _engine!.enableLocalAudio(false);
      _isMicPublishing = false;
      _log('🔇 PTT INACTIVO — role=Audience + enableLocalAudio(false)');
    } catch (e) {
      _log('Error muteMic: $e');
    }
  }

  // ─────────────────── Grabación Local ───────────────────

  /// Inicia grabación local del audio del canal en [filePath].
  /// El archivo es AAC encoded (extensión .aac o .m4a).
  /// Captura TODO lo que se escucha en el canal (incluyendo nuestro propio
  /// PTT cuando estamos hablando) para tenerlo en historial local.
  Future<bool> startLocalRecording(String filePath) async {
    if (_engine == null || !_isInChannel) {
      _log('startLocalRecording ignorado: engine=$_engine, isInChannel=$_isInChannel');
      return false;
    }
    try {
      await _engine!.startAudioRecording(AudioRecordingConfiguration(
        filePath: filePath,
        sampleRate: 32000,
        fileRecordingType: AudioFileRecordingType.audioFileRecordingMixed,
        quality: AudioRecordingQualityType.audioRecordingQualityMedium,
      ));
      _log('🎬 Grabación local iniciada → $filePath');
      return true;
    } catch (e) {
      _log('Error startLocalRecording: $e');
      return false;
    }
  }

  Future<void> stopLocalRecording() async {
    if (_engine == null) return;
    try {
      await _engine!.stopAudioRecording();
      _log('⏹️ Grabación local detenida');
    } catch (e) {
      _log('Error stopLocalRecording: $e');
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

  @override
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

  /// Epoch en segundos para serializar a SharedPreferences (mismo
  /// formato que devuelve la Cloud Function).
  int get expiresAtEpoch => _expiresAt.millisecondsSinceEpoch ~/ 1000;

  /// Considera expirado 1h antes del verdadero expiry para dejar margen.
  bool get isExpired =>
      DateTime.now().isAfter(_expiresAt.subtract(const Duration(hours: 1)));
}
