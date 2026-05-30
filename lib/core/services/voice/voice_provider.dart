/// Capa de abstracción para el proveedor de audio en tiempo real
/// (walkie-talkie). Hoy hay un único provider (Agora); en Fase 3 de
/// la migración aterriza `LiveKitVoiceProvider` y se selecciona por
/// `voiceProvider` en `associations/{id}` vía `VoiceProviderFactory`.
///
/// **Diseño:** la interfaz expone *únicamente* el API común que la UI
/// del walkie consume — joining, mic on/off, park/resume, lifecycle,
/// permisos, callbacks. Funcionalidad provider-específica (overlay PTT
/// Android, token prewarming) sigue siendo de implementación, no parte
/// del contrato.
///
/// Referencia: `docs/superpowers/specs/2026-05-19-livekit-hybrid-migration.md`
abstract class VoiceProvider {
  /// Inicializa el engine. `channelHint` permite al provider pre-traer
  /// el token del canal probable para acelerar el primer `joinChannel`.
  Future<void> initialize({String? channelHint});

  /// Se une al canal `channelId` en modo audience (sin publicar mic).
  /// El mic local se publica con [unmuteMic] al apretar PTT.
  Future<void> joinChannel(String channelId);

  /// Sale del canal y libera el mic. Limpia cualquier estado de park.
  Future<void> leaveChannel();

  /// "Estaciona" el canal: sale del canal Agora/LiveKit (deja de
  /// facturar minutos) pero mantiene el engine vivo. [resumeFromPark]
  /// lo reanuda en ~300 ms. Implementado para el auto-disconnect por
  /// inactividad — ahorro de costos cuando nadie habla en el canal.
  Future<void> parkChannel();

  /// Reconecta al canal previamente parked. Idempotente.
  /// Devuelve true si quedó conectado al final.
  Future<bool> resumeFromPark();

  /// Publica el mic local (PTT presionado). Pasa el role a Broadcaster
  /// si el provider distingue roles.
  Future<void> unmuteMic();

  /// Deja de publicar el mic (PTT soltado). Crítico: el mic hardware
  /// debe quedar libre para otras apps. Ver memory
  /// `feedback_mic_release_invariant.md` para los 6 escenarios donde
  /// esto se valida.
  Future<void> muteMic();

  /// Destruye completamente el engine. Para Android, esto es lo que
  /// libera la sesión de audio del SO y desmarca la app como "usando
  /// mic". Se llama en: radio OFF, logout, suspensión, app kill.
  Future<void> destroyEngine();

  /// Re-habilita la recepción de audio remoto al volver de background.
  /// Android suele quitarle el audio focus a la app — hay que pedirlo
  /// explícito (mute off + speakerphone on + restore volume).
  Future<void> resumeAudioReceive();

  /// Libera la captura de mic hardware sin salir del canal — útil
  /// cuando la app va a background.
  Future<void> releaseAudioCapture();

  /// Verifica el permiso `RECORD_AUDIO` (Android) / mic (iOS).
  Future<bool> hasMicPermission();

  /// Reproduce un efecto de sonido local (beep PTT, kerchunk, etc.)
  /// mezclándolo dentro del pipeline del provider — bypassa el
  /// AudioFocus de Android y los filtros OEM (MIUI, EMUI).
  ///
  /// El archivo `filePath` debe estar en disco local (no asset). El
  /// efecto es **local-only**: los demás participantes del canal no
  /// lo escuchan (comportamiento Motorola). Devuelve `false` si el
  /// engine no está listo y la UI debe usar un fallback (AudioPlayer).
  Future<bool> playLocalEffect(String filePath, {int soundId = 1});

  // ─── Control de audio + grabación + lifecycle (compartido) ───
  // Añadidos 2026-05-29 al completar Fase 1: la UI del walkie los consume
  // y ambos providers (Agora/LiveKit) los necesitan. Ver Addendum en la
  // spec de migración. Funcionalidad puramente Agora-Android (overlay PTT,
  // quickPtt) sigue fuera del contrato.

  /// Volumen de reproducción del audio remoto. Rango estilo Agora
  /// (0–400; 100 = original). La UI usa este getter para el slider.
  int get playbackVolume;

  /// Ajusta el volumen de reproducción del audio remoto.
  Future<void> setPlaybackVolume(int volume);

  /// Silencia/activa la recepción del audio remoto SIN salir del canal
  /// (el botón "mute" del walkie). No afecta la publicación del mic.
  Future<void> setRemoteAudioMuted(bool muted);

  /// Graba localmente el audio del canal a `filePath` (historial de
  /// audios). Devuelve `false` si el engine no está listo.
  ///
  /// [recordMic] indica la dirección a grabar cuando el provider no puede
  /// mezclar ambas (LiveKit): `true` = mi micrófono (lo que mandé, cuando
  /// el speaker soy yo), `false` = audio remoto (lo que oí). Agora graba la
  /// mezcla completa e ignora este flag.
  Future<bool> startLocalRecording(String filePath, {bool recordMic = false});

  /// Detiene la grabación local iniciada con [startLocalRecording].
  Future<void> stopLocalRecording();

  /// Pre-trae el token del canal `channelId` para acelerar el primer
  /// `joinChannel` (optimización de arranque). No bloquea.
  void prewarmToken(String channelId);

  /// Libera el engine de forma intencional (logout, app kill). A
  /// diferencia de [destroyEngine], NO guarda el "último canal" para
  /// auto-reconexión. Internamente suele delegar en [destroyEngine].
  Future<void> dispose();

  // ─── Overlay PTT flotante (Canal Persistente) ───
  // Usados por OverlayPttService (botón flotante Android). Compuestos sobre
  // initialize/join/mute/unmute/destroy — ambos providers los implementan.

  /// Activa el modo overlay: inicializa + se une al canal + mic OFF
  /// (escuchando). Deja el engine conectado para PTT instantáneo.
  Future<void> overlayActivate(String channelId);

  /// Desactiva el modo overlay: destruye el engine → mic 100% libre.
  Future<void> overlayDeactivate();

  /// PTT instantáneo: enciende el mic (reconecta al canal si se perdió).
  Future<void> quickPttStart(String channelId);

  /// PTT instantáneo: apaga el mic (sigue conectado al canal).
  Future<void> quickPttStop();

  /// Último canal antes de un [destroyEngine] — para auto-recuperar el
  /// overlay si el SO mató el engine (Doze mode, background kill).
  String? get lastChannelBeforeDestroy;

  // ─── Estado ───
  bool get isInitialized;
  bool get isInChannel;
  bool get isMicMuted;
  bool get isParked;
  String? get currentChannelId;
  String? get parkedChannelId;

  // ─── Callbacks ───
  /// Reporta actividad de voz local (VAD). La página del walkie lo
  /// usa para auto-soltar el PTT si nadie habla por X segundos.
  set onLocalVoiceActivity(void Function(bool active)? cb);

  /// Reporta errores del provider para que la UI muestre feedback.
  set onError(void Function(String message)? cb);
}
