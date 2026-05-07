import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/services/local_audio_history_service.dart';
import '../../../../core/theme/app_theme.dart';

/// Tarjeta para una entrada de audio del historial local del walkie-talkie.
/// Soporta play/pause y compartir vía share_plus (WhatsApp, etc.).
class AudioHistoryTile extends StatefulWidget {
  final AudioHistoryEntry entry;
  final bool isMe;
  final VoidCallback? onDelete;

  const AudioHistoryTile({
    super.key,
    required this.entry,
    this.isMe = false,
    this.onDelete,
  });

  @override
  State<AudioHistoryTile> createState() => _AudioHistoryTileState();
}

class _AudioHistoryTileState extends State<AudioHistoryTile> {
  late final AudioPlayer _player;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  bool _playing = false;

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
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
    } else {
      await _player.play(DeviceFileSource(widget.entry.filePath));
    }
  }

  Future<void> _share() async {
    final e = widget.entry;
    final time = DateFormat('dd MMM HH:mm').format(e.startedAt);
    final caption =
        'Audio de ${e.speakerName} en canal "${e.channelName}" — $time';
    await Share.shareXFiles(
      [
        XFile(
          e.filePath,
          mimeType: 'audio/aac',
          name: 'audio_${e.id}.aac',
        ),
      ],
      subject: 'Audio walkie-talkie',
      text: caption,
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final time = DateFormat('HH:mm').format(e.startedAt);
    final color =
        widget.isMe ? AppTheme.primaryColor : AppTheme.secondaryColor;
    final progress = _total.inMilliseconds > 0
        ? _position.inMilliseconds / _total.inMilliseconds
        : 0.0;

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
                    widget.isMe ? 'Tú' : e.speakerName,
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
                        valueColor:
                            AlwaysStoppedAnimation<Color>(color),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _fmt(_position),
                            style: const TextStyle(fontSize: 11),
                          ),
                          Text(
                            _total.inSeconds > 0
                                ? _fmt(_total)
                                : '${e.durationSec}s',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _share,
                  tooltip: 'Compartir',
                  icon: const Icon(Icons.share, size: 22),
                ),
                if (widget.onDelete != null)
                  IconButton(
                    onPressed: widget.onDelete,
                    tooltip: 'Borrar',
                    icon: const Icon(Icons.delete_outline, size: 22),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
