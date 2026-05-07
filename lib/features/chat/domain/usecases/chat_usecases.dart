import 'package:equatable/equatable.dart';
import '../../../../core/usecases/usecase.dart';
import '../../data/models/chat_model.dart';
import '../repositories/chat_repository.dart';

// ========== Watch Chat Rooms ==========

class WatchChatRoomsUseCase {
  final ChatRepository repository;
  WatchChatRoomsUseCase(this.repository);
  Stream<List<ChatRoomModel>> call(String userId) =>
      repository.watchChatRooms(userId);
}

// ========== Get or Create Chat Room ==========

class CreateChatRoomParams extends Equatable {
  final List<String> participantIds;
  final List<String> participantNames;
  const CreateChatRoomParams({required this.participantIds, required this.participantNames});
  @override
  List<Object?> get props => [participantIds, participantNames];
}

class GetOrCreateChatRoomUseCase implements UseCase<ChatRoomModel, CreateChatRoomParams> {
  final ChatRepository repository;
  GetOrCreateChatRoomUseCase(this.repository);
  @override
  Future<ChatRoomModel> call(CreateChatRoomParams params) =>
      repository.getOrCreateChatRoom(params.participantIds, params.participantNames);
}

// ========== Watch Messages ==========

class WatchMessagesUseCase {
  final ChatRepository repository;
  WatchMessagesUseCase(this.repository);
  Stream<List<ChatMessageModel>> call(String chatRoomId) =>
      repository.watchMessages(chatRoomId);
}

// ========== Send Message ==========

class SendMessageUseCase implements UseCase<void, ChatMessageModel> {
  final ChatRepository repository;
  SendMessageUseCase(this.repository);
  @override
  Future<void> call(ChatMessageModel message) =>
      repository.sendMessage(message);
}

// ========== Mark Messages As Read ==========

class MarkMessagesReadParams extends Equatable {
  final String chatRoomId;
  final String userId;
  const MarkMessagesReadParams({required this.chatRoomId, required this.userId});
  @override
  List<Object?> get props => [chatRoomId, userId];
}

class MarkMessagesReadUseCase implements UseCase<void, MarkMessagesReadParams> {
  final ChatRepository repository;
  MarkMessagesReadUseCase(this.repository);
  @override
  Future<void> call(MarkMessagesReadParams params) =>
      repository.markMessagesAsRead(params.chatRoomId, params.userId);
}

// ========== Watch Unread Count ==========

class WatchUnreadCountUseCase {
  final ChatRepository repository;
  WatchUnreadCountUseCase(this.repository);
  Stream<int> call(String userId) =>
      repository.watchUnreadCount(userId);
}
