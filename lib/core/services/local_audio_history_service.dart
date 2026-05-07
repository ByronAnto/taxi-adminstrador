import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

/// Servicio de historial local de audios del walkie-talkie.
///
/// Cumple el requerimiento de Byron:
/// - Audios guardados LOCALMENTE en cada celular (no en nube).
/// - Solo del día de hoy (purge automático >24h).
/// - Re-escuchables desde el historial.
/// - Compartibles vía share_plus (WhatsApp, etc.).
///
/// Storage:
/// - Archivos físicos en getApplicationDocumentsDirectory()/walkie_audios/
/// - Metadata en Hive box `audio_history` con shape:
///   { id, channelId, channelName, speakerId, speakerName, startedAt (ms),
///     durationSec, filePath }
class LocalAudioHistoryService {
  LocalAudioHistoryService._();
  static final LocalAudioHistoryService instance =
      LocalAudioHistoryService._();

  static const _boxName = 'audio_history';
  static const _retention = Duration(hours: 24);

  Box? _box;
  Directory? _audioDir;

  Future<void> initialize() async {
    _box ??= await Hive.openBox(_boxName);
    final docs = await getApplicationDocumentsDirectory();
    _audioDir = Directory('${docs.path}/walkie_audios');
    if (!await _audioDir!.exists()) {
      await _audioDir!.create(recursive: true);
    }
    // Purga al iniciar.
    await purgeOlder();
  }

  /// Reserva un nuevo archivo de audio para grabar.
  /// Retorna el path absoluto que debe pasarse a Agora.
  Future<String> reservePath(String entryId) async {
    if (_audioDir == null) await initialize();
    return '${_audioDir!.path}/$entryId.aac';
  }

  /// Crea la entrada de historial con metadata. Llamar al iniciar grabación.
  Future<void> startEntry({
    required String id,
    required String channelId,
    required String channelName,
    required String speakerId,
    required String speakerName,
    required DateTime startedAt,
    required String filePath,
  }) async {
    if (_box == null) await initialize();
    await _box!.put(id, {
      'id': id,
      'channelId': channelId,
      'channelName': channelName,
      'speakerId': speakerId,
      'speakerName': speakerName,
      'startedAt': startedAt.millisecondsSinceEpoch,
      'durationSec': 0,
      'filePath': filePath,
      'finalized': false,
    });
  }

  /// Cierra la entrada con la duración real. Si el archivo no se generó
  /// (mute o stop instantáneo), borra la entrada.
  Future<void> finalizeEntry(String id, {required int durationSec}) async {
    if (_box == null) return;
    final entry = _box!.get(id);
    if (entry == null) return;
    final filePath = entry['filePath'] as String?;
    final fileExists =
        filePath != null && await File(filePath).exists();
    if (!fileExists || durationSec < 1) {
      // Sin archivo válido o transmisión muy corta; borrar entry y archivo.
      await _box!.delete(id);
      if (filePath != null) {
        try {
          await File(filePath).delete();
        } catch (_) {}
      }
      return;
    }
    await _box!.put(id, {
      ...Map<String, dynamic>.from(entry as Map),
      'durationSec': durationSec,
      'finalized': true,
    });
  }

  /// Lista de audios del día actual para un canal. Más recientes primero.
  List<AudioHistoryEntry> entriesForChannel(String channelId) {
    if (_box == null) return [];
    final cutoff =
        DateTime.now().subtract(_retention).millisecondsSinceEpoch;
    final raw = _box!.values
        .whereType<Map>()
        .where((m) {
          final ch = m['channelId'] as String?;
          final at = m['startedAt'] as int?;
          final fin = m['finalized'] == true;
          return ch == channelId && at != null && at >= cutoff && fin;
        })
        .toList();
    raw.sort((a, b) =>
        (b['startedAt'] as int).compareTo(a['startedAt'] as int));
    return raw.map(AudioHistoryEntry.fromMap).toList();
  }

  /// Borra entradas y archivos más viejos que la retención (24h).
  Future<void> purgeOlder() async {
    if (_box == null) return;
    final cutoff =
        DateTime.now().subtract(_retention).millisecondsSinceEpoch;
    final toDelete = <dynamic>[];
    for (final key in _box!.keys) {
      final entry = _box!.get(key);
      if (entry is! Map) continue;
      final at = entry['startedAt'] as int?;
      if (at == null || at < cutoff) {
        toDelete.add(key);
        final fp = entry['filePath'] as String?;
        if (fp != null) {
          try {
            await File(fp).delete();
          } catch (_) {}
        }
      }
    }
    for (final k in toDelete) {
      await _box!.delete(k);
    }
    if (toDelete.isNotEmpty) {
      debugPrint(
          'LocalAudioHistory: purgados ${toDelete.length} audios > 24h');
    }
  }

  Future<void> deleteEntry(String id) async {
    if (_box == null) return;
    final entry = _box!.get(id);
    if (entry is Map) {
      final fp = entry['filePath'] as String?;
      if (fp != null) {
        try {
          await File(fp).delete();
        } catch (_) {}
      }
    }
    await _box!.delete(id);
  }
}

class AudioHistoryEntry {
  final String id;
  final String channelId;
  final String channelName;
  final String speakerId;
  final String speakerName;
  final DateTime startedAt;
  final int durationSec;
  final String filePath;

  const AudioHistoryEntry({
    required this.id,
    required this.channelId,
    required this.channelName,
    required this.speakerId,
    required this.speakerName,
    required this.startedAt,
    required this.durationSec,
    required this.filePath,
  });

  factory AudioHistoryEntry.fromMap(Map m) {
    return AudioHistoryEntry(
      id: m['id'] as String,
      channelId: m['channelId'] as String,
      channelName: m['channelName'] as String? ?? '',
      speakerId: m['speakerId'] as String,
      speakerName: m['speakerName'] as String? ?? '',
      startedAt:
          DateTime.fromMillisecondsSinceEpoch(m['startedAt'] as int),
      durationSec: m['durationSec'] as int? ?? 0,
      filePath: m['filePath'] as String,
    );
  }
}
