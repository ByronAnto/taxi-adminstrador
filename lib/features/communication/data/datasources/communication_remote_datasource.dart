import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/channel_model.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/current_user_context.dart';

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
    // Multi-tenant: filtrar por la asociación del usuario actual.
    // Sin este filtro, las reglas Firestore rechazan todo el snapshot por
    // contener docs de otros tenants.
    final aid = CurrentUserContext.instance.associationId;
    Query query = _channelsRef.where('isActive', isEqualTo: true);
    if (aid != null && aid.isNotEmpty) {
      query = query.where('associationId', isEqualTo: aid);
    }
    return query.orderBy('name').snapshots().map((snapshot) =>
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
    // Usar set(uid) en vez de add() para que el ID del doc coincida con
    // el ChannelModel.uid (UUID generado en el cliente).
    await _channelsRef.doc(channel.uid).set(channel.toFirestore());
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

  /// Libera el lock del canal.
  /// - Si [force] es false (default): solo el speaker actual puede liberar.
  /// - Si [force] es true: libera incondicionalmente. Usado por
  ///   admin/operadora cuando alguien queda con el "PTT pegado" y
  ///   bloquea el canal para todos. Las reglas Firestore validan el rol.
  Future<void> unlockChannel({
    required String channelId,
    required String userId,
    bool force = false,
  }) async {
    if (force) {
      await _channelsRef.doc(channelId).update({
        'currentSpeakerId': null,
        'currentSpeakerName': null,
        'speakerLockedAt': null,
      });
      return;
    }
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
    final aid = CurrentUserContext.instance.associationId;
    Query query = _messagesRef.where('channelId', isEqualTo: channelId);
    if (aid != null && aid.isNotEmpty) {
      query = query.where('associationId', isEqualTo: aid);
    }
    return query
        .orderBy('createdAt', descending: false)
        .limitToLast(100)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => MessageModel.fromFirestore(doc)).toList());
  }

  Future<void> sendChannelMessage(MessageModel message) async {
    await _messagesRef.doc(message.uid).set(message.toFirestore());
  }
}
