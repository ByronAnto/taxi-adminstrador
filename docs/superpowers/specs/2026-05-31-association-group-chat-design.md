# Grupo de chat de la asociación (texto, efímero 24h)

**Fecha:** 2026-05-31
**Estado:** aprobado, listo para plan de implementación

## Contexto

La pantalla **Mensajes** (`chat_list_page.dart`) hoy tiene dos tabs: **Privados**
(chat 1-a-1 texto/imagen, casi sin uso) y **Radio** (`RadioHistoryView`, audios del
walkie + respaldo del bot). Se quiere un **grupo de chat de la asociación** estilo
grupo de WhatsApp: solo texto, efímero a 24h, con notificaciones push de mensajes
nuevos. El audio ya está cubierto por la tab Radio, así que el grupo es **solo texto**.

## Decisiones (cerradas con el usuario)

- **Un solo grupo por asociación** (no por canal de radio).
- **Todos los miembros activos escriben** (los mismos que usan el radio PTT). No es
  solo-anuncios.
- **Reemplaza la tab "Privados".** Mensajes queda: **Grupo | Radio**. El chat 1-a-1
  deja de tener tab de lista (ver Nota sobre chat privado).
- **Auto-borrado 24h** (igual que radio y chat privado).
- **No leídos: local por dispositivo** (sin sync en la nube).
- **Notificaciones push** a todos los miembros de la asociación menos el emisor.
- Mostrar **"Unidad #N · Nombre"** como autor (reúsa `numeroVehiculo`), consistente
  con las burbujas de audio.

Fuera de alcance (YAGNI): editar/borrar mensajes a mano, "visto por" (read receipts),
imágenes/audio en el grupo, sync de no-leídos entre dispositivos, multi-grupo.

## Arquitectura

### Datos (Firestore)

Subcolección por tenant: **`associationChats/{associationId}/groupMessages/{id}`**.

Campos del mensaje:
- `senderId: string`
- `senderName: string`
- `senderVehiculo: string` (unidad; '' si no tiene)
- `text: string`
- `createdAt: Timestamp` (serverTimestamp)
- `expiresAt: Timestamp` (createdAt + 24h; redundante con el cron pero útil para
  filtrar en cliente)

Nombre `groupMessages` (no `messages`) para que el `collectionGroup` del cron de
purga NO colisione con la colección top-level `messages` del canal de radio.

Doc padre opcional `associationChats/{associationId}` con `lastMessageText`,
`lastMessageAt`, `lastSenderName` para previews futuros (no crítico para v1).

### Permisos (firestore.rules)

Para `associationChats/{aid}/groupMessages/{id}`:
- `read`: `request.auth != null && request.auth.token.associationId == aid`.
- `create`: lo anterior + `request.resource.data.senderId == request.auth.uid` +
  `text` no vacío y acotado (p.ej. ≤ 2000 chars).
- `update`, `delete`: denegado (inmutable; borra el cron con Admin SDK).

Usa los **custom claims** ya existentes (`associationId` en el token, seteado por el
trigger `syncUserClaims`). Verificar el nombre exacto del claim en las reglas actuales.

### App (Flutter)

Nuevo módulo `lib/features/group_chat/` siguiendo el patrón de `chat`:
- `data/models/group_message_model.dart` — modelo + from/toFirestore.
- `data/datasources/group_chat_remote_datasource.dart` — `stream(associationId)`
  (query ordenada por `createdAt`, limit ~200) y `send(associationId, text)`.
- `data/repositories/` + `domain/` — interfaz fina (o, si se prefiere simplicidad,
  un servicio directo sin capa de dominio, como otros widgets del repo).
- `presentation/pages/group_chat_view.dart` — `StreamBuilder` con lista de burbujas
  + caja de texto (TextField + botón enviar). Burbujas alineadas izq/der por `isMe`,
  con "Unidad #N · Nombre", texto y hora. Reúsa estilo del chat privado.

`chat_list_page.dart`:
- Reemplazar la tab **Privados** por **Grupo** (`Tab(icon: Icons.groups, text: 'Grupo')`).
  Tabs finales: Grupo | Radio. Quitar `_buildPrivateChatsTab` del TabBarView (queda
  `GroupChatView()` y `RadioHistoryView()`).
- Al entrar a la tab Grupo, marcar leído (ver No leídos).

### No leídos (local)

Servicio `GroupUnreadService` (SharedPreferences):
- Clave `group_last_read_{associationId}` = millis de la última apertura.
- `markRead(associationId)` al abrir la tab Grupo o al recibir foco.
- `unreadCount(associationId, messages)` = nº de mensajes con `createdAt >
  lastRead && senderId != miUid`.
- Badge en la tab "Grupo" y en el ícono "Chat" del bottom nav (donde ya se arma el
  nav). El stream del grupo alimenta el conteo.

### Notificaciones push (Cloud Function)

`exports.onGroupMessageCreated = onDocumentCreated(
  "associationChats/{aid}/groupMessages/{id}", ...)`:
1. Lee el mensaje creado (`senderId`, `senderName`, `text`, `aid` del path).
2. Junta `fcmToken` de `users` donde `associationId == aid && status == 'active'`,
   excluyendo `senderId`. (Helper nuevo `_sendFcmToAssociation`, espejo de
   `_sendFcmGlobalToRoles`, batches de 500.)
3. Envía push: `title: "Grupo · <nombre asociación>"`, `body: text` (truncado ~120),
   `data: { type: 'group_chat', associationId: aid }`, android `channelId:
   'taxi_default'`, sonido/vibración.
4. Tap → abrir tab Grupo (manejar `type:'group_chat'` en `fcm_message_handler`).

Nombre de la asociación: leer `associations/{aid}.name` (cachear como en el bot).

### Purga 24h (Cloud Function)

`exports.purgeOldGroupChat = onSchedule(cron horario)`:
- `db.collectionGroup('groupMessages').where('createdAt','<=', now-24h)` en lotes de
  300, borrado por batch hasta agotar. Clon de `_runPurgeOldChannelMessages`.
- Requiere índice de `collectionGroup` en `createdAt` (Firestore lo pide; agregar a
  `firestore.indexes.json` o crear desde el link del error).

## Nota sobre el chat privado 1-a-1

Se elimina solo la **tab de lista** "Privados". Si hay otros accesos al chat 1-a-1
(p.ej. "tocar un conductor en el Mapa"), en v1 se dejan funcionando para no romper
flujos; su limpieza total queda como tarea aparte. **Verificar en implementación**
si esos accesos siguen y decidir con el usuario si se quitan también.

## Despliegue

- **Cloud Functions**: `onGroupMessageCreated` + `purgeOldGroupChat` (deploy).
- **firestore.rules** + **firestore.indexes.json** (deploy).
- **App**: build APK arm64 (`--split-per-abi --build-number=N`), instalar en los 2
  teléfonos, reemplazar APK público en Oracle (`sshoracle:/home/ubuntu/recordings/`).

## Pruebas (manual, 2 dispositivos)

- A escribe en el Grupo → B recibe push y ve el mensaje en tiempo real con
  "Unidad #N · Nombre".
- B no abre el grupo → badge muestra no leídos; al abrir, se limpia.
- El emisor NO recibe push de su propio mensaje.
- Mensaje de hace >24h desaparece (cron) — o validar el filtro de cliente por
  `expiresAt`.
- Reglas: un usuario de otra asociación NO puede leer/escribir en ese grupo.
