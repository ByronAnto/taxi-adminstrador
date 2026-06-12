import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
// Prefijo `rtdb` para evitar colisiones de nombres con cloud_firestore
// (`Query`, `Transaction` existen en ambas librerías).
import 'package:firebase_database/firebase_database.dart' as rtdb;
import '../models/channel_model.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/current_user_context.dart';
import '../../../../core/services/rtdb_service.dart';

class CommunicationRemoteDatasource {
  final FirebaseFirestore _firestore;

  /// Servicio RTDB para el camino EFÍMERO del lock del PTT. Inyectable en
  /// tests; por defecto el singleton compartido. Expone los flags cacheados
  /// (`lockEnabled`) y los helpers de refs (`channelLockRef`).
  final RtdbService _rtdb;

  CommunicationRemoteDatasource({
    FirebaseFirestore? firestore,
    RtdbService? rtdb,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _rtdb = rtdb ?? RtdbService.instance;

  /// associationId del tenant actual para los paths RTDB. Fallback a
  /// `'jipijapa'` para docs/sesiones legacy sin associationId (riesgo #1 del
  /// diseño): así el path RTDB nunca queda vacío y las reglas siguen
  /// validando contra el claim del JWT.
  String get _associationId {
    final aid = CurrentUserContext.instance.associationId;
    return (aid != null && aid.isNotEmpty) ? aid : 'jipijapa';
  }

  /// Ref al lock RTDB de un canal: `/channelLocks/{associationId}/{channelId}`.
  rtdb.DatabaseReference _lockRef(String channelId) =>
      _rtdb.channelLockRef(_associationId, channelId);

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

  /// Observar un canal específico en tiempo real (para estado PTT lock).
  ///
  /// Firma INTACTA `Stream<ChannelModel>` — el bloc, los usecases y la UI no
  /// cambian: siguen leyendo `channel.isLocked / currentSpeakerId /
  /// currentSpeakerName / isLockExpired`.
  ///
  /// • Flag OFF (default): camino Firestore puro, exactamente como antes.
  /// • Flag ON: stream HÍBRIDO. El doc Firestore aporta lo durable (nombre,
  ///   isActive, members…) y el nodo RTDB `/channelLocks/{aid}/{channelId}`
  ///   aporta el lock efímero. Se mapea `uid→currentSpeakerId`,
  ///   `name→currentSpeakerName`, `since→speakerLockedAt`, SOBREESCRIBIENDO
  ///   los campos de lock que pudieran haber quedado viejos en Firestore.
  Stream<ChannelModel> watchChannel(String channelId) {
    final firestoreStream = _channelsRef.doc(channelId).snapshots().map(
          (doc) => ChannelModel.fromFirestore(doc),
        );

    // Flag OFF: comportamiento actual INTACTO.
    if (!_rtdb.lockEnabled) return firestoreStream;

    // Flag ON: combinar el canal Firestore con el lock RTDB. Hand-roll del
    // merge (sin rxdart) con un StreamController para no añadir dependencias.
    return _hybridChannelStream(channelId, firestoreStream);
  }

  /// Combina el [ChannelModel] de Firestore con el lock RTDB del canal.
  ///
  /// Riesgo #3 del diseño: el nodo RTDB del lock puede NO existir todavía
  /// (nadie ha hablado), así que sembramos `null` como valor inicial para no
  /// bloquear la primera pintura del canal mientras Firestore ya emitió.
  Stream<ChannelModel> _hybridChannelStream(
    String channelId,
    Stream<ChannelModel> firestoreStream,
  ) {
    final controller = StreamController<ChannelModel>();

    ChannelModel? lastChannel;
    Map<dynamic, dynamic>? lastLock;
    bool lockSeen = false; // ¿el stream RTDB ya emitió al menos una vez?

    StreamSubscription<ChannelModel>? channelSub;
    StreamSubscription<rtdb.DatabaseEvent>? lockSub;

    void emitMerged() {
      final channel = lastChannel;
      if (channel == null) return;
      // Aún no llegó la primera emisión del lock: pintar el canal tal cual
      // (sin bloquear). En cuanto el lock emita, re-emitimos ya fusionado.
      if (!lockSeen) {
        controller.add(channel);
        return;
      }
      controller.add(_mergeLock(channel, lastLock));
    }

    channelSub = firestoreStream.listen(
      (channel) {
        lastChannel = channel;
        emitMerged();
      },
      onError: controller.addError,
    );

    lockSub = _lockRef(channelId).onValue.listen(
      (event) {
        lockSeen = true;
        final val = event.snapshot.value;
        lastLock = val is Map ? val : null;
        emitMerged();
      },
      // Si RTDB falla (reglas/red), degradamos al canal Firestore puro.
      onError: (_) {
        lockSeen = true;
        lastLock = null;
        emitMerged();
      },
    );

    controller.onCancel = () async {
      await channelSub?.cancel();
      await lockSub?.cancel();
      // Cerrar el controller (higiene): sin esto queda abierto aunque ya no
      // tenga oyentes ni fuentes.
      if (!controller.isClosed) await controller.close();
    };

    return controller.stream;
  }

  /// Proyecta el nodo de lock RTDB sobre el [ChannelModel]. Si el lock no
  /// existe, limpia los campos de speaker (estado "nadie habla"), descartando
  /// cualquier lock fantasma que hubiera quedado en Firestore (riesgo #5).
  ChannelModel _mergeLock(ChannelModel channel, Map<dynamic, dynamic>? lock) {
    // Sin nodo / sin speaker => "nadie habla". Limpia los campos de lock
    // (descarta cualquier lock fantasma de Firestore, riesgo #5).
    if (lock == null) {
      return channel.withLock(
        currentSpeakerId: null,
        currentSpeakerName: null,
        speakerLockedAt: null,
      );
    }
    final uid = lock['uid'] as String?;
    final name = lock['name'] as String?;
    final since = lock['since'];
    if (uid == null || uid.isEmpty) {
      return channel.withLock(
        currentSpeakerId: null,
        currentSpeakerName: null,
        speakerLockedAt: null,
      );
    }
    // `since` llega como ms (ServerValue.timestamp). Si aún no resolvió
    // (null/no-int), tratamos el lock como recién adquirido usando "ahora"
    // para que `isLockExpired` (timeout 35 s) NO lo expire prematuramente.
    final lockedAt = since is int
        ? DateTime.fromMillisecondsSinceEpoch(since)
        : (since is double
            ? DateTime.fromMillisecondsSinceEpoch(since.toInt())
            : DateTime.now());
    return channel.withLock(
      currentSpeakerId: uid,
      currentSpeakerName: name ?? '',
      speakerLockedAt: lockedAt,
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
    // Flag ON: camino RTDB (transacción + onDisconnect). Firma sin cambios.
    if (_rtdb.lockEnabled) {
      return _lockChannelRtdb(
        channelId: channelId,
        userId: userId,
        userName: userName,
      );
    }
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
    // Flag ON: camino RTDB. Firma sin cambios.
    if (_rtdb.lockEnabled) {
      return _unlockChannelRtdb(
        channelId: channelId,
        userId: userId,
        force: force,
      );
    }
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

  // ========== PTT LOCK — CAMINO RTDB ==========

  /// Adquiere el lock vía transacción RTDB sobre `/channelLocks/{aid}/{cid}`.
  ///
  /// Reglas de la transacción (espejo del camino Firestore):
  /// - Nodo vacío => adquirir.
  /// - Lock propio (mismo uid) => re-adquirir (refresca `since`).
  /// - Lock de otro NO expirado (≤35 s) => abortar => retorna false.
  /// - Lock de otro expirado => robar (el timeout 35 s es el cinturón extra
  ///   además de `onDisconnect`, que ya limpia si el dueño murió).
  ///
  /// Al confirmarse, registra `onDisconnect().remove()`: si el celular muere
  /// o pierde datos, el servidor RTDB libera el lock solo (beneficio clave).
  Future<bool> _lockChannelRtdb({
    required String channelId,
    required String userId,
    required String userName,
  }) async {
    final ref = _lockRef(channelId);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final result = await ref.runTransaction((current) {
      final data = current is Map ? current : null;
      if (data != null) {
        final holderId = data['uid'] as String?;
        final since = data['since'];
        final sinceMs = since is int
            ? since
            : (since is double ? since.toInt() : null);
        final expired = sinceMs == null || (nowMs - sinceMs) > 35000;

        // Otro lo tiene y NO expiró => abortar (no robar).
        if (holderId != null &&
            holderId.isNotEmpty &&
            holderId != userId &&
            !expired) {
          return rtdb.Transaction.abort();
        }
      }

      // Adquirir/re-adquirir. `since` = ServerValue.timestamp: las reglas lo
      // fuerzan con `.validate (=== now)` y el SDK lo resuelve en el server.
      return rtdb.Transaction.success(<String, Object?>{
        'uid': userId,
        'name': userName,
        'since': rtdb.ServerValue.timestamp,
      });
    });

    if (!result.committed) return false;

    // Confirmamos que el nodo final es NUESTRO (la transacción pudo confirmar
    // un robo legítimo; verificamos el uid resultante por seguridad).
    final finalVal = result.snapshot.value;
    final acquired = finalVal is Map && finalVal['uid'] == userId;

    if (acquired) {
      // Auto-liberación si el celular muere: registrar SIEMPRE tras adquirir
      // (re-registrar también cubre reconexiones, riesgo #4).
      try {
        await ref.onDisconnect().remove();
      } catch (_) {
        // No romper la adquisición si onDisconnect falla; el timeout 35 s y
        // el unlock explícito siguen siendo cinturones de seguridad.
      }
    }
    return acquired;
  }

  /// Libera el lock RTDB.
  /// - `force` (admin/operadora): elimina el nodo incondicionalmente. Las
  ///   reglas RTDB validan el rol del JWT.
  /// - Normal: transacción que solo elimina si el lock es propio o expiró.
  /// En ambos casos cancela el `onDisconnect` pendiente para no re-disparar.
  Future<void> _unlockChannelRtdb({
    required String channelId,
    required String userId,
    bool force = false,
  }) async {
    final ref = _lockRef(channelId);

    // Cancelar el onDisconnect registrado al adquirir: ya liberamos en vivo.
    try {
      await ref.onDisconnect().cancel();
    } catch (_) {
      // Inofensivo si no había onDisconnect pendiente.
    }

    if (force) {
      await ref.remove();
      return;
    }

    await ref.runTransaction((current) {
      final data = current is Map ? current : null;
      if (data == null) return rtdb.Transaction.success(null); // ya libre
      final holderId = data['uid'] as String?;
      final since = data['since'];
      final sinceMs =
          since is int ? since : (since is double ? since.toInt() : null);
      final expired = sinceMs == null ||
          (DateTime.now().millisecondsSinceEpoch - sinceMs) > 35000;

      // Solo el dueño actual (o si expiró) puede liberar.
      if (holderId == userId || expired) {
        return rtdb.Transaction.success(null); // remove
      }
      return rtdb.Transaction.abort(); // lock de otro vigente: no tocar
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
