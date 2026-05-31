// lib/features/group_chat/data/group_unread_service.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/group_message_model.dart';

/// No leídos del grupo, local por dispositivo (SharedPreferences).
class GroupUnreadService {
  GroupUnreadService._();
  static final GroupUnreadService instance = GroupUnreadService._();

  /// Conteo de no leídos compartido entre la tab "Grupo" (que lo recomputa)
  /// y el ícono "Chat" del bottom nav (que lo escucha con
  /// [ValueListenableBuilder]).
  final ValueNotifier<int> unreadNotifier = ValueNotifier<int>(0);

  static String _key(String aid) => 'group_last_read_$aid';

  Future<int> lastReadMs(String aid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key(aid)) ?? 0;
  }

  Future<void> markRead(String aid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key(aid), DateTime.now().millisecondsSinceEpoch);
    unreadNotifier.value = 0;
  }

  /// Mensajes de OTROS con createdAt > lastRead. Función pura (testeable).
  static int unreadCount({
    required List<GroupMessageModel> messages,
    required int lastReadMs,
    required String myUid,
  }) {
    var n = 0;
    for (final m in messages) {
      if (m.senderId == myUid) continue;
      if (m.createdAt.millisecondsSinceEpoch > lastReadMs) n++;
    }
    return n;
  }
}
