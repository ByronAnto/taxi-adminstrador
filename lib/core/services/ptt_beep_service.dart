import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Sonidos tipo radio Motorola / Zello al iniciar y terminar PTT.
///
/// Genera dos beeps cortos sintéticos (sin assets externos):
/// - **start**: doble tono ascendente (440 Hz → 880 Hz, 80 ms cada uno).
/// - **end**: doble tono descendente (880 Hz → 440 Hz, 80 ms cada uno).
///
/// La generación es WAV mono 16 kHz int16. Se cachea en memoria para que
/// el play sea instantáneo (0 ms de latencia, importante en PTT).
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
      _startBytes = _buildWav([
        _Tone(freqHz: 1200, ms: 70),
        _Tone(freqHz: 1800, ms: 90),
      ]);
      _endBytes = _buildWav([
        _Tone(freqHz: 1800, ms: 70),
        _Tone(freqHz: 900, ms: 90),
      ]);
      // Modo low latency, no interrumpir música si la hay
      await _player.setReleaseMode(ReleaseMode.stop);
      _ready = true;
    } catch (e) {
      debugPrint('PttBeepService.initialize error: $e');
    }
  }

  Future<void> playStart() => _play(_startBytes);
  Future<void> playEnd() => _play(_endBytes);

  Future<void> _play(Uint8List? bytes) async {
    if (bytes == null) {
      await initialize();
      bytes = bytes ?? _startBytes;
      if (bytes == null) return;
    }
    try {
      await _player.stop();
      await _player.play(BytesSource(bytes), mode: PlayerMode.lowLatency);
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
        // Onda senoidal con amplitud 0.6 para no saturar.
        final v = sin(twoPiF * ts) * 0.6 * env;
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
  const _Tone({required this.freqHz, required this.ms});
}
