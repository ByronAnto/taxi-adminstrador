const { TokenVerifier } = require('livekit-server-sdk');
const { buildLiveKitToken } = require('../lib/livekitToken');

const API_KEY = 'APItestkey';
const API_SECRET = 'secret_at_least_32_chars_long_xxxxxx';

describe('buildLiveKitToken', () => {
  test('genera un JWT verificable con identity, room y grants correctos', async () => {
    const { url, token, expiresAt } = await buildLiveKitToken({
      apiKey: API_KEY,
      apiSecret: API_SECRET,
      url: 'wss://livekit.it-services.center',
      identity: 'user-123',
      channelName: 'jipijapa-canal-1',
      ttlSeconds: 3600,
      now: 1_000_000,
    });

    expect(url).toBe('wss://livekit.it-services.center');
    expect(expiresAt).toBe(1_000_000 + 3600);
    expect(typeof token).toBe('string');

    // Round-trip real: el token debe verificar con el mismo key/secret.
    const claims = await new TokenVerifier(API_KEY, API_SECRET).verify(token);
    expect(claims.sub).toBe('user-123'); // identity → sub
    expect(claims.video.room).toBe('jipijapa-canal-1');
    expect(claims.video.roomJoin).toBe(true);
    expect(claims.video.canPublish).toBe(true);
    expect(claims.video.canSubscribe).toBe(true);
  });

  test('un token firmado con otro secret NO verifica (seguridad)', async () => {
    const { token } = await buildLiveKitToken({
      apiKey: API_KEY,
      apiSecret: API_SECRET,
      url: 'wss://x',
      identity: 'u',
      channelName: 'c',
    });
    const wrong = new TokenVerifier(API_KEY, 'otro_secret_distinto_de_32_caracteres');
    await expect(wrong.verify(token)).rejects.toBeDefined();
  });

  test('ttl por defecto es 24h', async () => {
    const { expiresAt } = await buildLiveKitToken({
      apiKey: API_KEY,
      apiSecret: API_SECRET,
      url: 'wss://x',
      identity: 'u',
      channelName: 'c',
      now: 0,
    });
    expect(expiresAt).toBe(86400);
  });
});
