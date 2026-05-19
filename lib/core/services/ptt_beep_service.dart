import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

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
  bool _ready = false;

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

      // **Audio focus FUERTE** para piercear el audio de Agora.
      //
      // Antes usábamos assistanceSonification + gainTransientMayDuck. Ese
      // combo "amistoso" funcionaba cuando el engine se destruía al
      // cambiar de tab (Agora soltaba la sesión y el beep ganaba). Tras
      // commit cf54f64 (engine vivo permanentemente) Agora mantiene
      // MODE_IN_COMMUNICATION y el beep quedaba mudo / iba al earpiece.
      //
      // Combo nuevo:
      // - usageType: notificationEvent → categoría notificación, no llamada
      // - contentType: sonification → tono corto, no música
      // - audioFocus: gainTransient → toma foco exclusivo por ~100 ms
      // - isSpeakerphoneOn: true → fuerza speaker, no earpiece
      //
      // Los Motorola reales también pisan el audio remoto durante el
      // talk-permit; el efecto deseado es el mismo (~90 ms de "click").
      await _applyContext();
      _ready = true;
    } catch (e) {
      debugPrint('PttBeepService.initialize error: $e');
    }
  }

  Future<void> playStart() => _play(_startBytes);
  Future<void> playEnd() => _play(_endBytes);

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

  Future<void> _play(Uint8List? bytes) async {
    if (bytes == null) {
      await initialize();
      bytes = bytes ?? _startBytes;
      if (bytes == null) return;
    }
    try {
      // Re-aplicar contexto antes de cada play: en algunos devices
      // Android resetea el AudioFocus de un AudioPlayer cuando otro
      // (Agora) toma MODE_IN_COMMUNICATION. Sin esto, el primer beep
      // podía sonar pero los siguientes no.
      await _applyContext();
      await _player.stop();
      await _player.play(BytesSource(bytes), mode: PlayerMode.lowLatency);
      debugPrint('🔔 PttBeepService: beep enviado al player');
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
