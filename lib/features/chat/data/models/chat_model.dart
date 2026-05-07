import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo de mensaje de chat (solo texto)
class ChatMessageModel {
  final String uid;
  final String chatRoomId;
  final String senderId;
  final String senderName;
  final String message;
  final bool isRead;
  final DateTime createdAt;

  const ChatMessageModel({
    required this.uid,
    required this.chatRoomId,
    required this.senderId,
    required this.senderName,
    required this.message,
    this.isRead = false,
    required this.createdAt,
  });

  factory ChatMessageModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ChatMessageModel(
      uid: doc.id,
      chatRoomId: data['chatRoomId'] ?? '',
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? '',
      message: data['message'] ?? '',
      isRead: data['isRead'] ?? false,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'chatRoomId': chatRoomId,
      'senderId': senderId,
      'senderName': senderName,
      'message': message,
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
