import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo de mensaje de chat (texto e imagen).
///
/// Almacenamiento: Firestore actúa como transporte temporal con
/// `expiresAt = createdAt + 24h`. Una Cloud Function cron purga los docs y
/// blobs vencidos. Desde la perspectiva del usuario, los mensajes viven
/// en su celular durante 24h y luego desaparecen.
class ChatMessageModel {
  final String uid;
  final String chatRoomId;
  final String senderId;
  final String senderName;

  /// Texto del mensaje. Vacío si solo es imagen.
  final String message;

  /// URL pública del blob en Firebase Storage. Null si es solo texto.
  final String? imageUrl;

  /// Path del blob en Storage para la purga (`chat_images/{roomId}/{uid}.jpg`).
  final String? imagePath;

  /// Cuándo el mensaje (y el blob asociado) deben purgarse. Default 24h.
  final DateTime expiresAt;

  final bool isRead;
  final DateTime createdAt;

  const ChatMessageModel({
    required this.uid,
    required this.chatRoomId,
    required this.senderId,
    required this.senderName,
    this.message = '',
    this.imageUrl,
    this.imagePath,
    required this.expiresAt,
    this.isRead = false,
    required this.createdAt,
  });

  bool get hasImage => imageUrl != null && imageUrl!.isNotEmpty;

  factory ChatMessageModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final created =
        (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
    return ChatMessageModel(
      uid: doc.id,
      chatRoomId: data['chatRoomId'] ?? '',
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? '',
      message: data['message'] ?? '',
      imageUrl: data['imageUrl'] as String?,
      imagePath: data['imagePath'] as String?,
      expiresAt: (data['expiresAt'] as Timestamp?)?.toDate() ??
          created.add(const Duration(hours: 24)),
      isRead: data['isRead'] ?? false,
      createdAt: created,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'chatRoomId': chatRoomId,
      'senderId': senderId,
      'senderName': senderName,
      'message': message,
      'imageUrl': imageUrl,
      'imagePath': imagePath,
      'expiresAt': Timestamp.fromDate(expiresAt),
      'isRead': isRead,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}

/// Modelo de sala de chat
class ChatRoomModel {
  final String uid;
  final List<String> participantIds;
  final List<String> participantNames;
  final String? lastMessage;
  final String? lastSenderId;
  final DateTime? lastMessageTime;
  final DateTime createdAt;

  const ChatRoomModel({
    required this.uid,
    required this.participantIds,
    required this.participantNames,
    this.lastMessage,
    this.lastSenderId,
    this.lastMessageTime,
    required this.createdAt,
  });

  factory ChatRoomModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ChatRoomModel(
      uid: doc.id,
      participantIds: List<String>.from(data['participantIds'] ?? []),
      participantNames: List<String>.from(data['participantNames'] ?? []),
      lastMessage: data['lastMessage'],
      lastSenderId: data['lastSenderId'],
      lastMessageTime: (data['lastMessageTime'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'participantIds': participantIds,
      'participantNames': participantNames,
      'lastMessage': lastMessage,
      'lastSenderId': lastSenderId,
      'lastMessageTime': lastMessageTime != null
          ? Timestamp.fromDate(lastMessageTime!)
          : null,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}
