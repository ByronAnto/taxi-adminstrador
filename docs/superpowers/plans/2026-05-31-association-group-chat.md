# Grupo de chat de la asociación — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agregar un grupo de chat de texto por asociación (efímero 24h, con push de no leídos) que reemplaza la tab "Privados" en la pantalla Mensajes.

**Architecture:** Mensajes en subcolección `associationChats/{aid}/groupMessages`. La app escribe/lee directo a Firestore (stream en tiempo real). Una Cloud Function notifica por FCM a los miembros de la asociación (menos el emisor) y otra purga >24h. No leídos local por dispositivo (SharedPreferences).

**Tech Stack:** Flutter (flutter_test, bloc_test, mocktail), Firebase (Firestore, Cloud Functions v2 — jest), FCM.

**Spec:** `docs/superpowers/specs/2026-05-31-association-group-chat-design.md`

---

## File Structure

**App (Flutter)**
- Create `lib/features/group_chat/data/models/group_message_model.dart` — modelo + `fromMap`/`toFirestore` + `authorLabel`.
- Create `lib/features/group_chat/data/group_chat_service.dart` — `stream(aid)` y `send(aid, text)` contra Firestore (servicio directo, sin capa de dominio, como otros widgets del repo).
- Create `lib/features/group_chat/data/group_unread_service.dart` — `markRead`/`lastReadMs` (SharedPreferences) + `unreadCount(...)` puro.
- Create `lib/features/group_chat/presentation/group_chat_view.dart` — StreamBuilder + composer.
- Modify `lib/features/chat/presentation/pages/chat_list_page.dart` — reemplazar tab Privados por Grupo.

**Server (Cloud Functions)**
- Create `functions/lib/groupChat.js` — lógica pura: `buildNotification(...)`, `tokensForAssociation(...)`.
- Modify `functions/index.js` — trigger `onGroupMessageCreated` + cron `purgeOldGroupChat`.

**Tests**
- Create `test/features/group_chat/group_message_model_test.dart`
- Create `test/features/group_chat/group_unread_service_test.dart`
- Create `functions/test/groupChat.test.js`

**Reglas/índices**
- Modify `firestore.rules`
- Modify `firestore.indexes.json`

---

## Task 1: GroupMessageModel + tests

**Files:**
- Create: `lib/features/group_chat/data/models/group_message_model.dart`
- Test: `test/features/group_chat/group_message_model_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/group_chat/group_message_model_test.dart`
Expected: FAIL (no existe `group_message_model.dart`).

- [ ] **Step 3: Write minimal implementation**

```dart
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/group_chat/group_message_model_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/group_chat/data/models/group_message_model.dart test/features/group_chat/group_message_model_test.dart
git commit -m "feat(group-chat): modelo GroupMessageModel + tests"
```

---

## Task 2: GroupUnreadService (no leídos local) + tests

**Files:**
- Create: `lib/features/group_chat/data/group_unread_service.dart`
- Test: `test/features/group_chat/group_unread_service_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/group_chat/group_unread_service_test.dart`
Expected: FAIL (no existe el servicio).

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/features/group_chat/data/group_unread_service.dart
import 'package:shared_preferences/shared_preferences.dart';
import 'models/group_message_model.dart';

/// No leídos del grupo, local por dispositivo (SharedPreferences).
class GroupUnreadService {
  GroupUnreadService._();
  static final GroupUnreadService instance = GroupUnreadService._();

  static String _key(String aid) => 'group_last_read_$aid';

  Future<int> lastReadMs(String aid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key(aid)) ?? 0;
  }

  Future<void> markRead(String aid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key(aid), DateTime.now().millisecondsSinceEpoch);
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/group_chat/group_unread_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/group_chat/data/group_unread_service.dart test/features/group_chat/group_unread_service_test.dart
git commit -m "feat(group-chat): GroupUnreadService (no leídos local) + tests"
```

---

## Task 3: GroupChatService (stream + send a Firestore)

**Files:**
- Create: `lib/features/group_chat/data/group_chat_service.dart`

No test unitario (I/O Firestore puro; se valida en prueba manual de la Task 8).

- [ ] **Step 1: Write the implementation**

```dart
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
  Stream<List<GroupMessageModel>> stream(String aid) {
    return _col(aid)
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
```

- [ ] **Step 2: Verify it compiles**

Run: `flutter analyze lib/features/group_chat/data/group_chat_service.dart`
Expected: No issues.

- [ ] **Step 3: Commit**

```bash
git add lib/features/group_chat/data/group_chat_service.dart
git commit -m "feat(group-chat): GroupChatService (stream + send Firestore)"
```

---

## Task 4: GroupChatView (UI lista + composer)

**Files:**
- Create: `lib/features/group_chat/presentation/group_chat_view.dart`

Necesita el `associationId` del usuario actual. Verificar cómo se obtiene en el repo
(p.ej. `context.read<AuthBloc>().state` o un user provider). En este plan se asume un
getter `_associationId(context)`; **en implementación, copiar el patrón que ya usa
`radio_history_view.dart` o `home_page.dart` para leer el usuario actual.**

- [ ] **Step 1: Write the implementation**

```dart
// lib/features/group_chat/presentation/group_chat_view.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../data/group_chat_service.dart';
import '../data/group_unread_service.dart';
import '../data/models/group_message_model.dart';

/// Tab "Grupo": chat de texto de la asociación, estilo WhatsApp.
class GroupChatView extends StatefulWidget {
  /// associationId del usuario actual.
  final String associationId;

  /// uid del usuario actual (para alinear burbujas y no leídos).
  final String myUid;

  const GroupChatView({
    super.key,
    required this.associationId,
    required this.myUid,
  });

  @override
  State<GroupChatView> createState() => _GroupChatViewState();
}

class _GroupChatViewState extends State<GroupChatView> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Al abrir la tab, marcar leído.
    GroupUnreadService.instance.markRead(widget.associationId);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    _controller.clear();
    try {
      await GroupChatService.instance.send(widget.associationId, text);
      await GroupUnreadService.instance.markRead(widget.associationId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo enviar el mensaje')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: StreamBuilder<List<GroupMessageModel>>(
            stream: GroupChatService.instance.stream(widget.associationId),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final msgs = snap.data ?? const <GroupMessageModel>[];
              if (msgs.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Aún no hay mensajes en el grupo.\n'
                      'Escribe el primero — lo verán todos los miembros.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              // Marcar leído cada vez que llega data nueva mientras está abierto.
              GroupUnreadService.instance.markRead(widget.associationId);
              return ListView.builder(
                reverse: true, // más nuevos abajo
                padding: const EdgeInsets.all(12),
                itemCount: msgs.length,
                itemBuilder: (context, i) =>
                    _bubble(msgs[i], msgs[i].senderId == widget.myUid),
              );
            },
          ),
        ),
        _composer(),
      ],
    );
  }

  Widget _bubble(GroupMessageModel m, bool isMe) {
    final time = DateFormat('HH:mm').format(m.createdAt);
    final color = isMe ? AppTheme.primaryColor : AppTheme.secondaryColor;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: isMe ? color.withValues(alpha: 0.12) : AppTheme.surfaceColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isMe ? 'Tú' : m.authorLabel,
              style: TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 12, color: color),
            ),
            const SizedBox(height: 2),
            Text(m.text, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 2),
            Text(time,
                style: const TextStyle(
                    fontSize: 10, color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Mensaje al grupo...',
                  filled: true,
                  fillColor: AppTheme.surfaceColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `flutter analyze lib/features/group_chat/presentation/group_chat_view.dart`
Expected: No issues (puede advertir sobre `myUid`/`associationId` no usados si cambia algo — corregir).

- [ ] **Step 3: Commit**

```bash
git add lib/features/group_chat/presentation/group_chat_view.dart
git commit -m "feat(group-chat): GroupChatView (lista + composer)"
```

---

## Task 5: Reemplazar tab "Privados" por "Grupo" en Mensajes

**Files:**
- Modify: `lib/features/chat/presentation/pages/chat_list_page.dart`

- [ ] **Step 1: Leer el archivo y ubicar el TabBar + TabBarView**

Run: `grep -n "Privados\|_buildPrivateChatsTab\|TabBarView\|_tabs" lib/features/chat/presentation/pages/chat_list_page.dart`
Confirmar: TabBar con `Tab(... 'Privados')` y `Tab(... 'Radio')`, y TabBarView con
`_buildPrivateChatsTab()` + `const RadioHistoryView()`.

- [ ] **Step 2: Cambiar la tab y la vista**

En el `TabBar.tabs`, reemplazar:
```dart
Tab(icon: Icon(Icons.chat_bubble_outline), text: 'Privados'),
```
por:
```dart
Tab(icon: Icon(Icons.groups), text: 'Grupo'),
```

En el `TabBarView.children`, reemplazar `_buildPrivateChatsTab()` por:
```dart
GroupChatView(
  associationId: _associationId(context),
  myUid: _myUid(context),
),
```

Agregar el import al inicio:
```dart
import '../../../group_chat/presentation/group_chat_view.dart';
```

**`_associationId(context)` y `_myUid(context)`:** copiar el patrón que ya usa este
archivo o `radio_history_view.dart` para leer el usuario actual (hay un
`_currentUserId()` en `radio_history_view.dart`). Si `chat_list_page` ya tiene acceso
al usuario (AuthBloc/observer), reutilizarlo. Si no, leer de
`FirebaseAuth.instance.currentUser` (uid) y el `associationId` del claim/estado de
auth tal como lo hace `home_page.dart`.

- [ ] **Step 3: Eliminar el código muerto del chat privado de ESTA pantalla**

Borrar el método `_buildPrivateChatsTab()` y los helpers que SOLO usaba esa tab
(`_buildEmptyChats`, `_buildChatTile`, `_searchController`, `_searchQuery`,
`_otherName`, el `BlocBuilder<ChatBloc>` local). NO borrar el feature `chat` completo
ni sus otros accesos (ver Nota del spec). Tras borrar, `flutter analyze` no debe
quejarse de símbolos sin usar.

- [ ] **Step 4: Verify it compiles**

Run: `flutter analyze lib/features/chat/presentation/pages/chat_list_page.dart`
Expected: No issues.

- [ ] **Step 5: Commit**

```bash
git add lib/features/chat/presentation/pages/chat_list_page.dart
git commit -m "feat(group-chat): Mensajes = Grupo | Radio (reemplaza Privados)"
```

---

## Task 6: Badge de no leídos en la tab y el bottom nav

**Files:**
- Modify: `lib/features/chat/presentation/pages/chat_list_page.dart` (badge en la tab "Grupo")
- Modify: el widget del bottom nav que arma el ícono "Chat" (ubicar con grep)

- [ ] **Step 1: Ubicar el bottom nav "Chat"**

Run: `grep -rn "Mis pagos\|'Chat'\|\"Chat\"\|BottomNavigation\|NavigationBar" lib --include=*.dart | head`
Identificar el archivo que arma el bottom nav (Inicio/Mapa/mic/Chat/Mis pagos).

- [ ] **Step 2: Badge en la tab "Grupo"**

En `chat_list_page.dart`, envolver el contenido de la tab "Grupo" para que muestre un
`Badge` con el conteo. Usar un `StreamBuilder` sobre `GroupChatService.instance.stream`
+ `FutureBuilder`/valor de `GroupUnreadService.instance.lastReadMs` y
`GroupUnreadService.unreadCount(...)`. Como el `lastReadMs` es async, mantener el
último valor en estado local y recomputar al llegar mensajes. Ejemplo de la Tab:

```dart
Tab(
  icon: const Icon(Icons.groups),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text('Grupo'),
      if (_groupUnread > 0) ...[
        const SizedBox(width: 6),
        Badge(label: Text('$_groupUnread')),
      ],
    ],
  ),
),
```
donde `_groupUnread` se actualiza con un listener al `stream` + `lastReadMs`. Cuando
el `TabController` está en la tab Grupo (index 0), forzar `_groupUnread = 0` y
`markRead`.

- [ ] **Step 3: Badge en el ícono "Chat" del bottom nav**

En el archivo del bottom nav, envolver el ícono de "Chat" con un `Badge` que use el
mismo conteo. Exponer el conteo desde un punto común — opción simple: un
`ValueNotifier<int>` estático en `GroupUnreadService` que `GroupChatView`/la tab
actualizan, y que el bottom nav escucha con `ValueListenableBuilder`. Agregar a
`GroupUnreadService`:

```dart
final ValueNotifier<int> unreadNotifier = ValueNotifier<int>(0);
```
Actualizar `unreadNotifier.value` cada vez que se recomputa el conteo (en la tab) y
ponerlo en 0 al `markRead`.

- [ ] **Step 4: Verify**

Run: `flutter analyze lib/features/chat lib/features/group_chat`
Expected: No issues.

Prueba manual (después del build, Task 11): con dos teléfonos, B con la app en otra
tab → A escribe → el ícono "Chat" y la tab "Grupo" de B muestran el badge; al abrir
Grupo, el badge se limpia.

- [ ] **Step 5: Commit**

```bash
git add lib/features/group_chat/data/group_unread_service.dart lib/features/chat/presentation/pages/chat_list_page.dart <archivo_bottom_nav>
git commit -m "feat(group-chat): badge de no leídos en tab Grupo y bottom nav"
```

---

## Task 7: Reglas Firestore + índice collectionGroup

**Files:**
- Modify: `firestore.rules`
- Modify: `firestore.indexes.json`

- [ ] **Step 1: Agregar reglas para groupMessages**

En `firestore.rules`, dentro del `match /databases/{db}/documents`, agregar (usa el
helper `myAssociationId()` que ya existe):

```
match /associationChats/{aid}/groupMessages/{msgId} {
  allow read: if isAuthenticated() && myAssociationId() == aid;
  allow create: if isAuthenticated()
    && myAssociationId() == aid
    && request.resource.data.senderId == request.auth.uid
    && request.resource.data.text is string
    && request.resource.data.text.size() > 0
    && request.resource.data.text.size() <= 2000;
  allow update, delete: if false; // inmutable; purga por Admin SDK
}
```

- [ ] **Step 2: Agregar índice collectionGroup**

En `firestore.indexes.json`, agregar al array `indexes`:

```json
{
  "collectionGroup": "groupMessages",
  "queryScope": "COLLECTION_GROUP",
  "fields": [
    { "fieldPath": "createdAt", "order": "ASCENDING" }
  ]
}
```

- [ ] **Step 3: Validar sintaxis**

Run: `python3 -c "import json,sys; json.load(open('firestore.indexes.json')); print('indexes OK')"`
Expected: `indexes OK`.
Run: `firebase deploy --only firestore:rules --dry-run` (si `firebase` está disponible)
o revisar manualmente que las llaves del bloque cierren bien.

- [ ] **Step 4: Commit**

```bash
git add firestore.rules firestore.indexes.json
git commit -m "feat(group-chat): reglas + índice collectionGroup de groupMessages"
```

---

## Task 8: Lógica pura de notificación (functions/lib/groupChat.js) + tests

**Files:**
- Create: `functions/lib/groupChat.js`
- Test: `functions/test/groupChat.test.js`

- [ ] **Step 1: Write the failing test**

```js
// functions/test/groupChat.test.js
const { buildNotification, tokensForAssociation } = require('../lib/groupChat');

describe('buildNotification', () => {
  test('arma título con nombre de asociación y trunca el cuerpo', () => {
    const long = 'a'.repeat(200);
    const n = buildNotification({
      senderName: 'Byron', text: long, associationName: 'Jipijapa',
    });
    expect(n.title).toBe('Grupo · Jipijapa');
    expect(n.body.length).toBeLessThanOrEqual(123); // 120 + '...'
    expect(n.body.endsWith('...')).toBe(true);
  });
  test('cuerpo corto no se trunca', () => {
    const n = buildNotification({
      senderName: 'Byron', text: 'hola', associationName: 'Jipijapa',
    });
    expect(n.body).toBe('Byron: hola');
  });
});

describe('tokensForAssociation', () => {
  const users = [
    { associationId: 'a', status: 'active', fcmToken: 't1' },
    { associationId: 'a', status: 'active', fcmToken: 't2' }, // emisor
    { associationId: 'a', status: 'inactive', fcmToken: 't3' },
    { associationId: 'b', status: 'active', fcmToken: 't4' },
    { associationId: 'a', status: 'active', fcmToken: '' },
  ];
  test('solo activos de la asociación, sin el emisor ni tokens vacíos', () => {
    const toks = tokensForAssociation(users, 'a', 'u2', { 't2': 'u2' });
    expect(toks).toEqual(['t1']);
  });
});
```

Nota: `tokensForAssociation(users, aid, senderId, tokenToUid)` — como los user docs
de ejemplo no traen uid, el test pasa un mapa `token→uid` para identificar al emisor.
En `index.js` se construye con `senderId` real comparando el id del doc.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd functions && npx jest test/groupChat.test.js`
Expected: FAIL (no existe `lib/groupChat.js`).

- [ ] **Step 3: Write minimal implementation**

```js
// functions/lib/groupChat.js
'use strict';

const BODY_MAX = 120;

/// Arma {title, body} de la push del grupo. Trunca el texto a BODY_MAX.
function buildNotification({ senderName, text, associationName }) {
  const name = (associationName || '').trim() || 'Asociación';
  const sender = (senderName || '').trim() || 'Alguien';
  let body = `${sender}: ${text || ''}`;
  if (body.length > BODY_MAX) body = body.slice(0, BODY_MAX) + '...';
  return { title: `Grupo · ${name}`, body };
}

/// Filtra tokens FCM de los miembros ACTIVOS de la asociación `aid`, excluyendo
/// al emisor y tokens vacíos. `userDocs` es un array de objetos de usuario que
/// incluyen `{ associationId, status, fcmToken, uid? }`. Para identificar al
/// emisor cuando los docs no traen uid, se acepta un `tokenToUid` opcional.
function tokensForAssociation(userDocs, aid, senderId, tokenToUid = {}) {
  const out = [];
  for (const u of userDocs) {
    if (u.associationId !== aid) continue;
    if (u.status !== 'active') continue;
    const t = u.fcmToken;
    if (typeof t !== 'string' || t.length === 0) continue;
    const uid = u.uid != null ? u.uid : tokenToUid[t];
    if (uid === senderId) continue;
    out.push(t);
  }
  return out;
}

module.exports = { buildNotification, tokensForAssociation };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd functions && npx jest test/groupChat.test.js`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/groupChat.js functions/test/groupChat.test.js
git commit -m "feat(group-chat): lógica pura de notificación + tests (jest)"
```

---

## Task 9: Trigger onGroupMessageCreated (push FCM)

**Files:**
- Modify: `functions/index.js`

- [ ] **Step 1: Agregar el trigger**

Cerca de los otros `onDocumentCreated` (p.ej. junto a `onTripRequestCreated`),
agregar. Reutiliza `buildNotification`/`tokensForAssociation` de `lib/groupChat.js` y
el patrón de envío FCM de `_sendFcmGlobalToRoles`:

```js
const { buildNotification, tokensForAssociation } = require("./lib/groupChat");

// Cache simple de nombres de asociación (como en el bot recorder).
const _assocNames = new Map();
async function _getAssociationName(aid) {
  if (_assocNames.has(aid)) return _assocNames.get(aid);
  let name = aid;
  try {
    const snap = await db.collection("associations").doc(aid).get();
    if (snap.exists) name = snap.data().name || aid;
  } catch (_) { /* noop */ }
  _assocNames.set(aid, name);
  return name;
}

exports.onGroupMessageCreated = onDocumentCreated(
  { document: "associationChats/{aid}/groupMessages/{msgId}", region: "us-central1" },
  async (event) => {
    const msg = event.data?.data();
    if (!msg) return;
    const aid = event.params.aid;
    const senderId = msg.senderId;

    // Usuarios de la asociación (con uid del doc).
    const snap = await db
      .collection("users")
      .where("associationId", "==", aid)
      .where("status", "==", "active")
      .get();
    const userDocs = snap.docs.map((d) => ({ uid: d.id, ...d.data() }));
    const tokens = tokensForAssociation(userDocs, aid, senderId);
    if (tokens.length === 0) return;

    const associationName = await _getAssociationName(aid);
    const { title, body } = buildNotification({
      senderName: msg.senderName,
      text: msg.text,
      associationName,
    });

    const { getMessaging } = require("firebase-admin/messaging");
    const data = { type: "group_chat", associationId: aid };
    for (let i = 0; i < tokens.length; i += 500) {
      const chunk = tokens.slice(i, i + 500);
      await getMessaging().sendEachForMulticast({
        tokens: chunk,
        notification: { title, body },
        data,
        android: {
          priority: "high",
          notification: {
            sound: "default",
            channelId: "taxi_default",
            defaultSound: true,
            defaultVibrateTimings: true,
          },
        },
        apns: { payload: { aps: { sound: "default" } } },
      });
    }
    console.log(`[group-chat] push aid=${aid} tokens=${tokens.length}`);
  },
);
```

Verificar que `onDocumentCreated` ya esté importado (lo está, línea 2) y que `db` y
`Timestamp` estén disponibles en el scope (lo están).

- [ ] **Step 2: Lint/sintaxis**

Run: `cd functions && node --check index.js`
Expected: sin errores.
Run: `cd functions && npx jest` (los tests existentes + groupChat siguen verdes)
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add functions/index.js
git commit -m "feat(group-chat): trigger onGroupMessageCreated → push FCM a la asociación"
```

---

## Task 10: Cron purgeOldGroupChat (24h)

**Files:**
- Modify: `functions/index.js`

- [ ] **Step 1: Agregar el cron**

Junto a `purgeOldChannelMessages`, agregar (clon con `collectionGroup`):

```js
async function _runPurgeOldGroupChat() {
  const cutoff = Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);
  let deleted = 0;
  for (let i = 0; i < 50; i++) {
    const snap = await db
      .collectionGroup("groupMessages")
      .where("createdAt", "<=", cutoff)
      .limit(300)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
    deleted += snap.size;
    if (snap.size < 300) break;
  }
  return { deleted };
}

exports.purgeOldGroupChat = onSchedule(
  {
    schedule: "40 * * * *", // cada hora, minuto 40 (desfasado de los otros purges)
    timeZone: "America/Guayaquil",
    timeoutSeconds: 540,
    memory: "256MiB",
    retryCount: 1,
  },
  async () => {
    const summary = await _runPurgeOldGroupChat();
    console.log("purgeOldGroupChat:", JSON.stringify(summary));
    return summary;
  },
);
```

- [ ] **Step 2: Sintaxis**

Run: `cd functions && node --check index.js`
Expected: sin errores.

- [ ] **Step 3: Commit**

```bash
git add functions/index.js
git commit -m "feat(group-chat): cron purgeOldGroupChat (borra mensajes >24h)"
```

---

## Task 11: Manejar el tap de la notificación (abrir tab Grupo)

**Files:**
- Modify: `lib/core/services/fcm_message_handler.dart`

- [ ] **Step 1: Ubicar el manejo de `data['type']`**

Run: `grep -n "type\|data\[\|navigat\|onMessageOpenedApp\|routeFor" lib/core/services/fcm_message_handler.dart | head`
Identificar dónde se enruta según `message.data['type']`.

- [ ] **Step 2: Agregar el caso group_chat**

Agregar una rama: si `data['type'] == 'group_chat'`, navegar a la pantalla Mensajes
con la tab "Grupo" seleccionada (índice 0 tras el reemplazo). Usar el mismo mecanismo
de navegación que los otros `type` ya manejados en este archivo. Si la app abre
Mensajes con un `initialIndex`, pasar 0; si no, simplemente abrir `ChatListPage`.

- [ ] **Step 3: Verify**

Run: `flutter analyze lib/core/services/fcm_message_handler.dart`
Expected: No issues.

- [ ] **Step 4: Commit**

```bash
git add lib/core/services/fcm_message_handler.dart
git commit -m "feat(group-chat): abrir tab Grupo al tocar la push"
```

---

## Task 12: Deploy + build + prueba manual

**Files:** ninguno (despliegue).

- [ ] **Step 1: Tests completos**

Run: `flutter test` → todos verdes.
Run: `cd functions && npx jest` → todos verdes.
Run: `flutter analyze` → sin issues nuevos.

- [ ] **Step 2: Deploy Cloud Functions + reglas + índice**

```bash
firebase deploy --only functions:onGroupMessageCreated,functions:purgeOldGroupChat,firestore:rules,firestore:indexes
```
Esperar a que el índice `groupMessages` termine de construirse (consola Firebase).

- [ ] **Step 3: Build APK arm64 + instalar + reemplazar APK público**

```bash
cd ~/Repositorios/taxis
flutter build apk --release --split-per-abi --build-number=4115
APK=build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
for d in 3B101FDJG000FN 2e8a7498; do adb -s $d install -r "$APK"; done
scp "$APK" sshoracle:/home/ubuntu/recordings/taxi-jipijapa.apk
```
(versionCode resultante = 4115 + 2000 = 6115, ascendente sobre 6114.)

- [ ] **Step 4: Prueba manual (2 dispositivos, misma asociación)**

1. A abre Mensajes → tab **Grupo** → escribe "hola grupo".
2. B (otra app/teléfono) recibe **push** "Grupo · <asociación>" y ve el mensaje en
   tiempo real con "Unidad #N · Nombre".
3. El emisor A **no** recibe push de su propio mensaje.
4. B en otra tab → badge de no leídos en "Grupo" y en el ícono "Chat"; al abrir Grupo
   se limpia.
5. Tocar la push abre la tab Grupo.
6. (Reglas) Un usuario de otra asociación no ve estos mensajes.

- [ ] **Step 5: Commit final / cierre**

Nada que commitear si todo lo anterior ya está. Confirmar el estado y entregar el link
de descarga.

---

## Notas de implementación

- **Usuario actual / associationId:** varias tasks necesitan `uid` y `associationId`
  del usuario. Copiar el patrón existente (`radio_history_view.dart._currentUserId()`,
  `home_page.dart`, o el AuthBloc). No inventar un mecanismo nuevo.
- **Chat privado 1-a-1:** este plan solo quita su tab de lista. Si el usuario quiere
  eliminar también sus otros accesos (Mapa/perfil) y el feature `chat`, es una tarea
  aparte (confirmar con el usuario).
