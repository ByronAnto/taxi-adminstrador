import '../../domain/repositories/chat_repository.dart';
import '../datasources/chat_remote_datasource.dart';
import '../models/chat_model.dart';

class ChatRepositoryImpl implements ChatRepository {
  final ChatRemoteDatasource _datasource;

  ChatRepositoryImpl(this._datasource);

  @override
  Stream<List<ChatRoomModel>> watchChatRooms(String userId) =>
      _datasource.watchChatRooms(userId);

  @override
  Future<ChatRoomModel> getOrCreateChatRoom(
    List<String> participantIds,
    List<String> participantNames,
  ) =>
      _datasource.getOrCreateChatRoom(participantIds, participantNames);

  @override
  Stream<List<ChatMessageModel>> watchMessages(String chatRoomId) =>
      _datasource.watchMessages(chatRoomId);

  @override
  Future<void> sendMessage(ChatMessageModel message) =>
      _datasource.sendMessage(message);

  @override
  Future<void> markMessagesAsRead(String chatRoomId, String userId) =>
      _datasource.markMessagesAsRead(chatRoomId, userId);

  @override
  Stream<int> watchUnreadCount(String userId) =>
      _datasource.watchUnreadCount(userId);
}
