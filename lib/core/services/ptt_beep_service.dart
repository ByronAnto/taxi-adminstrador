import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'voice/voice_provider_factory.dart';

/// Sonidos tipo radio Motorola al iniciar y terminar PTT.
///
/// Genera 2 beeps WAV en memoria con perfil "talk permit" / "roger beep"
/// clásicos de radios análogas:
/// - **start (talk permit)**: pip único 1750 Hz · 90 ms — el típico
///   "boop" que indica que ya podés hablar.
/// - **end (roger beep)**: 2-tono "kerchunk" 1750 Hz · 80 ms → 1000 Hz · 100 ms
///   con leve overlap — el cierre característico de Motorola al soltar PTT.
///
/// Amplitude 0.95 (casi clipping) para que se oiga aún con Agora
/// acaparando la sesión de audio. Audio context `assistanceSonification`
/// para que se enrute al altavoz, no al earpiece de la llamada.
class PttBeepService {
  PttBeepService._();
  static final PttBeepService instance = PttBeepService._();

  final AudioPlayer _player = AudioPlayer(playerId: 'ptt_beep');
  Uint8List? _startBytes;
  Uint8List? _endBytes;
  Uint8List? _deniedBytes;
  bool _ready = false;

  // ── Path en disco de los WAV (para Agora playEffect) ──
  // Agora SDK necesita un path absoluto; no acepta BytesSource ni assets.
  // Se escriben al `initialize()` y se reusan en cada beep.
  String? _startPath;
  String? _endPath;
  String? _deniedPath;

  /// Soundeffect IDs para Agora playEffect — uno por tipo de beep
  /// para que el SDK pueda cachear cada uno en memoria.
  static const int _soundIdStart = 9001;
  static const int _soundIdEnd = 9002;
  static const int _soundIdDenied = 9003;

  /// Pre-genera los WAV en memoria. Llamar al iniciar la app o lazy.
  Future<void> initialize() async {
    if (_ready) return;
    try {
      // Talk-permit Motorola: pip único agudo de 90 ms a 1750 Hz.
      _startBytes = _buildWav([
        _Tone(freqHz: 1750, ms: 90, amplitude: 0.95),
      ]);
      // Roger beep Motorola: 2-tono clásico al soltar el PTT.
      // 1750 Hz alto (80 ms) → 1000 Hz medio-grave (110 ms), con un
      // pequeño silencio entre tonos para marcar el "kerchunk".
      _endBytes = _buildWav([
        _Tone(freqHz: 1750, ms: 80, amplitude: 0.95),
        _Tone(freqHz: 0, ms: 20, amplitude: 0), // silencio breve
        _Tone(freqHz: 1000, ms: 110, amplitude: 0.95),
      ]);
      // Denial chirp Motorola: dos pips bajos en 500 Hz, sonoramente
      // distintos del talk-permit (1750 Hz alto) y del roger (mixto).
      // Patrón clásico de radio para "canal ocupado, no podés hablar".
      _deniedBytes = _buildWav([
        _Tone(freqHz: 500, ms: 100, amplitude: 0.95),
        _Tone(freqHz: 0, ms: 70, amplitude: 0),
        _Tone(freqHz: 500, ms: 100, amplitude: 0.95),
      ]);

      // Escribir WAV a disco — requerido por Agora playEffect (acepta
      // path absoluto, no Bytes). Se hace una sola vez en la vida de
      // la app, sobrescribiendo si ya existían (por si cambia el WAV).
      final dir = await getApplicationSupportDirectory();
      final startFile = File('${dir.path}/ptt_start.wav');
      final endFile = File('${dir.path}/ptt_end.wav');
      final deniedFile = File('${dir.path}/ptt_denied.wav');
      await startFile.writeAsBytes(_startBytes!, flush: true);
      await endFile.writeAsBytes(_endBytes!, flush: true);
      await deniedFile.writeAsBytes(_deniedBytes!, flush: true);
      _startPath = startFile.path;
      _endPath = endFile.path;
      _deniedPath = deniedFile.path;

      // Audio context para el AudioPlayer (fallback cuando Agora no está
      // disponible — radio OFF, antes del primer joinChannel, etc.).
      await _applyContext();
      _ready = true;
    } catch (e) {
      debugPrint('PttBeepService.initialize error: $e');
    }
  }

  Future<void> playStart() =>
      _play(bytes: _startBytes, filePath: _startPath, soundId: _soundIdStart);
  Future<void> playEnd() =>
      _play(bytes: _endBytes, filePath: _endPath, soundId: _soundIdEnd);

  /// Beep de "canal ocupado / lock denegado". Sonoramente distinto del
  /// talk-permit y el roger: dos pips graves en 500 Hz que el oyente
  /// asocia con "no podés transmitir" — mismo patrón Motorola.
  Future<void> playDenied() => _play(
        bytes: _deniedBytes,
        filePath: _deniedPath,
        soundId: _soundIdDenied,
      );

  Future<void> _applyContext() async {
    await _player.setAudioContext(AudioContext(
      android: const AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: false,
        // **Xiaomi/MIUI fix:** notificationEvent + gainTransient se
        // silencia en MIUI durante MODE_IN_COMMUNICATION. El único stream
        // que MIUI respeta durante llamadas activas es STREAM_RING, que
        // se obtiene con usageType: notificationRingtone. Trick conocido
        // para apps de comunicación que necesitan beeps audibles.
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.notificationRingtone,
        // gain (no transient): el sistema no nos revoca el foco a los
        // pocos ms. Como el AudioPlayer hace stop() automático tras
        // reproducir, el foco se libera al terminar el beep igual.
        audioFocus: AndroidAudioFocus.gain,
      ),
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: const {AVAudioSessionOptions.duckOthers},
      ),
    ));
    // Volumen explícito al máximo del player. El SO sigue respetando
    // el volumen del stream del usuario; esto sólo asegura que no haya
    // un cap interno del AudioPlayer en 0.5 / 0.8.
    await _player.setVolume(1.0);
    await _player.setReleaseMode(ReleaseMode.stop);
  }

  Future<void> _play({
    Uint8List? bytes,
    String? filePath,
    required int soundId,
  }) async {
    if (!_ready) await initialize();

    // ─── Path preferido: Agora playEffect ───────────────────────────
    // Mezcla el WAV dentro del propio pipeline del provider de audio
    // (Agora hoy, LiveKit en Fase 3). Bypassa el AudioFocus del SO y
    // los filtros MIUI/EMUI/etc. porque Android sólo ve UN AudioTrack
    // (el de Agora con el efecto sumado), no dos streams en paralelo.
    //
    // Truco usado por Zello y otras PTT apps nativas — explicación
    // completa en feedback_mic_release_invariant.md.
    final path = filePath ?? _startPath;
    if (path != null) {
      final ok = await VoiceProviderFactory.current
          .playLocalEffect(path, soundId: soundId);
      if (ok) {
        debugPrint('🔔 PttBeepService: beep via VoiceProvider (mixed)');
        return;
      }
    }

    // ─── Fallback: AudioPlayer con STREAM_RING ──────────────────────
    // Sólo se usa cuando el engine Agora NO está vivo (ej: radio OFF,
    // arranque temprano de la app). En esos escenarios no hay MIUI
    // bloqueando porque tampoco hay MODE_IN_COMMUNICATION activo.
    final b = bytes ?? _startBytes;
    if (b == null) return;
    try {
      await _applyContext();
      await _player.stop();
      await _player.play(BytesSource(b), mode: PlayerMode.lowLatency);
      debugPrint('🔔 PttBeepService: beep via AudioPlayer fallback');
    } catch (e) {
      debugPrint('PttBeepService._play error: $e');
    }
  }

  // ─── Generación WAV mono 16 kHz 16-bit PCM ───

  static const int _sampleRate = 16000;

  Uint8List _buildWav(List<_Tone> tones) {
    // Total samples para todos los tonos.
    int totalSamples = 0;
    for (final t in tones) {
      totalSamples += (_sampleRate * t.ms / 1000).round();
    }

    final pcm = Int16List(totalSamples);
    int offset = 0;
    for (final t in tones) {
      final samples = (_sampleRate * t.ms / 1000).round();
      final twoPiF = 2 * pi * t.freqHz;
      for (int i = 0; i < samples; i++) {
        final ts = (offset + i) / _sampleRate;
        // Envolvente simple para evitar clicks (fade in/out 8 ms).
        final fadeSamples = (_sampleRate * 0.008).round();
        double env = 1.0;
        if (i < fadeSamples) env = i / fadeSamples;
        if (i > samples - fadeSamples) {
          env = (samples - i) / fadeSamples;
        }
        // Si el tono es silencio (freq=0 o amplitude=0), escribimos 0.
        final double v = t.amplitude == 0 || t.freqHz == 0
            ? 0
            : sin(twoPiF * ts) * t.amplitude * env;
        pcm[offset + i] = (v * 32767).round().clamp(-32768, 32767);
      }
      offset += samples;
    }

    final bytesPerSample = 2;
    final dataSize = pcm.length * bytesPerSample;
    final fileSize = 36 + dataSize;
    final wav = BytesBuilder();

    // RIFF header
    wav.add(_ascii('RIFF'));
    wav.add(_le32(fileSize));
    wav.add(_ascii('WAVE'));
    // fmt chunk
    wav.add(_ascii('fmt '));
    wav.add(_le32(16)); // PCM
    wav.add(_le16(1)); // PCM = 1
    wav.add(_le16(1)); // mono
    wav.add(_le32(_sampleRate));
    wav.add(_le32(_sampleRate * bytesPerSample)); // byte rate
    wav.add(_le16(bytesPerSample)); // block align
    wav.add(_le16(16)); // bits per sample
    // data chunk
    wav.add(_ascii('data'));
    wav.add(_le32(dataSize));
    wav.add(pcm.buffer.asUint8List());

    return wav.toBytes();
  }

  Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);
  Uint8List _le16(int v) =>
      Uint8List(2)..buffer.asByteData().setInt16(0, v, Endian.little);
  Uint8List _le32(int v) =>
      Uint8List(4)..buffer.asByteData().setInt32(0, v, Endian.little);
}

class _Tone {
  final int freqHz;
  final int ms;
  final double amplitude;
  const _Tone({
    required this.freqHz,
    required this.ms,
    this.amplitude = 0.6,
  });
}
