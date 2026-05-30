# radio-recorder — Respaldo de audio del radio (LiveKit → Firestore)

Bot server-side que graba **cada transmisión PTT** del walkie-talkie y la deja
como **mensaje de voz reproducible** en el chat del canal, con retención de 24h.
Sirve de respaldo/auditoría: si un conductor dice que no escuchó o no moduló,
queda el registro de lo que pasó por la radio.

## Cómo funciona

1. Se une como participante **oculto** (`hidden: true`, sin publicar) a cada
   sala LiveKit activa. Descubre salas con `listRooms()` cada 10s, así que se
   incorpora solo a los canales nuevos.
2. Se suscribe a los tracks de audio y **segmenta por mute/unmute** (= inicio/fin
   de PTT, porque la app pre-publica el mic y solo lo mutea/desmutea).
3. Al cerrar cada clip escribe un `.wav` en `/recordings/<channelId>/` y crea un
   doc en la colección `messages` con: `channelId`, `senderId`, `senderName`
   (resuelto de `users/{uid}`), `associationId` (de `channels/{id}`), `type:'voz'`,
   `durationSeconds`, `audioUrl` (servido por Caddy en `/rec/...`), `createdAt`.

## Multi-grupo (multi-tenant)

Cada grupo de taxistas = una asociación con su(s) canal(es) = sala(s) LiveKit.
Un solo bot atiende **todas** las salas: se une a cualquiera activa y etiqueta
cada clip con el `associationId`/`channelId` correcto, de modo que el respaldo
aparece solo en el chat de ese grupo (aislamiento por reglas Firestore). Si
algún día hubiera decenas de canales muy activos, se puede repartir el bot en
varias instancias por subconjunto de salas.

## Retención 24h

- **Archivos `.wav`**: el propio bot barre cada hora y borra los > 24h
  (el host no tiene cron).
- **Docs de mensaje**: la Cloud Function `purgeOldChannelMessages` (cron horario)
  borra los mensajes del canal > 24h. Así no quedan docs huérfanos ni players rotos.

## Despliegue (Oracle, junto a LiveKit)

Servicio en `~/livekit/docker-compose.yaml` (`radio-recorder`), red `host`.
- Secreto: `~/livekit/radio-recorder/secrets/firebase-sa.json` (service account
  `radio-recorder@…`, rol `datastore.user`) — **NO se commitea** (gitignored).
- Grabaciones: `/home/ubuntu/recordings` (montado), servidas por Caddy en
  `https://livekit.it-services.center/rec/...`.
- Env: `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `PUBLIC_BASE`,
  `GOOGLE_APPLICATION_CREDENTIALS`.

```bash
cd ~/livekit && sudo docker compose up -d --build radio-recorder
sudo docker logs -f radio-recorder
```

## Notas

- ARM64: usa `node:20-bookworm-slim` (glibc) porque `@livekit/rtc-node` trae
  binarios nativos gnu (no funciona en alpine/musl).
- Sin puertos nuevos: todo es interno (red Docker) + el 443 de Caddy.
- v1: las URLs de audio son no-adivinables pero públicas (sin token). Endurecer
  con token firmado es una mejora futura.
