import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/chat_model.dart';

class ChatRemoteDatasource {
  final FirebaseFirestore _firestore;

  ChatRemoteDatasource({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference get _chatRoomsRef =>
      _firestore.collection('chat_rooms');

  // ========== SALAS DE CHAT ==========

  Stream<List<ChatRoomModel>> watchChatRooms(String userId) {
    return _chatRoomsRef
        .where('participantIds', arrayContains: userId)
        .orderBy('lastMessageTime', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => ChatRoomModel.fromFirestore(doc)).toList());
  }

  Future<ChatRoomModel> getOrCreateChatRoom(
    List<String> participantIds,
    List<String> participantNames,
  ) async {
    // Buscar sala existente
    final sortedIds = List<String>.from(participantIds)..sort();
    final snapshot = await _chatRoomsRef
        .where('participantIds', isEqualTo: sortedIds)
        .limit(1)
        .get();

    if (snapshot.docs.isNotEmpty) {
      return ChatRoomModel.fromFirestore(snapshot.docs.first);
    }

    // Crear nueva sala
    final room = ChatRoomModel(
      uid: '',
      participantIds: sortedIds,
      participantNames: participantNames,
      createdAt: DateTime.now(),
    );
    final docRef = await _chatRoomsRef.add(room.toFirestore());
    final newDoc = await docRef.get();
    return ChatRoomModel.fromFirestore(newDoc);
  }

  // ========== MENSAJES ==========

  Stream<List<ChatMessageModel>> watchMessages(String chatRoomId) {
    return _chatRoomsRef
        .doc(chatRoomId)
        .collection('messages')
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => ChatMessageModel.fromFirestore(doc)).toList());
  }

  Future<void> sendMessage(ChatMessageModel message) async {
    final batch = _firestore.batch();

    // Agregar mensaje a la subcolección
    final msgRef = _chatRoomsRef
        .doc(message.chatRoomId)
        .collection('messages')
        .doc();
    batch.set(msgRef, message.toFirestore());

    // Actualizar último mensaje en la sala
    batch.update(_chatRoomsRef.doc(message.chatRoomId), {
      'lastMessage': message.message,
      'lastSenderId': message.senderId,
      'lastMessageTime': Timestamp.fromDate(DateTime.now()),
    });

    await batch.commit();
  }

  Future<void> markMessagesAsRead(String chatRoomId, String userId) async {
    final unread = await _chatRoomsRef
        .doc(chatRoomId)
        .collection('messages')
        .where('isRead', isEqualTo: false)
        .where('senderId', isNotEqualTo: userId)
        .get();

    final batch = _firestore.batch();
    for (final doc in unread.docs) {
      batch.update(doc.reference, {'isRead': true});
    }
    await batch.commit();
  }

  Stream<int> watchUnreadCount(String userId) {
    return _chatRoomsRef
        .where('participantIds', arrayContains: userId)
        .snapshots()
        .asyncMap((snapshot) async {
      int total = 0;
      for (final room in snapshot.docs) {
        final unread = await room.reference
            .collection('messages')
            .where('isRead', isEqualTo: false)
            .where('senderId', isNotEqualTo: userId)
            .get();
        total += unread.docs.length;
      }
      return total;
    });
  }
}
