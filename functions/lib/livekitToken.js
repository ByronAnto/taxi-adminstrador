const { AccessToken } = require("livekit-server-sdk");

/**
 * Construye un JWT de acceso a LiveKit para un participante del walkie-talkie.
 *
 * Función pura: no toca Firebase ni los secrets — recibe todo por parámetro,
 * de modo que sea testeable en aislamiento (patrón `lib/` del repo).
 *
 * @param {object} p
 * @param {string} p.apiKey       API key del server LiveKit
 * @param {string} p.apiSecret    API secret del server LiveKit
 * @param {string} p.url          URL del server (wss://...) — se devuelve al cliente
 * @param {string} p.identity     Identidad del participante (uid de Firebase)
 * @param {string} p.channelName  Nombre de la sala/canal
 * @param {number} [p.ttlSeconds] Vigencia del token en segundos (default 24h)
 * @param {number} [p.now]        Epoch (s) actual — inyectable para tests
 * @returns {Promise<{url: string, token: string, expiresAt: number}>}
 */
async function buildLiveKitToken({
  apiKey,
  apiSecret,
  url,
  identity,
  channelName,
  ttlSeconds = 86400,
  now = Math.floor(Date.now() / 1000),
}) {
  const at = new AccessToken(apiKey, apiSecret, {
    identity,
    ttl: ttlSeconds,
  });
  at.addGrant({
    roomJoin: true,
    room: channelName,
    canPublish: true,
    canSubscribe: true,
  });

  // En livekit-server-sdk v2, toJwt() es async.
  const token = await at.toJwt();
  return { url, token, expiresAt: now + ttlSeconds };
}

module.exports = { buildLiveKitToken };
