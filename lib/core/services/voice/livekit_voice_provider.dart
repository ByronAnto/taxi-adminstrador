import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:permission_handler/permission_handler.dart';

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
/// **Limitaciones conocidas de esta primera versión (ver spec, Fase 3):**
/// - `playLocalEffect`: LiveKit no mezcla SFX locales en el engine → devuelve
///   `false` para que la UI use su fallback (AudioPlayer).
/// - `startLocalRecording`/`stopLocalRecording`: el historial de audios local
///   aún no está soportado en LiveKit → no-op (devuelve `false`).
/// - `setPlaybackVolume`: livekit_client 2.5.4 no expone control de volumen de
///   reproducción en runtime → se guarda el valor (lo consume el slider) pero
///   no se aplica a nivel SDK.
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
    try {
      await _ensureSdkInit(); // bypassVoiceProcessing ANTES de conectar
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
        ..on<lk.RoomDisconnectedEvent>((e) {
          _isInChannel = false;
          _isMicPublishing = false;
          // Permite re-join: limpia el target salvo que sea un cierre limpio.
          if (_targetChannelId == channelId) _targetChannelId = null;
          _log('RoomDisconnected: ${e.reason}');
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
      // Forzar salida por ALTAVOZ. Con bypassVoiceProcessing (MODE_NORMAL) el
      // audio remoto se rutea al auricular y se oye bajísimo; esto lo manda al
      // speaker (como hacía Agora). Sin headset/BT enchufado.
      try {
        await lk.Hardware.instance.setSpeakerphoneOn(true);
      } catch (e) {
        _log('setSpeakerphoneOn: $e');
      }
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
    _targetChannelId = null;
    await _teardownRoom();
    _currentChannelId = null;
    _parkedChannelId = null;
    _lastChannelBeforeDestroy = null;
    _isInChannel = false;
    _isMicPublishing = false;
    _micWanted = false;
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
    await destroyEngine();
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
      _log('mic pre-publicado y muteado (PTT instantáneo, mic libre OK)');
    } catch (e) {
      // Si falla (p.ej. permiso aún no concedido), no rompemos el join: el mic
      // se publicará perezosamente en el primer unmuteMic (vuelve al camino
      // viejo, solo con el retardo de la primera vez).
      _isMicPublishing = false;
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
    try {
      await lk.Hardware.instance.setSpeakerphoneOn(true);
    } catch (_) {}
    await _applyVolumeAll();
  }

  // ─────────────────── Control de audio ───────────────────

  @override
  int get playbackVolume => _playbackVolume;

  @override
  Future<void> setPlaybackVolume(int volume) async {
    _playbackVolume = volume.clamp(
        AgoraService.playbackVolumeMin, AgoraService.playbackVolumeMax);
    await _applyVolumeAll();
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

  // ─────────────────── Estado ───────────────────

  @override
  bool get isInitialized => _isInitialized;

  @override
  bool get isInChannel => _isInChannel;

  @override
  bool get isMicMuted => !_isMicPublishing;

  @override
  bool get isParked => _parkedChannelId != null;

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
