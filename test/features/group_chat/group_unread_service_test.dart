// test/features/group_chat/group_unread_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_jipijapa/features/group_chat/data/group_unread_service.dart';
import 'package:taxi_jipijapa/features/group_chat/data/models/group_message_model.dart';

GroupMessageModel _msg(String sender, int ms) => GroupMessageModel(
      uid: '$sender$ms',
      senderId: sender,
      senderName: sender,
      text: 't',
      createdAt: DateTime.fromMillisecondsSinceEpoch(ms),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(ms + 1),
    );

void main() {
  test('cuenta mensajes de otros posteriores a lastRead', () {
    final msgs = [_msg('otro', 100), _msg('otro', 300), _msg('yo', 400)];
    final n = GroupUnreadService.unreadCount(
        messages: msgs, lastReadMs: 200, myUid: 'yo');
    expect(n, 1); // solo el de 'otro' en 300; el mío no cuenta
  });

  test('lastRead 0 cuenta todos los de otros', () {
    final msgs = [_msg('otro', 100), _msg('otro', 300)];
    final n = GroupUnreadService.unreadCount(
        messages: msgs, lastReadMs: 0, myUid: 'yo');
    expect(n, 2);
  });
}
