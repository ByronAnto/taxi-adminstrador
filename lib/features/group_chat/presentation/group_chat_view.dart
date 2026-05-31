// lib/features/group_chat/presentation/group_chat_view.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../data/group_chat_service.dart';
import '../data/group_unread_service.dart';
import '../data/models/group_message_model.dart';

/// Tab "Grupo": chat de texto de la asociación, estilo WhatsApp.
class GroupChatView extends StatefulWidget {
  /// associationId del usuario actual.
  final String associationId;

  /// uid del usuario actual (para alinear burbujas y no leídos).
  final String myUid;

  const GroupChatView({
    super.key,
    required this.associationId,
    required this.myUid,
  });

  @override
  State<GroupChatView> createState() => _GroupChatViewState();
}

class _GroupChatViewState extends State<GroupChatView> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Al abrir la tab, marcar leído.
    GroupUnreadService.instance.markRead(widget.associationId);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    _controller.clear();
    try {
      await GroupChatService.instance.send(widget.associationId, text);
      await GroupUnreadService.instance.markRead(widget.associationId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo enviar el mensaje')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: StreamBuilder<List<GroupMessageModel>>(
            stream: GroupChatService.instance.stream(widget.associationId),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final msgs = snap.data ?? const <GroupMessageModel>[];
              if (msgs.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Aún no hay mensajes en el grupo.\n'
                      'Escribe el primero — lo verán todos los miembros.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              // Marcar leído cada vez que llega data nueva mientras está abierto.
              GroupUnreadService.instance.markRead(widget.associationId);
              return ListView.builder(
                reverse: true, // más nuevos abajo
                padding: const EdgeInsets.all(12),
                itemCount: msgs.length,
                itemBuilder: (context, i) =>
                    _bubble(msgs[i], msgs[i].senderId == widget.myUid),
              );
            },
          ),
        ),
        _composer(),
      ],
    );
  }

  Widget _bubble(GroupMessageModel m, bool isMe) {
    final time = DateFormat('HH:mm').format(m.createdAt);
    final color = isMe ? AppTheme.primaryColor : AppTheme.secondaryColor;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: isMe ? color.withValues(alpha: 0.12) : AppTheme.surfaceColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isMe ? 'Tú' : m.authorLabel,
              style: TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 12, color: color),
            ),
            const SizedBox(height: 2),
            Text(m.text, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 2),
            Text(time,
                style: const TextStyle(
                    fontSize: 10, color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Mensaje al grupo...',
                  filled: true,
                  fillColor: AppTheme.surfaceColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
