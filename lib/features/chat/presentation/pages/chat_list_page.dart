import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/chat_model.dart';
import '../bloc/chat_bloc.dart';

/// Página principal de chats - lista de conversaciones
class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadChatRooms();
  }

  void _loadChatRooms() {
    final authState = context.read<AuthBloc>().state;
    if (authState is AuthAuthenticated) {
      context.read<ChatBloc>().add(
            ChatRoomsWatchStarted(authState.user.uid),
          );
    }
  }

  String _currentUserId() {
    final authState = context.read<AuthBloc>().state;
    return authState is AuthAuthenticated ? authState.user.uid : '';
  }

  /// Get the other participant's name from the room
  String _otherName(ChatRoomModel room) {
    final myId = _currentUserId();
    final idx = room.participantIds.indexOf(myId);
    if (idx >= 0 && room.participantNames.length > 1) {
      return room.participantNames[idx == 0 ? 1 : 0];
    }
    return room.participantNames.isNotEmpty
        ? room.participantNames.first
        : 'Chat';
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mensajes')),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Buscar conversación...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: AppTheme.surfaceColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
            ),
          ),

          // Chat room list
          Expanded(
            child: BlocBuilder<ChatBloc, ChatState>(
              builder: (context, state) {
                if (state is ChatLoading) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (state is ChatRoomsLoaded) {
                  var rooms = state.rooms;
                  if (_searchQuery.isNotEmpty) {
                    rooms = rooms
                        .where((r) => _otherName(r)
                            .toLowerCase()
                            .contains(_searchQuery))
                        .toList();
                  }

                  if (rooms.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.chat_bubble_outline,
                              size: 64, color: Colors.grey[300]),
                          const SizedBox(height: 16),
                          Text('Sin conversaciones',
                              style: TextStyle(
                                  color: Colors.grey[500], fontSize: 16)),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    itemCount: rooms.length,
                    itemBuilder: (ctx, i) => _buildChatTile(rooms[i]),
                  );
                }

                if (state is ChatError) {
                  return Center(child: Text(state.message));
                }

                return const Center(
                    child: Text('Inicia una conversación'));
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatTile(ChatRoomModel room) {
    final name = _otherName(room);
    final lastMsg = room.lastMessage ?? 'Sin mensajes';
    final time = room.lastMessageTime;
    final timeStr = time != null
        ? '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'
        : '';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.15),
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: const TextStyle(
              fontWeight: FontWeight.bold, color: AppTheme.primaryColor),
        ),
      ),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        lastMsg,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
      trailing: Text(timeStr,
          style:
              const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BlocProvider.value(
              value: context.read<ChatBloc>(),
              child: ChatDetailPage(
                chatRoomId: room.uid,
                chatName: name,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Página de detalle de chat - mensajes
class ChatDetailPage extends StatefulWidget {
  final String chatRoomId;
  final String chatName;

  const ChatDetailPage({
    super.key,
    required this.chatRoomId,
    required this.chatName,
  });

  @override
  State<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends State<ChatDetailPage> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    context.read<ChatBloc>().add(
          ChatMessagesWatchStarted(widget.chatRoomId),
        );
    // Mark as read
    final myId = _currentUserId();
    if (myId.isNotEmpty) {
      context.read<ChatBloc>().add(
            ChatMarkReadRequested(widget.chatRoomId, myId),
          );
    }
  }

  String _currentUserId() {
    final authState = context.read<AuthBloc>().state;
    return authState is AuthAuthenticated ? authState.user.uid : '';
  }

  String _currentUserName() {
    final authState = context.read<AuthBloc>().state;
    if (authState is AuthAuthenticated) {
      return '${authState.user.name} ${authState.user.lastname}';
    }
    return '';
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final msg = ChatMessageModel(
      uid: const Uuid().v4(),
      chatRoomId: widget.chatRoomId,
      senderId: _currentUserId(),
      senderName: _currentUserName(),
      message: text,
      createdAt: DateTime.now(),
    );

    context.read<ChatBloc>().add(ChatSendMessageRequested(msg));
    _messageController.clear();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myId = _currentUserId();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor:
                  AppTheme.primaryColor.withValues(alpha: 0.15),
              child: Text(
                widget.chatName.isNotEmpty
                    ? widget.chatName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                    fontSize: 14, color: AppTheme.primaryColor),
              ),
            ),
            const SizedBox(width: 8),
            Text(widget.chatName, style: const TextStyle(fontSize: 16)),
          ],
        ),
      ),
      body: Column(
        children: [
          // Messages
          Expanded(
            child: BlocBuilder<ChatBloc, ChatState>(
              builder: (context, state) {
                if (state is ChatMessagesLoaded &&
                    state.chatRoomId == widget.chatRoomId) {
                  final messages = state.messages;

                  if (messages.isEmpty) {
                    return const Center(
                        child: Text('Envía el primer mensaje'));
                  }

                  return ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (ctx, i) {
                      // Reverse order: newest first
                      final msg = messages[messages.length - 1 - i];
                      final isMe = msg.senderId == myId;
                      return _buildMessageBubble(msg, isMe);
                    },
                  );
                }

                if (state is ChatLoading) {
                  return const Center(child: CircularProgressIndicator());
                }

                return const Center(child: Text('Cargando mensajes...'));
              },
            ),
          ),

          // Input bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.surfaceColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Escribe un mensaje...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 6),
                CircleAvatar(
                  backgroundColor: AppTheme.primaryColor,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white, size: 20),
                    onPressed: _sendMessage,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessageModel msg, bool isMe) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
        decoration: BoxDecoration(
          color: isMe
              ? AppTheme.primaryColor
              : AppTheme.surfaceColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Text(
                msg.senderName,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.secondaryColor,
                ),
              ),
            Text(
              msg.message,
              style: TextStyle(
                color: isMe ? Colors.white : AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${msg.createdAt.hour.toString().padLeft(2, '0')}:${msg.createdAt.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                fontSize: 10,
                color: isMe
                    ? Colors.white.withValues(alpha: 0.7)
                    : AppTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
