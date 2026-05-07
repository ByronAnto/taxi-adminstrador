import '../../data/models/chat_model.dart';

/// Interfaz abstracta del repositorio de chat
abstract class ChatRepository {
  /// Obtener salas de chat del usuario
  Stream<List<ChatRoomModel>> watchChatRooms(String userId);

  /// Obtener o crear sala de chat entre dos usuarios
  Future<ChatRoomModel> getOrCreateChatRoom(List<String> participantIds, List<String> participantNames);

  /// Observar mensajes de una sala en tiempo real
  Stream<List<ChatMessageModel>> watchMessages(String chatRoomId);

  /// Enviar un mensaje
  Future<void> sendMessage(ChatMessageModel message);

  /// Marcar mensajes como leídos
  Future<void> markMessagesAsRead(String chatRoomId, String userId);

  /// Obtener conteo de mensajes no leídos
  Stream<int> watchUnreadCount(String userId);
}
