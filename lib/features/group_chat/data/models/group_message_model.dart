// lib/features/group_chat/data/models/group_message_model.dart
import 'package:cloud_firestore/cloud_firestore.dart';

/// Mensaje del grupo de chat de la asociación (texto, efímero 24h).
class GroupMessageModel {
  final String uid;
  final String senderId;
  final String senderName;
  final String senderVehiculo; // '' si no tiene unidad
  final String text;
  final DateTime createdAt;
  final DateTime expiresAt;

  const GroupMessageModel({
    required this.uid,
    required this.senderId,
    required this.senderName,
    this.senderVehiculo = '',
    required this.text,
    required this.createdAt,
    required this.expiresAt,
  });

  /// Constructor puro (testeable sin Firestore). Acepta `createdAtMs`/
  /// `expiresAtMs` (millis) o `Timestamp` bajo `createdAt`/`expiresAt`.
  factory GroupMessageModel.fromMap(String id, Map<String, dynamic> data) {
    DateTime ts(String tsKey, String msKey, DateTime fallback) {
      final t = data[tsKey];
      if (t is Timestamp) return t.toDate();
      final ms = data[msKey];
      if (ms is int) return DateTime.fromMillisecondsSinceEpoch(ms);
      return fallback;
    }

    final created = ts('createdAt', 'createdAtMs', DateTime.now());
    return GroupMessageModel(
      uid: id,
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? '',
      senderVehiculo: data['senderVehiculo'] ?? '',
      text: data['text'] ?? '',
      createdAt: created,
      expiresAt: ts('expiresAt', 'expiresAtMs',
          created.add(const Duration(hours: 24))),
    );
  }

  factory GroupMessageModel.fromFirestore(DocumentSnapshot doc) =>
      GroupMessageModel.fromMap(doc.id, doc.data() as Map<String, dynamic>);

  Map<String, dynamic> toFirestore() => {
        'senderId': senderId,
        'senderName': senderName,
        'senderVehiculo': senderVehiculo,
        'text': text,
        'createdAt': Timestamp.fromDate(createdAt),
        'expiresAt': Timestamp.fromDate(expiresAt),
      };

  /// "Unidad #N · Nombre" si trae unidad; si no, solo el nombre.
  String get authorLabel {
    final u = senderVehiculo.trim();
    return u.isNotEmpty ? 'Unidad #$u · $senderName' : senderName;
  }
}
