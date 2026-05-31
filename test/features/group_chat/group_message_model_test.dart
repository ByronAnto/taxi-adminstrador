// test/features/group_chat/group_message_model_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_jipijapa/features/group_chat/data/models/group_message_model.dart';

void main() {
  group('GroupMessageModel.fromMap', () {
    test('parsea campos básicos', () {
      final m = GroupMessageModel.fromMap('abc', {
        'senderId': 'u1',
        'senderName': 'Byron Realpe',
        'senderVehiculo': '12',
        'text': 'hola',
        'createdAtMs': 1000,
        'expiresAtMs': 1000 + 86400000,
      });
      expect(m.uid, 'abc');
      expect(m.senderId, 'u1');
      expect(m.text, 'hola');
      expect(m.createdAt.millisecondsSinceEpoch, 1000);
    });
  });

  group('authorLabel', () {
    test('con unidad → "Unidad #N · Nombre"', () {
      final m = _make(vehiculo: '12', name: 'Byron Realpe');
      expect(m.authorLabel, 'Unidad #12 · Byron Realpe');
    });
    test('sin unidad → solo nombre', () {
      final m = _make(vehiculo: '', name: 'Byron Realpe');
      expect(m.authorLabel, 'Byron Realpe');
    });
  });
}

GroupMessageModel _make({required String vehiculo, required String name}) =>
    GroupMessageModel(
      uid: 'x',
      senderId: 'u1',
      senderName: name,
      senderVehiculo: vehiculo,
      text: 't',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(86400000),
    );
