import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/models/chat_model.dart';
import '../../domain/usecases/chat_usecases.dart';

// ============ EVENTS ============

abstract class ChatEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class ChatRoomsWatchStarted extends ChatEvent {
  final String userId;
  ChatRoomsWatchStarted(this.userId);
  @override
  List<Object?> get props => [userId];
}

class ChatRoomsUpdated extends ChatEvent {
  final List<ChatRoomModel> rooms;
  ChatRoomsUpdated(this.rooms);
  @override
  List<Object?> get props => [rooms];
}

class ChatMessagesWatchStarted extends ChatEvent {
  final String chatRoomId;
  ChatMessagesWatchStarted(this.chatRoomId);
  @override
  List<Object?> get props => [chatRoomId];
}

class ChatMessagesUpdated extends ChatEvent {
  final List<ChatMessageModel> messages;
  ChatMessagesUpdated(this.messages);
  @override
  List<Object?> get props => [messages];
}

class ChatSendMessageRequested extends ChatEvent {
  final ChatMessageModel message;
  ChatSendMessageRequested(this.message);
  @override
  List<Object?> get props => [message.uid];
}

class ChatMarkReadRequested extends ChatEvent {
  final String chatRoomId;
  final String userId;
  ChatMarkReadRequested(this.chatRoomId, this.userId);
  @override
  List<Object?> get props => [chatRoomId, userId];
}

class ChatCreateRoomRequested extends ChatEvent {
  final List<String> participantIds;
  final List<String> participantNames;
  ChatCreateRoomRequested(this.participantIds, this.participantNames);
  @override
  List<Object?> get props => [participantIds];
}

// ============ STATES ============

abstract class ChatState extends Equatable {
  @override
  List<Object?> get props => [];
}

class ChatInitial extends ChatState {}

class ChatLoading extends ChatState {}

class ChatRoomsLoaded extends ChatState {
  final List<ChatRoomModel> rooms;
  ChatRoomsLoaded(this.rooms);
  @override
  List<Object?> get props => [rooms];
}

class ChatMessagesLoaded extends ChatState {
  final List<ChatMessageModel> messages;
  final String chatRoomId;
  ChatMessagesLoaded({required this.messages, required this.chatRoomId});
  @override
  List<Object?> get props => [messages, chatRoomId];
}

class ChatRoomCreated extends ChatState {
  final ChatRoomModel room;
  ChatRoomCreated(this.room);
  @override
  List<Object?> get props => [room.uid];
}

class ChatError extends ChatState {
  final String message;
  ChatError(this.message);
  @override
  List<Object?> get props => [message];
}

// ============ BLOC ============

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final WatchChatRoomsUseCase watchChatRooms;
  final WatchMessagesUseCase watchMessages;
  final SendMessageUseCase sendMessage;
  final MarkMessagesReadUseCase markMessagesRead;
  final GetOrCreateChatRoomUseCase getOrCreateChatRoom;

  StreamSubscription<List<ChatRoomModel>>? _roomsSubscription;
  StreamSubscription<List<ChatMessageModel>>? _messagesSubscription;

  ChatBloc({
    required this.watchChatRooms,
    required this.watchMessages,
    required this.sendMessage,
    required this.markMessagesRead,
    required this.getOrCreateChatRoom,
  }) : super(ChatInitial()) {
    on<ChatRoomsWatchStarted>(_onRoomsWatchStarted);
    on<ChatRoomsUpdated>(_onRoomsUpdated);
    on<ChatMessagesWatchStarted>(_onMessagesWatchStarted);
    on<ChatMessagesUpdated>(_onMessagesUpdated);
    on<ChatSendMessageRequested>(_onSendMessage);
    on<ChatMarkReadRequested>(_onMarkRead);
    on<ChatCreateRoomRequested>(_onCreateRoom);
  }

  Future<void> _onRoomsWatchStarted(
    ChatRoomsWatchStarted event,
    Emitter<ChatState> emit,
  ) async {
    emit(ChatLoading());
    await _roomsSubscription?.cancel();
    _roomsSubscription = watchChatRooms(event.userId).listen(
      (rooms) => add(ChatRoomsUpdated(rooms)),
      onError: (error) => add(ChatRoomsUpdated(const [])),
    );
  }

  void _onRoomsUpdated(
    ChatRoomsUpdated event,
    Emitter<ChatState> emit,
  ) {
    emit(ChatRoomsLoaded(event.rooms));
  }

  Future<void> _onMessagesWatchStarted(
    ChatMessagesWatchStarted event,
    Emitter<ChatState> emit,
  ) async {
    emit(ChatLoading());
    await _messagesSubscription?.cancel();
    _messagesSubscription = watchMessages(event.chatRoomId).listen(
      (messages) => add(ChatMessagesUpdated(messages)),
      onError: (_) => add(ChatMessagesUpdated(const [])),
    );
  }

  void _onMessagesUpdated(
    ChatMessagesUpdated event,
    Emitter<ChatState> emit,
  ) {
    emit(ChatMessagesLoaded(
      messages: event.messages,
      chatRoomId: event.messages.isNotEmpty ? event.messages.first.chatRoomId : '',
    ));
  }

  Future<void> _onSendMessage(
    ChatSendMessageRequested event,
    Emitter<ChatState> emit,
  ) async {
    try {
      await sendMessage(event.message);
    } catch (e) {
      emit(ChatError('Error al enviar mensaje: $e'));
    }
  }

  Future<void> _onMarkRead(
    ChatMarkReadRequested event,
    Emitter<ChatState> emit,
  ) async {
    try {
      await markMessagesRead(MarkMessagesReadParams(
        chatRoomId: event.chatRoomId,
        userId: event.userId,
      ));
    } catch (_) {
      // silent fail for read receipts
    }
  }

  Future<void> _onCreateRoom(
    ChatCreateRoomRequested event,
    Emitter<ChatState> emit,
  ) async {
    try {
      final room = await getOrCreateChatRoom(CreateChatRoomParams(
        participantIds: event.participantIds,
        participantNames: event.participantNames,
      ));
      emit(ChatRoomCreated(room));
    } catch (e) {
      emit(ChatError('Error al crear chat: $e'));
    }
  }

  @override
  Future<void> close() {
    _roomsSubscription?.cancel();
    _messagesSubscription?.cancel();
    return super.close();
  }
}
