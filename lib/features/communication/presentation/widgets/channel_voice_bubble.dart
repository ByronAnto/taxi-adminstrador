import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/models/channel_model.dart';

/// Burbuja de mensaje de voz del canal (respaldo del audio del radio).
///
/// El bot grabador server-side publica cada PTT como [MessageModel]
/// (type:'voz') con un [MessageModel.audioUrl] (.wav servido por
/// https://livekit.it-services.center/rec/...). Esta burbuja reproduce ese
/// audio DESDE la URL con `audioplayers` (`UrlSource`), siguiendo el mismo
/// patrón de play/pause/posición de `AudioHistoryTile` (que usa archivos
/// locales con `DeviceFileSource`).
///
/// Visible para TODOS los roles. Si el mensaje no trae `audioUrl` (mensajes
/// viejos solo-metadatos) NO se usa esta burbuja: ver fallback en
/// `RadioHistoryView`.
class ChannelVoiceBubble extends StatefulWidget {
  final MessageModel message;

  /// True si el mensaje lo envió el usuario actual (alinea a la derecha).
  final bool isMe;

  const ChannelVoiceBubble({
    super.key,
    required this.message,
    this.isMe = false,
  });

  @override
  State<ChannelVoiceBubble> createState() => _ChannelVoiceBubbleState();
}

class _ChannelVoiceBubbleState extends State<ChannelVoiceBubble> {
  late final AudioPlayer _player;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  bool _playing = false;
  bool _sharing = false;

  /// Etiqueta del hablante: "Unidad #N · Nombre" si trae unidad, si no solo el
  /// nombre. Para mis propios audios, "Tú".
  String get _speakerLabel {
    final msg = widget.message;
    if (widget.isMe) return 'Tú';
    final unidad = msg.senderVehiculo?.trim() ?? '';
    if (unidad.isNotEmpty) return 'Unidad #$unidad · ${msg.senderName}';
    return msg.senderName;
  }

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _player.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() => _playing = s == PlayerState.playing);
    });
    _player.onPositionChanged.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
    _player.onDurationChanged.listen((d) {
      if (!mounted) return;
      setState(() => _total = d);
    });
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _position = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    // Liberamos el AudioPlayer para no fugar recursos nativos.
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
    } else {
      // Reproduce el .wav directamente desde la URL del bot grabador.
      await _player.play(UrlSource(widget.message.audioUrl!));
    }
  }

  /// Comparte el audio (WhatsApp, etc.). Como el `.wav` vive en una URL remota,
  /// hay que descargarlo a un archivo temporal antes de compartirlo con
  /// `share_plus` (no comparte URLs remotas como archivo).
  Future<void> _share() async {
    final msg = widget.message;
    final url = msg.audioUrl;
    if (url == null || url.isEmpty || _sharing) return;
    setState(() => _sharing = true);
    try {
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/audio_${msg.uid}.wav');
      await file.writeAsBytes(resp.bodyBytes);

      final time = DateFormat('dd MMM HH:mm').format(msg.createdAt);
      final caption = 'Audio de $_speakerLabel — $time';
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'audio/wav', name: 'audio_${msg.uid}.wav')],
        subject: 'Audio walkie-talkie',
        text: caption,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo descargar el audio para compartir'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final time = DateFormat('HH:mm').format(msg.createdAt);
    final color =
        widget.isMe ? AppTheme.primaryColor : AppTheme.secondaryColor;
    final progress = _total.inMilliseconds > 0
        ? _position.inMilliseconds / _total.inMilliseconds
        : 0.0;
    // Duración mostrada: la del player si ya cargó, si no la de metadatos.
    final durLabel = _total.inSeconds > 0
        ? _fmt(_total)
        : '${msg.durationSeconds ?? 0}s';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: widget.isMe ? color.withValues(alpha: 0.08) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.mic, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _speakerLabel,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: color,
                    ),
                  ),
                ),
                Text(
                  time,
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  onPressed: _togglePlay,
                  icon: Icon(
                    _playing ? Icons.pause_circle : Icons.play_circle,
                    color: color,
                    size: 36,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        minHeight: 4,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _fmt(_position),
                            style: const TextStyle(fontSize: 11),
                          ),
                          Text(
                            durLabel,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _sharing
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        onPressed: _share,
                        tooltip: 'Compartir',
                        icon: const Icon(Icons.share, size: 22),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
