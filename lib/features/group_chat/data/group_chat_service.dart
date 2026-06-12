// lib/features/group_chat/data/group_chat_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'models/group_message_model.dart';

/// Lee/escribe el grupo de chat de la asociación en
/// `associationChats/{aid}/groupMessages`. La app escribe directo; las reglas
/// Firestore restringen por `associationId` (custom claim).
class GroupChatService {
  GroupChatService._();
  static final GroupChatService instance = GroupChatService._();

  CollectionReference<Map<String, dynamic>> _col(String aid) =>
      FirebaseFirestore.instance
          .collection('associationChats')
          .doc(aid)
          .collection('groupMessages');

  /// Stream de los últimos ~200 mensajes, más nuevos primero.
  ///
  /// Filtro 24h en el QUERY (no solo confiar en el cron de purga): así ni el
  /// backlog del servidor ni la caché local de Firestore pueden mostrar
  /// mensajes vencidos. El cutoff se fija al abrir el stream, suficiente
  /// porque la pantalla recrea el stream en cada apertura.
  Stream<List<GroupMessageModel>> stream(String aid) {
    final cutoff = Timestamp.fromDate(
        DateTime.now().subtract(const Duration(hours: 24)));
    return _col(aid)
        .where('createdAt', isGreaterThan: cutoff)
        .orderBy('createdAt', descending: true)
        .limit(200)
        .snapshots()
        .map((snap) =>
            snap.docs.map(GroupMessageModel.fromFirestore).toList());
  }

  /// Envía un mensaje de texto. Resuelve nombre/unidad del usuario actual desde
  /// `users/{uid}`. No-op si el texto está vacío.
  Future<void> send(String aid, String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    String senderName = user.displayName ?? '';
    String senderVehiculo = '';
    try {
      final u = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final d = u.data();
      if (d != null) {
        final full =
            '${d['name'] ?? ''} ${d['lastName'] ?? d['lastname'] ?? ''}'.trim();
        if (full.isNotEmpty) senderName = full;
        senderVehiculo = (d['numeroVehiculo'] ?? '').toString().trim();
      }
    } catch (_) {/* usa lo que haya */}

    final now = DateTime.now();
    await _col(aid).add({
      'senderId': user.uid,
      'senderName': senderName,
      'senderVehiculo': senderVehiculo,
      'text': clean,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 24))),
    });
  }
}
