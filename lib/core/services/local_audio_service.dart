import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';

/// Servicio para gestión local de archivos de audio (walkie-talkie PTT).
/// - Guarda grabaciones en el dispositivo.
/// - Decodifica audio base64 recibido por Firestore para reproducción.
/// - Auto-elimina archivos de audio después de 30 minutos.
class LocalAudioService {
  static const Duration audioLifetime = Duration(minutes: 30);
  static const String _audioDir = 'walkie_audio';
  static const int maxAudioDurationSeconds = 30; // Max 30 seg por mensaje PTT

  final Logger _logger = Logger();
  Timer? _cleanupTimer;

  /// Inicia el servicio de limpieza automática.
  /// Ejecuta limpieza cada 5 minutos.
  void startAutoCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => cleanupExpiredAudio(),
    );
    // Limpieza inicial al arrancar
    cleanupExpiredAudio();
  }

  /// Detiene el servicio de limpieza automática.
  void stopAutoCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  /// Obtiene el directorio de audio local.
  Future<Directory> _getAudioDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final audioDir = Directory('${appDir.path}/$_audioDir');
    if (!await audioDir.exists()) {
      await audioDir.create(recursive: true);
    }
    return audioDir;
  }

  /// Guarda audio grabado localmente y devuelve la ruta del archivo.
  Future<String> saveRecordedAudio(String sourceFilePath) async {
    final audioDir = await _getAudioDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final extension = sourceFilePath.split('.').last;
    final destPath = '${audioDir.path}/ptt_$timestamp.$extension';

    final sourceFile = File(sourceFilePath);
    if (await sourceFile.exists()) {
      await sourceFile.copy(destPath);
      _logger.d('Audio guardado: $destPath');
      return destPath;
    }
    throw Exception('Archivo de audio no encontrado: $sourceFilePath');
  }

  /// Convierte un archivo de audio a base64 para enviar por Firestore.
  /// Solo para audios cortos (PTT ≤ 30 segundos).
  Future<String> audioFileToBase64(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Archivo no encontrado: $filePath');
    }

    final bytes = await file.readAsBytes();
    // Limitar tamaño: ~500KB max para no exceder límites de Firestore
    if (bytes.length > 500 * 1024) {
      throw Exception(
        'Audio demasiado grande (${(bytes.length / 1024).round()}KB). '
        'Máximo 500KB para enviar por canal.',
      );
    }

    return base64Encode(bytes);
  }

  /// Decodifica audio base64 recibido y lo guarda como archivo temporal
  /// para reproducción. Devuelve la ruta del archivo.
  Future<String> base64ToAudioFile(
    String base64Audio, {
    String extension = 'm4a',
    String? messageId,
  }) async {
    final audioDir = await _getAudioDirectory();
    final fileName = messageId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final filePath = '${audioDir.path}/recv_$fileName.$extension';

    // Si el archivo ya existe (ya decodificado antes), reutilizar
    final existingFile = File(filePath);
    if (await existingFile.exists()) {
      return filePath;
    }

    final bytes = base64Decode(base64Audio);
    await File(filePath).writeAsBytes(bytes);
    _logger.d('Audio decodificado: $filePath');
    return filePath;
  }

  /// Elimina archivos de audio más viejos que [audioLifetime] (30 min).
  Future<int> cleanupExpiredAudio() async {
    int deletedCount = 0;
    try {
      final audioDir = await _getAudioDirectory();
      if (!await audioDir.exists()) return 0;

      final now = DateTime.now();
      final files = audioDir.listSync();

      for (final entity in files) {
        if (entity is File) {
          final stat = await entity.stat();
          final age = now.difference(stat.modified);

          if (age > audioLifetime) {
            await entity.delete();
            deletedCount++;
            _logger.d('Audio eliminado (${age.inMinutes} min): ${entity.path}');
          }
        }
      }

      if (deletedCount > 0) {
        _logger.i('Limpieza de audio: $deletedCount archivos eliminados');
      }
    } catch (e) {
      _logger.e('Error en limpieza de audio: $e');
    }
    return deletedCount;
  }

  /// Elimina TODOS los archivos de audio locales.
  Future<void> clearAllAudio() async {
    try {
      final audioDir = await _getAudioDirectory();
      if (await audioDir.exists()) {
        await audioDir.delete(recursive: true);
        _logger.i('Todos los archivos de audio eliminados');
      }
    } catch (e) {
      _logger.e('Error eliminando audios: $e');
    }
  }

  /// Obtiene el tamaño total de audio almacenado en bytes.
  Future<int> getStorageUsage() async {
    try {
      final audioDir = await _getAudioDirectory();
      if (!await audioDir.exists()) return 0;

      int totalSize = 0;
      final files = audioDir.listSync();
      for (final entity in files) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
      return totalSize;
    } catch (e) {
      return 0;
    }
  }

  /// Dispone el servicio.
  void dispose() {
    stopAutoCleanup();
  }
}
