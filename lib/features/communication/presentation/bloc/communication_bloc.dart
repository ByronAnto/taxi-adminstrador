import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/models/channel_model.dart';
import '../../domain/usecases/communication_usecases.dart';

// ============ EVENTS ============

abstract class CommunicationEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class ChannelsWatchStarted extends CommunicationEvent {}

class ChannelsUpdated extends CommunicationEvent {
  final List<ChannelModel> channels;
  ChannelsUpdated(this.channels);
  @override
  List<Object?> get props => [channels];
}

class ChannelSelected extends CommunicationEvent {
  final String? channelId;
  ChannelSelected(this.channelId);
  @override
  List<Object?> get props => [channelId];
}

class ChannelMessagesUpdated extends CommunicationEvent {
  final List<MessageModel> messages;
  ChannelMessagesUpdated(this.messages);
  @override
  List<Object?> get props => [messages];
}

class ChannelCreateRequested extends CommunicationEvent {
  final ChannelModel channel;
  ChannelCreateRequested(this.channel);
  @override
  List<Object?> get props => [channel.uid];
}

class ChannelJoinRequested extends CommunicationEvent {
  final String channelId;
  final String userId;
  ChannelJoinRequested(this.channelId, this.userId);
  @override
  List<Object?> get props => [channelId, userId];
}

class ChannelLeaveRequested extends CommunicationEvent {
  final String channelId;
  final String userId;
  ChannelLeaveRequested(this.channelId, this.userId);
  @override
  List<Object?> get props => [channelId, userId];
}

class ChannelMessageSendRequested extends CommunicationEvent {
  final MessageModel message;
  ChannelMessageSendRequested(this.message);
  @override
  List<Object?> get props => [message.uid];
}

// === PTT Lock Events ===

class PttLockRequested extends CommunicationEvent {
  final String channelId;
  final String userId;
  final String userName;
  PttLockRequested({
    required this.channelId,
    required this.userId,
    required this.userName,
  });
  @override
  List<Object?> get props => [channelId, userId, userName];
}

class PttUnlockRequested extends CommunicationEvent {
  final String channelId;
  final String userId;
  PttUnlockRequested({required this.channelId, required this.userId});
  @override
  List<Object?> get props => [channelId, userId];
}

class ActiveChannelUpdated extends CommunicationEvent {
  final ChannelModel channel;
  ActiveChannelUpdated(this.channel);
  @override
  List<Object?> get props => [channel.uid, channel.currentSpeakerId];
}

// ============ STATES ============

abstract class CommunicationState extends Equatable {
  @override
  List<Object?> get props => [];
}

class CommunicationInitial extends CommunicationState {}

class CommunicationLoading extends CommunicationState {}

class CommunicationLoaded extends CommunicationState {
  final List<ChannelModel> channels;
  final String? activeChannelId;
  final ChannelModel? activeChannel; // Canal activo con estado PTT en tiempo real
  final List<MessageModel> activeMessages;
  final bool isPttLocked; // true si alguien tiene el lock
  final String? pttSpeakerId;
  final String? pttSpeakerName;
  final bool pttLockDenied; // true si se intentó hablar pero otro lo tiene

  CommunicationLoaded({
    this.channels = const [],
    this.activeChannelId,
    this.activeChannel,
    this.activeMessages = const [],
    this.isPttLocked = false,
    this.pttSpeakerId,
    this.pttSpeakerName,
    this.pttLockDenied = false,
  });

  @override
  List<Object?> get props => [
        channels,
        activeChannelId,
        activeChannel,
        activeMessages,
        isPttLocked,
        pttSpeakerId,
        pttSpeakerName,
        pttLockDenied,
      ];

  CommunicationLoaded copyWith({
    List<ChannelModel>? channels,
    String? activeChannelId,
    ChannelModel? activeChannel,
    List<MessageModel>? activeMessages,
    bool? isPttLocked,
    String? pttSpeakerId,
    String? pttSpeakerName,
    bool? pttLockDenied,
    bool clearActiveChannel = false,
  }) {
    return CommunicationLoaded(
      channels: channels ?? this.channels,
      activeChannelId: clearActiveChannel
          ? activeChannelId
          : (activeChannelId ?? this.activeChannelId),
      activeChannel: clearActiveChannel ? null : (activeChannel ?? this.activeChannel),
      activeMessages: activeMessages ?? this.activeMessages,
      isPttLocked: isPttLocked ?? this.isPttLocked,
      pttSpeakerId: pttSpeakerId ?? this.pttSpeakerId,
      pttSpeakerName: pttSpeakerName ?? this.pttSpeakerName,
      pttLockDenied: pttLockDenied ?? this.pttLockDenied,
    );
  }
}

class CommunicationError extends CommunicationState {
  final String message;
  CommunicationError(this.message);
  @override
  List<Object?> get props => [message];
}

// ============ BLOC ============

class CommunicationBloc extends Bloc<CommunicationEvent, CommunicationState> {
  final WatchChannelsUseCase watchChannels;
  final WatchChannelUseCase watchChannel;
  final CreateChannelUseCase createChannel;
  final JoinChannelUseCase joinChannel;
  final LeaveChannelUseCase leaveChannel;
  final WatchChannelMessagesUseCase watchChannelMessages;
  final SendChannelMessageUseCase sendChannelMessage;
  final LockChannelUseCase lockChannel;
  final UnlockChannelUseCase unlockChannel;

  StreamSubscription<List<ChannelModel>>? _channelsSubscription;
  StreamSubscription<List<MessageModel>>? _messagesSubscription;
  StreamSubscription<ChannelModel>? _activeChannelSubscription;

  CommunicationBloc({
    required this.watchChannels,
    required this.watchChannel,
    required this.createChannel,
    required this.joinChannel,
    required this.leaveChannel,
    required this.watchChannelMessages,
    required this.sendChannelMessage,
    required this.lockChannel,
    required this.unlockChannel,
  }) : super(CommunicationInitial()) {
    on<ChannelsWatchStarted>(_onChannelsWatchStarted);
    on<ChannelsUpdated>(_onChannelsUpdated);
    on<ChannelSelected>(_onChannelSelected);
    on<ChannelMessagesUpdated>(_onMessagesUpdated);
    on<ChannelCreateRequested>(_onCreateChannel);
    on<ChannelJoinRequested>(_onJoinChannel);
    on<ChannelLeaveRequested>(_onLeaveChannel);
    on<ChannelMessageSendRequested>(_onSendMessage);
    on<PttLockRequested>(_onPttLockRequested);
    on<PttUnlockRequested>(_onPttUnlockRequested);
    on<ActiveChannelUpdated>(_onActiveChannelUpdated);
  }

  Future<void> _onChannelsWatchStarted(
    ChannelsWatchStarted event,
    Emitter<CommunicationState> emit,
  ) async {
    emit(CommunicationLoading());
    await _channelsSubscription?.cancel();
    _channelsSubscription = watchChannels().listen(
      (channels) => add(ChannelsUpdated(channels)),
      onError: (_) => add(ChannelsUpdated(const [])),
    );
  }

  void _onChannelsUpdated(
    ChannelsUpdated event,
    Emitter<CommunicationState> emit,
  ) {
    final current = state;
    if (current is CommunicationLoaded) {
      emit(current.copyWith(channels: event.channels));
    } else {
      emit(CommunicationLoaded(channels: event.channels));
    }
  }

  Future<void> _onChannelSelected(
    ChannelSelected event,
    Emitter<CommunicationState> emit,
  ) async {
    await _messagesSubscription?.cancel();
    await _activeChannelSubscription?.cancel();
    _messagesSubscription = null;
    _activeChannelSubscription = null;

    final current = state;
    if (current is CommunicationLoaded) {
      emit(current.copyWith(
        activeChannelId: event.channelId,
        activeMessages: const [],
        isPttLocked: false,
        pttSpeakerId: '',
        pttSpeakerName: '',
        pttLockDenied: false,
        clearActiveChannel: true,
      ));
    }

    // Si se deseleccionó (null), no hay canal al que suscribirse.
    final selectedId = event.channelId;
    if (selectedId == null) return;

    // Escuchar mensajes del canal seleccionado
    _messagesSubscription = watchChannelMessages(selectedId).listen(
      (messages) => add(ChannelMessagesUpdated(messages)),
      onError: (_) => add(ChannelMessagesUpdated(const [])),
    );

    // Escuchar estado del canal en tiempo real (PTT lock)
    _activeChannelSubscription = watchChannel(selectedId).listen(
      (channel) => add(ActiveChannelUpdated(channel)),
      onError: (_) {},
    );
  }

  void _onActiveChannelUpdated(
    ActiveChannelUpdated event,
    Emitter<CommunicationState> emit,
  ) {
    final current = state;
    if (current is CommunicationLoaded) {
      final ch = event.channel;
      emit(current.copyWith(
        activeChannel: ch,
        isPttLocked: ch.isLocked && !ch.isLockExpired,
        pttSpeakerId: ch.currentSpeakerId ?? '',
        pttSpeakerName: ch.currentSpeakerName ?? '',
        pttLockDenied: false,
      ));
    }
  }

  void _onMessagesUpdated(
    ChannelMessagesUpdated event,
    Emitter<CommunicationState> emit,
  ) {
    final current = state;
    if (current is CommunicationLoaded) {
      emit(current.copyWith(activeMessages: event.messages));
    }
  }

  Future<void> _onCreateChannel(
    ChannelCreateRequested event,
    Emitter<CommunicationState> emit,
  ) async {
    try {
      await _retryFirestore(() => createChannel(event.channel));
    } catch (e) {
      dev.log('CommunicationBloc: createChannel error: $e');
      emit(CommunicationError('Error al crear canal: $e'));
    }
  }

  Future<void> _onJoinChannel(
    ChannelJoinRequested event,
    Emitter<CommunicationState> emit,
  ) async {
    try {
      await _retryFirestore(() => joinChannel(ChannelMemberParams(
        channelId: event.channelId,
        userId: event.userId,
      )));
    } catch (e) {
      dev.log('CommunicationBloc: joinChannel error: $e');
      emit(CommunicationError('Error al unirse al canal: $e'));
    }
  }

  Future<void> _onLeaveChannel(
    ChannelLeaveRequested event,
    Emitter<CommunicationState> emit,
  ) async {
    try {
      await _retryFirestore(() => leaveChannel(ChannelMemberParams(
        channelId: event.channelId,
        userId: event.userId,
      )));
    } catch (e) {
      dev.log('CommunicationBloc: leaveChannel error: $e');
      emit(CommunicationError('Error al salir del canal: $e'));
    }
  }

  Future<void> _onSendMessage(
    ChannelMessageSendRequested event,
    Emitter<CommunicationState> emit,
  ) async {
    try {
      await _retryFirestore(() => sendChannelMessage(event.message));
    } catch (e) {
      dev.log('CommunicationBloc: sendMessage error: $e');
      emit(CommunicationError('Error al enviar mensaje: $e'));
    }
  }

  // === Retry helper para operaciones Firestore transitorias ===

  /// Reintenta [operation] hasta [maxRetries] veces con backoff exponencial.
  /// Retorna el resultado o lanza la excepción del último intento.
  Future<T> _retryFirestore<T>(
    Future<T> Function() operation, {
    int maxRetries = 3,
  }) async {
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        return await operation();
      } catch (e) {
        final isTransient = e.toString().contains('unavailable') ||
            e.toString().contains('deadline-exceeded') ||
            e.toString().contains('network');
        if (!isTransient || attempt == maxRetries - 1) rethrow;
        // Backoff: 500ms, 1s, 2s
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        dev.log('CommunicationBloc: retry ${attempt + 1}/$maxRetries');
      }
    }
    throw StateError('unreachable');
  }

  // === PTT Lock/Unlock ===

  Future<void> _onPttLockRequested(
    PttLockRequested event,
    Emitter<CommunicationState> emit,
  ) async {
    try {
      final acquired = await _retryFirestore(() => lockChannel(LockChannelParams(
        channelId: event.channelId,
        userId: event.userId,
        userName: event.userName,
      )));

      if (!acquired) {
        final current = state;
        if (current is CommunicationLoaded) {
          emit(current.copyWith(pttLockDenied: true));
        }
      }
      // Si se adquirió, el stream de watchChannel emitirá la actualización
    } catch (e) {
      // No destruir el estado — el lock expira solo y el stream se re-sincroniza
      dev.log('CommunicationBloc: lockChannel falló después de reintentos: $e');
    }
  }

  Future<void> _onPttUnlockRequested(
    PttUnlockRequested event,
    Emitter<CommunicationState> emit,
  ) async {
    try {
      await _retryFirestore(() => unlockChannel(UnlockChannelParams(
        channelId: event.channelId,
        userId: event.userId,
      )));
      // El stream de watchChannel emitirá la actualización
    } catch (e) {
      // No destruir el estado — el lock expira solo y el stream se re-sincroniza
      dev.log('CommunicationBloc: unlockChannel falló después de reintentos: $e');
    }
  }

  @override
  Future<void> close() {
    _channelsSubscription?.cancel();
    _messagesSubscription?.cancel();
    _activeChannelSubscription?.cancel();
    return super.close();
  }
}
