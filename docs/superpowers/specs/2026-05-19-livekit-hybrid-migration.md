# Migración híbrida Agora → LiveKit (self-hosted)

> **Estado:** Diseño aprobado el 2026-05-19. Implementación en curso — ver **Addendum 2026-05-29** abajo para el estado real y correcciones al plan original.

---

## Addendum 2026-05-29 — Estado real + correcciones

### ✅ Infraestructura LiveKit desplegada (Fase 2 — server)

No se usó un VPS Hetzner/DO como decía el borrador, sino una **VM Oracle Cloud** ya disponible:

- **Host:** `ubuntu@149.130.183.24` (Ubuntu 24.04 LTS, **ARM64**, 4 vCPU, 23 GB RAM). SSH alias `sshoracle`.
- **Docker** Engine 29.5.2 + Compose v5.1.4 (repo oficial).
- **LiveKit** (`livekit/livekit-server:latest`, `network_mode: host`) en `~/livekit/`. Puertos 7880/tcp, 7881/tcp, 7882/udp. `use_external_ip: true`.
- **TLS vía Caddy** (no certbot standalone como el borrador): `caddy:2` como reverse proxy, termina HTTPS en :443 → reenvía a `127.0.0.1:7880`. Cert Let's Encrypt automático y auto-renovado.
- **URL real de producción:** **`wss://livekit.it-services.center`** (puerto 443, sin `:7880`). ⚠️ El borrador asumía `wss://livekit.tu-dominio.com:7880` — **usar la URL nueva** en cliente y CF.
- **Doble firewall** abierto: iptables local de la VM (persistido) + Security List de Oracle Cloud (TCP 80, 443, 7880-7881, UDP 7882, todos con Source Port = All).
- Deploy versionado en el repo: `deploy/livekit/` (docker-compose, Caddyfile, livekit.yaml.example, README). Secrets reales NO versionados (en `~/livekit/.livekit_keys` en la VM).

### ✅ Cloud Function de token (Fase 2 — CF)

- Implementada como **`generateLiveKitToken`** (nombre real; el borrador la llamaba `getLiveKitToken`). Espejo de `generateAgoraToken`.
- Lógica pura en `functions/lib/livekitToken.js` + handler delgado en `index.js` (patrón `lib/` del repo).
- **Tests:** `functions/test/livekitToken.test.js` — round-trip real con `TokenVerifier`, rechazo con secret equivocado, TTL default. 16/16 verde.
- Dependencia: `livekit-server-sdk@^2.15.4`. Nota: en v2 **`toJwt()` es async** (await obligatorio).
- Identity del token = `request.auth.uid`. TTL = 24h (alineado con Agora, no 6h del borrador).
- Secrets pendientes de setear: `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_URL` (= `wss://livekit.it-services.center`).
- ⚠️ **Pendiente del checklist:** el borrador pide "validada con membresía". Hoy `generateAgoraToken` **no** valida membresía (solo `requireAuth`), así que `generateLiveKitToken` lo espeja. Agregar validación de membresía a ambas si se requiere antes de Go-Live.

### ⚠️ CORRECCIÓN al plan: Fase 1 NO es un find&replace mecánico

El borrador decía *"cambio mecánico, find&replace, ~30 referencias"*. **Falso.** La interfaz `VoiceProvider` es un **subconjunto estricto** del API público de `AgoraService`. La UI llama métodos Agora-específicos que **no existen en la interfaz**, así que un swap a ciegas `AgoraService.instance → VoiceProviderFactory.current` **no compila**.

Métodos usados fuera del contrato `VoiceProvider`:

| Sitio | Métodos fuera de la interfaz | Decisión |
|-------|------------------------------|----------|
| `walkie_talkie_page.dart` | `setPlaybackVolume`, `playbackVolume` (getter), `startLocalRecording`, `stopLocalRecording`, `setRemoteAudioMuted` | **Agregar a la interfaz** — son funcionalidad de audio compartida que LiveKit también necesitará |
| `walkie_talkie_page.dart` | `prewarmToken` | **Queda Agora-específico** (optimización; LiveKit puede no-op) |
| `overlay_ptt_service.dart` | `overlayActivate/Deactivate`, `quickPttStart/Stop`, `lastChannelBeforeDestroy` | **Se queda en `AgoraService.instance`** — overlay PTT Android, ya excluido del contrato por diseño |
| `main.dart`, `session_teardown_service.dart` | `dispose()` | **Agregar `dispose()` a la interfaz** (lifecycle; internamente llama a `destroyEngine()`) |

**Plan corregido de Fase 1 (completar abstracción):**

1. Extender `VoiceProvider` con: `dispose()`, `setPlaybackVolume(int)`, `int get playbackVolume`, `setRemoteAudioMuted(bool)`, `Future<bool> startLocalRecording(String)`, `stopLocalRecording()`.
2. `AgoraService` ya los implementa → 0 cambios funcionales en Agora.
3. Migrar a `VoiceProviderFactory.current`: `walkie_talkie_page.dart` (común), `main.dart` y `session_teardown_service.dart` (`dispose`).
4. **NO migrar** `overlay_ptt_service.dart` ni la ref a `prewarmToken` — quedan ligados a `AgoraService` por ahora.
5. Llamar `VoiceProviderFactory.selectFor(associationId)` tras login (hoy no se llama).

**Implicancia para Fase 3:** `LiveKitVoiceProvider` deberá implementar también los métodos recién agregados a la interfaz (recording local, volumen de playback, remote-audio-mute). El borrador de la Fase 3 abajo NO los incluye — ampliarlo.

---

## Motivación

A 25 usuarios/día (Jipijapa) Agora factura ~$140–$300/mes. A 100 usuarios (4 cooperativas) escala a ~$1500/mes, lo que **borra el margen del SaaS** ($50–$80/coop/mes de ingreso). LiveKit self-hosted en un VPS de $20–$40/mes soporta cientos de usuarios sin costo por minuto.

**Antes de migrar** ya estamos haciendo auto-disconnect en Agora (~60–70% de ahorro inmediato). LiveKit es la siguiente palanca, para cuando tengamos 3+ coops y el costo justifique la inversión de admin de servidor.

## Estrategia: híbrido, no big-bang

NO migramos toda la base al mismo tiempo. La idea es:

1. **Abstraer la capa de audio** detrás de una interfaz `VoiceProvider`. Hoy hay un solo provider (`AgoraVoiceProvider`); agregamos `LiveKitVoiceProvider`.
2. **Feature flag por cooperativa** (`associations/{id}.voiceProvider` = `"agora"` | `"livekit"`). Por defecto, `agora`. Para activar LiveKit en una coop específica: cambiar el campo en Firestore.
3. **Coop piloto** (probablemente una de prueba sin tráfico real) corre en LiveKit varias semanas. Comparamos: calidad de audio, latencia, downtime, costos reales.
4. **Si el piloto va bien**: migramos coops una por una con su consentimiento.
5. **Si falla**: cambiar el campo en Firestore vuelve la coop a Agora **sin redeploy**. Rollback en 5 segundos.

**Invariante crítico:** Agora sigue funcionando todo el tiempo durante la transición. NO se borra código de Agora hasta que el último cliente esté en LiveKit y haya pasado ≥30 días sin regresiones.

---

## Arquitectura del provider abstraction

### Interfaz Dart (cliente)

```dart
// lib/core/services/voice/voice_provider.dart
abstract class VoiceProvider {
  Future<void> initialize({String? channelHint});
  Future<void> joinChannel(String channelId);
  Future<void> leaveChannel();
  Future<void> unmuteMic();
  Future<void> muteMic();
  Future<void> destroyEngine();
  Future<void> resumeAudioReceive();
  Future<void> releaseAudioCapture();

  bool get isInChannel;
  bool get isMicPublishing;
  String? get currentChannelId;
  void Function(bool active)? onLocalVoiceActivity;
  void Function(String? err)? onError;
}
```

`AgoraService` se renombra internamente a `AgoraVoiceProvider` y implementa esta interfaz. Toda la API pública queda igual; sólo cambia la firma del singleton.

### Selector

```dart
// lib/core/services/voice/voice_provider_factory.dart
class VoiceProviderFactory {
  static VoiceProvider _current = AgoraVoiceProvider.instance;
  static VoiceProvider get current => _current;

  /// Selecciona el provider según el feature flag de la asociación.
  /// Llamar UNA VEZ tras login, cuando ya tenemos los claims del usuario.
  static Future<void> selectFor(String associationId) async {
    final doc = await FirebaseFirestore.instance
        .collection('associations').doc(associationId).get();
    final flag = (doc.data()?['voiceProvider'] as String?) ?? 'agora';
    final next = flag == 'livekit'
        ? LiveKitVoiceProvider.instance
        : AgoraVoiceProvider.instance;
    if (next == _current) return;
    await _current.destroyEngine();
    _current = next;
  }
}
```

Todo el código que hoy llama `AgoraService.instance.X()` cambia a `VoiceProviderFactory.current.X()`. Cambio mecánico (find&replace, ~30 referencias).

### Cloud Function: token genérico

Hoy `getAgoraToken` (Cloud Function HTTPS callable) devuelve un token de Agora. Agregamos `getLiveKitToken` con la misma estructura de respuesta:

```js
// functions/voice/livekit.js
exports.getLiveKitToken = onCall(async (req) => {
  const { channelId } = req.data;
  const uid = req.auth.uid;
  // Validar membresía como ya se hace para Agora
  ...
  const at = new AccessToken(LK_API_KEY, LK_API_SECRET, {
    identity: uid,
    ttl: 60 * 60 * 6, // 6h
  });
  at.addGrant({ roomJoin: true, room: channelId, canPublish: true, canSubscribe: true });
  return { token: at.toJwt(), expiresAt: Math.floor(Date.now()/1000) + 6*3600 };
});
```

El cliente, dentro de cada provider, llama a su CF correspondiente. La firma del fetch es la misma.

---

## Infraestructura: LiveKit en Docker

### Server VPS recomendado

- **Provider:** Hetzner, DigitalOcean, Vultr (cualquiera con datacenter en US o LATAM)
- **Specs mínimas:** 2 vCPU, 4 GB RAM, 80 GB SSD, 1 Gbps (≈ $20/mes)
- **Specs para 100 usuarios simultáneos:** 4 vCPU, 8 GB RAM (≈ $40/mes)
- **Sistema:** Ubuntu 24.04 LTS
- **DNS:** `livekit.tu-dominio.com` apuntando al VPS

### Step by step: levantar LiveKit con Docker

#### 1. Preparar el VPS

```bash
# Conectarse al VPS
ssh root@livekit.tu-dominio.com

# Actualizar y instalar docker + docker compose
apt update && apt upgrade -y
apt install -y docker.io docker-compose-v2 ufw certbot

# Firewall: SSH + LiveKit
ufw allow 22/tcp
ufw allow 7880/tcp  # WebSocket signaling
ufw allow 7881/tcp  # TCP fallback (TURN/TLS)
ufw allow 50000:60000/udp  # WebRTC media (UDP range)
ufw allow 80/tcp 443/tcp  # Certbot + reverse proxy si lo usas
ufw enable
```

#### 2. Certificado TLS (Let's Encrypt)

LiveKit necesita TLS para que los clientes Flutter (Android/iOS) acepten el WebSocket. Generamos el certificado **antes** de levantar el contenedor:

```bash
# Standalone mode — para esto puerto 80 debe estar libre
certbot certonly --standalone -d livekit.tu-dominio.com \
  --email brealpeaymara@gmail.com --agree-tos --non-interactive

# Los certs quedan en /etc/letsencrypt/live/livekit.tu-dominio.com/
ls /etc/letsencrypt/live/livekit.tu-dominio.com/
# fullchain.pem  privkey.pem  ...
```

Cron para renovación automática:

```bash
echo "0 3 * * * certbot renew --quiet && docker compose -f /opt/livekit/docker-compose.yml restart" \
  | crontab -
```

#### 3. Estructura de archivos

```bash
mkdir -p /opt/livekit/{config,data}
cd /opt/livekit
```

#### 4. `livekit.yaml` (configuración del server)

```yaml
# /opt/livekit/config/livekit.yaml
port: 7880
bind_addresses:
  - ""  # bind all interfaces

rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true

keys:
  # Genera con: openssl rand -hex 32
  # Esta API_KEY/SECRET la usa la Cloud Function getLiveKitToken
  APIxxxxxxxxxxx: secretxxxxxxxxxxx

logging:
  level: info
  json: false

# Habilitar grabación si querés guardar audios server-side
# (por defecto OFF — usamos grabación local Agora-style en el cliente)
egress:
  enabled: false

# Limitar bitrate de audio (opus, ~32 kbps suficiente para voz)
audio:
  active_level: 35
  min_score: 6
```

**Generar API key/secret:**

```bash
echo "API$(openssl rand -hex 8 | tr 'a-z' 'A-Z'): $(openssl rand -hex 32)"
# Copia la línea completa al campo `keys` del livekit.yaml
```

Guardá esa API key y secret en un secret manager (Bitwarden, sops, GCP Secret Manager). La vas a necesitar para configurar la Cloud Function.

#### 5. `docker-compose.yml`

```yaml
# /opt/livekit/docker-compose.yml
version: "3.9"
services:
  livekit:
    image: livekit/livekit-server:latest
    container_name: livekit
    restart: unless-stopped
    network_mode: host  # Necesario para WebRTC con UDP range
    volumes:
      - ./config/livekit.yaml:/etc/livekit.yaml:ro
      - /etc/letsencrypt/live/livekit.tu-dominio.com:/etc/livekit/tls:ro
    command:
      - --config=/etc/livekit.yaml
      - --bind=0.0.0.0
    environment:
      LIVEKIT_KEYS: "" # se lee del yaml
```

#### 6. Levantar el servidor

```bash
cd /opt/livekit
docker compose up -d
docker compose logs -f livekit
# Esperá hasta ver: "starting LiveKit server" + "listening on ..."
```

#### 7. Healthcheck

```bash
# Desde el VPS
curl -i https://livekit.tu-dominio.com:7880
# Espera HTTP 200 o 426 (upgrade required) — ambos OK, significan que el server responde

# Desde tu laptop
nc -vz livekit.tu-dominio.com 7880
```

#### 8. Configurar las Cloud Functions

```bash
# En functions/
cd ~/Repositorios/taxis/functions
npm install livekit-server-sdk

# Setear secret
firebase functions:secrets:set LK_API_KEY
firebase functions:secrets:set LK_API_SECRET
firebase functions:secrets:set LK_HOST  # "wss://livekit.tu-dominio.com:7880"

# Deploy
firebase deploy --only functions:getLiveKitToken
```

#### 9. Activar provider en una asociación piloto

En Firebase console (o vía script):

```js
db.collection('associations').doc('jipijapa-test').update({
  voiceProvider: 'livekit'
});
```

Los conductores de esa coop, al reabrir la app, cargarán el `LiveKitVoiceProvider`. El resto sigue en Agora.

---

## Cliente Flutter: LiveKit SDK

### Dependencia

```yaml
# pubspec.yaml
dependencies:
  livekit_client: ^2.4.0  # check pub.dev for latest
```

### Implementación del provider

```dart
// lib/core/services/voice/livekit_voice_provider.dart
import 'package:livekit_client/livekit_client.dart' as lk;

class LiveKitVoiceProvider implements VoiceProvider {
  LiveKitVoiceProvider._();
  static final instance = LiveKitVoiceProvider._();

  lk.Room? _room;
  String? _currentChannelId;
  bool _isMicPublishing = false;

  @override
  Future<void> joinChannel(String channelId) async {
    final token = await _fetchToken(channelId);
    _room = lk.Room();
    await _room!.connect('wss://livekit.tu-dominio.com:7880', token,
      roomOptions: const lk.RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultAudioPublishOptions: lk.AudioPublishOptions(
          dtx: true,  // Discontinuous transmission — clave para PTT
        ),
      ),
    );
    _currentChannelId = channelId;
    // Empezamos sin publicar (audience mode)
    await _room!.localParticipant?.setMicrophoneEnabled(false);
  }

  @override
  Future<void> unmuteMic() async {
    await _room?.localParticipant?.setMicrophoneEnabled(true);
    _isMicPublishing = true;
  }

  @override
  Future<void> muteMic() async {
    await _room?.localParticipant?.setMicrophoneEnabled(false);
    _isMicPublishing = false;
  }

  @override
  Future<void> leaveChannel() async {
    await _room?.disconnect();
    _room = null;
    _currentChannelId = null;
    _isMicPublishing = false;
  }

  // ... resto de métodos análogos a AgoraService
}
```

### Permisos Android (mismo que Agora)

Ya existen en `AndroidManifest.xml` — LiveKit usa los mismos:
- `RECORD_AUDIO`
- `MODIFY_AUDIO_SETTINGS`
- `BLUETOOTH_CONNECT`
- `FOREGROUND_SERVICE_MICROPHONE`

---

## Plan de migración por fases

### Fase 0 (HOY): Auto-disconnect en Agora

- Implementar inactividad → leave en `AgoraService` + UX "Conectando..."
- Ahorro inmediato: ~60–70%
- **Sin migrar nada.**

### Fase 1 (~1 semana): Abstracción de provider

- Crear `VoiceProvider` interface
- Refactorizar `AgoraService` → `AgoraVoiceProvider` implementando la interfaz
- Crear `VoiceProviderFactory.current`
- Find&replace de `AgoraService.instance` → `VoiceProviderFactory.current`
- Tests: que todo siga funcionando idéntico con Agora.
- **Sin LiveKit aún.**

### Fase 2 (~1 semana): LiveKit server + token CF

- Levantar VPS + Docker (steps 1–7 arriba)
- `getLiveKitToken` Cloud Function
- Smoke test: cliente de pruebas (CLI o web) conectándose al server

### Fase 3 (~1 semana): `LiveKitVoiceProvider` cliente

- Implementar provider Flutter
- Coop de prueba (`jipijapa-test`) con `voiceProvider: 'livekit'`
- Switch entre providers sin reinstalar APK (tomar nota: bloquea login si necesita reload — investigar)
- Pruebas head-to-head: latencia, calidad, drop rate

### Fase 4 (~2 semanas): Piloto en producción

- Una coop real (la más chica + tolerante) en LiveKit
- Monitor diario: complaints, audio quality, server CPU/RAM
- Métricas en Firestore: `voiceMetrics/{coop-id}/{date}` con bitrate medio, packet loss, reconexiones
- Si algo se rompe: cambiar `voiceProvider` a `agora` en Firestore → todos vuelven a Agora en el siguiente login

### Fase 5 (~1 mes): Rollout gradual

- 1 coop más por semana
- Por cada coop migrada, notificar al admin + monitor 48h
- Mantener Agora hasta que la última coop esté en LiveKit + 30 días sin issues

### Fase 6 (cleanup): Apagar Agora

- Cancelar plan Agora en consola
- Marcar `AgoraVoiceProvider` como deprecated (no borrar aún — necesitamos rollback path por 30 días más)
- Tras 30 días sin issues: borrar `AgoraVoiceProvider`, `getAgoraToken`, dependencia `agora_rtc_engine` del pubspec

---

## Switchear y probar los dos lados

El **objetivo de diseño** es que en un mismo APK, un conductor puede correr en Agora y otro en LiveKit. Esto significa:

**Sin redeploy de APK ni store update:**

```js
// Para probar LiveKit en tu propio user:
db.collection('associations').doc('jipijapa').update({
  voiceProvider: 'livekit'
});
// Reiniciar app → ahora corre en LiveKit
```

**Vuelta atrás instantánea (rollback):**

```js
db.collection('associations').doc('jipijapa').update({
  voiceProvider: 'agora'
});
// Reiniciar app → vuelve a Agora
```

**A/B testing per-user** (opcional, para validación más fina):

```dart
// El factory puede mirar también un campo en users/{uid}
final userOverride = await getUserVoiceOverride(uid);
if (userOverride != null) return providerFor(userOverride);
```

Útil para que Byron pueda estar en LiveKit mientras el resto de Jipijapa sigue en Agora — comparación directa en el mismo canal **NO funciona** (son redes distintas). Lo que sí funciona: dos conductores en LiveKit hablándose, dos en Agora hablándose, mismo canal lógico pero distinto provider físico.

---

## Costos comparados

| Escenario | Agora actual | Agora + auto-disconnect | LiveKit self-hosted |
|---|---|---|---|
| 1 coop, 25 usuarios | ~$300/mes | ~$60–90/mes | $20–40/mes VPS, fijo |
| 4 coops, 100 usuarios | ~$1500/mes | ~$300–450/mes | $40/mes VPS, fijo |
| 10 coops, 250 usuarios | ~$4000/mes | ~$800–1200/mes | $80/mes VPS (2 servers o más RAM) |

**Otros costos LiveKit que sí escalan:**
- Egress de datos del VPS: Hetzner/DO suelen incluir 20 TB/mes. Voz Opus a 32 kbps × 100 users × 10 h/día × 30 días = ~3.5 TB/mes. Margen amplio.
- TURN/STUN: incluido en LiveKit server (no se paga aparte).
- Backups: ~$5/mes si querés snapshots automáticos.

**Costo del esfuerzo (Byron solo):**
- Fase 1 (abstracción): ~8 h
- Fase 2 (server): ~6 h (incluyendo aprender Docker compose, TLS, DNS)
- Fase 3 (cliente): ~10 h
- Fase 4 (piloto + bugs): ~10 h
- Fase 5 (rollout): ~5 h
- **Total: ~40 h** distribuidas en 2 meses

---

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Server VPS se cae 2 AM | Status checker en CF (cron 5min) → si LiveKit no responde, auto-switch a Agora en Firestore. Conductores recuperan audio al siguiente refresh (~30s) |
| Latencia LiveKit > Agora | Piloto exhaustivo Fase 4 antes de migrar coops reales. Si latencia >200 ms en pruebas, NO migrar |
| LiveKit SDK Flutter inestable | Probar `livekit_client` antes de Fase 3. Si tiene bugs serios, replanificar (LiveKit Cloud managed como alternativa, ~$0.5/1000 min — más barato que Agora pero no $0) |
| Mic release invariant se rompe | Aplicar el mismo test plan documentado en `feedback_mic_release_invariant.md` al `LiveKitVoiceProvider`. Bloquear merge si falla |
| DDoS al VPS | Cloudflare como proxy (UDP no proxy-eable, pero firewall + fail2ban + rate limit en signaling) |
| Pérdida de API_SECRET | Backup encriptado (sops + age) en repo privado del usuario |

---

## Checklist pre-Go-Live (Fase 4)

- [ ] VPS healthcheck verde 7 días
- [ ] Certificado TLS renovado automáticamente (probar `certbot renew --dry-run`)
- [ ] Cron de renovación restart de Docker probado
- [ ] Cloud Function `generateLiveKitToken` validada con membresía (no permite tokens para users de otra coop) — ver Addendum 2026-05-29
- [ ] `LiveKitVoiceProvider` certificado en los 6 escenarios del invariante de mic release
- [ ] Rollback a Agora probado en vivo (cambiar flag → reiniciar app → audio funciona)
- [ ] Métrica de uptime LiveKit visible en dashboard admin
- [ ] Plan de comunicación al admin de la coop piloto

---

## Referencias

- LiveKit docs: https://docs.livekit.io/
- Docker image: https://hub.docker.com/r/livekit/livekit-server
- Flutter SDK: https://pub.dev/packages/livekit_client
- Memory `feedback_mic_release_invariant.md` — los 6 escenarios que el nuevo provider DEBE pasar
- Memory `project_radio_toggle_2026-05.md` — comportamiento esperado del toggle ON/OFF
