# PROMPT MAESTRO — Cierre del proyecto Taxis App

> **Para revisión de Byron antes de arrancar autónomo.** Este documento es el
> contrato de trabajo: lo que hay que terminar, en qué orden, con qué criterios
> de "hecho", y qué decisiones necesito de ti antes de tocar código.

---

## 0. Contexto heredado (no rehacer)

- **App**: `taxi_jipijapa` (Flutter + Firebase + Agora). SaaS multi-tenant para
  asociaciones de taxis en Ecuador.
- **Stack**: Flutter 3.11, Firebase (Auth/Firestore/Functions Node 22 2nd Gen/
  Messaging/Storage), Agora RTC, GoRouter, BLoC + GetIt/Injectable.
- **Multi-tenancy**: campo `associationId` en cada doc Firestore.
  `associations/{slug}` con `theme.{primaryColor, secondaryColor, accentColor, logoUrl}`.
- **Roles definidos hoy**: `superAdmin` (Byron), `admin` (1 por asociación),
  `operadora`, `conductor`. Custom claims sincronizados por trigger
  `syncUserClaims`.
- **Walkie-talkie**: ya tiene toggle ON/OFF persistente (sesión 2026-05-07).
  Ver `docs/superpowers/specs/` y `lib/core/services/radio_power_service.dart`.
- **Pricing tiers**: en `pricingTiers/{id}` editables desde panel super-admin.
  No hardcoded. Defaults: trial, basic \$49, pro \$129, enterprise \$249.
- **Pasarela de pago**: Stripe NO opera en Ecuador. Por ahora transferencia
  bancaria manual con comprobante. Alternativas evaluadas: PayPhone,
  DataFast, Kushki.

---

## 1. Alcance completo agrupado por dominio

Re-organicé tus 13 puntos en 7 dominios para que features que comparten
infraestructura se diseñen juntas y no haya retrabajo.

### Dominio A — Identidad y roles (puntos 1, 8, 13 parcial)

A.1. Validar que los 4 perfiles ya existentes (super-admin, admin, operadora,
conductor) están consistentes en: (a) custom claims, (b) reglas Firestore,
(c) navegación de la app, (d) registro de nuevos usuarios.

A.2. Estado del conductor — máquina de estados en `users/{uid}.status`:
- `active` (default)
- `paymentPending` (plan vencido, sin acción)
- `paymentBlocked` (mora confirmada, app en modo "solo pago")
- `disabledByAdmin` (admin lo desactivó)

A.3. **(Decisión D-1 abajo)** Cliente final: ¿perfil nuevo en la app o portal
web Next.js separado?

### Dominio B — Suscripción y bloqueo (puntos 2, 3, 8)

B.1. Caducidad de planes:
- Cloud Function programada (cron diario 00:00 ECU) que recorre
  `associations/{aid}.subscription.expiresAt` y marca como vencido.
- Al vencer: marca `subscription.status = expired` y todos los conductores
  de esa asociación pasan a `paymentPending` (no bloqueados aún —
  período de gracia configurable, default 3 días).

B.2. Bloqueo por mora:
- Si `paymentPending` + dueDate + grace < hoy → `paymentBlocked`.
- App detecta el estado al iniciar y al recibir custom claim refresh.
- Si `paymentBlocked`: el router solo permite acceso a una pantalla
  **"Cuenta bloqueada"** con: detalle de pago pendiente + formulario para
  subir comprobante (ya existe `PaymentProof` en el modelo).
- Admin valida el comprobante → estado vuelve a `active`.

B.3. Desactivación por admin:
- Admin desde `users_management` puede pasar conductor a `disabledByAdmin`
  con motivo opcional.
- Mismo bloqueo de UI que `paymentBlocked` pero el conductor NO puede subir
  pago — solo ve mensaje "Contacta a tu administrador".

### Dominio C — Operación de viajes (puntos 4, 5, 11, 13 parcial)

C.1. Modelo único `trips/{tripId}` (multi-tenant) usado por TODOS los
reportes. Campos:
```
{
  associationId, driverId, driverName,
  operadoraId? (si fue asignado),
  clienteId? clienteNombre? telefono?,
  origen { lat, lng, address },
  destino? { lat, lng, address },
  estado: 'solicitado'|'asignado'|'enRuta'|'finalizado'|'cancelado',
  monto?, metodoPago?,
  inicio, fin?, duracionMin?,
  source: 'walkieTalkie'|'apkOperadora'|'webCliente'|'manual',
  associationId, createdAt, updatedAt
}
```

C.2. Botón **"+1 carrera"** del conductor (1 click, sin formulario):
- Auto-rellena `driverId`, hora, ubicación actual GPS.
- Crea `trips/{id}` con `estado=finalizado`, `source=manual`.
- Permite editar después si quiere agregar monto/destino.

C.3. **Operadora asigna carrera** (en el modal del walkie-talkie, solo para
perfil operadora):
- Botón "Asignar carrera" abre modal con: conductor (dropdown de online),
  cliente (nombre + teléfono opcional), origen.
- Crea `trips/{id}` con `source=apkOperadora`, `estado=asignado`.
- Push notification al conductor (FCM) + mensaje en su walkie.
- Métrica: `operadora_metrics/{operadoraId}/{yyyy-mm-dd}`: contador de
  viajes asignados por día.

C.4. Reporte para conductor (1-click):
- Pantalla "Mis carreras" con: hoy, semana, mes (tabs).
- Total de carreras + monto.
- Listado simple, exportable a PDF (ver Dominio E).

C.5. Mapa estilo Uber (tiempo real):
- Hoy `driver_location_service` ya escribe periódicamente.
  **Validar la frecuencia** y el costo de Firestore reads.
- Suscripción a `users` filtrado por `associationId` + `isAvailable=true` +
  `status=active`.
- UI: marker animado con interpolación (Tween) entre updates para parecer
  fluido.
- **(Decisión D-4)** Frecuencia y backend (Firestore vs RTDB).

### Dominio D — Estado y ubicación (puntos 9, 10)

D.1. **Switch GENERAL activo/inactivo** (separado del switch del radio):
- Vive en `users/{uid}.isAvailable` (bool, default true).
- ON: la app envía ubicación + aparece en el mapa para los demás.
- OFF: la app DEJA de enviar ubicación; deja de aparecer en el mapa;
  no recibe asignaciones.
- **Es independiente del toggle del radio** (que hicimos anoche): puedes
  estar disponible (GPS ON) con el radio apagado, o radio encendido sin
  estar disponible.
- UI: un solo switch grande en la AppBar / drawer, visible siempre.

D.2. Comportamiento por defecto:
- Conductor recién logueado → `isAvailable = true`.
- Si cierra la app o pierde conexión por más de N minutos
  (default 10) → marcar como `lastSeen + offline` para que el mapa lo
  ataje, pero NO cambiar `isAvailable` automáticamente.

### Dominio E — Contabilidad y reportes (puntos 6, 7)

E.1. Modelo de movimiento contable `cashflow/{id}` (multi-tenant):
```
{
  associationId,
  tipo: 'ingreso'|'egreso',
  categoria: string,                 // configurable por asociación
  subcategoria?: string,
  monto: number,
  fecha: timestamp,
  metodoPago?: 'efectivo'|'transferencia'|'deposito',
  beneficiario?: string,             // operadora, proveedor, etc.
  descripcion?: string,
  comprobanteUrl?: string,
  createdBy: string,                 // userId del admin que registró
  createdAt: timestamp
}
```

E.2. Categorías configurables — `associations/{aid}.cashflowCategories`:
```
{
  ingresos: ['cuotas', 'multas', 'recargas', ...],   // editable
  egresos:  ['operadoras', 'mantenimiento', ...]      // editable
}
```
Plantilla base que el super-admin define + extensible por cada admin.

E.3. Pantalla **"Caja"** del admin:
- Tab "Resumen": ingresos del día/semana/mes, egresos, balance.
- Tab "Movimientos": lista filtrable + botón "+ Ingreso" / "+ Egreso".
- Tab "Pagos a operadoras": acceso rápido (es la categoría más usada).

E.4. **Análisis contable / reportes**:
- Períodos: día, semana, mes, trimestre, semestre, año.
- Agregaciones precomputadas en `analytics/{aid}/{period}/{date}` por
  Cloud Function (cron) para no pegarle a Firestore en cada vista.
- Charts en la app (sparkline + barras).

E.5. **Exportable** Excel + PDF:
- PDF: A4, márgenes 2.5 cm, encabezado con logo + nombre asociación
  (toma de `associations/{aid}.theme.logoUrl`).
- Excel: una hoja por período, formato ec-ES.
- Librerías Flutter: `pdf` + `printing` para PDF; `excel` o
  `syncfusion_flutter_xlsio` para Excel.

E.6. Branding configurable:
- Pantalla super-admin → editar `theme` por asociación: logo (upload),
  primaryColor, secondaryColor, accentColor.
- Theming dinámico: `MaterialTheme` se reconstruye desde `theme` al
  loguear. (Pendiente confirmar — ver memoria del proyecto).

### Dominio F — Notificaciones y eventos (punto 12)

F.1. Notificaciones manuales del admin:
- Pantalla admin "Notificaciones" → crear notificación con:
  título, cuerpo, audiencia (todos | solo conductores | solo operadoras),
  programada (now | datetime).
- Backend: Cloud Function consume `notifications/{id}` con
  `status=scheduled` cuando llega su `scheduledAt` y dispara FCM.
- App: pantalla "Notificaciones" con historial.

F.2. Eventos de Quito (aglomeración):
- Cloud Function programada (diario, 06:00) llama a Gemini API
  (`gemini-2.5` con web-search tool use) preguntando:
  "¿Qué eventos públicos masivos hay hoy en Quito? (conciertos, partidos,
  teatros, marchas, festivales). Devolver JSON con: nombre, lugar, hora,
  tipo, lat/lng aproximados, asistencia esperada."
- Guarda en `eventsQuito/{yyyy-mm-dd}` (público entre asociaciones).
- App: tab "Eventos" en notificaciones, con mapa de calor opcional.
- **(Decisión D-3)** Confirmar fuente de IA (Gemini API requiere clave
  + presupuesto).

### Dominio G — Portal cliente (punto 13)

**(Decisión D-1)** Dos opciones:

**Opción G-A**: Perfil "cliente" en la app actual.
- Pros: una sola APK, infraestructura compartida.
- Contras: la app es pesada (343MB debug); el cliente no necesita Agora,
  GPS broadcast, etc.

**Opción G-B**: Web separada (Next.js + Firebase web SDK).
- Pros: link compartible, funciona en cualquier dispositivo, ligera.
- Contras: requiere desarrollo separado y nuevo deploy (Vercel/Firebase
  Hosting).

**Recomendación**: G-B (web separada) porque la asistencia esperada del
cliente es ocasional, mientras que conductores/operadoras usan la app
8h/día.

Modelo común para ambas opciones — `tripRequests/{id}`:
```
{
  associationId,           // del cliente que registra
  clienteId, clienteNombre, clienteTelefono,
  origen { lat, lng, address },
  destino? { lat, lng, address },
  cuandoSolicitado: timestamp,
  paraCuando: timestamp,    // immediata o programada
  estado: 'pendiente'|'asignada'|'rechazada'|'cumplida',
  asignadoA?: driverId,
  notas?: string
}
```

La operadora ve la lista en su panel y la asigna.

---

## 2. Decisiones que necesito de ti antes de empezar

| # | Decisión | Recomendación | Espera tu OK |
|---|----------|---------------|--------------|
| D-1 | Cliente: app o web | **Web Next.js separada** (carpeta `client_web/` en este repo) | si, aqui mismo |
| D-2 | Caducidad: cron + client-side | **Ambos** (cron diario + chequeo al abrir app) | ambos |
| D-3 | Eventos Quito: fuente IA | **Gemini 2.5 con web-search tool**. Cuesta ~\$0.01/día | ok, esta bien |
| D-4 | Mapa real-time backend | **Mantener Firestore** con throttle a 5s/update; migrar a RTDB solo si los costos suben | mantener firestores me dejas un analsisi de costos profa y lo que deberiamos migrar de ser el caso |
| D-5 | Categorías cashflow editables | **Plantilla base + cada admin agrega** | si |
| D-6 | Conductor bloqueado puede subir comprobante | **Sí**, esa es la única acción permitida | si |
| D-7 | Período de gracia tras vencer plan | **3 días** antes de bloquear | no, se bloquea el dia que se acaba |
| D-8 | Notificaciones FCM: programadas | **Sí**, con `scheduledAt` y cron de despacho | ok |
| D-9 | Branding: ¿theming dinámico ya funciona? | **Validar** antes de tocar; si no, implementar | dinamico |

> Marca con ☑ las que apruebas, o escríbeme la alternativa que prefieras.

---

## 3. Orden de implementación (fases)

Cada fase termina con: tests + APK debug + commit + actualización de
PROGRESS.md. No avanzo a la siguiente sin esos 4 pasos.

| Fase | Dominio | Por qué primero | Estimado |
|------|---------|-----------------|----------|
| **0** | A.1 (validación) + D.1, D.2 (switch general) | Bloquea todo: mapa, asignación de carreras, reportes dependen de saber quién está activo | 1 sesión |
| **1** | B (suscripción y bloqueo) | Es el core monetario; todo lo demás se construye sobre conductores activos | 2 sesiones |
| **2** | C.1, C.2, C.3 (modelo trips + +1 carrera + asignación operadora) | Es el corazón operativo del día a día | 2 sesiones |
| **3** | C.4 (reportes conductor) + C.5 (mapa Uber) | Da visibilidad al usuario final, depende del modelo `trips` y de `isAvailable` | 2 sesiones |
| **4** | E (contabilidad + reportes admin + branding) | Cierra el ciclo administrativo | 2 sesiones |
| **5** | F (notificaciones + eventos Quito) | Mejora UX, no bloqueante | 1 sesión |
| **6** | G (portal cliente) | Crecimiento — solo si las fases anteriores están sólidas | 2 sesiones |

**Total estimado**: 12 sesiones autónomas, ~3 semanas si trabajamos a
ritmo de 2-3 sesiones por semana.

---

## 4. Definition of Done (DoD) por feature

Una feature solo se considera terminada si cumple TODOS estos puntos:

- [ ] Compila: `flutter analyze` sin errores nuevos en archivos tocados.
- [ ] Build APK debug exit 0.
- [ ] Reglas Firestore actualizadas si hay nuevas colecciones.
- [ ] Funciona offline-friendly cuando aplica (Firestore offline cache).
- [ ] Multi-tenant: filtrado por `associationId` en queries y reglas.
- [ ] UI responde a los 4 estados del conductor (active / pending / blocked / disabled).
- [ ] No rompe el toggle del radio (tests manuales del walkie-talkie).
- [ ] Commit con mensaje descriptivo (Conventional Commits) + co-author.
- [ ] PROGRESS.md actualizado: qué cambió, cómo probarlo, issues que quedan.

---

## 5. Notas técnicas / referencias rápidas

- **Custom claims**: tras cualquier cambio de rol o estado, llamar
  `getIdToken(true)` en el cliente para refrescar.
- **Firestore Rules**: validar PTT lock con `request.time +
  serverTimestamp`. Cliente usa `FieldValue.serverTimestamp()`.
- **Costos críticos**:
  - Agora ~\$0.99/1000 user-min (revisar en cada feature que use audio).
  - Firestore reads: usar `.snapshots()` con `where` específico, paginar
    siempre.
  - Cloud Functions cron: gratis hasta 2M invocaciones/mes (suficiente).
- **Permisos sensibles**: cualquier acción que cambie estado del usuario
  requiere ser admin de la asociación o super-admin.
- **Logs y monitoreo**: usar `package:logger` con tags (ya existe).
- **i18n**: la app está en español hardcoded. NO refactorizar a i18n a
  menos que se pida explícitamente.

---

## 6. Cómo voy a trabajar autónomo

1. Leo este documento + memoria del proyecto al inicio de cada sesión.
2. Tomo la siguiente fase no terminada del cuadro de la sección 3.
3. Antes de tocar código:
   - Documento decisiones pendientes en PROGRESS.md.
   - Si encuentro una decisión nueva sin tu input, **uso la opción
     conservadora** (la menos invasiva) y la marco para que la revises.
4. Trabajo en commits pequeños con conventional commits
   (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`).
5. NO uso `git push` (lo hacés vos cuando estés conforme).
6. NO toco hooks de pre-commit ni `--no-verify`.
7. Al cierre de cada sesión: actualizo PROGRESS.md con (a) lo hecho,
   (b) commits, (c) cómo probar, (d) próxima fase, (e) decisiones
   pendientes.
8. Si encuentro un bug crítico fuera del scope de la fase, lo arreglo y
   commiteo aparte con `fix:` y lo dejo señalado en PROGRESS.

---

## 7. Cosas que NO voy a hacer sin tu permiso explícito

- Borrar archivos / colecciones existentes.
- `git push` o crear PRs en GitHub.
- Cambiar `pricingTiers` o cobros activos.
- Borrar conductores o asociaciones reales.
- Tocar `firestore.rules` sin tener tests previos.
- Activar funcionalidades en producción (todo en debug primero).

---

## 8. Lo que necesito de ti AHORA para arrancar

1. Leer este documento.
2. Marcar las decisiones D-1 a D-9 (sección 2).
3. Decirme si el orden de fases (sección 3) te sirve o si quieres otro.
4. Avisarme cuando esté listo: **"go fase 0"** o el que prefieras.

Una vez con tu OK, arranco autónomo siguiendo este contrato.
