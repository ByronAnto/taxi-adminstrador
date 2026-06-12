<task-notification>
<task-id>a7178a40c3f653f7c</task-id>
<tool-use-id>toolu_01QUD91V1yq9aiwhkKDsC5i6</tool-use-id>
<output-file>/tmp/claude-1000/-home-byron-realpe-Repositorios-taxis/991e6752-7cca-4218-97a0-e86b88f61a36/tasks/a7178a40c3f653f7c.output</output-file>
<status>completed</status>
<summary>Agent "SRE cost audit of Cloud Functions" completed</summary>
<result>I have everything needed. Here's the audit report.

---

# Auditoría de costo — Cloud Functions v2 (taxis-f0f51)

Auditoría de `/home/byron-realpe/Repositorios/taxis/functions/index.js` (5116 líneas, ~50 funciones), `functions/lib/*.js`, `functions/package.json` y `firebase.json`. **No modifiqué nada**: todo lo de abajo es propuesto.

## 1. Resumen ejecutivo — top optimizaciones por ahorro a escala

Ordenadas por impacto real en la factura (lecturas Firestore e instancias/duración, que es lo que escala con # conductores × # asociaciones):

1. **Tres crones nocturnos hacen el MISMO trabajo de morosidad con N+1 por conductor** — `enforcePayments` (`index.js:2437`), `checkSubscriptions` (`index.js:2944`) y `checkDriverDues` (`index.js:3754`) recorren todas las asociaciones y todos los usuarios, y al menos dos hacen 1-2 queries Firestore **por conductor**. A 50 asociaciones × 200 conductores = 10 000 conductores → ~20 000-30 000 lecturas/noche **× 3 funciones redundantes**. Es el mayor driver de costo a escala. **Consolidar en una sola función** y eliminar el N+1 (ver §4).
2. **`enforcePayments` Pase B: query `_lastValidatedPayment` + `_hasActivePermit` por cada conductor** (`index.js:2515`, `2521`). Esto es O(conductores) queries serializadas. Reemplazar por lectura en lote por asociación o materializar `nextDueAt` en el doc del user.
3. **Audiencias de push leen el doc COMPLETO de cada usuario activo** (`_sendFcmToRoles` `index.js:2664`, `_sendFcmGlobalToRoles` `index.js:2703`, `onGroupMessageCreated` `index.js:2646`, dispatch `index.js:2341`). Solo se usa `fcmToken` (+`role`). Añadir `.select("fcmToken","role")` recorta egress y memoria sin cambiar # lecturas. `_sendFcmGlobalToRoles` además **lee TODOS los usuarios de la plataforma** en cada evento de Quito.
4. **Crones de alta frecuencia que invocan aunque no haya trabajo**: `markStaleDriversOffline` cada 2 min = **720 inv/día**; `dispatchScheduledNotifications` cada 5 min = **288 inv/día**. Hoy gratis, pero son invocaciones + arranque garantizado. Bajar `markStaleDriversOffline` a cada 3-5 min y considerar mover el "stale" a TTL/lógica cliente.
5. **`concurrency` sin configurar en ninguna función** (`grep` confirma 0 ocurrencias). Las callable/HTTP I/O-bound (token Agora/LiveKit, reportPayment, etc.) se beneficiarían de `concurrency` alto para reducir # instancias bajo carga concurrente.

Honestamente, **la init global ya está bien** (singletons a nivel módulo, §3) y las memorias configuradas son en general razonables. El problema real es **el patrón N+1 de los crones de morosidad** y la **redundancia de 3 crones**, no microoptimizaciones.

---

## 2. Hallazgos por criterio

### Criterio 1 — Cold start, caché e init global

**Lo que YA está bien (no tocar):**
- `initializeApp()` + `const db = getFirestore()` están a nivel módulo (`index.js:20-21`) y se reutilizan entre invocaciones del contenedor caliente. Correcto.
- `getAuth()`, `getStorage()` se llaman on-demand pero devuelven el singleton del SDK; no se re-inicializa nada caro. Aceptable.
- Secrets vía `defineSecret(...)` (`index.js:34-55`): Firebase v2 inyecta el secret como **variable de entorno al arrancar el contenedor**, no por invocación. `GEMINI_API_KEY.value()` lee de env, no llama a Secret Manager por request. Correcto y barato.

**Hallazgos:**

- **Lazy `require("firebase-admin/messaging")` repetido** en `_sendMulticastAndPrune` (`index.js:2589`) y `_sendFcmToUid` (`index.js:2625`). Recomendación **matizada**: `firebase-admin` ya está cargado completo en el módulo (se usa `getFirestore`, `getAuth`, `getStorage` al tope), así que el sub-módulo `messaging` ya está en el árbol de dependencias resuelto — el `require` lazy aquí **no ahorra cold-start real** (no es un paquete pesado independiente), solo añade un lookup de cache de módulos por llamada. Es trivial pero conviene **hoistearlo a nivel módulo** para limpieza, junto a los demás requires de firebase-admin:
  ```js
  // index.js, cabecera (junto a línea 7)
  const { getMessaging } = require("firebase-admin/messaging");
  ```
  y borrar las dos líneas `const { getMessaging } = require(...)` internas. Impacto en factura: ~nulo, pero correcto.

- **`require("nodemailer")` lazy** dentro de `sendPasswordResetEmail` (`index.js:3899`): **DEJAR lazy**. nodemailer SÍ es un paquete relativamente pesado y solo lo usa esta función. Hoistearlo penalizaría el cold-start de las ~49 funciones que NO envían email. Correcto como está.

- **`require("./lib/dueDate")` lazy** dentro de `enforcePayments` (`index.js:2494`): es un módulo local minúsculo. Indiferente; puede hoistearse o quedarse. No mueve la aguja.

- **Cachés a nivel módulo:**
  - `_assocNames = new Map()` (`index.js:4625`): cachea nombre de asociación en `onGroupMessageCreated`. **Riesgo de crecer sin cota** en instancias de larga vida (1 entry por asociación). A escala "exponencial de asociaciones" podría acumular miles de entries en una instancia caliente. Es texto corto, riesgo bajo, pero conviene una cota:
    ```js
    const _assocNames = new Map();
    const _ASSOC_NAMES_MAX = 500;
    async function _getAssociationName(aid) {
      if (_assocNames.has(aid)) {
        const v = _assocNames.get(aid);      // refresca LRU
        _assocNames.delete(aid); _assocNames.set(aid, v);
        return v;
      }
      let name = aid;
      try {
        const snap = await db.collection("associations").doc(aid)
          .select("name").get();           // §4: solo el campo name
        if (snap.exists) name = snap.data().name || aid;
      } catch (_) {}
      if (_assocNames.size &gt;= _ASSOC_NAMES_MAX) {
        _assocNames.delete(_assocNames.keys().next().value); // evict más viejo
      }
      _assocNames.set(aid, name);
      return name;
    }
    ```
    Además **invalidación**: el nombre se cachea para siempre; si una asociación se renombra, las instancias calientes sirven el viejo. Aceptable para un título de push.
  - `userCache = new Map()` (`index.js:3991`): está **dentro** del handler `backfillPayments`, vive solo durante esa invocación. Sin riesgo de leak. Correcto.

### Criterio 2 — Memoria y CPU

Memorias declaradas (resto = default **256MiB**):

| Función | memory declarada |
|---|---|
| `purgeExpiredProofs` (`:2259`) | 512MiB |
| `enforcePayments` (`:2441`) | 512MiB |
| `checkSubscriptions`, `dispatchScheduledNotifications`, `purgeExpiredNotifications`, `purgeOldChatMessages`, `purgeOldChannelMessages`, `purgeOldGroupChat`, `checkDriverDues`, `markStaleDriversOffline`, `computeDriverPercentiles`, `fetchQuitoEvents` | 256MiB |
| Todas las `onCall`/triggers sin `memory:` | 256MiB (default) |

**Hallazgos:**
- Todos los crones son **I/O-bound** (esperan Firestore/FCM/HTTP), no CPU-bound. En I/O-bound bajar memoria **no daña la latencia** porque el cuello es la red, y baja GiB-s. Las que están en **512MiB sin justificación CPU** (`enforcePayments`, `purgeExpiredProofs`) podrían bajar a 256MiB salvo que se haya visto OOM por traer colecciones grandes a memoria (ver siguiente punto). Recomendación: dejar 512MiB **solo si** el snapshot de usuarios cabe ajustado; con `.select()` (§4) baja el footprint y se puede probar 256MiB.
- **Procesamiento pesado en memoria — traer colecciones enteras con `.get()`:**
  - `_runComputeDriverPercentiles` (`index.js:4425`): `db.collection("drivers").get()` trae **TODOS los drivers de la plataforma completos** a memoria para ordenar por `totalTrips`. A escala = decenas de miles de docs completos en RAM. **Doble problema**: (a) memoria, (b) `batch.commit()` por asociación con **&gt;500 escrituras revienta** (límite Firestore 500/batch — `index.js:4444-4460` no trocea). Propuesta:
    ```js
    async function _runComputeDriverPercentiles() {
      // solo los campos necesarios → menos egress y RAM
      const snap = await db.collection("drivers")
        .select("totalTrips", "associationId", "archivedAt", "deletedAt")
        .get();
      const byAssoc = {};
      for (const d of snap.docs) {
        const data = d.data();
        if (data.archivedAt || data.deletedAt) continue;
        const aid = data.associationId;
        if (!aid) continue;
        (byAssoc[aid] ||= []).push({ ref: d.ref, trips: Number(data.totalTrips) || 0 });
      }
      let writes = 0;
      for (const aid of Object.keys(byAssoc)) {
        const list = byAssoc[aid];
        list.sort((a, b) =&gt; b.trips - a.trips);
        const total = list.length;
        let batch = db.batch(), n = 0;
        for (let i = 0; i &lt; list.length; i++) {
          const rank = i + 1;
          batch.set(list[i].ref, {
            tripsRank: rank,
            tripsTotalDrivers: total,
            tripsTopPercent: Math.max(1, Math.ceil((rank / total) * 100)),
            percentileUpdatedAt: FieldValue.serverTimestamp(),
          }, { merge: true });
          writes++;
          if (++n === 450) { await batch.commit(); batch = db.batch(); n = 0; } // trocear
        }
        if (n &gt; 0) await batch.commit();
      }
      return { ok: true, associations: Object.keys(byAssoc).length, writes };
    }
    ```
    El `.select()` aquí reduce egress dramáticamente (un driver doc puede traer posición, historial, etc.) y el troceo evita un fallo a escala. **Bug latente + ahorro**, prioritario.

### Criterio 3 — Arquitectura de escalado

- **`concurrency`: ningún sitio lo setea.** En v2, callable/HTTP por defecto = 80; los **event-driven (Firestore/Schedule) = 1 forzado** (no se puede subir en triggers Firestore). Así que:
  - Para las `onCall` I/O-bound (`generateAgoraToken` `:84`, `generateLiveKitToken` `:153`, `reportPayment` `:1060`, etc.) el default 80 ya está bien. **No hace falta tocar** salvo que quieras topar memoria.
  - **No** subas concurrency en funciones con caché mutable a nivel módulo si compartieran estado peligroso — aquí `_assocNames`/`userCache` no son race-sensibles, pero los triggers Firestore ya van a concurrency 1 de todos modos.
- **`maxInstances`: NINGUNA función tiene tope.** Esto es el **riesgo de fuga de costo** más claro ante un pico o un bucle de escrituras. Un trigger como `onTripFinalized`/`onTripAssignmentChanged`/`onGroupMessageCreated` sin `maxInstances` puede escalar sin límite si entra una avalancha (o un loop accidental de escrituras). **Propongo topes** (tabla §4). Lo más seguro y de mayor ROI: poner `maxInstances` razonable en todos los triggers y callables.
- **`minInstances`: ninguna &gt;0.** Correcto, cero costo idle. No tocar (no hay requisito de latencia crítica que lo justifique).
- **Operaciones serializadas (await tras await) que alargan duración:**
  - `enforcePayments` Pase B (`index.js:2510-2536`): por cada conductor hace `await _lastValidatedPayment` → `await _hasActivePermit` → `await update` → `await _sendFcmToUid`, todo **en serie dentro de un `for`**. A escala la duración crece linealmente y se acerca al `timeoutSeconds: 540`. Paralelizar por lotes con `Promise.all` sobre chunks (p.ej. 50) reduce wall-time y por tanto GiB-s:
    ```js
    const CHUNK = 50;
    for (let i = 0; i &lt; usersSnap.docs.length; i += CHUNK) {
      const slice = usersSnap.docs.slice(i, i + CHUNK);
      await Promise.all(slice.map(async (uDoc) =&gt; {
        const u = uDoc.data();
        if (!["conductor","admin"].includes(u.role) || !u.approvedAt) return;
        const last = await _lastValidatedPayment(uDoc.id, aDoc.id);
        const nextDue = computeNextDueDate(
          { approvedAt: u.approvedAt.toDate ? u.approvedAt.toDate() : u.approvedAt }, cfg, last);
        if (nextDue.getTime() &gt; now.toMillis()) return;
        if (await _hasActivePermit(uDoc.id, nextDue)) return;
        await uDoc.ref.update({ status:"paymentBlocked", blockedAt:now, blockReason:"cuota_vencida", updatedAt:now });
        blockedCount++;
        await _sendFcmToUid(uDoc.id, { title:"Tu cuenta fue bloqueada", body:"Sube tu comprobante de pago para reactivarte." }).catch(()=&gt;{});
      }));
    }
    ```
    Mejor aún: eliminar el `_lastValidatedPayment` por-usuario materializando `nextDueAt` en el doc del user (lo escribe `validatePayment`), y entonces el cron es una sola query `where("nextDueAt","&lt;=",now)` — pasa de O(usuarios) lecturas a O(morosos). Ese es el cambio de fondo que de verdad aplana la factura, pero requiere prueba (§5).
  - `checkSubscriptions` (`index.js:2803-2885`) y `checkDriverDues` (`index.js:3676-3748`): mismo patrón de `for` serializado con `await update` por usuario. Mismo tratamiento (Promise.all por chunks). `checkDriverDues` además hace una **query de payments por conductor** (`index.js:3706`) — N+1 igual que enforcePayments.
  - **Redundancia estructural**: `enforcePayments`, `checkSubscriptions` y `checkDriverDues` se solapan (los tres bloquean/reactivan por morosidad, a las 00:00/00:05/00:30). Consolidar en **un solo cron** elimina 2/3 del costo de este bloque. Es el cambio de mayor impacto; requiere validar que la lógica de gracia se unifica bien (§5).

### Criterio 4 — Egress / lecturas Firestore

- **`.select()` ausente en todas las queries de audiencia de push.** La lectura se cobra igual por doc, pero `.select()` recorta bytes de egress y RAM (los user docs traen muchos campos). Aplicar en:
  - `_sendFcmToRoles` (`index.js:2664`): `.where(...).select("fcmToken","role").get()`
  - `_sendFcmGlobalToRoles` (`index.js:2703`): `.select("fcmToken","role")`
  - `_runDispatchScheduledNotifications` (`index.js:2341`): `.select("fcmToken")`
  - `onGroupMessageCreated` (`index.js:2646`): `.select("fcmToken")` (el sender se filtra por id del doc, no necesita más campos)
  - `markStaleDriversOffline` (`index.js:2354`): `.select("updatedAt")` (solo necesita ref + updatedAt)
  - `computeDriverPercentiles` (ya mostrado arriba)
- **`_sendFcmGlobalToRoles` lee TODOS los usuarios `active`/`paymentPending` de la plataforma** en cada evento de Quito (`index.js:2703`). A escala es la query más cara de la app. Opciones, en orden de esfuerzo:
  1. `.select("fcmToken","role")` (quick win inmediato).
  2. Mantener una **colección/índice de tokens** (`pushTokens/{uid}` con `{token, role}`) actualizada por el cliente, y leer solo esa — docs minúsculos, mucho menos egress.
  3. Usar **FCM topics** (`/topics/role_conductor`) para fan-out sin leer Firestore en absoluto: el cliente se suscribe al topic por rol/asociación y el server hace 1 `send` a topic. Esto **elimina la query de audiencia** para broadcasts (eventos Quito, avisos globales). Es la solución correcta a escala "exponencial".
- **Egress inter-región:** las functions con región explícita están en **`us-central1`** (10 ocurrencias) y las 28 `onCall({})` sin región **también default a `us-central1`**. **Falta confirmar la región de Firestore**: no pude leerla desde el repo (`.firebaserc` solo trae el projectId; no hay `locationId`). **Acción para el dueño**: verificar con `gcloud firestore databases list --project taxis-f0f51` (o consola). Si Firestore está en `nam5`/`us-central` → mismo continente, egress intra-Google gratis/barato, OK. Si por accidente quedó en `southamerica-east1` u otra, habría egress inter-región en cada lectura/escritura de los crones masivos → caro a escala. **Recomiendo confirmarlo** antes de dar por bueno este punto; es barato verificar y caro si está mal.

---

## 3. Patrón de init global / Singleton — estado y propuesta

El patrón actual **ya es correcto** en lo esencial. Propuesta de cabecera ideal (consolidando el hoist de `getMessaging` y dejando `nodemailer` lazy):

```js
// ── nivel módulo: se ejecuta UNA vez por arranque de contenedor, se
//    reutiliza en todas las invocaciones calientes ──
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentWritten, onDocumentUpdated, onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { setGlobalOptions } = require("firebase-functions/v2");   // ← NUEVO
const { defineSecret } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getStorage } = require("firebase-admin/storage");
const { getMessaging } = require("firebase-admin/messaging");    // ← hoisted (firebase-admin ya cargado)

initializeApp();
const db = getFirestore();

// Defaults globales: región única (= región de Firestore) + tope de instancias
// para que NINGUNA función pueda fugar costo ante un pico/bucle.
setGlobalOptions({
  region: "us-central1",   // alinear con la región real de Firestore
  maxInstances: 10,        // override por función donde haga falta más
  memory: "256MiB",
});
```
`setGlobalOptions` además te deja **borrar los `region: "us-central1"` repetidos** en 10 funciones (menos ruido, una sola fuente de verdad). `nodemailer` se queda lazy en `sendPasswordResetEmail` (correcto). **Nota:** añadir `setGlobalOptions`/`maxInstances` cambia la config de deploy de todas las funciones → desplegar y verificar.

---

## 4. Tabla memoria / concurrency / maxInstances recomendada

Perfil de todas son **I/O-bound** (nada hace cómputo CPU pesado; Gemini es HTTP remoto). `concurrency` solo aplica a callable/HTTP; los triggers Firestore/Schedule van a 1 por diseño de v2.

| Función | Tipo | Perfil | memoria actual→propuesta | concurrency | maxInstances |
|---|---|---|---|---|---|
| `generateAgoraToken` / `generateLiveKitToken` | onCall | I/O (firma local, rápida) | 256→256 | 80 (default) | 10 |
| `reportPayment`/`validatePayment`/`approveDriver`/… (callables CRUD) | onCall | I/O | 256→256 | 80 | 10 |
| `migrateToMultitenant` / `backfill*` / `inheritArchivedRecords` | onCall admin | I/O batch | 256→512 (jobs grandes) | 1 | 2 |
| `syncUserClaims` | trigger | I/O | 256→256 | 1 (forzado) | 10 |
| `onTripFinalized` | trigger | I/O serial | 256→256 | 1 | 10 |
| `onTripAssignmentChanged`/`onTripRequestCreated`/`onTripRequestStatusChanged`/`onTripRequestRated` | trigger | I/O | 256→256 | 1 | 10 |
| `onGroupMessageCreated` | trigger | I/O (audiencia) | 256→256 | 1 | 10 |
| `mirrorExpenseToCashflow` | trigger | I/O | 256→256 | 1 | 5 |
| **`enforcePayments`** | cron | I/O N+1 | 512→256 (tras `.select`) | 1 | 2 |
| `checkSubscriptions` / `checkDriverDues` | cron | I/O N+1 | 256→256 (idealmente **fusionar** con enforcePayments) | 1 | 2 |
| `computeDriverPercentiles` | cron | I/O + sort en RAM | 256→512 (trae todos drivers; o 256 con `.select`) | 1 | 1 |
| `markStaleDriversOffline` | cron 2min | I/O | 256→256 (bajar frecuencia a 3-5min) | 1 | 1 |
| `dispatchScheduledNotifications` | cron 5min | I/O | 256→256 | 1 | 1 |
| `purgeExpiredProofs` | cron | I/O storage | 512→256 (probar) | 1 | 1 |
| `purgeExpired*`/`purgeOld*` | cron | I/O | 256→256 | 1 | 1 |
| `fetchQuitoEvents` | cron | I/O (Gemini HTTP) | 256→256 | 1 | 1 |

`maxInstances` en triggers de trips/chat puesto a 10 evita fuga ante avalancha sin estrangular operación normal. Crones a 1-2 (no necesitan paralelismo de instancias).

---

## 5. Quick wins (bajo riesgo) vs cambios que requieren prueba

**Quick wins — aplicables ya, riesgo bajo:**
- Añadir `.select(...)` a las 5-6 queries de audiencia/stale/percentiles (§2, §4). No cambia comportamiento, solo recorta egress/RAM.
- Añadir `maxInstances` (global vía `setGlobalOptions` + overrides). Solo topa picos; con `maxInstances: 10` no afecta operación normal.
- Cota/LRU en `_assocNames` (§1).
- Hoist de `getMessaging` (§3).
- Trocear `batch.commit()` en `computeDriverPercentiles` (§2) — **además corrige un bug latente** (&gt;500 escrituras/batch falla). Riesgo bajo, alto valor.
- Bajar frecuencia de `markStaleDriversOffline` de 2 a 3-5 min (verificar que el threshold `STALE_MINUTES=6` sigue coherente).

**Cambios que requieren prueba antes de aplicar:**
- **Fusionar `enforcePayments` + `checkSubscriptions` + `checkDriverDues`** en un único cron. Alto ahorro, pero hay que reconciliar las tres lógicas de gracia (`SUBSCRIPTION_GRACE_DAYS`, `DRIVER_DUES_GRACE_DAYS`, permisos) y validar con datos reales que no cambie qué usuarios se bloquean/reactivan.
- **Eliminar el N+1 materializando `nextDueAt`/`lastValidatedPaymentAt`** en el doc del user (escrito por `validatePayment`) para que el cron sea una query `where("nextDueAt","&lt;=",now)`. Es el cambio de mayor impacto a escala, pero toca el modelo de datos y necesita backfill + pruebas.
- **FCM topics** para broadcasts (eventos Quito / avisos globales) en lugar de leer toda la colección `users`. Elimina la query más cara, pero requiere que el cliente Flutter se suscriba/desuscriba a topics por rol y asociación, y migrar el envío.
- Bajar memorias 512→256 en `enforcePayments`/`purgeExpiredProofs`: probar que no hay OOM con volumen real tras aplicar `.select()`.
- `setGlobalOptions({region})`: confirmar primero la **región real de Firestore** (`gcloud firestore databases list`) y alinear; desplegar todas las funciones y verificar.

**Lo que ya está bien y NO recomiendo tocar:** init singleton (`db`), secrets vía env, `nodemailer` lazy, `minInstances=0`, `userCache` scoped al handler, concurrency default 80 en callables.</result>
<usage><subagent_tokens>54684</subagent_tokens><tool_uses>20</tool_uses><duration_ms>212905</duration_ms></usage>
</task-notification>