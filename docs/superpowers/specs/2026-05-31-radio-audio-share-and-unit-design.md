# Audios del radio: compartir + número de unidad

**Fecha:** 2026-05-31
**Estado:** aprobado, listo para implementar

## Contexto

Tras migrar de Agora a LiveKit, el bot server-side `radio-recorder` (Oracle, junto
a LiveKit) graba cada transmisión PTT y la publica como mensaje `type:'voz'` en la
colección `messages` de Firestore, con `senderName`, `audioUrl` (`.wav` servido por
Caddy en `/rec/...`), `durationSeconds`, retención 24h. En la app, esos audios se
muestran en la pestaña **Radio** (`RadioHistoryView`) mediante la burbuja
`ChannelVoiceBubble`.

Hoy esa burbuja solo permite reproducir: no se puede **compartir** el audio (ej. a
WhatsApp) ni muestra el **número de unidad** (`numeroVehiculo`) de quien habló.

## Objetivo

1. **Compartir** el audio de la burbuja del servidor a apps externas (WhatsApp, etc.).
2. Mostrar el **número de unidad** junto al nombre: formato `Unidad #12 · Byron Realpe`.

Fuera de alcance: tocar el historial local (`AudioHistoryTile`), botón de borrar
manual (no existe en la burbuja del servidor; los audios solo se auto-eliminan a 24h),
y audios viejos (los grabados antes del cambio muestran solo nombre).

## Diseño

### 1. Compartir (solo app)

`ChannelVoiceBubble` reproduce desde una URL remota (`UrlSource`). `share_plus` no
comparte una URL remota como archivo, así que:

- Agregar un botón 🔗 (`Icons.share`) en la fila de controles de la burbuja.
- Al tocarlo: descargar el `.wav` de `message.audioUrl` a un archivo temporal
  (`getTemporaryDirectory()` + `http.get`), luego `Share.shareXFiles([XFile(tmp,
  mimeType: 'audio/wav', name: 'audio_<id>.wav')], text: caption)`.
- `caption`: `Audio de <unidadYNombre> — <dd MMM HH:mm>`.
- Estado de carga: mientras descarga, el botón muestra un spinner pequeño y se
  deshabilita (evita doble tap / descargas duplicadas).
- Errores (sin señal / 404): SnackBar "No se pudo descargar el audio para compartir".
  No usar `print`.

### 2. Número de unidad

**Origen del dato:** `users/{uid}.numeroVehiculo` (string; ya existe, se ve como
"Unidad #X" en otras pantallas).

**Server — `deploy/radio-recorder/index.js`:**
- Donde hoy resuelve `senderName` vía `getUserName(uid)` (lee `users/{uid}`, cacheado),
  resolver también `numeroVehiculo`. Refactor: `getUserInfo(uid)` → `{ name, vehiculo }`
  con un solo `get()` y un cache `Map`.
- Al crear el doc del mensaje, añadir `senderVehiculo: <numeroVehiculo|''>`.
- Requiere **rebuild + redeploy** del contenedor `radio-recorder` en Oracle.

**App — `channel_model.dart` (`MessageModel`):**
- Nuevo campo `final String? senderVehiculo;`.
- `fromFirestore`: `senderVehiculo: data['senderVehiculo'] as String?`.
- `toFirestore`: incluirlo (la app no escribe estos docs, pero por consistencia).

**App — `channel_voice_bubble.dart`:**
- Construir la etiqueta del hablante: si `senderVehiculo` no es vacío →
  `Unidad #<senderVehiculo> · <senderName>`; si no → `<senderName>`. Para `isMe`
  mantener `Tú` (sin unidad, igual que hoy) — o `Tú` a secas.
- Esa misma etiqueta alimenta el `caption` de compartir.

### Retención (sin cambios)

Confirmado en código: `.wav` barridos por el bot >24h y docs borrados por la Cloud
Function `purgeOldChannelMessages` >24h. El nuevo campo `senderVehiculo` no afecta esto.

## Archivos

| Archivo | Cambio |
|---|---|
| `deploy/radio-recorder/index.js` | Resolver y guardar `senderVehiculo` (redeploy) |
| `lib/features/communication/data/models/channel_model.dart` | Campo `senderVehiculo` en `MessageModel` |
| `lib/features/communication/presentation/widgets/channel_voice_bubble.dart` | Botón compartir (descarga+share) + etiqueta con unidad |

## Pruebas

- Manual en 2 dispositivos: modular en un canal → aparece la burbuja con
  `Unidad #N · Nombre` → compartir → llega el `.wav` a WhatsApp.
- Audio sin unidad (usuario sin `numeroVehiculo`) → muestra solo el nombre, sin romper.
- Sin señal al compartir → SnackBar de error, sin crash.
