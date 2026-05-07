import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
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

    final now = DateTime.now();
    final msg = ChatMessageModel(
      uid: const Uuid().v4(),
      chatRoomId: widget.chatRoomId,
      senderId: _currentUserId(),
      senderName: _currentUserName(),
      message: text,
      expiresAt: now.add(const Duration(hours: 24)),
      createdAt: now,
    );

    context.read<ChatBloc>().add(ChatSendMessageRequested(msg));
    _messageController.clear();
  }

  /// Pick image from gallery o cámara, sube a Storage con expiresAt 24h y
  /// crea el doc en Firestore. La imagen se purga automáticamente por
  /// Cloud Function tras 24h (mismo flujo que payments.proof.photoExpired).
  Future<void> _sendImage(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      imageQuality: 75,
      maxWidth: 1600,
    );
    if (picked == null) return;
    if (!mounted) return;

    final myId = _currentUserId();
    final myName = _currentUserName();
    final msgId = const Uuid().v4();
    final path = 'chat_images/${widget.chatRoomId}/$msgId.jpg';
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
        content: Text('Subiendo imagen...'),
        duration: Duration(seconds: 2)));

    try {
      final ref = FirebaseStorage.instance.ref(path);
      final file = File(picked.path);
      final now = DateTime.now();
      final expiresAt = now.add(const Duration(hours: 24));
      await ref.putFile(
        file,
        SettableMetadata(
          contentType: 'image/jpeg',
          customMetadata: {
            'expiresAt': expiresAt.millisecondsSinceEpoch.toString(),
            'roomId': widget.chatRoomId,
          },
        ),
      );
      final url = await ref.getDownloadURL();
      final msg = ChatMessageModel(
        uid: msgId,
        chatRoomId: widget.chatRoomId,
        senderId: myId,
        senderName: myName,
        message: '',
        imageUrl: url,
        imagePath: path,
        expiresAt: expiresAt,
        createdAt: now,
      );
      if (!mounted) return;
      context.read<ChatBloc>().add(ChatSendMessageRequested(msg));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Error subiendo imagen: $e'),
        backgroundColor: AppTheme.errorColor,
      ));
    }
  }

  void _showAttachSheet() {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galería'),
              onTap: () {
                Navigator.pop(context);
                _sendImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Cámara'),
              onTap: () {
                Navigator.pop(context);
                _sendImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
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
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  tooltip: 'Adjuntar imagen',
                  onPressed: _showAttachSheet,
                ),
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
      child: GestureDetector(
        onLongPress: () => _shareMessage(msg),
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
            if (msg.hasImage)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedNetworkImage(
                    imageUrl: msg.imageUrl!,
                    width: 220,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => Container(
                      width: 220,
                      height: 160,
                      color: Colors.grey.shade300,
                      child: const Center(
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                    errorWidget: (_, _, _) => Container(
                      width: 220,
                      height: 160,
                      color: Colors.grey.shade200,
                      child:
                          const Icon(Icons.broken_image, size: 40),
                    ),
                  ),
                ),
              ),
            if (msg.message.isNotEmpty)
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
    ),
    );
  }

  /// Reenvía el mensaje (texto + imagen si tiene) por WhatsApp / share nativo.
  /// Si tiene imagen, descarga el blob y lo comparte como archivo.
  Future<void> _shareMessage(ChatMessageModel msg) async {
    if (msg.hasImage) {
      try {
        final ref = FirebaseStorage.instance.refFromURL(msg.imageUrl!);
        final tmp = File(
            '${Directory.systemTemp.path}/chat_${msg.uid}.jpg');
        await ref.writeToFile(tmp);
        await Share.shareXFiles(
          [XFile(tmp.path, mimeType: 'image/jpeg')],
          text: msg.message.isNotEmpty
              ? msg.message
              : 'Imagen enviada por ${msg.senderName}',
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo compartir: $e')),
          );
        }
      }
    } else if (msg.message.isNotEmpty) {
      await Share.share(msg.message);
    }
  }
}
