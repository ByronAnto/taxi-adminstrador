import '../../data/models/channel_model.dart';

/// Interfaz abstracta del repositorio de comunicación walkie-talkie
abstract class CommunicationRepository {
  /// Observar canales disponibles
  Stream<List<ChannelModel>> watchChannels();

  /// Observar un canal específico en tiempo real (estado PTT lock)
  Stream<ChannelModel> watchChannel(String channelId);

  /// Obtener canal por ID
  Future<ChannelModel> getChannelById(String channelId);

  /// Crear un canal
  Future<void> createChannel(ChannelModel channel);

  /// Unirse a un canal
  Future<void> joinChannel(String channelId, String userId);

  /// Salir de un canal
  Future<void> leaveChannel(String channelId, String userId);

  /// PTT Lock: Intentar bloquear el canal para hablar
  Future<bool> lockChannel({
    required String channelId,
    required String userId,
    required String userName,
  });

  /// PTT Lock: Liberar el canal
  Future<void> unlockChannel({
    required String channelId,
    required String userId,
  });

  /// Observar mensajes de un canal en tiempo real
  Stream<List<MessageModel>> watchChannelMessages(String channelId);

  /// Enviar mensaje al canal (texto, voz)
  Future<void> sendChannelMessage(MessageModel message);

  /// Obtener miembros del canal
  Future<List<String>> getChannelMembers(String channelId);
}
