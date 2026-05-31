import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show AndroidAudioConfiguration, Helper;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agora_service.dart' show AgoraService;
import 'voice_provider.dart';

/// Implementación de [VoiceProvider] sobre LiveKit self-hosted.
///
/// Reemplaza a Agora detrás del feature flag `associations/{id}.voiceProvider`.
/// El token se pide a la Cloud Function `generateLiveKitToken`, que devuelve
/// `{url, token, expiresAt}` (la URL es `wss://livekit.it-services.center`).
///
/// **Modelo PTT (igual que Agora):** se entra al canal en modo audiencia
/// (mic deshabilitado); al apretar PTT se publica el mic con [unmuteMic] y al
/// soltar se silencia con [muteMic] — el mic hardware queda libre.
///
/// **Volumen de reproducción (fix audio bajo / slider):** livekit_client 2.5.4
/// no expone `setVolume` en `RemoteAudioTrack`, PERO flutter_webrtc sí permite
/// ajustar la ganancia del track recibido vía `Helper.setVolume(factor, track)`
/// (mapea al nativo `AudioTrack.setVolume`, rango 0–10). Además, por defecto
/// flutter_webrtc rutea el audio WebRTC al stream `STREAM_VOICE_CALL`
/// (MODE_IN_COMMUNICATION / USAGE_VOICE_COMMUNICATION): se oye bajo y NO sube
/// con el volumen multimedia del celular. Por eso forzamos
/// `AndroidAudioConfiguration.media` (STREAM_MUSIC / USAGE_MEDIA, MODE_NORMAL)
/// tras conectar y en cada reconexión/resume → el audio sale por el altavoz al
/// volumen multimedia y el slider de ganancia (100–400 → 1.0–4.0) sí tiene
/// efecto audible. MODE_NORMAL coincide con bypassVoiceProcessing → no rompe el
/// invariante de mic libre. El valor del slider se persiste en SharedPreferences
/// y se reaplica a las pistas nuevas (TrackSubscribed) y en cold-start.
///
/// **Limitaciones conocidas de esta primera versión (ver spec, Fase 3):**
/// - `playLocalEffect`: LiveKit no mezcla SFX locales en el engine → devuelve
///   `false` para que la UI use su fallback (AudioPlayer).
/// - `startLocalRecording`/`stopLocalRecording`: el historial de audios local
///   aún no está soportado en LiveKit → no-op (devuelve `false`).
class LiveKitVoiceProvider implements VoiceProvider {
  LiveKitVoiceProvider._();
  static final LiveKitVoiceProvider instance = LiveKitVoiceProvider._();

  static const String _tokenFunctionName = 'generateLiveKitToken';
  static const Duration _tokenCallTimeout = Duration(seconds: 15);

  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;

  bool _isInitialized = false;
  bool _isInChannel = false;
  bool _isMicPublishing = false;
  // True mientras LiveKit está reconectando la Room (evento RoomReconnecting) o
  // mientras nuestro backoff de re-join está corriendo tras un RoomDisconnected
  // no intencional. La UI lo lee vía [isReconnecting].
  bool _isReconnecting = false;
  // Salida INTENCIONAL en curso (leaveChannel/destroyEngine/dispose/cambio de
  // cuenta). Mientras esté en true, un RoomDisconnectedEvent NO dispara la
  // auto-reconexión con backoff (no queremos resucitar una sesión que cerramos
  // a propósito).
  bool _intentionalDisconnect = false;
  // Reconexión con backoff en curso (la cancelamos si el usuario sale a propósito).
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  static const List<Duration> _reconnectBackoff = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];
  // Estado de mic DESEADO (último press/release gana) + cadena que serializa
  // los setMicrophoneEnabled. Toques rápidos de PTT (las llamadas son async
  // ~100-300ms) se solapaban y el mic quedaba PEGADO en ON. La cadena aplica
  // siempre el `_micWanted` más reciente, en orden, sin overlap → converge a
  // OFF si soltaste de último.
  bool _micWanted = false;
  Future<void> _micChain = Future<void>.value();
  bool _isRemoteAudioMuted = false;
  // Default 200 = factor 2.0 (boost). Con bypassVoiceProcessing=true no hay AGC,
  // el audio entra más bajo; este boost + altavoz forzado compensan. Slider 100–400.
  int _playbackVolume = 200;
  // Clave de persistencia del volumen del radio (mismo comportamiento que Agora:
  // sobrevive a cold-starts para no perder la ganancia que ajustó el conductor).
  static const String _kPrefsPlaybackVolume = 'livekit_playback_volume';
  bool _volumeHydrated = false;

  // Guarda de idempotencia: el provider es singleton y varios componentes
  // (página walkie + RadioForegroundService) pueden llamar joinChannel sobre
  // el mismo canal. Sin esto, cada llamada recreaba el Room → dos conexiones
  // con la misma identidad → LiveKit expulsa (`duplicateIdentity`) y el
  // handshake DTLS nunca completa. `_targetChannelId` = canal al que estamos
  // conectados o conectándonos.
  bool _connecting = false;
  String? _targetChannelId;
  // Connect en curso: callers concurrentes (ej. el primer PTT tras reabrir)
  // lo esperan para no transmitir a una sala a medio conectar.
  Future<void>? _joinInFlight;

  String? _currentChannelId;
  String? _parkedChannelId;
  String? _lastChannelBeforeDestroy;

  // BUG mic — true si entramos al canal SIN poder pre-publicar el mic (permiso
  // no concedido en ese momento). El engine WebRTC quedó "sin micrófono"; un
  // unmuteMic posterior no lo re-adquiere. Cuando el permiso se concede después,
  // [ensureMicReady] re-inicializa el engine para tomarlo (sin reiniciar la app).
  bool _joinedWithoutMic = false;

  // Token cacheado por canal (url + jwt + expiry).
  final Map<String, _LiveKitToken> _tokenCache = {};

  // BUG 1 — identidad de la sesión de voz activa. El JWT de LiveKit embebe la
  // identidad = uid del usuario. Como el provider es singleton, al cambiar de
  // cuenta SIN reiniciar (logout de A → login de B) el `_tokenCache` y la
  // `Room` conectada seguían usando la identidad de A → el servidor LiveKit
  // veía al dispositivo como A. Guardamos el uid con el que se generó el
  // token/room para detectar el cambio y forzar teardown + refetch.
  String? _identityUid;

  void Function(bool active)? _onLocalVoiceActivity;
  void Function(String message)? _onError;

  void _log(String msg) => debugPrint('[LiveKit] $msg');

  // ─────────────────── Token ───────────────────

  Future<_LiveKitToken> _fetchToken(String channelId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('Usuario no autenticado al pedir token LiveKit');
    }

    // BUG 1 — detección de cambio de uid: si el usuario autenticado AHORA no
    // es el dueño de la sesión de voz activa, todo el estado cacheado (tokens
    // por canal + Room conectada) pertenece a la cuenta anterior. Lo
    // invalidamos antes de usar el cache para no reusar la identidad vieja.
    if (_identityUid != null && _identityUid != user.uid) {
      _log('Cambio de uid detectado ($_identityUid → ${user.uid}) — '
          'teardown + invalidar tokens');
      await _resetIdentityState();
    }

    final cached = _tokenCache[channelId];
    if (cached != null && !cached.isExpired) return cached;

    try {
      await user.getIdToken(true);
    } catch (e) {
      _log('⚠️ No se pudo refrescar idToken: $e');
    }

    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable(_tokenFunctionName)
          .call({'channelName': channelId}).timeout(_tokenCallTimeout);

      final data = (res.data as Map?) ?? const {};
      final url = data['url'] as String?;
      final token = data['token'] as String?;
      final expiresAt = (data['expiresAt'] as num?)?.toInt();

      if (url == null || url.isEmpty || token == null || token.isEmpty) {
        throw Exception('Respuesta inválida de generateLiveKitToken');
      }
      final t = _LiveKitToken(url: url, token: token, expiresAt: expiresAt);
      _tokenCache[channelId] = t;
      // BUG 1 — sella la sesión de voz con el uid que generó el token. Las
      // próximas llamadas comparan contra esto para detectar cambio de cuenta.
      _identityUid = user.uid;
      _log('Token LiveKit recibido OK (${token.length} chars) para uid=${user.uid}');
      return t;
    } on FirebaseFunctionsException catch (e) {
      _log('❌ Cloud Function error (${e.code}): ${e.message}');
      throw Exception('No se pudo obtener token LiveKit: ${e.message ?? e.code}');
    }
  }

  @override
  void prewarmToken(String channelId) {
    // Prefetch del JWT para acelerar el primer joinChannel. No bloquea.
    unawaited(_fetchToken(channelId).then(
      (_) {},
      onError: (e) => _log('prewarmToken falló (ignorado): $e'),
    ));
  }

  // ─────────────────── Lifecycle ───────────────────

  // Inicialización del SDK WebRTC (una sola vez). bypassVoiceProcessing=true
  // hace que LiveKit configure el audio Android en MODE_NORMAL (media) en vez
  // de MODE_IN_COMMUNICATION. Crítico para el invariante de liberación del mic:
  // con communication, el SO RESERVA el micrófono toda la conexión (aunque
  // estés solo escuchando) → otras apps no pueden grabar. Con media, el mic
  // solo se ocupa cuando hay un track publicando (durante PTT) y queda libre
  // el resto. Debe correr ANTES de cualquier Room.connect.
  static bool _sdkInitialized = false;
  Future<void> _ensureSdkInit() async {
    if (_sdkInitialized) return;
    try {
      // bypass=true: MODE_NORMAL → mic libre para otras apps. Idempotente con
      // el init de main(); si ya se inicializó, no-op.
      await lk.LiveKitClient.initialize(bypassVoiceProcessing: true);
    } catch (e) {
      _log('LiveKitClient.initialize: $e');
    }
    _sdkInitialized = true; // no reintentar aunque falle (evita loops)
  }

  @override
  Future<void> initialize({String? channelHint}) async {
    await _ensureSdkInit();
    // LiveKit no requiere un engine global: la sala se crea por conexión.
    _isInitialized = true;
    if (channelHint != null && channelHint.isNotEmpty) {
      prewarmToken(channelHint);
    }
    _log('initialize OK (channelHint=$channelHint)');
  }

  @override
  Future<void> joinChannel(String channelId) async {
    // Idempotente: si ya estamos conectados o conectándonos a este canal, no
    // recrear el Room (evita el duplicateIdentity / thrashing que tumba DTLS).
    // Si hay un connect EN CURSO al mismo canal, ESPERAMOS a que termine —
    // clave para que el primer PTT tras reabrir no transmita a una sala a
    // medio conectar (se perdía el primer audio).
    if (_targetChannelId == channelId && (_isInChannel || _connecting)) {
      _log('joinChannel idempotente (ya en/entrando a $channelId)');
      final inFlight = _joinInFlight;
      if (inFlight != null) {
        try {
          await inFlight;
        } catch (_) {}
      }
      return;
    }

    _targetChannelId = channelId;
    _connecting = true;
    final fut = _doJoin(channelId);
    _joinInFlight = fut;
    try {
      await fut;
    } finally {
      if (identical(_joinInFlight, fut)) _joinInFlight = null;
      _connecting = false;
    }
  }

  Future<void> _doJoin(String channelId) async {
    // Vamos a conectar (o reconectar) a propósito: limpiamos la bandera de
    // salida intencional para que un eventual RoomDisconnected futuro sí dispare
    // la auto-reconexión.
    _intentionalDisconnect = false;
    try {
      await _ensureSdkInit(); // bypassVoiceProcessing ANTES de conectar
      await _hydrateVolume(); // recupera la ganancia persistida (cold-start)
      // Fija la ruta de audio MEDIA (stream MUSIC) en el AudioSwitchManager
      // ANTES de connect, para que WebRTC active el foco de audio ya con el
      // stream correcto (la doc recomienda configurarlo antes de la sesión). Se
      // reaplica tras connect/reconnect/resume por si el SO lo revierte.
      try {
        await Helper.setAndroidAudioConfiguration(
            AndroidAudioConfiguration.media);
      } catch (e) {
        _log('setAndroidAudioConfiguration(pre-connect): $e');
      }
      final t = await _fetchToken(channelId);

      // Cambiando de canal (o reconectando): cierra la sala previa.
      await _teardownRoom();

      final room = lk.Room(
        roomOptions: const lk.RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioPublishOptions: lk.AudioPublishOptions(
            dtx: true, // Discontinuous transmission — clave para PTT
          ),
          // Procesamiento de audio por SOFTWARE (WebRTC APM). Funciona sobre el
          // mic CRUDO (bypassVoiceProcessing=true) sin reservar el micrófono:
          //  - noiseSuppression: supresión de ruido software
          //  - echoCancellation: cancela eco (medio-dúplex igual ayuda)
          //  - autoGainControl: normaliza/sube el volumen del que habla
          //  - highPassFilter: corta el ruido grave (motor/calle) — clave en taxi
          //  - typingNoiseDetection / voiceIsolation: aíslan la voz
          defaultAudioCaptureOptions: lk.AudioCaptureOptions(
            noiseSuppression: true,
            echoCancellation: true,
            autoGainControl: true,
            highPassFilter: true,
            typingNoiseDetection: true,
            voiceIsolation: true,
          ),
        ),
      );

      final listener = room.createListener();
      listener
        ..on<lk.RoomReconnectingEvent>((e) {
          // El SDK detectó pérdida de conexión y está reconectando solo
          // (ICE/transport). No tocamos la Room; solo exponemos el estado.
          _isReconnecting = true;
          _log('RoomReconnecting (SDK auto-reconnect en curso)');
        })
        ..on<lk.RoomReconnectedEvent>((e) {
          // El SDK recuperó la conexión por su cuenta. Re-forzamos altavoz y
          // volumen (el SO pudo soltar el audio focus) y limpiamos el estado.
          _isReconnecting = false;
          _isInChannel = true;
          _log('RoomReconnected (recuperado por el SDK)');
          unawaited(() async {
            await _forceMediaAudioRoute();
            await _applyVolumeAll();
          }());
        })
        ..on<lk.RoomDisconnectedEvent>((e) {
          _isInChannel = false;
          _isMicPublishing = false;
          // Permite re-join: limpia el target salvo que sea un cierre limpio.
          if (_targetChannelId == channelId) _targetChannelId = null;
          _log('RoomDisconnected: ${e.reason}');
          // Si la salida fue INTENCIONAL (leave/destroy/dispose/cambio de
          // cuenta) no resucitamos nada. Si NO lo fue y el radio debería seguir
          // conectado, lanzamos la reconexión con backoff (el SDK ya intentó su
          // auto-reconnect y se rindió → RoomDisconnected es definitivo).
          if (_intentionalDisconnect) {
            _isReconnecting = false;
          } else {
            _scheduleReconnect(channelId);
          }
        })
        ..on<lk.ActiveSpeakersChangedEvent>((e) {
          final lp = room.localParticipant;
          final speaking =
              lp != null && e.speakers.any((s) => s.sid == lp.sid);
          _onLocalVoiceActivity?.call(speaking);
        })
        ..on<lk.TrackSubscribedEvent>((e) {
          // Aplica el volumen/mute actual a cada audio remoto que entra.
          final t = e.track;
          if (t is lk.RemoteAudioTrack) _applyVolumeToTrack(t);
        });

      await room.connect(t.url, t.token);
      // Ruta de audio MEDIA + ALTAVOZ. Por defecto flutter_webrtc rutea el audio
      // recibido al stream VOICE_CALL (MODE_IN_COMMUNICATION): se oye bajo y NO
      // sube con el volumen MULTIMEDIA que el conductor pone al máximo. Forzamos
      // el stream MUSIC/USAGE_MEDIA (MODE_NORMAL) — así sale fuerte por el
      // altavoz y el slider de ganancia tiene efecto real. MODE_NORMAL coincide
      // con bypassVoiceProcessing → NO rompe el mic libre.
      await _forceMediaAudioRoute();
      _room = room;
      _listener = listener;
      _currentChannelId = channelId;
      _parkedChannelId = null;
      _isInChannel = true;
      _isMicPublishing = false;
      // BUG 2 — pre-publicar el mic AHORA (al conectar) y dejarlo muteado. Así
      // la negociación SDP / publicación del track de audio (lo caro: crear el
      // sender + transceiver y renegociar) se paga UNA vez aquí, no al primer
      // PTT. Después, apretar PTT solo hace unmute (restart del MediaStreamTrack
      // sobre el sender ya existente) → mucho más rápido que el publish inicial.
      //
      // MIC LIBRE PRESERVADO: con stopAudioCaptureOnMute=true (default en
      // AudioCaptureOptions y vigente en Android, donde skipStopForTrackMute()
      // es false), el mute() de LiveKit llama mediaStreamTrack.stop() → SUELTA
      // el micrófono hardware. Por eso pre-publicar + mutear NO acapara el mic
      // en reposo: el track queda publicado (negociado) pero su captura física
      // está detenida; otras apps pueden grabar mientras no se transmite.
      await _prepublishMic(room);
      _log('joinChannel OK: $channelId');
    } catch (e) {
      _log('❌ joinChannel: $e');
      _isInChannel = false;
      if (_targetChannelId == channelId) _targetChannelId = null;
      _onError?.call('joinChannel: $e');
      rethrow;
    }
  }

  @override
  Future<void> leaveChannel() async {
    _intentionalDisconnect = true; // salida a propósito → no auto-reconectar
    _cancelReconnect();
    _targetChannelId = null;
    await _teardownRoom();
    _currentChannelId = null;
    _parkedChannelId = null;
    _isInChannel = false;
    _isMicPublishing = false;
    _log('leaveChannel OK');
  }

  @override
  Future<void> parkChannel() async {
    // LiveKit self-hosted NO factura por minuto (a diferencia de Agora), así
    // que NO desconectamos durante los silencios: mantener la conexión viva
    // = el conductor escucha la siguiente transmisión al instante, sin perder
    // el arranque ni esperar reconexión. No-op intencional (no marca parked,
    // por eso `isParked` queda false y la lógica de auto-resume del walkie se
    // salta sola). Resuelve el "resume poco fluido" del modelo Agora.
    _log('parkChannel ignorado (LiveKit: conexión persistente, sin billing)');
  }

  @override
  Future<bool> resumeFromPark() async {
    // Como parkChannel es no-op, normalmente seguimos conectados → instantáneo.
    if (_isInChannel) return true;
    // Si hay un connect en curso (ej. reabrir app → auto-reconexión al último
    // canal), `_targetChannelId` lo apunta: joinChannel lo espera (idempotente).
    final ch = _parkedChannelId ??
        _targetChannelId ??
        _currentChannelId ??
        _lastChannelBeforeDestroy;
    if (ch == null || ch.isEmpty) return false;
    try {
      await joinChannel(ch);
      return _isInChannel;
    } catch (e) {
      _log('resumeFromPark reconexión falló: $e');
      return false;
    }
  }

  @override
  Future<void> destroyEngine() async {
    _intentionalDisconnect = true; // teardown a propósito → no auto-reconectar
    _cancelReconnect();
    _lastChannelBeforeDestroy = _currentChannelId ?? _parkedChannelId;
    _targetChannelId = null;
    await _teardownRoom();
    _currentChannelId = null;
    _parkedChannelId = null;
    _isInChannel = false;
    _isMicPublishing = false;
    _isInitialized = false;
    _log('destroyEngine — último canal: $_lastChannelBeforeDestroy');
  }

  @override
  Future<void> dispose() async {
    _lastChannelBeforeDestroy = null; // dispose intencional: no auto-rejoin
    await destroyEngine();
    // BUG 1 — dispose es el teardown intencional (logout/app kill): la sesión
    // de voz ya no pertenece a nadie. Invalida tokens cacheados e identidad
    // para que el próximo usuario pida un token fresco con SU identidad.
    _tokenCache.clear();
    _identityUid = null;
    _log('dispose completo (tokens + identidad invalidados)');
  }

  /// BUG 1 — Resetea TODO el estado ligado a la identidad del usuario actual:
  /// desconecta/dispone la Room viva, invalida los tokens cacheados (cada uno
  /// embebe la identidad/uid del dueño) y limpia el uid sellado. Tras esto el
  /// provider queda listo para pedir un token fresco con la nueva identidad en
  /// el próximo [joinChannel]. NO guarda "último canal" → no auto-reconecta con
  /// la cuenta vieja. Lo llama [VoiceProviderFactory.resetForUserChange] desde
  /// el listener de auth (logout y login de un uid distinto).
  Future<void> resetForUserChange() async {
    _log('resetForUserChange — teardown completo de la sesión de voz');
    await _resetIdentityState();
  }

  /// Teardown común para cambio de cuenta: cierra la Room, olvida canales y
  /// purga tokens + identidad. No marca `_lastChannelBeforeDestroy` para evitar
  /// que el auto-resume reconecte con la identidad anterior.
  Future<void> _resetIdentityState() async {
    _intentionalDisconnect = true; // cambio de cuenta → no auto-reconectar
    _cancelReconnect();
    _targetChannelId = null;
    await _teardownRoom();
    _currentChannelId = null;
    _parkedChannelId = null;
    _lastChannelBeforeDestroy = null;
    _isInChannel = false;
    _isMicPublishing = false;
    _micWanted = false;
    _joinedWithoutMic = false;
    _tokenCache.clear();
    _identityUid = null;
  }

  // ─────────────────── Overlay PTT (Canal Persistente) ───────────────────

  @override
  Future<void> overlayActivate(String channelId) async {
    if (!_isInitialized) await initialize(channelHint: channelId);
    if (!_isInChannel || _currentChannelId != channelId) {
      await joinChannel(channelId); // joinChannel ya espera el connect
    }
    await muteMic(); // mic OFF — se enciende solo al presionar PTT
    _log('overlayActivate LISTO — $channelId, mic OFF');
  }

  @override
  Future<void> overlayDeactivate() async {
    // LiveKit = conexión persistente (hasPersistentConnection=true): NO
    // destruimos el engine al desactivar el overlay. La Room sigue viva para
    // que el radio dentro de la app continúe escuchando/transmitiendo. Solo
    // garantizamos que el mic quede muteado (mic hardware libre en reposo).
    // El teardown real (mic 100% libre del SO) ocurre en destroyEngine/dispose
    // cuando se apaga el radio o se cierra sesión.
    await muteMic();
    _log('overlayDeactivate (persistente) — Room intacta, mic OFF');
  }

  @override
  Future<void> quickPttStart(String channelId) async {
    // Reconectar si el SO mató la conexión en background.
    if (!_isInChannel || _room == null) {
      await overlayActivate(channelId);
    }
    await unmuteMic();
    if (!_isMicPublishing) {
      throw Exception('No se pudo activar el micrófono');
    }
  }

  @override
  Future<void> quickPttStop() async {
    await muteMic();
  }

  /// Programa un intento de reconexión con backoff (2s, 5s, 10s; luego se
  /// queda en 10s) tras un RoomDisconnected NO intencional. Idempotente: si ya
  /// hay un timer pendiente, no encola otro. Se cancela en cuanto el usuario
  /// sale a propósito ([_cancelReconnect]).
  void _scheduleReconnect(String channelId) {
    if (_intentionalDisconnect) return;
    if (_reconnectTimer != null && _reconnectTimer!.isActive) return;
    _isReconnecting = true;
    final delay = _reconnectAttempt < _reconnectBackoff.length
        ? _reconnectBackoff[_reconnectAttempt]
        : _reconnectBackoff.last;
    _log('Reconexión programada en ${delay.inSeconds}s '
        '(intento ${_reconnectAttempt + 1}) → canal $channelId');
    _reconnectTimer = Timer(delay, () async {
      _reconnectTimer = null;
      // El usuario pudo salir mientras esperábamos, o ya nos reconectamos.
      if (_intentionalDisconnect || _isInChannel) {
        _isReconnecting = false;
        return;
      }
      _reconnectAttempt++;
      try {
        _log('Reintentando join a $channelId…');
        await joinChannel(channelId);
        if (_isInChannel) {
          _reconnectAttempt = 0;
          _isReconnecting = false;
          _log('Reconexión OK a $channelId');
          return;
        }
      } catch (e) {
        _log('Reintento de reconexión falló: $e');
      }
      // Sigue caído → reprogramar (a menos que el usuario haya salido).
      if (!_intentionalDisconnect && !_isInChannel) {
        _scheduleReconnect(channelId);
      } else {
        _isReconnecting = false;
      }
    });
  }

  /// Cancela cualquier reconexión pendiente y resetea el contador de backoff.
  /// Llamar en toda salida intencional para no resucitar la sesión.
  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _isReconnecting = false;
  }

  Future<void> _teardownRoom() async {
    try {
      await _listener?.dispose();
    } catch (_) {}
    _listener = null;
    try {
      await _room?.disconnect();
    } catch (_) {}
    try {
      await _room?.dispose();
    } catch (_) {}
    _room = null;
  }

  // ─────────────────── Mic (PTT) ───────────────────

  /// BUG 2 — Publica el track de mic una vez tras conectar y lo deja muteado.
  /// El `setMicrophoneEnabled(true)` inicial crea la publicación (negociación
  /// SDP, lo costoso); el `setMicrophoneEnabled(false)` inmediato lo silencia
  /// y —por stopAudioCaptureOnMute=true— suelta el mic hardware. Resultado: la
  /// publicación queda lista para que el primer PTT solo haga unmute (rápido),
  /// sin acaparar el micrófono mientras nadie transmite.
  Future<void> _prepublishMic(lk.Room room) async {
    final lp = room.localParticipant;
    if (lp == null) return;
    try {
      await lp.setMicrophoneEnabled(true); // publica + negocia (una vez)
      await lp.setMicrophoneEnabled(false); // mute → stop captura → mic libre
      _isMicPublishing = false;
      _micWanted = false;
      _joinedWithoutMic = false; // mic adquirido OK
      _log('mic pre-publicado y muteado (PTT instantáneo, mic libre OK)');
    } catch (e) {
      // Si falla (p.ej. permiso aún no concedido), no rompemos el join: el mic
      // se publicará perezosamente en el primer unmuteMic (vuelve al camino
      // viejo, solo con el retardo de la primera vez). Marcamos que entramos
      // SIN mic para que [ensureMicReady] re-inicialice el engine cuando el
      // permiso se conceda después (sin reiniciar la app).
      _isMicPublishing = false;
      _joinedWithoutMic = true;
      _log('pre-publicación de mic falló (se publicará en el 1er PTT): $e');
    }
  }

  @override
  Future<void> unmuteMic() => _setMic(true);

  @override
  Future<void> muteMic() => _setMic(false);

  /// Cambia el estado del mic de forma SERIALIZADA y convergente. Cada llamada
  /// fija `_micWanted` y encola la aplicación en `_micChain`; cada paso aplica
  /// el deseo MÁS RECIENTE (no el de cuando se encoló), así press+release
  /// rápidos se colapsan y el mic nunca queda pegado en ON.
  Future<void> _setMic(bool want) {
    _micWanted = want;
    _micChain = _micChain.then((_) async {
      final lp = _room?.localParticipant;
      if (lp == null) return;
      // Aplicar el deseo actual (pudo cambiar mientras estábamos en cola).
      final target = _micWanted;
      if (target == _isMicPublishing) return; // ya está como se quiere
      try {
        await lp.setMicrophoneEnabled(target);
        _isMicPublishing = target;
      } catch (e) {
        _log('setMic($target): $e');
        if (target) _onError?.call('unmuteMic: $e');
      }
    });
    return _micChain;
  }

  @override
  Future<void> releaseAudioCapture() async {
    // Libera la captura de mic sin salir del canal (app a background).
    await muteMic();
  }

  @override
  Future<void> resumeAudioReceive() async {
    // Re-habilita la recepción de audio remoto al volver de background.
    _isRemoteAudioMuted = false;
    await _forceMediaAudioRoute();
    await _applyVolumeAll();
  }

  // ─────────────────── Control de audio ───────────────────

  @override
  int get playbackVolume => _playbackVolume;

  @override
  Future<void> setPlaybackVolume(int volume) async {
    _playbackVolume = volume.clamp(
        AgoraService.playbackVolumeMin, AgoraService.playbackVolumeMax);
    _volumeHydrated = true; // valor explícito del usuario: no lo pisa la hidratación
    await _applyVolumeAll();
    // Persistir para sobrevivir cold-starts (mismo comportamiento que Agora).
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPrefsPlaybackVolume, _playbackVolume);
    } catch (_) {}
    _log('🔊 Volumen radio = $_playbackVolume (factor ${_playbackVolume / 100.0})');
  }

  /// Carga el volumen del radio persistido (una sola vez por proceso). Si el
  /// usuario ya ajustó el slider en esta sesión, NO lo sobrescribe.
  Future<void> _hydrateVolume() async {
    if (_volumeHydrated) return;
    _volumeHydrated = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_kPrefsPlaybackVolume);
      if (saved != null) {
        _playbackVolume = saved.clamp(
            AgoraService.playbackVolumeMin, AgoraService.playbackVolumeMax);
        _log('Volumen radio hidratado: $_playbackVolume');
      }
    } catch (_) {}
  }

  /// Fuerza la ruta de audio a MEDIA (stream MUSIC / USAGE_MEDIA, MODE_NORMAL)
  /// y el altavoz. Es la corrección del "audio bajo": por defecto flutter_webrtc
  /// rutea el audio recibido al stream VOICE_CALL, que se oye bajo y NO sube con
  /// el volumen multimedia del celular. En Android `AndroidAudioConfiguration.media`
  /// lo manda al stream MUSIC; en iOS es no-op interno. MODE_NORMAL mantiene el
  /// mic libre (igual que bypassVoiceProcessing). Idempotente y seguro de llamar
  /// tras conectar, en reconexión y al volver de background.
  Future<void> _forceMediaAudioRoute() async {
    try {
      await Helper.setAndroidAudioConfiguration(AndroidAudioConfiguration.media);
    } catch (e) {
      _log('setAndroidAudioConfiguration(media): $e');
    }
    try {
      await lk.Hardware.instance.setSpeakerphoneOn(true);
    } catch (e) {
      _log('setSpeakerphoneOn: $e');
    }
  }

  @override
  Future<void> setRemoteAudioMuted(bool muted) async {
    // Mute = volumen 0 (mantiene la suscripción, sin cortar el track).
    _isRemoteAudioMuted = muted;
    await _applyVolumeAll();
  }

  /// Aplica el volumen/mute actual a TODOS los audios remotos suscritos.
  Future<void> _applyVolumeAll() async {
    final room = _room;
    if (room == null) return;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        final t = pub.track;
        if (t is lk.RemoteAudioTrack) await _applyVolumeToTrack(t);
      }
    }
  }

  /// Ajusta el volumen de un audio remoto. Agora usa 100=original..400;
  /// WebRTC usa un factor (1.0 = original), así que dividimos /100.
  Future<void> _applyVolumeToTrack(lk.RemoteAudioTrack track) async {
    try {
      final factor = _isRemoteAudioMuted ? 0.0 : (_playbackVolume / 100.0);
      await Helper.setVolume(factor, track.mediaStreamTrack);
    } catch (e) {
      _log('setVolume: $e');
    }
  }

  // ─────────────────── Grabación local (no soportada aún) ───────────────────

  @override
  Future<bool> startLocalRecording(String filePath,
      {bool recordMic = false}) async {
    // NO soportado en LiveKit client-side: grabar el audio WebRTC en vivo con
    // MediaRecorder (INPUT/OUTPUT) en Android PELEA con la llamada — el
    // recorder acapara el mic (falla `unmuteMic`/publish) y el OUTPUT corta
    // el pipeline de reproducción (audio entrecortado). Devolvemos false para
    // que el walkie NO cree entrada de historial. El historial centralizado,
    // si se requiere, va por LiveKit Egress (server-side, no toca al cliente).
    return false;
  }

  @override
  Future<void> stopLocalRecording() async {
    // no-op (la grabación local está deshabilitada — ver startLocalRecording)
  }

  // ─────────────────── Efectos / permisos ───────────────────

  @override
  Future<bool> playLocalEffect(String filePath, {int soundId = 1}) async {
    // LiveKit no mezcla efectos locales en el pipeline del engine.
    // Devolvemos false para que la UI use su fallback (AudioPlayer).
    return false;
  }

  @override
  Future<bool> hasMicPermission() async {
    final status = await Permission.microphone.status;
    return status.isGranted;
  }

  @override
  Future<void> ensureMicReady() async {
    // Solo actuamos si entramos al canal sin mic Y el permiso YA está concedido.
    // En cualquier otro caso es un no-op rápido (no toca el engine sano).
    if (!_joinedWithoutMic) return;
    if (!await hasMicPermission()) return;

    _log('ensureMicReady — re-inicializando engine para tomar el mic concedido');
    final ch = _currentChannelId ?? _targetChannelId ?? _lastChannelBeforeDestroy;
    try {
      await destroyEngine();
      await initialize(channelHint: ch);
      if (ch != null && ch.isNotEmpty) {
        await joinChannel(ch);
      }
      _joinedWithoutMic = false;
      _log('ensureMicReady OK — engine re-creado con mic disponible (canal=$ch)');
    } catch (e) {
      // Si falla, dejamos el flag para reintentar en el próximo PTT/resume.
      _log('❌ ensureMicReady: $e');
    }
  }

  // ─────────────────── Estado ───────────────────

  @override
  bool get isInitialized => _isInitialized;

  @override
  bool get isInChannel => _isInChannel;

  @override
  bool get isReconnecting => _isReconnecting;

  @override
  bool get isMicMuted => !_isMicPublishing;

  @override
  bool get isParked => _parkedChannelId != null;

  // LiveKit self-hosted: conexión persistente, sin facturación por minuto.
  // parkChannel es no-op → no usamos el timer de park (evita spam cada 5s).
  @override
  bool get supportsPark => false;

  // LiveKit self-hosted: la Room queda conectada mientras el engine vive →
  // el overlay PTT puede reusar la conexión (activación instantánea, sin
  // destroy/rejoin). Ver OverlayPttService.start/stop y walkie_talkie_page.
  @override
  bool get hasPersistentConnection => true;

  @override
  String? get currentChannelId => _currentChannelId;

  @override
  String? get parkedChannelId => _parkedChannelId;

  bool get isRemoteAudioMuted => _isRemoteAudioMuted;

  @override
  String? get lastChannelBeforeDestroy => _lastChannelBeforeDestroy;

  // ─────────────────── Callbacks ───────────────────

  @override
  set onLocalVoiceActivity(void Function(bool active)? cb) =>
      _onLocalVoiceActivity = cb;

  @override
  set onError(void Function(String message)? cb) => _onError = cb;
}

/// Token LiveKit cacheado con expiración informada por el servidor.
class _LiveKitToken {
  _LiveKitToken({required this.url, required this.token, int? expiresAt})
      : _expiresAt = expiresAt != null
            ? DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)
            : DateTime.now().add(const Duration(hours: 20));

  final String url;
  final String token;
  final DateTime _expiresAt;

  /// Considera expirado 1h antes del verdadero expiry para dejar margen.
  bool get isExpired =>
      DateTime.now().isAfter(_expiresAt.subtract(const Duration(hours: 1)));
}
