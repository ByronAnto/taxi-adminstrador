import '../../domain/repositories/communication_repository.dart';
import '../datasources/communication_remote_datasource.dart';
import '../models/channel_model.dart';

class CommunicationRepositoryImpl implements CommunicationRepository {
  final CommunicationRemoteDatasource _datasource;

  CommunicationRepositoryImpl(this._datasource);

  @override
  Stream<List<ChannelModel>> watchChannels() =>
      _datasource.watchChannels();

  @override
  Stream<ChannelModel> watchChannel(String channelId) =>
      _datasource.watchChannel(channelId);

  @override
  Future<ChannelModel> getChannelById(String channelId) =>
      _datasource.getChannelById(channelId);

  @override
  Future<void> createChannel(ChannelModel channel) =>
      _datasource.createChannel(channel);

  @override
  Future<void> joinChannel(String channelId, String userId) =>
      _datasource.joinChannel(channelId, userId);

  @override
  Future<void> leaveChannel(String channelId, String userId) =>
      _datasource.leaveChannel(channelId, userId);

  @override
  Future<bool> lockChannel({
    required String channelId,
    required String userId,
    required String userName,
  }) =>
      _datasource.lockChannel(
        channelId: channelId,
        userId: userId,
        userName: userName,
      );

  @override
  Future<void> unlockChannel({
    required String channelId,
    required String userId,
    bool force = false,
  }) =>
      _datasource.unlockChannel(
        channelId: channelId,
        userId: userId,
        force: force,
      );

  @override
  Stream<List<MessageModel>> watchChannelMessages(String channelId) =>
      _datasource.watchChannelMessages(channelId);

  @override
  Future<void> sendChannelMessage(MessageModel message) =>
      _datasource.sendChannelMessage(message);

  @override
  Future<List<String>> getChannelMembers(String channelId) =>
      _datasource.getChannelMembers(channelId);
}
