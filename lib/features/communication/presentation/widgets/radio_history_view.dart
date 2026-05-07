import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../../../core/services/local_audio_history_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/channel_model.dart';
import '../bloc/communication_bloc.dart';
import 'audio_history_tile.dart';

/// Vista del historial del canal del walkie-talkie:
/// - Audios locales (24h, guardados en este celular).
/// - Mensajes de texto recientes del canal (Firestore).
///
/// Reusada en el tab "Chat" del bottom nav. Antes vivía dentro del
/// walkie_talkie_page pero se movió aquí para que el radio quede solo
/// con la cola de unidades + el botón PTT, dándole protagonismo a la
/// operación.
class RadioHistoryView extends StatefulWidget {
  const RadioHistoryView({super.key});

  @override
  State<RadioHistoryView> createState() => _RadioHistoryViewState();
}

class _RadioHistoryViewState extends State<RadioHistoryView> {
  String? _currentUserId() {
    final auth = context.read<AuthBloc>().state;
    if (auth is AuthAuthenticated) return auth.user.uid;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CommunicationBloc, CommunicationState>(
      builder: (context, state) {
        if (state is! CommunicationLoaded) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state.activeChannelId == null) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.radio, size: 64, color: Colors.grey[300]),
                const SizedBox(height: 16),
                Text(
                  'Selecciona un canal en el Radio',
                  style: TextStyle(color: Colors.grey[500], fontSize: 16),
                ),
              ],
            ),
          );
        }

        final audios = LocalAudioHistoryService.instance
            .entriesForChannel(state.activeChannelId!);
        final texts = state.activeMessages
            .where((m) => m.type == 'texto')
            .toList();

        if (audios.isEmpty && texts.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.mic_none, size: 64, color: Colors.grey[300]),
                const SizedBox(height: 16),
                Text('Sin mensajes recientes',
                    style:
                        TextStyle(color: Colors.grey[500], fontSize: 16)),
                const SizedBox(height: 8),
                Text(
                  'Los audios del canal y mensajes de texto se guardan 24h.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
                ),
              ],
            ),
          );
        }

        // Combinar audios + textos ordenados por fecha desc.
        final items = <_HistoryItem>[
          ...audios.map((a) => _HistoryItem.audio(a)),
          ...texts.map((t) => _HistoryItem.text(t)),
        ]..sort((a, b) => b.at.compareTo(a.at));

        final myUid = _currentUserId();

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            if (item.audio != null) {
              final isMe = item.audio!.speakerId == myUid;
              return AudioHistoryTile(
                entry: item.audio!,
                isMe: isMe,
                onDelete: () async {
                  await LocalAudioHistoryService.instance
                      .deleteEntry(item.audio!.id);
                  if (mounted) setState(() {});
                },
              );
            }
            return _buildTextTile(item.text!, myUid);
          },
        );
      },
    );
  }

  Widget _buildTextTile(MessageModel msg, String? myUid) {
    final isMe = msg.senderId == myUid;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isMe ? AppTheme.primaryColor.withValues(alpha: 0.1) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.message,
                    size: 16, color: AppTheme.textSecondary),
                const SizedBox(width: 8),
                Text(
                  isMe ? 'Tú' : msg.senderName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: isMe ? AppTheme.secondaryColor : null,
                  ),
                ),
                const Spacer(),
                Text(
                  DateFormat('HH:mm').format(msg.createdAt),
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(msg.text ?? '',
                style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

class _HistoryItem {
  final AudioHistoryEntry? audio;
  final MessageModel? text;
  final DateTime at;
  _HistoryItem._({this.audio, this.text, required this.at});
  factory _HistoryItem.audio(AudioHistoryEntry e) =>
      _HistoryItem._(audio: e, at: e.startedAt);
  factory _HistoryItem.text(MessageModel m) =>
      _HistoryItem._(text: m, at: m.createdAt);
}
