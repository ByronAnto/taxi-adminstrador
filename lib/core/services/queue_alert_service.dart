import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants/app_constants.dart';

/// Notifica a la **operadora/admin** con sonido + vibración cada vez que
/// un conductor entra a la cola de la parada.
///
/// Funciona tanto si:
/// - El conductor mismo se mete tocando "Entrar a parada"
/// - La operadora lo agrega manualmente desde el modal
///
/// Estrategia:
/// 1. Suscribirse a `drivers where associationId == X and inQueueAt != null`
/// 2. Mantener un set local de `driverDocId` ya conocidos
/// 3. Cuando aparece un id nuevo → ding-ding + heavy haptic
/// 4. Filtrar el primer snapshot (los que ya estaban en la cola al entrar
///    al servicio NO disparan alerta — sería ruido)
///
/// El sonido es WAV mono 16 kHz sintético, dos tonos ascendentes en
/// frecuencias **distintas** al PTT para que la operadora pueda
/// distinguirlos auditivamente.
class QueueAlertService {
  QueueAlertService._();
  static final QueueAlertService instance = QueueAlertService._();

  final AudioPlayer _player = AudioPlayer(playerId: 'queue_alert');
  Uint8List? _alertBytes;
  bool _ready = false;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  final Set<String> _knownInQueue = <String>{};
  bool _isFirstSnapshot = true;
  bool _enabled = false;

  /// Llamar al login. Solo arranca si el rol es operadora o admin
  /// (los que necesitan saber quién llega a la cola).
  Future<void> bind({
    required String role,
    required String associationId,
  }) async {
    if (associationId.isEmpty) return;
    if (role != AppConstants.roleOperator &&
        role != AppConstants.roleAdmin) {
      return; // Conductores no reciben este alert
    }
    if (_enabled) return; // Ya bind con otro
    _enabled = true;
    _isFirstSnapshot = true;
    _knownInQueue.clear();

    await _ensureSoundReady();

    _sub = FirebaseFirestore.instance
        .collection('drivers')
        .where('associationId', isEqualTo: associationId)
        .where('inQueueAt', isNull: false)
        .snapshots()
        .listen(_onSnapshot, onError: (e) {
      debugPrint('🔔 [QueueAlert] error: $e');
    });

    debugPrint('🔔 [QueueAlert] bind aid=$associationId role=$role');
  }

  Future<void> unbind() async {
    await _sub?.cancel();
    _sub = null;
    _knownInQueue.clear();
    _isFirstSnapshot = true;
    _enabled = false;
  }

  void _onSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    final currentIds = snap.docs.map((d) => d.id).toSet();

    if (_isFirstSnapshot) {
      _knownInQueue.addAll(currentIds);
      _isFirstSnapshot = false;
      return;
    }

    final newcomers = currentIds.difference(_knownInQueue);
    final left = _knownInQueue.difference(currentIds);

    if (newcomers.isNotEmpty) {
      // Una sola alerta aunque entren varios a la vez (no spammear).
      _fire();
    }

    _knownInQueue
      ..removeAll(left)
      ..addAll(newcomers);
  }

  Future<void> _fire() async {
    // Vibración pesada (~100 ms en Android), distinguible del haptic de
    // PTT que es light/medium.
    HapticFeedback.heavyImpact();
    // Pequeño delay y un segundo pulso → patrón "ding ding".
    Future.delayed(const Duration(milliseconds: 220), () {
      HapticFeedback.heavyImpact();
    });
    await _playBeep();
  }

  // ─────────────────── WAV mono 16 kHz sintético ───────────────────

  Future<void> _ensureSoundReady() async {
    if (_ready) return;
    try {
      _alertBytes = _buildWav([
        _Tone(freqHz: 1500, ms: 90),
        _Tone(freqHz: 0, ms: 60), // silencio entre los dos dings
        _Tone(freqHz: 1500, ms: 90),
      ]);
      await _player.setReleaseMode(ReleaseMode.stop);
      _ready = true;
    } catch (e) {
      debugPrint('QueueAlertService.init error: $e');
    }
  }

  Future<void> _playBeep() async {
    await _ensureSoundReady();
    final bytes = _alertBytes;
    if (bytes == null) return;
    try {
      await _player.stop();
      await _player.play(BytesSource(bytes), mode: PlayerMode.lowLatency);
    } catch (e) {
      debugPrint('QueueAlertService.play error: $e');
    }
  }

  static const int _sampleRate = 16000;

  Uint8List _buildWav(List<_Tone> tones) {
    int totalSamples = 0;
    for (final t in tones) {
      totalSamples += (_sampleRate * t.ms / 1000).round();
    }

    final pcm = Int16List(totalSamples);
    int offset = 0;
    for (final t in tones) {
      final samples = (_sampleRate * t.ms / 1000).round();
      if (t.freqHz <= 0) {
        // Silencio entre tonos.
        offset += samples;
        continue;
      }
      final twoPiF = 2 * pi * t.freqHz;
      final fadeSamples = (_sampleRate * 0.008).round();
      for (int i = 0; i < samples; i++) {
        final ts = (offset + i) / _sampleRate;
        double env = 1.0;
        if (i < fadeSamples) env = i / fadeSamples;
        if (i > samples - fadeSamples) {
          env = (samples - i) / fadeSamples;
        }
        final v = sin(twoPiF * ts) * 0.6 * env;
        pcm[offset + i] = (v * 32767).round().clamp(-32768, 32767);
      }
      offset += samples;
    }

    const bytesPerSample = 2;
    final dataSize = pcm.length * bytesPerSample;
    final fileSize = 36 + dataSize;
    final wav = BytesBuilder();
    wav.add(_ascii('RIFF'));
    wav.add(_le32(fileSize));
    wav.add(_ascii('WAVE'));
    wav.add(_ascii('fmt '));
    wav.add(_le32(16));
    wav.add(_le16(1));
    wav.add(_le16(1));
    wav.add(_le32(_sampleRate));
    wav.add(_le32(_sampleRate * bytesPerSample));
    wav.add(_le16(bytesPerSample));
    wav.add(_le16(16));
    wav.add(_ascii('data'));
    wav.add(_le32(dataSize));
    wav.add(pcm.buffer.asUint8List());
    return wav.toBytes();
  }

  Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);
  Uint8List _le16(int v) => Uint8List.fromList([v & 0xff, (v >> 8) & 0xff]);
  Uint8List _le32(int v) => Uint8List.fromList([
        v & 0xff,
        (v >> 8) & 0xff,
        (v >> 16) & 0xff,
        (v >> 24) & 0xff,
      ]);
}

class _Tone {
  final int freqHz;
  final int ms;
  const _Tone({required this.freqHz, required this.ms});
}
