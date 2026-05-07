# Taxis App — SaaS Multi-Asociación

Plataforma SaaS para asociaciones de taxis. Cada asociación funciona aislada con sus propios admins, conductores, viajes, walkie-talkie y datos. La app se vende por suscripción mensual/anual.

> Originalmente nació para la **Asociación de Taxis Jipijapa (Quito, Ecuador)**. Hoy soporta múltiples asociaciones (multi-tenant) — Jipijapa, La Roldós, Hotel Colón, etc.

---

## Stack

- **Flutter** 3.11 — Clean Architecture (data/domain/presentation) + BLoC + GetIt/Injectable + GoRouter.
- **Firebase**: Auth, Firestore, Cloud Functions (Node 22, 2nd Gen), Cloud Messaging, Storage.
- **Agora RTC** — walkie-talkie estilo Zello (PTT half-duplex con lock atómico en Firestore).
- **Android nativo** (Kotlin) — overlay PTT flotante + foreground service para radio en background.

---

## Visión SaaS

```
┌─────────────────────── TÚ (Super-admin / Byron) ───────────────────────┐
│  Vendes la app a asociaciones, creas su cuenta, cobras suscripción     │
└────────────────────────────┬───────────────────────────────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
   ┌────▼──────┐       ┌─────▼─────┐       ┌──────▼─────┐
   │ Jipijapa  │       │ La Roldós │       │ Hotel Colón│   ← cada una con
   │  (JIPI)   │       │   (ROLD)  │       │   (COLON)  │     su admin, sus
   │           │       │           │       │            │     socios, sus
   │ Admin     │       │ Admin     │       │ Admin      │     viajes, sus
   │  ↓        │       │  ↓        │       │  ↓         │     canales walkie
   │ Operad.   │       │ Operad.   │       │ Operad.    │
   │  ↓        │       │  ↓        │       │  ↓         │
   │ Conductr. │       │ Conductr. │       │ Conductr.  │
   └───────────┘       └───────────┘       └────────────┘
```

Aislamiento por campo `associationId` en cada documento Firestore + custom claims en JWT. Una sola base de código, un solo proyecto Firebase.

---

## Roles

| Rol | Quién | Ámbito |
|---|---|---|
| `superAdmin` | Tú (Byron) — `brealpeaymara@gmail.com` | Todo el sistema. Crea asociaciones, factura, suspende, rescata. |
| `admin` | Dueño de cada asociación | Solo SU asociación: gestionar socios, configurar canales/paradas, ver reportes. |
| `operadora` | Empleada del admin | Despachar viajes, aprobar conductores, atender emergencias. |
| `conductor` | Socio | Su perfil, su radio, sus pagos, viajes asignados. |

---

## Estructura de datos (Firestore)

```
associations/{slug}                            ← multi-tenant
  code: "JIPI"           (público, único, 4-8 chars)
  name, city, phone, email
  status: trial|active|suspended|cancelled
  pricingTierId: "basic"
  trialEndsAt, paidUntil
  maxDrivers, maxOperators, maxChannels
  ownerUid: <uid del admin>
  theme: { primaryColor, secondaryColor, accentColor, logoUrl }

pricingTiers/{id}                              ← editable por super-admin
  name, description
  monthlyPriceUsd, yearlyPriceUsd
  maxDrivers, maxOperators, maxChannels
  maxAgoraMinutesPerMonth (null = ilimitado)
  isPublic, sortOrder

users/{uid}
  associationId: "jipijapa"   ← clave de aislamiento
  role: admin|operadora|conductor
  status: active|pendingApproval|rejected|suspended
  approvedBy, approvedAt
  name, lastname, cedula, email, phone
  placa, cooperativa, codigoCooperativa, numeroVehiculo
  fotoVehiculo, fotoLicenciaFrontal, fotoLicenciaTrasera

(todas estas también con `associationId`):
drivers/, vehicles/, trips/, payments/, expenses/,
channels/, messages/, chat_rooms/, emergencies/,
competitor_trips/, taxi_stands/, incentives/
```

---

## Cloud Functions (`functions/index.js`)

| Función | Tipo | Quién la llama | Qué hace |
|---|---|---|---|
| `generateAgoraToken` | Callable | Cualquier user auth | Token RTC para walkie. Devuelve `{appId, token, expiresAt}`. |
| `syncUserClaims` | Trigger Firestore | Sistema | Sincroniza `associationId`, `role`, `status`, `superAdmin` al JWT cada vez que se escribe `users/{uid}`. ⚠️ Pendiente de deploy (ver pendientes). |
| `validateAssociationCode` | Callable público | Conductor sin auth | Verifica código `JIPI` antes de registrarse. Devuelve nombre/ciudad de la asociación. |
| `approveDriver` | Callable | Admin / operadora | Marca user `pendingApproval` → `active`. |
| `rejectDriver` | Callable | Admin / operadora | Marca user → `rejected`. |
| `transferAdmin` | Callable | Admin actual o super-admin | Transfiere rol admin entre socios. Atómica: nuevo admin sube a `admin`, viejo baja a `conductor`, asociación.ownerUid actualizada. |
| `setUserStatus` | Callable | Admin / operadora / super-admin | Suspender / reactivar socio. No deja suspender al admin actual. |
| `createAssociation` | Callable | Solo super-admin | Crea asociación + admin inicial con password temporal. |
| `seedDefaults` | Callable | Solo super-admin (one-time) | Siembra los 4 tiers + asociación `jipijapa`. |
| `migrateToMultitenant` | Callable | Solo super-admin (one-time) | Etiqueta todos los docs existentes con `associationId: jipijapa`. |

---

## Reglas Firestore (`firestore.rules`)

- **Helpers**: `isSuperAdmin()` (por email), `myAssociationId()` (del JWT), `isAdmin()`, `isOperatorOrAdmin()`, `pttLockExpired()`.
- `associations/{aid}` — read: super-admin o miembro; write: super-admin.
- `pricingTiers/{tid}` — read: cualquier auth; write: super-admin.
- `users/{userId}` — read: auth; create: self; update: self o admin; delete: admin.
- `channels/{aid}` — update se permite en 3 escenarios: admin, lock PTT válido, cambio de membresía propia.
- `messages` — create: senderId == self + canal público o miembro o admin; update: ❌; delete: admin.
- `chat_rooms` — solo participants.
- Resto (`trips`, `payments`, etc.) con permisos por rol; **falta filtrar por `associationId`** (pendiente).

---

## Setup local

```bash
# Requisitos: Flutter 3.11+, Node 22, Firebase CLI, gcloud CLI

# 1. Dependencias del cliente
flutter pub get

# 2. Variables de entorno locales
cp env.example .env

# 3. Google Maps API key
echo 'GOOGLE_MAPS_API_KEY=AIza...' >> android/local.properties
cp ios/Flutter/Secrets.xcconfig.example ios/Flutter/Secrets.xcconfig

# 4. Cloud Functions
cd functions && npm install && cd ..

# 5. Ejecutar
flutter run
```

---

## Despliegue a producción

### 1. Configurar secrets de Firebase Functions (una sola vez)

```bash
cd functions
firebase functions:secrets:set AGORA_APP_ID            # → tu Agora App ID
firebase functions:secrets:set AGORA_APP_CERTIFICATE   # → tu Agora App Certificate
```

### 2. Deploy

```bash
firebase deploy --only functions,firestore:rules,firestore:indexes
```

### 3. IAM público para todas las Callable

Cloud Functions 2nd Gen requiere `roles/run.invoker` para `allUsers` en cada Callable:

```bash
for f in generateagoratoken validateassociationcode approvedriver rejectdriver \
         createassociation seeddefaults migratetomultitenant transferadmin \
         setuserstatus; do
  gcloud run services add-iam-policy-binding $f \
    --region=us-central1 --member=allUsers --role=roles/run.invoker --quiet
done
```

> Si `syncUserClaims` (trigger) falla en el primer deploy con `Eventarc Service Agent`, espera 2 min y reintenta. Si vuelve a fallar:
> ```bash
> PROJECT_NUMBER=1043852093355
> gcloud projects add-iam-policy-binding taxis-f0f51 \
>   --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com" \
>   --role="roles/eventarc.eventReceiver" --quiet
> firebase deploy --only functions:syncUserClaims
> ```

### 4. Inicialización del SaaS (UNA SOLA VEZ)

1. Login con `brealpeaymara@gmail.com` en la app.
2. **Perfil → 🛡️ Panel SaaS** → Click **"Sembrar planes y asociación Jipijapa"**.
3. Click **"Migrar datos a multi-tenant"**.

---

## Operación del SaaS

### Crear una nueva asociación (cuando vendes la app)

1. Panel SaaS (`/super`) → **"+ Nueva"** en sección Asociaciones.
2. Llenar: código (`ROLD`), nombre, ciudad, plan, email del admin, datos del admin, días de trial.
3. Submit → la function genera un **password temporal** que se muestra UNA SOLA VEZ.
4. Copia y envía al admin de la asociación: `email`, `password temporal`, `código (ROLD)`.

### Gestionar planes (`pricingTiers`)

Panel SaaS → sección Planes → **"+ Nuevo"** o tap un plan para editar:
- ID (slug, único, no editable después).
- Nombre, descripción.
- Precio mensual y anual.
- Límites: drivers, operadoras, canales, minutos Agora/mes.
- Público / oculto.
- Eliminar (solo si nadie lo usa).

### Cambiar plan a una asociación

Panel SaaS → menú ⋮ asociación → **"Cambiar plan"** → selecciona → guarda.

### Gestionar socios

Como **admin de asociación**: Perfil → 👥 "Gestionar socios".
Como **super-admin**: Panel SaaS → menú ⋮ asociación → **"Ver socios"**.

Funcionalidades:
- Filtros (Todos / Pendientes / Activos / Suspendidos / Rechazados).
- Búsqueda por nombre, cédula, email.
- Acciones por socio: aprobar, rechazar (con motivo), suspender, reactivar, **hacer administrador**.

### Transferir admin (1 admin por asociación)

Menú ⋮ del socio destino → **"Hacer administrador"** → confirmar.
- El nuevo sube a `admin`.
- El admin saliente baja a **`conductor`** automáticamente.
- `associations/{aid}.ownerUid` se actualiza atómicamente.
- Caso "rescate" (admin desapareció): tú entras como super-admin y haces el cambio.

---

## Onboarding del conductor (Opción A: auto-registro con código)

1. Conductor descarga la app → "Crear cuenta".
2. **Sección "Tu Asociación"** (primera): escribe código (`JIPI`) → tap **"Verificar"**.
3. Si es válido, se muestra: `✓ Asociación de Taxis Jipijapa · Quito · código JIPI`.
4. Llena el resto: datos personales, tipo cuenta, datos vehículo (solo conductores), fotos, contraseña.
5. Submit → cuenta creada con `status: pendingApproval`.
6. El admin recibe la solicitud en su panel → **Aprobar** → conductor ya puede usar la app.

> Si el tipo es **Operadora**, los campos de cooperativa/vehículo/fotos se ocultan automáticamente.

---

## Modelo de monetización

### Planes default (configurables)

| Plan | Precio | Drivers | Operadoras | Canales | Min Agora/mes |
|---|---|---|---|---|---|
| Trial | $0/30 días | 5 | 1 | 1 | 5 000 |
| Básico | $49/mes | 30 | 1 | 3 | 50 000 |
| Pro | $129/mes | 100 | 3 | 10 | 200 000 |
| Enterprise | $249/mes | ∞ | ∞ | ∞ | ∞ |

### ⚠️ Cuidado con Agora (costo dominante)

| Servicio | Cálculo (30 conductores 8h/día) | Costo/mes |
|---|---|---|
| Agora audio | 432 000 user-min × $0.99/1000 | **~$430** |
| Firestore | 5M reads + 500k writes | ~$4 |
| Cloud Functions + Storage | uso bajo | ~$2 |

**Soluciones**:
1. **Idle timeout** en walkie-talkie (desconectar tras N min sin actividad) — reduce 70-90%.
2. Plan tarifa volumen Agora (descuento 30-50% con compromiso anual).
3. **Migrar a LiveKit self-hosted** (open source, VPS $20/mes) — ahorro brutal a partir de 5+ asociaciones.

### Pasarela de pago

⚠️ **Stripe NO opera en Ecuador**. Alternativas reales:
- **PayPhone** (más usado en EC, comisión ~5%)
- **DataFast** (bancos ecuatorianos)
- **Kushki** (LATAM, API moderna)

**Recomendación**: arrancar con transferencia bancaria manual hasta tener 5+ asociaciones, después integrar PayPhone.

---

## Estado actual del proyecto (al 2026-04-27)

### ✅ Implementado y funcionando

#### Walkie-talkie (Agora)
- Cloud Function `generateAgoraToken` con secrets (App Certificate fuera del cliente).
- Cliente Agora con cache de tokens, renovación automática, modo overlay PTT.
- PTT lock atómico en Firestore con timeout 35 s.
- Reglas Firestore endurecidas para `channels` y `messages` (validan transición de lock).
- App Check temporalmente desactivado en cliente (deps removidas).

#### Multi-tenancy
- Modelo `AssociationModel`, `PricingTierModel`, `UserModel` con `associationId` y `status`.
- Cloud Functions: `validateAssociationCode`, `approveDriver`, `rejectDriver`, `transferAdmin`, `setUserStatus`, `createAssociation`, `seedDefaults`, `migrateToMultitenant`.
- Reglas Firestore para `associations/` y `pricingTiers/`.

#### Panel super-admin (`/super`)
- Acceso por email `brealpeaymara@gmail.com`.
- Sembrado inicial (4 tiers + asociación Jipijapa).
- Migración de docs existentes a multi-tenant.
- CRUD completo de asociaciones (crear, suspender, activar, cancelar, cambiar plan, ver socios).
- CRUD completo de pricing tiers (crear, editar, ocultar/publicar, eliminar con validación de uso).

#### Gestión de socios (`/members`)
- Lista filtrable y buscable.
- Aprobar / rechazar pendientes (con motivo).
- Suspender / reactivar.
- Transferir admin (con confirmación).
- Reutilizable para admin (su asociación) y super-admin (cualquiera).

#### Registro multi-tenant
- Sección "Tu Asociación" al inicio del registro.
- Verificación del código contra Cloud Function antes de continuar.
- Campos de vehículo/fotos solo visibles para `conductor` (operadoras los saltan).

#### White-label parcial
- Strings genéricas: "Taxis App" en lugar de "Taxi Jipijapa" en login, home, perfil, mensajes.
- `appName` configurable centralmente en `AppConstants`.

### ⏸️ Pendiente — orden de prioridad

#### 1. Trigger `syncUserClaims` no desplegado
Sincroniza `associationId` y `role` al JWT automáticamente.
- **Impacto**: hoy las reglas Firestore no pueden filtrar por `associationId` del JWT (usan fallback por email para super-admin).
- **Fix**: deploy del trigger (puede requerir IAM extra de Eventarc — ver sección de despliegue).

#### 2. Reglas Firestore multi-tenant completas
Filtrar TODAS las colecciones (`drivers`, `trips`, `payments`, `expenses`, `channels`, `messages`, `emergencies`, `taxi_stands`, etc.) por `associationId`.
- **Impacto**: hoy un usuario podría leer datos de otra asociación si conoce IDs.
- **Pre-requisito**: que `syncUserClaims` esté operativo (paso 1).

#### 3. Pantalla "Pendiente de aprobación"
Cuando un user con `status: pendingApproval` se loguea, mostrar pantalla bloqueada en lugar de la app completa.

#### 4. Theming dinámico (white-label completo)
- Cargar `associations/{aid}.theme` al login.
- Aplicar colores y logo a `MaterialApp.theme` por asociación.

#### 5. Reactivar Firebase App Check
- Habilitar API de App Check en GCP.
- Registrar app Android (Play Integrity) y iOS (DeviceCheck).
- Registrar debug tokens en Firebase Console.
- Volver a poner `firebase_app_check` en `pubspec.yaml` y descomentar `activate()` en `main.dart`.
- Cambiar `enforceAppCheck: true` en `generateAgoraToken`.

#### 6. Integración de pago (PayPhone para Ecuador)
- Integración con PayPhone API.
- Cloud Function `processSubscriptionPayment`.
- Cron job que suspende asociaciones impagas (cuando `paidUntil < now`).
- Pantalla "Suscripción vencida" en la app.

#### 7. Cloud Functions de notificaciones FCM
- Notificar admin cuando hay nuevo registro pending.
- Notificar conductor cuando le aprueban / rechazan / asignan viaje / hay emergencia.

#### 8. Optimización de costos Agora
- Idle timeout en walkie-talkie (desconectar tras 5-10 min sin actividad).
- Métricas de minutos consumidos por asociación.
- Alertas cuando se acerca al límite del plan.

#### 9. Tests
- Solo `reports` tiene tests. Faltan en auth, trips, payments, communication, emergency, super_admin, admin.

#### 10. Otros
- Chat 1:1 sin página de conversación.
- Pantalla admin: configurar canales/paradas/incentivos por asociación.
- Pantalla admin: dashboard con métricas de su asociación.
- Pantalla super-admin: dashboard global (MRR, churn, asociaciones por plan).
- Overlay PTT flotante solo Android — iOS pendiente.
- Tier limit enforcement: bloquear creación de drivers/canales si se supera el plan.
- Migración futura a LiveKit (cuando haya 5+ asociaciones).

---

## Decisiones técnicas importantes

| Decisión | Adoptado | Razón |
|---|---|---|
| 1 admin por asociación | ✓ | Simplifica auditoría. El saliente baja a `conductor` al transferir. |
| `associationId` en cada doc + custom claims | ✓ | Más flexible que subcollections, escala mejor que un proyecto Firebase por asociación. |
| Auto-registro con código + aprobación (Opción A) | ✓ | El admin solo aprueba, no escribe nada. Escalable. |
| Admin crea cuenta directa (Opción C) | ⏸️ pendiente UI | Para socios sin smartphone. |
| Stripe | ❌ | No opera en Ecuador. Cambio a PayPhone. |
| App Check enforcement | ⏸️ pausado | Hasta completar setup en consola. |
| Multi-idioma | ❌ | Solo español. |
| Theming dinámico | ⏸️ pendiente | Cada asociación con sus colores. |

---

## Comandos útiles

```bash
# Análisis estático
flutter analyze

# Tests
flutter test

# Generar iconos / splash
flutter pub run flutter_launcher_icons
flutter pub run flutter_native_splash:create

# Ver logs de Cloud Functions
firebase functions:log

# Logs de una función específica
firebase functions:log --only generateAgoraToken

# Reglas Firestore — emulador local
firebase emulators:start --only firestore

# Re-sembrar planes (desde panel super-admin: botón "Sembrar")
# o por curl:
# curl -X POST https://us-central1-taxis-f0f51.cloudfunctions.net/seedDefaults \
#   -H "Authorization: Bearer <idToken>" \
#   -d '{"data":{}}'
```

---

## Archivos sensibles (en `.gitignore`)

- `android/local.properties`, `**/local.properties` — Google Maps API key.
- `ios/Flutter/Secrets.xcconfig` — Google Maps API key.
- `.env`, `.env.*` — variables de entorno.
- `*.jks`, `*.keystore`, `*.p12`, `*.key`, `*.pem` — keystores y certificados.
- `**/service-account*.json`, `**/firebase-adminsdk*.json` — credenciales GCP.
- `functions/.runtimeconfig.json`, `functions/.secret.local` — config de Functions.
- `flutter_*.log` — logs de runtime.

### Keystore release

```
~/keystores/taxi-jipijapa-release.jks
Alias: upload
DN: CN=Byron Realpe, OU=Mobile, O=Asociacion de Taxis, L=Quito, ST=Pichincha, C=EC
```

⚠️ **Backup obligatorio**. Sin esa keystore no puedes publicar updates en Play Store.
