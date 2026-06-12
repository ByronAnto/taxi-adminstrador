# Diseño — Migración de lo efímero a Realtime Database (PTT lock + presencia GPS)

Fecha: 2026-06-12
Rama de trabajo: `feat/rtdb-migration`
Instancia RTDB: `https://taxis-f0f51-default-rtdb.firebaseio.com` (us-central1, ya activa)
Autor del diseño: Arquitecto (este documento NO toca código todavía).

---

## 0. Objetivo y alcance

Mover a Realtime Database **solo lo efímero**:

1. **Lock del PTT** (hoy: transacción Firestore sobre el doc del canal — campos `currentSpeakerId` / `currentSpeakerName` / `speakerLockedAt` en `communication_remote_datasource.dart` líneas ~74-136).
2. **Presencia / ubicación GPS en vivo** (hoy: `DriverLocationService` → `DriverPresenceWriter` escribe en `drivers/{driverId}`).

Firestore conserva **todo lo durable**: canales, mensajes, drivers (doc completo), cron `markStaleDriversOffline`, mapa admin.

**Beneficio clave que DEBE quedar implementado:** `onDisconnect()` de RTDB →
- el lock del PTT se auto-libera si el celular muere / pierde datos (hoy depende del timeout de 35 s en cliente);
- la presencia se marca `online:false` en segundos cuando el socket cae.

**Invariante intocable:** la liberación del micrófono (`livekit_voice_provider`) NO se toca. Esta migración solo cambia DÓNDE vive el flag de "quién habla", no el control del mic.

**Rollback obligatorio:** flags Firestore `app_config/rtdb { lockEnabled: bool, presenceEnabled: bool }`. DEFAULT ausente/false = comportamiento actual INTACTO (camino Firestore). Mismo patrón que `app_config/duesEnforcement.mode` y `app_config/remoteLogging`. El flag se cachea al boot (un `get` + snapshot listener), NUNCA se lee por operación.

---

## 1. Esquema RTDB final

```
/channelLocks/{associationId}/{channelId}
    uid:   string        # quién tiene el lock (= currentSpeakerId)
    name:  string        # nombre visible (= currentSpeakerName)
    since: number        # ServerValue.timestamp (ms epoch). Reemplaza speakerLockedAt.

/presence/{associationId}/{uid}
    online:     bool      # true mientras el socket viva; onDisconnect → false
    lat:        number
    lng:        number
    speed:      number?   # opcional
    heading:    number?   # opcional
    accuracy:   number?   # opcional
    stationary: bool?     # opcional, espejo de stationaryMode
    status:     string    # 'libre' | 'ocupado' | ... (espejo del status del driver)
    driverId:   string    # id del doc Firestore drivers/{driverId} (para correlación)
    updatedAt:  number    # ServerValue.timestamp (ms)
```

Notas de diseño:
- **La clave del lock es `{associationId}/{channelId}`**, NO el doc del canal. Aísla por tenant (igual que las reglas Firestore) y permite reglas RTDB simples por path.
- **La clave de presencia es `{associationId}/{uid}`** (uid del usuario, NO driverId). El uid está en el JWT → la regla `.write` puede exigir `$uid === auth.uid` sin un lookup. `driverId` viaja como campo para que un consumidor pueda mapear a Firestore si hace falta.
- **`since` y `updatedAt` usan `ServerValue.timestamp`** (reloj del servidor RTDB), igual que hoy `speakerLockedAt` usa `serverTimestamp`. El cliente NO confía en su reloj local para el timeout.
- **El timeout de seguridad de 35 s se mantiene** (cliente compara `since` vs ahora), como cinturón de seguridad ADICIONAL a `onDisconnect`. `onDisconnect` cubre "socket muerto"; el timeout cubre "socket vivo pero app colgada / PTT pegado".

---

## 2. Reglas de seguridad RTDB

`database.rules.json` (nuevo archivo en la raíz, desplegado con `firebase deploy --only database`). Usa los custom claims del JWT (`associationId`, `role`) ya sincronizados por `syncUserClaims`.

```json
{
  "rules": {
    "channelLocks": {
      "$associationId": {
        ".read": "auth != null && auth.token.associationId === $associationId",
        "$channelId": {
          // Adquirir/refrescar: solo si está libre, o ya es mío, o expiró (35s),
          // o soy admin/operadora (force-unlock). El nuevo valor debe ser mío.
          ".write": "auth != null && auth.token.associationId === $associationId && (
              !data.exists() ||
              data.child('uid').val() === auth.uid ||
              (now - data.child('since').val()) > 35000 ||
              auth.token.role === 'admin' || auth.token.role === 'operadora' ||
              !newData.exists()
            )",
          ".validate": "!newData.exists() || (
              newData.hasChildren(['uid','name','since']) &&
              newData.child('uid').isString() &&
              newData.child('name').isString() &&
              newData.child('since').val() === now
            )",
          // Cuando escribo el lock, uid debe ser el mío (salvo force-unlock que borra).
          "uid": { ".validate": "!newData.exists() || newData.val() === auth.uid || auth.token.role === 'admin' || auth.token.role === 'operadora'" }
        }
      }
    },
    "presence": {
      "$associationId": {
        // El mapa admin/operadora lee toda la presencia de su tenant.
        ".read": "auth != null && auth.token.associationId === $associationId",
        "$uid": {
          // Solo el dueño escribe su propia presencia.
          ".write": "auth != null && auth.uid === $uid && auth.token.associationId === $associationId",
          ".validate": "!newData.exists() || newData.hasChildren(['online','updatedAt'])"
        }
      }
    }
  }
}
```

Decisiones de reglas:
- `now` es el reloj del servidor RTDB en ms; `since === now` fuerza que el cliente use `ServerValue.timestamp` (no puede falsificar `since`).
- Force-unlock de admin/operadora: la regla permite `.write` si el rol es admin/operadora, espejando la lógica actual de `unlockChannel(force:true)` validada por reglas Firestore.
- Liberar el lock = escribir `null` (`!newData.exists()`), permitido siempre que la condición de `.write` pase (mío, expirado, o admin).
- Presencia: nadie puede escribir la presencia de otro. El cron Firestore NO toca RTDB (sigue siendo Firestore-only); la limpieza de presencia RTDB la hace `onDisconnect`.

---

## 3. Flujo del LOCK (cuando `lockEnabled == true`)

### 3.1 Adquirir
- `runTransaction` sobre `/channelLocks/{aid}/{cid}`:
  - si `current == null` o `current.uid == miUid` o `(now - current.since) > 35000` → escribir `{uid, name, since: ServerValue.timestamp}` y devolver el commit (acquired = true).
  - si lo tiene otro y no expiró → abortar la transacción (return current) → acquired = false.
- **Inmediatamente tras adquirir**, registrar `ref.onDisconnect().remove()`. Esto hace que si el socket cae (app muere / sin datos), RTDB borre el lock en segundos → auto-liberación. ESTE es el beneficio clave.
  - Importante: el `onDisconnect` se registra DESPUÉS del commit exitoso. Si no adquirimos, no registramos onDisconnect (no es nuestro lock).

### 3.2 Liberar
- Normal (el speaker suelta el PTT): `ref.onDisconnect().cancel()` y luego `ref.remove()` con una transacción/condición de "solo si es mío o expiró".
  - Cancelar el `onDisconnect` antes de remover evita una doble-eliminación tardía si el socket cae justo después.
- Force (admin/operadora libera un PTT pegado): `ref.remove()` incondicional. La regla RTDB autoriza por rol.

### 3.3 Observar (decisión clave — ver §6)
- El bloc se suscribe al stream `onValue` de `/channelLocks/{aid}/{cid}` y mapea el snapshot a los mismos campos que hoy emite `ActiveChannelUpdated`: `isPttLocked`, `pttSpeakerId`, `pttSpeakerName`.
- El stream del **doc del canal Firestore se mantiene** para todo lo demás (nombre, isActive, memberIds, etc.). Solo se IGNORAN sus campos de lock cuando el flag está ON.

---

## 4. Flujo de PRESENCIA (cuando `presenceEnabled == true`)

**Dual-write.** Las escrituras Firestore actuales NO se quitan. Se AGREGA el camino RTDB.

- En `goOnline()`:
  - escribir `/presence/{aid}/{uid} = {online:true, status, driverId, updatedAt}`.
  - registrar `onDisconnect().update({online:false, updatedAt: ServerValue.timestamp})` (NO `.remove()` — queremos conservar la última lat/lng para el mapa, solo marcar offline).
- En cada `_pushLocation` (vía `DriverPresenceWriter`): además del `update` a Firestore, escribir lat/lng/speed/heading/accuracy/stationary/updatedAt en RTDB.
- En `goOffline()`: escribir `online:false` en RTDB y cancelar el `onDisconnect` previo (re-registrarlo si vuelve online).
- En `reset()` / logout (`hardOffline`): borrar o marcar offline el nodo RTDB.

El cron `markStaleDriversOffline` y el mapa admin **siguen leyendo Firestore** durante toda la transición. La presencia RTDB es aditiva; el mapa admin migra a leer RTDB en una fase posterior (fuera de alcance de esta migración).

---

## 5. Manejo del flag y rollback

`app_config/rtdb` (doc Firestore):
```
{ lockEnabled: false, presenceEnabled: false }   // default = ausente = false
```

- Nuevo servicio singleton **`RtdbFlags`** (en `lib/core/services/`), espejo del patrón de `remote_log_service.dart`:
  - `init()`: un `get()` inicial + `snapshots().listen()` sobre `app_config/rtdb`, cacheando `lockEnabled` / `presenceEnabled` en memoria.
  - getters síncronos `bool get lockEnabled` / `bool get presenceEnabled`, leídos por operación SIN tocar Firestore.
  - default seguro: doc ausente / error / permission-denied → ambos `false` (camino Firestore intacto). Re-suscripción tras 5 s ante error (igual que `remote_log_service`).
  - `init()` se llama en el boot junto a los otros servicios (ver `main.dart`).
- Cada punto de bifurcación pregunta `if (RtdbFlags.instance.lockEnabled)` / `presenceEnabled`. Con flag OFF, se ejecuta EXACTAMENTE el código de hoy.

---

## 6. DECISIÓN CLAVE — cómo observa la UI el lock con flag ON

**Estado actual:** `CommunicationBloc._onChannelSelected` abre `watchChannel(channelId)` (snapshot del doc Firestore) → emite `ActiveChannelUpdated(channel)` → `_onActiveChannelUpdated` deriva `isPttLocked`, `pttSpeakerId`, `pttSpeakerName` desde `channel.currentSpeakerId/Name/speakerLockedAt`. La página (`walkie_talkie_page.dart`) solo lee `state.isPttLocked / pttSpeakerId / pttSpeakerName` — NO toca el doc del canal directamente para el lock.

**Opción elegida (la más simple que no rompe la página): stream híbrido en el repositorio/datasource, transparente para el bloc y la UI.**

- Se mantiene `watchChannel(channelId)` como única fuente que el bloc consume, pero su implementación cambia según el flag:
  - **Flag OFF** → idéntico a hoy: stream del doc Firestore, con los campos de lock del doc.
  - **Flag ON** → un stream que combina:
    1. el doc Firestore del canal (nombre, isActive, memberIds, etc.), y
    2. el nodo RTDB `/channelLocks/{aid}/{cid}` (uid/name/since),
    y emite un `ChannelModel` donde `currentSpeakerId/Name/speakerLockedAt` provienen de RTDB y todo lo demás del doc Firestore.
- Se combinan con `Rx.combineLatest2` (rxdart ya disponible vía bloc) o un `StreamController` manual que re-emite cuando cualquiera de los dos cambia.

**Por qué es la más simple:**
- El bloc, los usecases y `walkie_talkie_page.dart` **no cambian**. Siguen viendo un `Stream<ChannelModel>` y leyendo `isPttLocked / pttSpeakerId / pttSpeakerName`. Toda la complejidad queda encapsulada en el datasource.
- `channel.isLockExpired` (timeout 35 s sobre `speakerLockedAt`) sigue funcionando porque mapeamos `since` (ms epoch RTDB) → `speakerLockedAt` (DateTime). El cinturón de seguridad del cliente se conserva.
- No hay que tocar el modelo `ChannelModel` ni los flags derivados del bloc.

---

## 7. LISTA EXACTA archivo-por-archivo de cambios (para implementadores)

### A. Dependencias y configuración

1. **`pubspec.yaml`** — agregar `firebase_database: ^11.x` (compatible con `firebase_core: ^3.12.1`). Correr `flutter pub get`.
2. **`lib/firebase_options.dart`** — verificar/añadir `databaseURL: 'https://taxis-f0f51-default-rtdb.firebaseio.com'` en la config Android/iOS si el SDK no lo deriva solo. (Verificar en runtime; si `FirebaseDatabase.instance` no resuelve la URL, pasarla explícita con `FirebaseDatabase.instanceFor(app:, databaseURL:)`.)
3. **`database.rules.json`** (NUEVO, raíz del repo) — las reglas de §2.
4. **`firebase.json`** — añadir bloque `"database": { "rules": "database.rules.json" }`.

### B. Flag de rollback

5. **`lib/core/services/rtdb_flags.dart`** (NUEVO) — singleton `RtdbFlags`:
   - `Future<void> init()` (get inicial + listener sobre `app_config/rtdb`), getters `bool get lockEnabled`, `bool get presenceEnabled`, default false, re-suscripción ante error. Modelo: `remote_log_service.dart`.
   - Consumido por: `CommunicationRemoteDatasource`, `DriverLocationService`, `DriverPresenceWriter`.
6. **`lib/main.dart`** — llamar `RtdbFlags.instance.init()` en el boot (cerca de donde se inicializan los otros servicios globales; tras `Firebase.initializeApp`).

### C. Lock del PTT

7. **`lib/features/communication/data/datasources/communication_remote_datasource.dart`** — cambios principales:
   - Inyectar `FirebaseDatabase` (nuevo parámetro opcional en el constructor, default `FirebaseDatabase.instance`).
   - Helper privado `DatabaseReference _lockRef(String channelId)` → `db.ref('channelLocks/$aid/$channelId')` (aid desde `CurrentUserContext.instance.associationId`).
   - **`lockChannel({channelId, userId, userName})`** — firma SIN cambios (`Future<bool>`). Implementación bifurca:
     - `if (RtdbFlags.instance.lockEnabled)` → `runTransaction` RTDB (lógica §3.1) + `onDisconnect().remove()` tras commit exitoso; devuelve acquired.
     - else → código Firestore actual intacto.
   - **`unlockChannel({channelId, userId, force})`** — firma SIN cambios. Bifurca:
     - `if (lockEnabled)` → cancelar `onDisconnect` + remove condicional (o incondicional si `force`); RTDB §3.2.
     - else → Firestore actual.
   - **`watchChannel(channelId)`** — firma SIN cambios (`Stream<ChannelModel>`). Bifurca:
     - `if (lockEnabled)` → stream híbrido (Firestore doc + RTDB lock node), mapea `since`→`speakerLockedAt`, `uid`→`currentSpeakerId`, `name`→`currentSpeakerName` (§6).
     - else → snapshot Firestore actual.
   - Consumido por: `CommunicationRepositoryImpl` (sin cambios), usecases (sin cambios), `CommunicationBloc` (sin cambios), `walkie_talkie_page.dart` (sin cambios).
   - **Riesgo a cubrir en impl:** si `associationId` es null/vacío (legacy), usar fallback `'jipijapa'` igual que las reglas Firestore, o caer a Firestore. Decidir y documentar en el código.

8. **`lib/config/injection/injection.dart`** — registrar `FirebaseDatabase` en el contenedor y pasarlo a `CommunicationRemoteDatasource` (sección `_initCommunication`). Si el datasource usa default `FirebaseDatabase.instance`, este cambio es opcional pero recomendado para testeo.

9. **`lib/features/communication/data/models/channel_model.dart`** — SIN cambios obligatorios. Se reutiliza tal cual; el datasource construye un `ChannelModel` con `currentSpeakerId/Name/speakerLockedAt` derivados de RTDB. (Opcional: un named-constructor `ChannelModel.withLock(base, uid, name, sinceMs)` para claridad — no imprescindible.)

   **NO cambian:** `communication_repository.dart`, `communication_repository_impl.dart`, `communication_usecases.dart`, `communication_bloc.dart`, `walkie_talkie_page.dart`. Toda la bifurcación vive en el datasource. (Verificar: el bloc deriva `isPttLocked = ch.isLocked && !ch.isLockExpired` — sigue válido porque mapeamos `since`→`speakerLockedAt`.)

### D. Presencia GPS (dual-write)

10. **`lib/core/services/driver_presence_writer.dart`** — agregar el dual-write RTDB:
    - Inyectar `FirebaseDatabase` (constructor, default `FirebaseDatabase.instance`).
    - Nuevo parámetro a `pushLocation(...)`: necesita el `uid` del usuario y el `associationId` para la clave `/presence/{aid}/{uid}` (hoy solo recibe `driverId`). Pasar `uid`/`associationId` desde `DriverLocationService` (que los conoce vía `CurrentUserContext` / `initialize`).
    - Dentro de `pushLocation`: tras el `update` Firestore actual, `if (RtdbFlags.instance.presenceEnabled)` → escribir el nodo RTDB con lat/lng/speed/heading/accuracy/stationary/status/online/updatedAt (`ServerValue.timestamp`).
    - Firma cambia → actualizar la llamada en `DriverLocationService._pushLocation`.
    - Consumido por: `DriverLocationService` (única llamada).

11. **`lib/core/services/driver_location_service.dart`** — cambios:
    - Guardar `_uid` y `_associationId` (ya guarda `_userId`; añadir associationId desde `initialize`).
    - **`goOnline()`** — tras poner online en Firestore, `if (presenceEnabled)` → escribir `/presence/{aid}/{uid} = {online:true, status, driverId, updatedAt}` y registrar `onDisconnect().update({online:false, updatedAt: ServerValue.timestamp})`.
    - **`goOffline()`** — `if (presenceEnabled)` → escribir `online:false` en RTDB; cancelar el `onDisconnect` previo (se re-registra en el próximo `goOnline`).
    - **`reset()` / `dispose()`** — `if (presenceEnabled)` → marcar offline / cancelar onDisconnect del nodo RTDB.
    - Pasar `uid` + `associationId` en cada llamada a `_presence.pushLocation(...)`.
    - **NO** se quita ninguna escritura Firestore. **NO** se toca la state machine STATIONARY ni el FGS ni los timers. Solo se AGREGA el camino RTDB tras los flags.

### E. Backend (Cloud Functions)

12. **`functions/index.js`** — `markStaleDriversOffline` y `_runMarkStaleDriversOffline` (líneas ~4937-5022): **SIN cambios** en esta migración. Siguen leyendo `drivers` en Firestore. La presencia RTDB con `onDisconnect` complementa (no reemplaza) al cron durante la transición. (Nota para fase futura: cuando el mapa admin lea RTDB, evaluar un cleanup RTDB; fuera de alcance.)

### F. Tests / verificación

13. **`test/`** — añadir test unitario para `DriverPresenceWriter` con un fake `FirebaseDatabase` (ya existe el patrón de inyección de Firestore). Verificar que con `presenceEnabled=false` NO escribe RTDB, y con `true` escribe ambos.
14. Verificación manual (emulador o staging): flag OFF → comportamiento idéntico; flag ON → matar la app durante PTT y confirmar que el lock desaparece de RTDB en <10 s (onDisconnect); cortar datos y confirmar presencia `online:false`.

---

## 8. Resumen del esquema RTDB (one-look)

- `/channelLocks/{associationId}/{channelId}` = `{ uid, name, since }` → reemplaza el lock Firestore. `onDisconnect().remove()` auto-libera.
- `/presence/{associationId}/{uid}` = `{ online, lat, lng, speed, heading, accuracy, stationary, status, driverId, updatedAt }` → dual-write aditivo. `onDisconnect().update({online:false})` marca offline en segundos.
- Reglas por tenant vía claims `associationId` + `role`; `since`/`updatedAt` forzados a `ServerValue.timestamp` por `.validate (=== now)`.

---

## 9. Riesgos

1. **`associationId` null/legacy.** La clave RTDB depende del tenant. Docs/usuarios legacy sin `associationId` romperían el path o caerían en reglas que niegan. Mitigación: fallback `'jipijapa'` (igual que reglas Firestore) o degradar a Firestore cuando el claim falte. DEBE decidirse en la impl del datasource.
2. **Claims no presentes al boot.** `syncUserClaims` puede no haber refrescado el JWT justo al abrir; las reglas RTDB rechazarían (`auth.token.associationId` undefined). Mitigación: el flag ON solo importa tras login con claims listos; las reglas niegan en silencio y el cliente puede degradar a Firestore. Considerar `getIdToken(true)` tras login (probablemente ya se hace para Firestore).
3. **Stream híbrido y orden de emisión.** `combineLatest` no emite hasta que AMBAS fuentes emitan al menos una vez. Si el nodo RTDB del lock no existe (canal sin nadie hablando), RTDB emite `null` — hay que sembrar ese `null` inicial para no bloquear la primera emisión (RTDB `onValue` sí emite un snapshot null inicial, verificar). Riesgo de que la UI tarde un instante extra en mostrar el primer estado del canal.
4. **`onDisconnect` y reconexiones.** Tras una reconexión de socket, los `onDisconnect` registrados se re-aplican automáticamente por el SDK, PERO si la app re-adquiere el lock hay que re-registrar `onDisconnect().remove()`. En presencia, re-registrar el `update({online:false})` en cada `goOnline`. No cancelar onDisconnect en `goOffline` deja un onDisconnect colgado inofensivo, pero conviene cancelarlo.
5. **Doble fuente de verdad transitoria (lock).** Con flag ON, Firestore conserva `currentSpeakerId` viejo y nadie lo limpia → datos stale en el doc del canal. Inofensivo mientras `watchChannel` ignore esos campos con flag ON, pero un rollback a OFF leería un lock fantasma. Mitigación: al activar el flag, limpiar (`null`) los campos de lock en los docs de canal; o que el rollback tolere el timeout de 35 s que ya expira el lock fantasma solo.
6. **Costos / cuota RTDB.** La presencia hace dual-write: duplica el volumen de escrituras durante la transición (Firestore + RTDB). RTDB cobra por GB descargado y conexiones simultáneas; con ~150 unidades por flota es bajo, pero monitorear el panel de uso al activar `presenceEnabled`.
7. **`firebase_database` y `databaseURL`.** Si `firebase_options.dart` no trae `databaseURL`, `FirebaseDatabase.instance` puede apuntar a la instancia equivocada o fallar. Usar `instanceFor(databaseURL:)` explícito reduce el riesgo.
8. **Reglas RTDB: timeout en `now - since`.** `now` y `since` deben estar ambos en ms. Si algún cliente escribe `since` en segundos, la comparación `> 35000` queda mal. La `.validate (since === now)` lo previene, pero revisar que el código use `ServerValue.timestamp` siempre.
