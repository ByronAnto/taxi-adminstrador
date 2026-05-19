import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/services/agora_service.dart';
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
  DateTime? _recordingStartTime;
  Timer? _recordingTimer;
  Timer? _durationTimer;
  int _recordingSeconds = 0;

  /// Anti-PTT-pegado: si el transmisor mantiene el lock pero no genera
  /// voz por [_maxSilenceSeconds] consecutivos, soltamos el PTT solo.
  /// Evita que un dedo pegado / botón atascado bloquee el canal para todos.
  static const int _maxSilenceSeconds = 10;
  Timer? _silenceTimer;
  DateTime? _lastVoiceAt;

  final _agoraService = AgoraService.instance;
  final _radioService = RadioForegroundService.instance;
  final _connectivity = ConnectivityService.instance;
  final _overlayService = OverlayPttService.instance;
  final _locationService = DriverLocationService.instance;
  final _radioPower = RadioPowerService.instance;

  /// true cuando no hay internet O el conductor está en modo Desconectado
  bool _isOffline = false;

  /// true solo cuando el conductor está en modo Desconectado (estado manual)
  bool _isDriverOffline = false;

  /// Último channelId al que nos unimos en Agora (para detectar cambios)
  String? _lastAgoraChannelId;


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
    _isDriverOffline = dependsOnGps && !_locationService.isOnline;
    _isOffline = !_connectivity.isConnected || _isDriverOffline;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Inicializar configuración del foreground task (sólo registro,
    // no arranca el servicio).
    _radioService.init();
    // Si el radio quedó ON de la sesión anterior, inicializar Agora.
    // Si quedó OFF, NO se inicializa nada — el mic queda libre para otras apps.
    if (_radioPower.isOn) {
      _agoraService.initialize().catchError((e) {
        debugPrint('Error inicializando Agora: $e');
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
        _recordingStartTime = null;
        // Mute Agora inmediato (no esperar al bloc). Esto llama
        // enableLocalAudio(false) que libera el mic hardware a nivel del SO.
        _agoraService.muteMic().catchError((e) {
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
        _agoraService.resumeAudioReceive().catchError((e) {
          debugPrint('Error resumeAudioReceive: $e');
        });
      }
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
      // ── Se perdió la conexión ──
      // Si estaba grabando PTT, detenerlo
      if (_isRecording) {
        final currentState = context.read<CommunicationBloc>().state;
        if (currentState is CommunicationLoaded) {
          _stopPtt(currentState);
        }
      }
      // Salir de Agora
      _agoraService.leaveChannel().catchError((_) {});
      _lastAgoraChannelId = null;
    } else if (!_isOffline && wasOffline) {
      // ── Conexión restaurada ──
      // Reconectar Agora al canal activo SOLO si el radio está ON.
      if (!_radioPower.isOn) return;
      final currentState = context.read<CommunicationBloc>().state;
      if (currentState is CommunicationLoaded &&
          currentState.activeChannelId != null) {
        _lastAgoraChannelId = currentState.activeChannelId;
        _agoraService
            .joinChannel(currentState.activeChannelId!)
            .catchError((e) {
          debugPrint('Error Agora rejoin tras reconexión: $e');
        });
      }
    }
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
    if (!_radioPower.isOn || !_agoraService.isInChannel) return;
    final history = LocalAudioHistoryService.instance;
    final entryId =
        '${DateTime.now().millisecondsSinceEpoch}_${speakerId.substring(0, speakerId.length.clamp(0, 6))}';
    final filePath = await history.reservePath(entryId);
    final ok = await _agoraService.startLocalRecording(filePath);
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
    await _agoraService.stopLocalRecording();
    final dur = startedAt == null
        ? 0
        : DateTime.now().difference(startedAt).inSeconds;
    await LocalAudioHistoryService.instance
        .finalizeEntry(id, durationSec: dur);
    if (mounted) setState(() {}); // Refrescar la lista del historial
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
        await _agoraService.initialize();
        if (channelToJoin != null) {
          _lastAgoraChannelId = channelToJoin;
          await _agoraService.joinChannel(channelToJoin);
          if (channelName != null && !_radioService.isRunning) {
            await _radioService.startService(channelName);
          }
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
      // Salir de Agora y destruir engine — libera mic hardware
      await _agoraService.destroyEngine();
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
      _agoraService.leaveChannel().catchError((_) {});
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
        _agoraService
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${state.pttSpeakerName ?? "Alguien"} está hablando. Espera tu turno.',
              ),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 2),
            ),
          );
        }
        // === Pre-warm token Agora ===
        // Apenas el usuario selecciona un canal (radio aún apagado),
        // disparamos el fetch del token en background. Cuando luego
        // pulse "Encender", el token ya estará en cache → encendido
        // sin esperar la red.
        if (state is CommunicationLoaded &&
            state.activeChannelId != null &&
            !_radioPower.isOn) {
          _agoraService.prewarmToken(state.activeChannelId!);
        }
        // El auto-resume del último canal se eliminó intencionalmente:
        // arrancamos siempre con radio OFF y, cuando el conductor toca
        // el switch, ahí seleccionamos `lastChannelId`. Así el ON es
        // siempre interactivo y nunca despierta solo audio en el canal.
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
            _agoraService.joinChannel(channelId).catchError((e) {
              debugPrint('Error Agora joinChannel: $e');
            });
          } else if (channelId == null && _lastAgoraChannelId != null) {
            _lastAgoraChannelId = null;
            _agoraService.leaveChannel().catchError((e) {
              debugPrint('Error Agora leaveChannel: $e');
            });
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
          return const Center(child: CircularProgressIndicator());
        }

        if (state is! CommunicationLoaded) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.wifi_off, size: 64, color: Colors.grey[300]),
                const SizedBox(height: 16),
                Text(
                  'Conectando al radio...',
                  style: TextStyle(color: Colors.grey[500], fontSize: 16),
                ),
              ],
            ),
          );
        }

        return Column(
          children: [
            // Banner de sin conexión dentro del walkie-talkie
            if (_isOffline) _buildOfflineBanner(),
            _buildPowerToggle(state),
            _buildChannelSelector(state),
            // Cola de unidades cerca de la parada — clave para coordinar
            // despacho estilo cooperativa.
            const StandQueueBar(),
            if (state.isPttLocked && _radioPower.isOn) _buildSpeakerBanner(state),
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

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isOn
            ? AppTheme.primaryColor.withValues(alpha: 0.08)
            : Colors.grey.shade100,
        border: Border(
          bottom: BorderSide(
            color: isOn
                ? AppTheme.primaryColor.withValues(alpha: 0.3)
                : Colors.grey.shade300,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isOn ? Icons.radio : Icons.power_settings_new,
            color: isOn ? AppTheme.primaryColor : Colors.grey.shade500,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isOn ? 'Radio encendido' : 'Radio apagado',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: isOn ? AppTheme.primaryColor : Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isOn
                      ? (hasChannel
                          ? 'Conectado a: ${channelName ?? "..."}'
                          : 'Selecciona un canal abajo')
                      : 'Micrófono libre — otras apps pueden usarlo',
                  style: TextStyle(
                    fontSize: 12,
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
              color: isOn ? AppTheme.primaryColor : Colors.grey.shade500,
            ),
            onPressed: _showVolumeDialog,
          ),
          Switch.adaptive(
            value: isOn,
            activeThumbColor: AppTheme.primaryColor,
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
    int current = _agoraService.playbackVolume;
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
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.volume_up, color: AppTheme.primaryColor),
                  SizedBox(width: 8),
                  Text('Volumen del radio'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ganancia: ${(current / 100).toStringAsFixed(1)}x  ·  $pct%',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    current <= 100
                        ? 'Volumen normal'
                        : current <= 200
                            ? 'Amplificado moderado'
                            : current <= 300
                                ? 'Amplificado fuerte'
                                : 'Amplificado al máximo',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Slider(
                    value: current.toDouble(),
                    min: AgoraService.playbackVolumeMin.toDouble(),
                    max: AgoraService.playbackVolumeMax.toDouble(),
                    divisions: (AgoraService.playbackVolumeMax -
                            AgoraService.playbackVolumeMin) ~/
                        10,
                    label: '${current ~/ 1}',
                    activeColor: AppTheme.primaryColor,
                    onChanged: (v) => setLocal(() => current = v.round()),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('1x',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600)),
                      Text('4x',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Sube el volumen del altavoz del celular al máximo '
                    'antes de amplificar acá. Valores >300 pueden saturar '
                    'la voz en bocinas pequeñas.',
                    style: TextStyle(
                      fontSize: 11,
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
                    await _agoraService.setPlaybackVolume(current);
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
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      color: _isDriverOffline && !noInternet
          ? Colors.orange.shade800
          : Colors.red.shade800,
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 10),
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

  /// Banner que muestra quién está hablando (estilo Zello)
  Widget _buildSpeakerBanner(CommunicationLoaded state) {
    final user = _currentUser;
    final isMe = state.pttSpeakerId == user?.uid;
    final isModerator = user != null &&
        (user.role == AppConstants.roleAdmin ||
            user.role == AppConstants.roleOperator);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: isMe ? AppTheme.successColor : Colors.orange.shade700,
      child: Row(
        children: [
          Icon(
            Icons.mic,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: 8),
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
        color: Colors.amber.shade50,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.info_outline,
                color: Colors.amber.shade800, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No tienes canales asignados. Pídele al admin que te '
                'agregue al canal de la cooperativa.',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.amber.shade900,
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

    return Container(
      height: 56,
      color: AppTheme.secondaryColor,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (canManage && index == visibleChannels.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ActionChip(
                avatar: Icon(Icons.add, size: 18,
                    color: AppTheme.primaryColor),
                label: Text(
                  'Nuevo',
                  style: TextStyle(
                      color: AppTheme.primaryColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
                backgroundColor: Colors.white,
                side: BorderSide(
                    color: AppTheme.primaryColor.withValues(alpha: 0.4)),
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
                              color: isSelected
                                  ? Colors.white
                                  : AppTheme.primaryColor,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  selected: isSelected,
                  selectedColor: AppTheme.primaryColor,
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
    // Bloquear PTT completamente si no hay internet, overlay activo, o radio OFF
    final canPtt = isOn &&
        hasChannel &&
        !isLockedByOther &&
        !_isOffline &&
        !_overlayService.isActive;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
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
                  _agoraService.setRemoteAudioMuted(_isMuted);
                },
                icon: Icon(
                  _isMuted ? Icons.volume_off : Icons.volume_up,
                  color: _isMuted ? AppTheme.errorColor : AppTheme.secondaryColor,
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
                          ? AppTheme.secondaryColor
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
                        ? AppTheme.primaryColor
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

  /// Activa/desactiva el botón PTT flotante sobre todas las apps.
  ///
  /// Con timeout para evitar que la UI quede colgada si stop()/start()
  /// del overlay se traban (typical en Android 14+ con Doze mode).
  Future<void> _toggleOverlay(CommunicationLoaded state) async {
    if (_overlayService.isActive) {
      // ── Desactivar overlay ──
      // Timeout de 4s — si stop se cuelga, forzamos el flag local para que
      // la UI vuelva a mostrar el icono "activar".
      try {
        await _overlayService.stop().timeout(const Duration(seconds: 4));
      } catch (e) {
        debugPrint('Overlay stop colgado: $e — forzando reset');
      }
      // Re-inicializar engine para uso en esta página
      try {
        await _agoraService.initialize();
        if (state.activeChannelId != null) {
          _lastAgoraChannelId = state.activeChannelId;
          await _agoraService.joinChannel(state.activeChannelId!);
        }
      } catch (e) {
        debugPrint('Error re-init Agora tras stop overlay: $e');
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
            backgroundColor: Colors.orange,
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

    // Destruir engine actual (el overlay gestiona su propio ciclo)
    await _agoraService.destroyEngine();
    _lastAgoraChannelId = null;

    // Iniciar overlay (conecta Agora al canal automáticamente)
    final started = await _overlayService.start(state.activeChannelId!);
    if (!mounted) return;
    if (started) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '🎙️ PTT Flotante activado — conectado al canal, PTT instantáneo',
          ),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );
      setState(() {});
    } else {
      // Falló overlayActivate (timeout join channel, sin red, etc.). El
      // botón nativo NO se mostró (gracias al fix del start). Avisamos al
      // usuario y volvemos a inicializar Agora en la página principal.
      try {
        await _agoraService.initialize();
        if (state.activeChannelId != null) {
          _lastAgoraChannelId = state.activeChannelId;
          await _agoraService.joinChannel(state.activeChannelId!);
        }
      } catch (_) {}
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
        backgroundColor: _isDriverOffline ? Colors.orange : Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
    HapticFeedback.heavyImpact();
  }

  /// Safe wrapper that guards against calling stop when not recording
  void _stopPttSafe(CommunicationLoaded state) {
    if (!_isRecording) return;
    _stopPtt(state);
  }

  Future<void> _startPtt(CommunicationLoaded state) async {
    final user = _currentUser;
    if (user == null || state.activeChannelId == null) return;
    if (_isRecording) return; // Prevent double-start

    // Verificar permiso de micrófono
    final hasPermission = await _agoraService.hasMicPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Se requiere permiso de micrófono para hablar'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    setState(() {
      _isRecording = true;
      _recordingSeconds = 0;
    });

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
    _agoraService.onLocalVoiceActivity = (active) {
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

    _recordingStartTime = DateTime.now();

    // 🔔 Feedback háptico + beep tipo Motorola/Zello al iniciar PTT
    HapticFeedback.mediumImpact();
    PttBeepService.instance.playStart();

    // Intentar adquirir el lock PTT en Firestore
    if (!mounted) return;
    context.read<CommunicationBloc>().add(
          PttLockRequested(
            channelId: state.activeChannelId!,
            userId: user.uid,
            userName: '${user.name} ${user.lastname}',
          ),
        );

    // ── AGORA: Desmutear mic → audio en tiempo real a todos ──
    try {
      await _agoraService.unmuteMic();
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

  Future<void> _stopPtt(CommunicationLoaded state) async {
    final user = _currentUser;
    if (user == null || state.activeChannelId == null) return;

    // Inmediatamente marcamos como no transmitiendo
    _recordingTimer?.cancel();
    _durationTimer?.cancel();
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _lastVoiceAt = null;
    _agoraService.onLocalVoiceActivity = null;
    final durationSeconds = _recordingStartTime != null
        ? DateTime.now().difference(_recordingStartTime!).inSeconds
        : 0;
    setState(() {
      _isRecording = false;
      _recordingSeconds = 0;
    });

    // ── AGORA: Mutear mic → dejar de transmitir ──
    try {
      await _agoraService.muteMic();
      // 🔔 Feedback háptico + beep "fin de transmisión" tipo Motorola
      HapticFeedback.lightImpact();
      PttBeepService.instance.playEnd();
    } catch (e) {
      // Silenciar error — ya dejamos de grabar en la UI
    }

    // Enviar mensaje ligero a Firestore (solo metadatos, sin audio base64)
    // para que quede registro en el historial del canal.
    if (durationSeconds >= 1 && mounted) {
      context.read<CommunicationBloc>().add(
            ChannelMessageSendRequested(
              MessageModel(
                uid: const Uuid().v4(),
                associationId: user.associationId,
                channelId: state.activeChannelId!,
                senderId: user.uid,
                senderName: '${user.name} ${user.lastname}',
                type: 'voz',
                durationSeconds: durationSeconds,
                createdAt: DateTime.now(),
              ),
            ),
          );
    }

    _recordingStartTime = null;

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

  /// Con Agora, el audio de voz se transmite en tiempo real.
  /// Los mensajes de voz en el historial son solo metadatos (duración).
  /// Los mensajes antiguos con audioBase64 ya no se reproducen.

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
              leading: Icon(Icons.settings, color: AppTheme.primaryColor),
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
              title: Text('Editar nombre'),
              onTap: () {
                Navigator.pop(ctx);
                _showEditChannelDialog(channel);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Colors.red.shade700),
              title: Text('Borrar canal',
                  style: TextStyle(color: Colors.red.shade700)),
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
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: Colors.blue.shade800),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Después de crearlo se abre la configuración para '
                        'elegir miembros y si es el canal por defecto.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.blue.shade900,
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
