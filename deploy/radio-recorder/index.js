// ─────────────────────────────────────────────────────────────────────────
//  radio-recorder — Bot de respaldo de radio (LiveKit → Firestore).
//
//  Se une como participante OCULTO a cada sala/canal LiveKit activo, se
//  suscribe a los tracks de audio y graba CADA transmisión PTT como un clip
//  .wav (segmentado por los eventos mute/unmute = inicio/fin de PTT). Al
//  cerrar el clip lo guarda en disco (servido por Caddy) y crea un mensaje
//  de voz `type:'voz'` con `audioUrl` en la colección de mensajes del canal,
//  para que aparezca en el chat y todos puedan reproducirlo.
//
//  Retención 24h: un cron del SO borra los .wav viejos; los docs de mensaje
//  ya se purgan a 24h por la función existente.
// ─────────────────────────────────────────────────────────────────────────
const fs = require("fs");
const path = require("path");
const {
  Room,
  RoomEvent,
  AudioStream,
  TrackKind,
  dispose,
} = require("@livekit/rtc-node");
const { AccessToken, RoomServiceClient } = require("livekit-server-sdk");
const admin = require("firebase-admin");

// ── Config (env) ──
const LIVEKIT_URL = process.env.LIVEKIT_URL || "ws://127.0.0.1:7880";
const API_KEY = process.env.LIVEKIT_API_KEY;
const API_SECRET = process.env.LIVEKIT_API_SECRET;
const REC_DIR = process.env.REC_DIR || "/recordings";
const PUBLIC_BASE = (
  process.env.PUBLIC_BASE || "https://livekit.it-services.center/rec"
).replace(/\/+$/, "");
const MIN_CLIP_MS = parseInt(process.env.MIN_CLIP_MS || "1000", 10);
const POLL_MS = parseInt(process.env.POLL_MS || "10000", 10);
const MESSAGES_COLLECTION = process.env.MESSAGES_COLLECTION || "messages";
const MAX_CLIP_SECONDS = parseInt(process.env.MAX_CLIP_SECONDS || "120", 10);

if (!API_KEY || !API_SECRET) {
  console.error("[recorder] Falta LIVEKIT_API_KEY / LIVEKIT_API_SECRET");
  process.exit(1);
}

// ── Firebase (usa GOOGLE_APPLICATION_CREDENTIALS = service account) ──
admin.initializeApp({ credential: admin.credential.applicationDefault() });
const db = admin.firestore();

// El http(s) endpoint para la API de salas (mismo host que el ws).
const HTTP_URL = LIVEKIT_URL.replace(/^ws/, "http");
const svc = new RoomServiceClient(HTTP_URL, API_KEY, API_SECRET);

// ── Caches (associationId por canal, nombre por uid) ──
const channelAssoc = new Map();
const userNames = new Map();

async function getAssociationId(channelId) {
  if (channelAssoc.has(channelId)) return channelAssoc.get(channelId);
  let aid = "";
  try {
    const snap = await db.collection("channels").doc(channelId).get();
    if (snap.exists) aid = snap.data().associationId || "";
  } catch (_) { /* noop */ }
  channelAssoc.set(channelId, aid);
  return aid;
}

// Resuelve nombre + número de unidad del usuario (cacheado). El nombre cae al
// uid si no se encuentra; la unidad cae a "" (la app muestra solo el nombre).
async function getUserInfo(uid) {
  if (userNames.has(uid)) return userNames.get(uid);
  let info = { name: uid, vehiculo: "" };
  try {
    const snap = await db.collection("users").doc(uid).get();
    if (snap.exists) {
      const d = snap.data();
      const full = `${d.name || ""} ${d.lastName || d.lastname || ""}`.trim();
      if (full) info.name = full;
      info.vehiculo = String(d.numeroVehiculo || "").trim();
    }
  } catch (_) { /* noop */ }
  userNames.set(uid, info);
  return info;
}

// ── Escritura WAV (PCM16 mono/estéreo) ──
function writeWav(filePath, int16Samples, sampleRate, channels) {
  const dataLen = int16Samples.length * 2;
  const buf = Buffer.alloc(44 + dataLen);
  buf.write("RIFF", 0);
  buf.writeUInt32LE(36 + dataLen, 4);
  buf.write("WAVE", 8);
  buf.write("fmt ", 12);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20); // PCM
  buf.writeUInt16LE(channels, 22);
  buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(sampleRate * channels * 2, 28);
  buf.writeUInt16LE(channels * 2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write("data", 36);
  buf.writeUInt32LE(dataLen, 40);
  for (let i = 0; i < int16Samples.length; i++) {
    buf.writeInt16LE(int16Samples[i], 44 + i * 2);
  }
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, buf);
}

// ── Estado de salas unidas ──
const joined = new Map(); // roomName -> Room

function isAudio(pub, track) {
  const k = (pub && pub.kind) ?? (track && track.kind);
  return k === TrackKind.KIND_AUDIO;
}

async function joinRoom(roomName) {
  if (joined.has(roomName)) return;
  joined.set(roomName, "connecting"); // lock para no unirse 2 veces

  const at = new AccessToken(API_KEY, API_SECRET, {
    identity: `recorder-${roomName}`.slice(0, 60),
    name: "Grabadora",
  });
  at.addGrant({
    roomJoin: true,
    room: roomName,
    canSubscribe: true,
    canPublish: false,
    canPublishData: false,
    hidden: true, // no aparece para los demás participantes
  });
  const token = await at.toJwt();

  const room = new Room();
  // segs: trackSid -> { active, startMs, samples[], sampleRate, channels, identity }
  const segs = new Map();

  room.on(RoomEvent.TrackSubscribed, (track, pub, participant) => {
    if (!isAudio(pub, track)) return;
    if (!segs.has(pub.sid)) {
      segs.set(pub.sid, {
        active: pub.muted === false,
        startMs: Date.now(),
        samples: [],
        sampleRate: 48000,
        channels: 1,
        identity: participant.identity,
      });
    }
    startAudioLoop(track, pub, participant, roomName, segs);
  });
  room.on(RoomEvent.TrackUnmuted, (pub, participant) => {
    beginSeg(segs, pub.sid, participant.identity);
  });
  room.on(RoomEvent.TrackMuted, (pub) => {
    finalizeSeg(segs, pub.sid, roomName).catch((e) =>
      console.warn("[recorder] finalize(mute) fail", e.message),
    );
  });
  room.on(RoomEvent.TrackUnsubscribed, (track, pub) => {
    finalizeSeg(segs, pub.sid, roomName).catch(() => {});
  });
  room.on(RoomEvent.Disconnected, () => {
    console.log(`[recorder] desconectado de ${roomName}`);
    joined.delete(roomName);
  });

  try {
    await room.connect(LIVEKIT_URL, token, {
      autoSubscribe: true,
      dynacast: false,
    });
    joined.set(roomName, room);
    console.log(`[recorder] unido a sala ${roomName}`);
  } catch (e) {
    joined.delete(roomName);
    console.warn(`[recorder] no pude unirme a ${roomName}: ${e.message}`);
  }
}

function beginSeg(segs, sid, identity) {
  const prev = segs.get(sid) || {};
  segs.set(sid, {
    active: true,
    startMs: Date.now(),
    samples: [],
    sampleRate: prev.sampleRate || 48000,
    channels: prev.channels || 1,
    identity: identity || prev.identity,
  });
}

async function startAudioLoop(track, pub, participant, roomName, segs) {
  const sid = pub.sid;
  let stream;
  try {
    stream = new AudioStream(track);
  } catch (e) {
    console.warn("[recorder] AudioStream fail", sid, e.message);
    return;
  }
  try {
    for await (const frame of stream) {
      const s = segs.get(sid);
      if (!s || !s.active) continue;
      s.sampleRate = frame.sampleRate;
      s.channels = frame.channels;
      const data = frame.data; // Int16Array
      // límite de memoria: descartar frames más allá de MAX_CLIP_SECONDS
      const cap = frame.sampleRate * frame.channels * MAX_CLIP_SECONDS;
      if (s.samples.length < cap) {
        for (let i = 0; i < data.length; i++) s.samples.push(data[i]);
      }
    }
  } catch (e) {
    // el stream termina cuando el track se va; finalizamos lo pendiente
    finalizeSeg(segs, sid, roomName).catch(() => {});
  }
}

async function finalizeSeg(segs, sid, roomName) {
  const s = segs.get(sid);
  if (!s || !s.active) return;
  s.active = false;
  const durMs = Date.now() - s.startMs;
  const samples = s.samples;
  s.samples = [];
  if (durMs < MIN_CLIP_MS || samples.length === 0) return;

  const startMs = s.startMs;
  const rel = `${roomName}/${s.identity}_${startMs}.wav`;
  const full = path.join(REC_DIR, rel);
  try {
    writeWav(full, Int16Array.from(samples), s.sampleRate, s.channels);
  } catch (e) {
    console.warn("[recorder] writeWav fail", e.message);
    return;
  }
  const durationSeconds = Math.max(1, Math.round(durMs / 1000));
  const aid = await getAssociationId(roomName);
  const { name: senderName, vehiculo: senderVehiculo } = await getUserInfo(
    s.identity,
  );
  try {
    await db.collection(MESSAGES_COLLECTION).add({
      associationId: aid,
      channelId: roomName,
      senderId: s.identity,
      senderName,
      senderVehiculo,
      type: "voz",
      audioUrl: `${PUBLIC_BASE}/${rel}`,
      durationSeconds,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(
      `[recorder] clip ${rel} (${durationSeconds}s) por ${senderName}`,
    );
  } catch (e) {
    console.warn("[recorder] Firestore add fail", e.message);
  }
}

// ── Descubrimiento de salas (polling) ──
async function poll() {
  try {
    const rooms = await svc.listRooms();
    for (const r of rooms) {
      if (!joined.has(r.name)) {
        joinRoom(r.name).catch((e) =>
          console.warn("[recorder] join fail", r.name, e.message),
        );
      }
    }
  } catch (e) {
    console.warn("[recorder] listRooms fail", e.message);
  }
}

// ── Retención 24h (el host no tiene cron; lo hace el propio bot) ──
const RETENTION_MS = 24 * 60 * 60 * 1000;
function sweepOldClips() {
  let removed = 0;
  try {
    const now = Date.now();
    for (const r of fs.readdirSync(REC_DIR, { withFileTypes: true })) {
      if (!r.isDirectory()) continue;
      const dir = path.join(REC_DIR, r.name);
      for (const f of fs.readdirSync(dir)) {
        const fp = path.join(dir, f);
        try {
          if (now - fs.statSync(fp).mtimeMs > RETENTION_MS) {
            fs.unlinkSync(fp);
            removed++;
          }
        } catch (_) { /* noop */ }
      }
    }
  } catch (_) { /* noop */ }
  if (removed > 0) console.log(`[recorder] retención: borrados ${removed} clips > 24h`);
}

console.log(`[recorder] arrancando — LiveKit ${LIVEKIT_URL}, salida ${REC_DIR}`);
poll();
setInterval(poll, POLL_MS);
sweepOldClips();
setInterval(sweepOldClips, 60 * 60 * 1000); // cada hora

// ── Apagado limpio ──
async function shutdown() {
  console.log("[recorder] apagando…");
  for (const [, room] of joined) {
    if (room && room.disconnect) {
      try {
        await room.disconnect();
      } catch (_) { /* noop */ }
    }
  }
  try {
    await dispose();
  } catch (_) { /* noop */ }
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
