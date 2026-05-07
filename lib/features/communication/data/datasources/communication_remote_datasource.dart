import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/channel_model.dart';
import '../../../../core/constants/app_constants.dart';

class CommunicationRemoteDatasource {
  final FirebaseFirestore _firestore;

  CommunicationRemoteDatasource({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference get _channelsRef =>
      _firestore.collection(AppConstants.channelsCollection);

  CollectionReference get _messagesRef =>
      _firestore.collection(AppConstants.messagesCollection);

  // ========== CANALES ==========

  Stream<List<ChannelModel>> watchChannels() {
    return _channelsRef
        .where('isActive', isEqualTo: true)
        .orderBy('name')
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => ChannelModel.fromFirestore(doc)).toList());
  }

  /// Observar un canal específico en tiempo real (para estado PTT lock)
  Stream<ChannelModel> watchChannel(String channelId) {
    return _channelsRef.doc(channelId).snapshots().map(
          (doc) => ChannelModel.fromFirestore(doc),
        );
  }

  Future<ChannelModel> getChannelById(String channelId) async {
    final doc = await _channelsRef.doc(channelId).get();
    if (!doc.exists) throw Exception('Canal no encontrado');
    return ChannelModel.fromFirestore(doc);
  }

  Future<void> createChannel(ChannelModel channel) async {
    await _channelsRef.add(channel.toFirestore());
  }

  Future<void> joinChannel(String channelId, String userId) async {
    await _channelsRef.doc(channelId).update({
      'memberIds': FieldValue.arrayUnion([userId]),
    });
  }

  Future<void> leaveChannel(String channelId, String userId) async {
    await _channelsRef.doc(channelId).update({
      'memberIds': FieldValue.arrayRemove([userId]),
    });
  }

  Future<List<String>> getChannelMembers(String channelId) async {
    final doc = await _channelsRef.doc(channelId).get();
    final data = doc.data() as Map<String, dynamic>;
    return List<String>.from(data['memberIds'] ?? []);
  }

  // ========== PTT LOCK (Zello-style) ==========

  /// Intenta bloquear el canal para hablar (transacción atómica).
  /// Retorna true si se adquirió el lock, false si otro lo tiene.
  Future<bool> lockChannel({
    required String channelId,
    required String userId,
    required String userName,
  }) async {
    return _firestore.runTransaction<bool>((transaction) async {
      final doc = await transaction.get(_channelsRef.doc(channelId));
      if (!doc.exists) throw Exception('Canal no encontrado');

      final channel = ChannelModel.fromFirestore(doc);

      // Si ya está bloqueado por otro usuario y no expiró
      if (channel.isLocked &&
          !channel.isLockedBy(userId) &&
          !channel.isLockExpired) {
        return false; // Otro está hablando
      }

      // Adquirir lock — speakerLockedAt usa serverTimestamp para que las
      // reglas Firestore puedan validar la transición con request.time.
      transaction.update(_channelsRef.doc(channelId), {
        'currentSpeakerId': userId,
        'currentSpeakerName': userName,
        'speakerLockedAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
  }

  /// Libera el lock del canal (solo el que lo tiene puede liberarlo).
  Future<void> unlockChannel({
    required String channelId,
    required String userId,
  }) async {
    return _firestore.runTransaction((transaction) async {
      final doc = await transaction.get(_channelsRef.doc(channelId));
      if (!doc.exists) return;

      final channel = ChannelModel.fromFirestore(doc);

      // Solo el speaker actual puede desbloquear (o si expiró)
      if (channel.isLockedBy(userId) || channel.isLockExpired) {
        transaction.update(_channelsRef.doc(channelId), {
          'currentSpeakerId': null,
          'currentSpeakerName': null,
          'speakerLockedAt': null,
        });
      }
    });
  }

  // ========== MENSAJES DE CANAL ==========

  Stream<List<MessageModel>> watchChannelMessages(String channelId) {
    return _messagesRef
        .where('channelId', isEqualTo: channelId)
        .orderBy('createdAt', descending: false)
        .limitToLast(100)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => MessageModel.fromFirestore(doc)).toList());
  }

  Future<void> sendChannelMessage(MessageModel message) async {
    await _messagesRef.add(message.toFirestore());
  }
}
