import 'package:equatable/equatable.dart';
import '../../../../core/usecases/usecase.dart';
import '../../data/models/channel_model.dart';
import '../repositories/communication_repository.dart';

// ========== Watch Channels ==========

class WatchChannelsUseCase {
  final CommunicationRepository repository;
  WatchChannelsUseCase(this.repository);
  Stream<List<ChannelModel>> call() => repository.watchChannels();
}

// ========== Watch Single Channel (PTT state) ==========

class WatchChannelUseCase {
  final CommunicationRepository repository;
  WatchChannelUseCase(this.repository);
  Stream<ChannelModel> call(String channelId) => repository.watchChannel(channelId);
}

// ========== Create Channel ==========

class CreateChannelUseCase implements UseCase<void, ChannelModel> {
  final CommunicationRepository repository;
  CreateChannelUseCase(this.repository);
  @override
  Future<void> call(ChannelModel channel) => repository.createChannel(channel);
}

// ========== Join Channel ==========

class ChannelMemberParams extends Equatable {
  final String channelId;
  final String userId;
  const ChannelMemberParams({required this.channelId, required this.userId});
  @override
  List<Object?> get props => [channelId, userId];
}

class JoinChannelUseCase implements UseCase<void, ChannelMemberParams> {
  final CommunicationRepository repository;
  JoinChannelUseCase(this.repository);
  @override
  Future<void> call(ChannelMemberParams params) =>
      repository.joinChannel(params.channelId, params.userId);
}

// ========== Leave Channel ==========

class LeaveChannelUseCase implements UseCase<void, ChannelMemberParams> {
  final CommunicationRepository repository;
  LeaveChannelUseCase(this.repository);
  @override
  Future<void> call(ChannelMemberParams params) =>
      repository.leaveChannel(params.channelId, params.userId);
}

// ========== Lock Channel (PTT) ==========

class LockChannelParams extends Equatable {
  final String channelId;
  final String userId;
  final String userName;
  const LockChannelParams({
    required this.channelId,
    required this.userId,
    required this.userName,
  });
  @override
  List<Object?> get props => [channelId, userId, userName];
}

class LockChannelUseCase implements UseCase<bool, LockChannelParams> {
  final CommunicationRepository repository;
  LockChannelUseCase(this.repository);
  @override
  Future<bool> call(LockChannelParams params) =>
      repository.lockChannel(
        channelId: params.channelId,
        userId: params.userId,
        userName: params.userName,
      );
}

// ========== Unlock Channel (PTT) ==========

class UnlockChannelParams extends Equatable {
  final String channelId;
  final String userId;
  const UnlockChannelParams({required this.channelId, required this.userId});
  @override
  List<Object?> get props => [channelId, userId];
}

class UnlockChannelUseCase implements UseCase<void, UnlockChannelParams> {
  final CommunicationRepository repository;
  UnlockChannelUseCase(this.repository);
  @override
  Future<void> call(UnlockChannelParams params) =>
      repository.unlockChannel(
        channelId: params.channelId,
        userId: params.userId,
      );
}

// ========== Watch Channel Messages ==========

class WatchChannelMessagesUseCase {
  final CommunicationRepository repository;
  WatchChannelMessagesUseCase(this.repository);
  Stream<List<MessageModel>> call(String channelId) =>
      repository.watchChannelMessages(channelId);
}

// ========== Send Channel Message ==========

class SendChannelMessageUseCase implements UseCase<void, MessageModel> {
  final CommunicationRepository repository;
  SendChannelMessageUseCase(this.repository);
  @override
  Future<void> call(MessageModel message) =>
      repository.sendChannelMessage(message);
}
