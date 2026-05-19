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
