<task-notification>
<task-id>aa0d0c2fd52190a98</task-id>
<tool-use-id>toolu_01GvSnjHm8fnhcGGRSnXnzHi</tool-use-id>
<output-file>/tmp/claude-1000/-home-byron-realpe-Repositorios-taxis/991e6752-7cca-4218-97a0-e86b88f61a36/tasks/aa0d0c2fd52190a98.output</output-file>
<status>completed</status>
<summary>Agent "Design Ola2 #1: merge payment crons" completed</summary>
<result>I now have everything needed: all three crons, the helpers (`_lastValidatedPayment`, `_hasActivePermit`), `computeNextDueDate`/`alignToDueDay`, the write sites (`validatePayment`, `approveDriver`, `voidPayment`, `updateBillingConfig`), the data model, and the test pattern. 

I've found a critical subtlety: the three crons have genuinely **divergent** logic (different statuses, different scopes, even a logical bug in `checkDriverDues`). This makes a naive 3-way fusion risky. Let me write the full spec/plan honestly reflecting that.

---

# Spec + Plan: Fusión segura de los crones de morosidad

**Proyecto:** `/home/byron-realpe/Repositorios/taxis` — Cloud Functions v2 (`functions/index.js`)
**Item:** Ola 2 del audit `docs/sre-audit-cloud-functions-2026-05-31.md` (mayor ahorro)
**Autor:** SRE + arquitecto. **Estado:** propuesta para aprobación. **No se modificó ningún archivo.**

&gt; **TL;DR / veredicto honesto:** Los 3 crones NO son redundantes — son **tres modelos de morosidad distintos y parcialmente contradictorios** que hoy corren secuencialmente (00:00 → 00:05 → 00:30) y se pisan entre sí. Fusionarlos de un golpe es **arriesgado** porque (a) usan estados, scopes y definiciones de "vencido" diferentes, y (b) `checkDriverDues` tiene un **bug latente de gracia** que la fusión no debe "heredar" ni "corregir silenciosamente". **Recomiendo un rollout por fases**: primero materializar `nextDueAt` y optimizar solo `enforcePayments` (el modelo canónico), validar en shadow, y **solo después** decidir con el dueño si `checkSubscriptions`/`checkDriverDues` se apagan o se absorben. La estimación de ahorro es real y grande (§6), pero el riesgo está en la reconciliación de lógica, no en la query.

---

## 1. Tabla comparativa de las 3 funciones

Referencias de código:
- `enforcePayments` — `index.js:2444`, helpers `_lastValidatedPayment` `:2744`, `_hasActivePermit` `:2759`, `computeNextDueDate` `lib/dueDate.js:81`.
- `checkSubscriptions` → `_runSubscriptionCheck` `index.js:2794`, `SUBSCRIPTION_GRACE_DAYS=3` `:2792`.
- `checkDriverDues` → `_runCheckDriverDues` `index.js:3673`, `_periodStartFor` `:3651`, `DRIVER_DUES_GRACE_DAYS=3` `:3649`.

| Dimensión | `enforcePayments` (00:00) | `checkSubscriptions` (00:05) | `checkDriverDues` (00:30) |
|---|---|---|---|
| **Qué cobra** | Cuota del **conductor** a su asociación (membresía interna) | Suscripción **SaaS** de la asociación al super-admin (paidUntil/trialEndsAt) | Cuota del **conductor** a su asociación (membresía interna) |
| **Scope de assoc** | Pase A: `status in [active,trial]`; Pase B: `status==active` **con `billingConfig.amount&gt;0`** | **TODAS** las associations (`.get()` sin filtro); salta solo si no hay `expiresAt` | TODAS las associations; salta si no hay `billingConfig.amount&gt;0` |
| **Scope de users** | Pase B: `status==active` + rol ∈ {conductor, admin} | rol ∈ {conductor, admin, **operadora**}, cualquier status excepto excluidos | **solo rol==conductor**, cualquier status excepto excluidos |
| **Definición de "vencido"** | `computeNextDueDate(approvedAt, cfg, lastValidatedPayment) &lt;= now` — **alineado a dueDay**, exacto | `paidUntil/trialEndsAt &lt; now - 3d` (gracia de la **asociación**) | `_periodStartFor(now) &lt; now - 3d` → **siempre true** salvo período &lt; 3 días (ver bug abajo) |
| **Estado que PONE (bloqueo)** | `paymentBlocked` + `blockReason:"cuota_vencida"` + `blockedAt` | `paymentBlocked` (sin blockReason) y `paymentPending` (warning) | `paymentBlocked` (sin blockReason) y `paymentPending` (warning) |
| **Estado que QUITA (reactiva)** | Pase C: `paymentBlocked`+`blockReason==cuota_vencida` → `active` (borra blockedAt/blockReason) | `paymentPending|paymentBlocked` → `active` si assoc al día | `paymentPending|paymentBlocked` → `active` si hay pago en período |
| **Respeta `disabledByAdmin`** | Sí (filtra `status==active` en query, no toca otros) | Sí (`continue` explícito) | Sí (`continue` explícito) |
| **Respeta `_hasActivePermit`** | **SÍ** (`:2528`) | **NO** | **NO** |
| **Manda FCM** | Sí (bloqueo y reactivación) | No | No |
| **Query N+1 por user** | `_lastValidatedPayment` (1 query) + `_hasActivePermit` (1 query) = **2 queries/conductor** | Ninguna (solo update) | `payments where ... paymentDate&gt;=periodStart` = **1 query/conductor** |
| **Suspende asociaciones** | Pase A: sí → `suspended` | Sí → `expired` (¡estado distinto!) | No |
| **retryCount** | (sin retryCount) | 2 | 2 |

### Dónde SE SOLAPAN
- Los tres pueden poner `paymentBlocked` / `paymentPending` / `active` sobre el **mismo doc de user** la misma noche, en orden 00:00 → 00:05 → 00:30. El último en correr (`checkDriverDues`) gana para conductores.
- `enforcePayments` Pase B/C y `checkDriverDues` cubren **el mismo dominio** (cuota del conductor) con dos algoritmos distintos.

### Dónde DIFIEREN (lo crítico — la fusión debe preservar o el dueño debe decidir)
1. **Estado de asociación vencida:** `enforcePayments` pone `suspended`; `checkSubscriptions` pone `expired`. Son estados distintos con semántica distinta (suspended = mora dura; expired = en gracia). **No fusionar a ciegas.**
2. **Permisos (`_hasActivePermit`):** solo `enforcePayments` los respeta. Si la fusión adopta el algoritmo de `checkDriverDues`, **un conductor con permiso activo (ej. licencia/vacaciones) quedaría bloqueado** → regresión grave.
3. **Definición de vencimiento:** `enforcePayments` usa `computeNextDueDate` (alineado a `dueDay`, exacto). `checkDriverDues` usa `_periodStartFor` ("período hacia atrás", aproximado). **Dan resultados distintos** para el mismo conductor en bordes de mes/semana.
4. **`blockReason`:** solo `enforcePayments` lo escribe (`cuota_vencida`). `validatePayment` (`:1292`) **depende de `blockReason=="cuota_vencida"`** para auto-reactivar al validar el pago. Si la fusión bloquea sin ese `blockReason`, la reactivación inmediata al validar **deja de funcionar**.
5. **Scope de roles:** operadora se bloquea en `checkSubscriptions` pero no en `checkDriverDues`. Admin se bloquea en `enforcePayments` Pase B pero su cuota conceptualmente es SaaS, no interna.

### Bug latente en `checkDriverDues` (no heredar, no corregir en silencio)
`_runCheckDriverDues` (`:3736`) compara `periodStart &lt; graceCutoff`, donde `periodStart = now - period` y `graceCutoff = now - 3d`. Para período mensual, `periodStart` es ~30 días atrás → **siempre** `&lt; now-3d` → **todo conductor sin pago en el período se bloquea sin gracia real**. El comentario en `:3734` admite que es "simplificado". La gracia de 3 días que la doc promete **no se aplica** para períodos &gt; 3 días. **Esto es justamente por qué la fusión es delicada**: si replicamos este comportamiento exacto en shadow, "coincidirá" con un bug; si lo arreglamos, divergirá del comportamiento actual. → Decisión explícita del dueño requerida (§5).

---

## 2. Diseño de la función unificada (`enforceMembershipDues`)

### 2.1 Principio de diseño
El **modelo canónico es `enforcePayments`** porque: usa `computeNextDueDate` (preciso, ya testeado en jest), respeta permisos, escribe `blockReason` (del que depende `validatePayment`), y manda FCM. La fusión = **generalizar `enforcePayments` para que cubra también el dominio de `checkDriverDues`**, eliminando el N+1 vía materialización, y dejando la suscripción SaaS (`checkSubscriptions`) **como módulo separado dentro del mismo cron** (no se mezcla con la cuota del conductor: son dineros y estados distintos).

### 2.2 Campos nuevos en `users/{uid}`
| Campo | Tipo | Significado | Quién lo escribe |
|---|---|---|---|
| `nextDueAt` | Timestamp | Próximo vencimiento de la cuota interna del conductor. `&lt;= now` ⇒ moroso. | `approveDriver`, `validatePayment`, `voidPayment`, `updateBillingConfig`, `backfillNextDueAt` |
| `lastValidatedPaymentAt` | Timestamp\|null | `validatedAt` del último pago no anulado (para recomputar sin query). | mismos sitios |
| `dueComputeVersion` | number | Versión del algoritmo de cómputo (permite re-backfill al cambiar lógica). | mismos sitios |

**Importante:** `nextDueAt` se materializa **solo para conductores con `billingConfig.amount&gt;0`**. Para usuarios sin cobro, `nextDueAt = null` y la query del cron nunca los toca (no se bloquea a quien no debe pagar).

### 2.3 Cómputo de `nextDueAt` (reusando `computeNextDueDate`)
Nuevo helper puro en `lib/dueDate.js` (testeable, sin Firestore):

```
nextDueAt = computeNextDueDate(
  { approvedAt },
  billingConfig,
  lastValidatedPayment  // {validatedAt} o null
)
```

- En `approveDriver`: `lastValidatedPayment=null` ⇒ primera cuota desde `approvedAt`.
- En `validatePayment` (pago no skipCashflow y concepto == `defaultConcept`): recalcular con el pago recién validado como `lastValidatedPayment`.
- En `voidPayment`: recalcular con el **nuevo** último pago no anulado (puede dejar `nextDueAt` en el pasado ⇒ moroso ⇒ correcto, ya que voidPayment además bloquea con `blockReason:"pago_anulado"`).
- En `updateBillingConfig`: recalcular para todos los conductores de esa asociación (el período/dueDay cambió). Esto es O(conductores de 1 assoc), aceptable y poco frecuente; trocear en batches de 450.

### 2.4 El cron unificado (pseudocódigo)
```
enforceMembershipDues (onSchedule, 00:00, America/Guayaquil, retryCount:2):
  now = Timestamp.now()
  MODE = readFlag("app_config/duesEnforcement.mode")  // "shadow" | "live"

  // ── Módulo 1: suscripción SaaS de asociaciones (ex-checkSubscriptions) ──
  //   se mantiene su lógica tal cual (expired/active + grace 3d),
  //   PERO se decide con el dueño si el estado vencido es "expired" o "suspended".
  runAssociationSubscriptions(now, MODE)

  // ── Módulo 2: morosidad de conductores (ex-enforcePayments B/C + checkDriverDues) ──
  // BLOQUEAR: una sola query, sin N+1
  toBlock = users.where("status","==","active")
                 .where("nextDueAt","&lt;=",now)
                 .select("nextDueAt","approvedAt","role","associationId")
  for u in toBlock (en chunks de 50, Promise.all):
      if not eligibleForDues(u): continue            // rol, billing&gt;0
      if await _hasActivePermit(u.id, u.nextDueAt): continue   // preserva permisos
      decide(MODE): block(u, "cuota_vencida") + FCM | logShadow("WOULD_BLOCK", u)

  // REACTIVAR: query de bloqueados con nextDueAt futuro
  toReactivate = users.where("status","==","paymentBlocked")
                      .where("blockReason","==","cuota_vencida")
                      .where("nextDueAt","&gt;",now)
  for u in toReactivate:
      decide(MODE): reactivate(u) + FCM | logShadow("WOULD_REACTIVATE", u)
```

Notas:
- El `paymentPending` (warning) se conserva como ventana de gracia configurable (`DUES_GRACE_DAYS`), implementada **dentro del cómputo de `nextDueAt`** o como segundo umbral `nextDueAt + grace`. Decisión §5.
- `_hasActivePermit` sigue siendo una query, pero **solo se ejecuta sobre los morosos candidatos** (decenas), no sobre todos. Eso es lo que mata el N+1.
- Requiere índice compuesto Firestore: `users(status ASC, nextDueAt ASC)` y `users(status ASC, blockReason ASC, nextDueAt ASC)`.

---

## 3. Backfill (`backfillNextDueAt`, callable de una sola vez)

```
backfillNextDueAt (onCall, superAdmin, timeout 540, dryRun param):
  for each association with billingConfig.amount&gt;0:
     cfg = billingConfig
     users = users.where(associationId==a).where(role in [conductor,admin]).get()
     batch (450):
       for u: 
          if !u.approvedAt: nextDueAt=null   // nunca bloquear sin approvedAt
          else:
             last = _lastValidatedPayment(u.id, a.id)   // N+1 SOLO en el backfill, una vez
             nextDueAt = computeNextDueDate({approvedAt}, cfg, last)
          if dryRun: log {uid, nextDueAt, wouldBlock: nextDueAt&lt;=now}
          else: batch.set(u.ref, {nextDueAt, lastValidatedPaymentAt:last?.validatedAt||null, dueComputeVersion:1}, {merge:true})
  return counts
```

**Seguridad anti-bloqueo:**
- Corre **primero con `dryRun:true`** y se revisa el log: ¿cuántos quedarían `nextDueAt&lt;=now`? Comparar contra el # de `paymentBlocked` actuales. Si el número es desproporcionado, hay un error de cómputo → no escribir.
- El backfill **solo escribe `nextDueAt`; NO cambia `status`**. Materializar el campo no bloquea a nadie por sí mismo: el bloqueo lo hace el cron, que arranca en modo shadow.
- Usuarios sin `approvedAt` ⇒ `nextDueAt=null` ⇒ jamás capturados por la query (`&lt;= now` excluye null). Inmunes.
- Idempotente: re-ejecutable; `merge:true`.

---

## 4. Rollout SEGURO por fases (lo más importante)

**Filosofía:** materializar y observar antes de cambiar comportamiento. Bandera central `app_config/duesEnforcement` con `{ mode: "off"|"shadow"|"live", canaryAssociationIds: [...] }`.

### Fase 0 — Preparación (sin tocar producción de comportamiento)
1. Añadir helper puro `computeNextDueAtForUser` en `lib/dueDate.js` + tests jest (TDD). No toca nada en runtime aún.
2. Añadir escritura de `nextDueAt`/`lastValidatedPaymentAt` en `approveDriver`, `validatePayment`, `voidPayment`, `updateBillingConfig`. **Aditivo**: campos nuevos, ningún cron los lee todavía. Deploy. Riesgo: nulo (solo escribe campos extra).
3. Crear índices compuestos Firestore. Deploy `firestore.indexes.json`.

### Fase 1 — Backfill en dry-run
4. Desplegar `backfillNextDueAt`. Ejecutar con `dryRun:true`. Revisar log: distribución de `nextDueAt`, # de `wouldBlock`. Comparar con realidad (# de `paymentBlocked` hoy).
5. Si cuadra, ejecutar `backfillNextDueAt` real. Ahora todos los users tienen `nextDueAt`. **Status intacto.**

### Fase 2 — Cron unificado en modo SHADOW (paralelo a los 3 viejos)
6. Desplegar `enforceMembershipDues` con `mode:"shadow"`. **Las 3 funciones viejas siguen activas y siguen siendo la fuente de verdad** (siguen escribiendo status). El cron nuevo corre a las 00:45 (después de los 3 viejos) y **solo loguea** `WOULD_BLOCK`/`WOULD_REACTIVATE` con uid + razón.
7. Job de comparación (puede ser un query manual sobre logs o una colección `duesShadowLog/{date}`): cada mañana comparar el set "shadow diría bloquear/reactivar" vs "el estado real que dejaron los crones viejos". **Correr en shadow ≥ 7 días** (cubre bordes de semana) e idealmente un cruce de fin de mes (cubre dueDay mensual).
8. Investigar CADA discrepancia. Las esperadas: el bug de gracia de `checkDriverDues` (§1) hará que shadow y viejo difieran. **Aquí el dueño decide** (§5) si el comportamiento correcto es el de `computeNextDueDate` (shadow) o el viejo.

### Fase 3 — Canary LIVE por asociación
9. Poner `mode:"live"` **solo para `canaryAssociationIds`** (1-2 asociaciones pequeñas/amigables). El cron nuevo escribe status real **solo para esas**; para el resto sigue en shadow. **Apagar los 3 crones viejos solo para esas asociaciones** no es posible (corren globales) → alternativa: en las viejas, `continue` si `assoc ∈ canary` (cambio temporal mínimo) para evitar doble escritura. 
10. Observar 3-7 días el canary: ¿algún conductor que pagó quedó bloqueado? ¿alguien con permiso? ¿reactivaciones correctas?

### Fase 4 — LIVE global + apagado de los viejos
11. `mode:"live"` global. En el mismo deploy, **desregistrar** `exports.enforcePayments`, `exports.checkSubscriptions`, `exports.checkDriverDues` (o convertirlos en no-op que solo loguea "deprecado"). Conservar `checkSubscriptionsNow`/`checkDriverDuesNow`/equivalente callable para trigger manual de emergencia.
12. Monitorear 2 semanas. Mantener el shadow-log activo como red de seguridad.

### Rollback
En cualquier fase: poner `mode:"shadow"` o `"off"` (variable Firestore, efecto inmediato sin redeploy) y reactivar los 3 crones viejos. Por eso **no se borran** hasta cerrar Fase 4 + ventana de observación.

---

## 5. Riesgos y casos borde

### Qué podría dejar bloqueado a un conductor que PAGÓ — y cómo se evita
| Riesgo | Causa | Mitigación en el diseño |
|---|---|---|
| `nextDueAt` desactualizado tras validar pago | `validatePayment` no recalcula `nextDueAt` | Fase 0 paso 2 lo añade; además `validatePayment` ya reactiva inmediato por `blockReason=="cuota_vencida"` (`:1292`) — **preservar ese path intacto**. |
| Pago anulado luego re-validado | orden de eventos | Recalcular `nextDueAt` en `voidPayment` **y** `validatePayment`; usar `_lastValidatedPayment` (ya filtra `voidedAt`). |
| Conductor con permiso activo bloqueado | adoptar lógica de `checkDriverDues` (no respeta permisos) | El cron unificado **llama `_hasActivePermit` antes de bloquear** (preserva comportamiento de `enforcePayments`). |
| `paymentPending` saltado directo a bloqueo | confundir gracia | `paymentPending` = warning antes de `nextDueAt`; bloqueo solo cuando `nextDueAt &lt;= now` (y, si se decide, `+ grace`). No se bloquea a quien está en `paymentPending` legítimo dentro de gracia. |
| `disabledByAdmin` reactivado por error | query de reactivación demasiado amplia | La query de reactivación filtra `status=="paymentBlocked"` **+ `blockReason=="cuota_vencida"`**; nunca toca `disabledByAdmin`, `pago_anulado`, etc. |
| Zona horaria | `computeNextDueDate` trabaja en **UTC** (`getUTCDate`), pero el cron corre `America/Guayaquil` (UTC-5) | **Riesgo real de borde de día.** `now` del cron es Timestamp UTC; `nextDueAt` se computa en UTC alineado a medianoche UTC. Un dueDay "día 5" significa 00:00 UTC del día 5 = 19:00 del día 4 en Ecuador. Hoy `enforcePayments` ya tiene esta característica → **la fusión la preserva idéntica** (mismo `computeNextDueDate`). No introducir cambios de TZ en esta fase; documentar que el comportamiento UTC es el actual. |

### Qué podría dejar ACTIVO a un moroso — y cómo se evita
| Riesgo | Mitigación |
|---|---|
| `nextDueAt` nunca materializado (user viejo) | Backfill (Fase 1) lo cubre; shadow detecta faltantes (user activo sin `nextDueAt` con billing&gt;0 = anomalía a loguear). |
| `nextDueAt=null` por falta de `approvedAt` | Correcto que no se bloquee (no aprobado = no debería operar de todos modos; otros flujos lo manejan). |
| Reloj/serverTimestamp pendiente | `nextDueAt` se escribe con valor calculado (Timestamp concreto), no `serverTimestamp()` pendiente, así la query lo ve consistente. |

### Decisiones que requieren al dueño (no las tomo yo)
1. **Asociación vencida: `expired` o `suspended`?** (divergencia §1.1). Propongo conservar AMBOS conceptos: `expired` durante gracia, `suspended` pasada la gracia.
2. **Bug de gracia de `checkDriverDues`:** ¿el comportamiento correcto es la gracia real (vía `computeNextDueDate`, que es lo que hará shadow) o replicar el bug? Recomiendo: corregir = usar `computeNextDueDate`, y comunicar a las asociaciones que la gracia ahora funciona como está documentada.
3. **`grace days` para conductores:** hoy `enforcePayments` **no tiene gracia** (bloquea exactamente en `nextDueAt`), mientras `checkSubscriptions`/`checkDriverDues` tienen 3 días. ¿Unificar a 3 días de gracia para el conductor? Esto **cambia el comportamiento de `enforcePayments`** (hoy más estricto). Decisión de negocio.

---

## 6. Estimación de ahorro (lecturas Firestore/noche)

Sea **A** = asociaciones, **D** = conductores/assoc, **N = A·D** total conductores.

**Antes (3 crones, por noche):**
- `enforcePayments`: A (assoc Pase A) + A (assoc Pase B) + N (users) + **2N** (`_lastValidatedPayment` + `_hasActivePermit` por user) + (bloqueados) ≈ **~3N**.
- `checkSubscriptions`: A + N (users) ≈ **~N**.
- `checkDriverDues`: A + N (users) + **N** (payments query por conductor) ≈ **~2N**.
- **Total ≈ 6N + ~4A lecturas/noche.**

**Después (cron unificado con `nextDueAt` materializado):**
- Módulo SaaS: A (associations) + N (users por assoc para propagar status) — esto **no se elimina** salvo que también se materialice; sigue ≈ N en el peor caso, pero es 1 update-scan sin sub-queries.
- Módulo conductores: **1 query de morosos** (M = morosos, típicamente ≪ N) + M·1 (`_hasActivePermit` solo sobre morosos) + 1 query de reactivables. ≈ **2M**, no O(N).

| Escala | Antes (~6N) | Después (módulo dues ~2M, asumiendo 5% morosos) | Reducción dues |
|---|---|---|---|
| 10 assoc × 200 = 2.000 | ~12.000 lecturas/noche | ~200 (M=100, ×2) | **~98%** |
| 50 assoc × 200 = 10.000 | ~60.000 lecturas/noche | ~1.000 (M=500, ×2) | **~98%** |

El **módulo SaaS** sigue siendo O(N) si se mantiene la propagación de status por user; optimizarlo (materializar también el estado de suscripción) es un paso posterior. Aun así, eliminar el N+1 de `enforcePayments`/`checkDriverDues` **baja el dominio de morosidad del conductor de ~6N a ~O(M)** — orden de magnitud, el ahorro grande del audit. A 50×200, pasar de ~60k a ~2k lecturas/noche (≈ -97%).

---

## 7. Plan de implementación (tasks bite-sized, TDD donde aplique)

**Bloque A — Lógica pura (TDD en `lib/dueDate.js`, sin tocar runtime)**
1. `[test]` Añadir a `dueDate.test.js` casos para un helper `computeNextDueAtForUser({approvedAt, lastPayment, billingConfig})` que envuelve `computeNextDueDate` y maneja `approvedAt` ausente (→ null) y `amount&lt;=0` (→ null). (RED)
2. `[impl]` Implementar `computeNextDueAtForUser` en `lib/dueDate.js`, exportarlo. (GREEN) — sin Firestore, 100% unit-testeable.
3. `[test]` Casos borde: pago anulado (lastPayment null), dueDay mensual en borde de mes, semanal en borde de semana, TZ (documentar UTC).

**Bloque B — Materialización (aditivo, deployable solo)**
4. En `approveDriver` (`:424`): tras setear `approvedAt`, escribir `nextDueAt` (= computeNextDueAtForUser sin pago) + `dueComputeVersion`.
5. En `validatePayment` (`:1281`): si concepto == `billingConfig.defaultConcept`, recalcular y escribir `nextDueAt`/`lastValidatedPaymentAt`. **No tocar** el path de reactivación por `blockReason`.
6. En `voidPayment` (`:1436`): recomputar `nextDueAt` con el nuevo último pago no anulado.
7. En `updateBillingConfig` (`:1903`): recomputar `nextDueAt` de los conductores de esa assoc en batches de 450.
8. Añadir índices a `firestore.indexes.json`: `users(status,nextDueAt)` y `users(status,blockReason,nextDueAt)`. Deploy.

**Bloque C — Backfill**
9. `backfillNextDueAt` callable (superAdmin) con `dryRun`. Ejecutar dry-run, revisar log, luego real.

**Bloque D — Cron unificado + shadow**
10. `enforceMembershipDues` onSchedule 00:45 con `mode` leído de `app_config/duesEnforcement`. Módulo conductores (block/reactivate por query) + reutilizar lógica SaaS de `_runSubscriptionCheck` como submódulo. En `shadow`: solo loguear a `duesShadowLog/{date}`.
11. Script/consulta de comparación shadow-vs-viejo. Correr ≥7 días + cruce fin de mes.

**Bloque E — Cutover**
12. Canary live por `canaryAssociationIds` (+ `continue` temporal en crones viejos para esas assoc).
13. Live global; desregistrar `enforcePayments`/`checkSubscriptions`/`checkDriverDues` (no-op deprecado); conservar callables `*Now` para trigger manual.
14. Observación 2 semanas; luego borrar código muerto.

---

### Archivos relevantes (rutas absolutas)
- `/home/byron-realpe/Repositorios/taxis/functions/index.js` — crones `:2444` (enforcePayments), `:2951`/`:2794` (checkSubscriptions/_runSubscriptionCheck), `:3761`/`:3673` (checkDriverDues/_runCheckDriverDues); helpers `:2744` `_lastValidatedPayment`, `:2759` `_hasActivePermit`, `:3651` `_periodStartFor`; write sites `:384` approveDriver, `:1257` validatePayment, `:1398` voidPayment, `:1866` updateBillingConfig.
- `/home/byron-realpe/Repositorios/taxis/functions/lib/dueDate.js` — `computeNextDueDate` `:81`, `alignToDueDay` `:25` (aquí va el nuevo helper puro).
- `/home/byron-realpe/Repositorios/taxis/functions/test/dueDate.test.js` — patrón jest existente (extender aquí).

---

## Conclusión honesta para aprobación
- El **ahorro es real y grande** (~97-98% en el dominio de morosidad del conductor a 50×200) y la query materializada es sólida.
- **Pero NO es trivial fusionar los 3 en uno solo de un golpe.** Difieren en estados (`suspended` vs `expired`), scope de roles, respeto a permisos, dependencia de `blockReason`, y `checkDriverDues` tiene un bug de gracia. Una fusión naïve **puede bloquear a un conductor que pagó o con permiso, o dejar de auto-reactivar al validar**.
- Por eso el plan **fasea**: (1) materializar `nextDueAt` y optimizar el modelo canónico (`enforcePayments`) **sin fusionar**, (2) correr en **shadow** comparando contra los viejos, (3) **el dueño decide** las 3 divergencias de negocio, (4) recién entonces apagar los viejos. La bandera `mode` permite rollback instantáneo sin redeploy.

Listo para tu aprobación. Si querés, el siguiente paso natural es el Bloque A (helper puro + tests jest), que es 100% seguro y no toca runtime.</result>
<usage><subagent_tokens>54033</subagent_tokens><tool_uses>12</tool_uses><duration_ms>186032</duration_ms></usage>
</task-notification>