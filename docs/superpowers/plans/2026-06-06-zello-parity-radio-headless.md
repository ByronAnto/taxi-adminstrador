# Paridad Zello — Radio headless en isolate del FGS · Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el radio (escuchar + transmitir con el flotante PTT) siga vivo aunque el usuario cierre/mate la app, moviendo la conexión LiveKit del isolate principal al isolate del Foreground Service.

**Architecture:** La conexión LiveKit (hoy en el isolate principal, muere al cerrar la app) pasa a vivir en el `TaskHandler` del FGS (`flutter_foreground_task`), que sobrevive al swipe. La UI se vuelve un cliente delgado que controla/observa por mensajes inter-isolate. No se cachea el FlutterEngine de la actividad (el mapa no se rompe).

**Tech Stack:** Flutter, `flutter_foreground_task` 8.10, `livekit_client` 2.5.4, `flutter_webrtc`, Kotlin (overlay nativo), Firestore.

**Spec:** `docs/superpowers/specs/2026-06-06-zello-parity-radio-headless-design.md`

**Hallazgo base (verificado en `radio_foreground_service.dart`):** hoy `_RadioTaskHandler` (isolate FGS) solo reenvía el tick de GPS; LiveKit + Firestore corren en el isolate PRINCIPAL. Por eso el radio sobrevive a background (proceso vivo) pero NO a swipe (actividad+isolate principal destruidos).

---

## ⚠️ Estrategia de planificación por incertidumbre

Este es un cambio nativo/isolate de alto riesgo. **La Fase 0 (spike) está totalmente detallada** porque es la acción inmediata y de-riesga la suposición central. Las **Fases 1–7 están como roadmap estructurado** (file structure + tareas + estrategia de test): sus pasos bite-sized con código exacto se finalizan **inmediatamente después del spike**, porque su resultado decide isolate (enfoque A) vs 2º FlutterEngine (enfoque B), lo que cambia las tareas nativas. Escribir ese código ahora sería adivinar.

---

## FASE 0 — Spike: ¿LiveKit corre dentro del isolate del FGS? (1 día, throwaway)

**Objetivo:** confirmar (o refutar) que `livekit_client` puede conectar, recibir audio y publicar mic **desde el `TaskHandler` del FGS**, sobreviviendo al swipe, sin romper el mapa. Es exploración: el código se **descarta** y se reimplementa con TDD en Fase 1+.

**Rama:** `spike/livekit-in-fgs-isolate` (desde `main`). NO mezclar con el código de producción.

**Archivos (solo del spike, a borrar después):**
- Modify (temporal): `lib/core/services/radio_foreground_service.dart` (`_RadioTaskHandler`)
- Create (temporal): `lib/spike/livekit_isolate_spike.dart`

- [ ] **Paso 1: Rama de spike**

Run:
```bash
cd ~/Repositorios/taxis && git checkout main && git checkout -b spike/livekit-in-fgs-isolate
```
Expected: "Cambiado a nueva rama 'spike/livekit-in-fgs-isolate'".

- [ ] **Paso 2: Registrar plugins en el isolate del FGS**

En `_radioTaskCallback` (top-level, `@pragma('vm:entry-point')`), antes de `setTaskHandler`, los plugins del isolate de background los registra `flutter_foreground_task` automáticamente al declarar el callback como entry-point. Verificar en `onStart` del handler que `WidgetsFlutterBinding.ensureInitialized()` corre y que `livekit_client` se puede importar sin error de registro de plugin. Añadir log remoto para evidencia.

- [ ] **Paso 3: Conectar LiveKit desde `onStart` del TaskHandler**

En el `_RadioTaskHandler.onStart`, crear una `lk.Room`, conectar a un canal de prueba (URL `wss://livekit.it-services.center`, token de prueba hardcodeado SOLO en el spike), suscribir audio remoto, forzar `AndroidAudioConfiguration.media`. Loguear cada paso vía `FlutterForegroundTask.sendDataToMain` (el isolate FGS no tiene el logger remoto del main; mandar strings al main para que el main los suba a `/logs`).

- [ ] **Paso 4: Probar en dispositivo real — escuchar en background**

Run (build + instalar en la PDA conectada):
```bash
flutter run --release
```
Acción manual: encender radio → hablar desde otro dispositivo en el mismo canal → confirmar audio. Mantener app en foreground.
Expected: se escucha; logs en `/logs` muestran `conectado` + `track suscrito`.

- [ ] **Paso 5: Probar swipe (la prueba clave)**

Acción manual: cerrar la app con swipe (apps recientes). Desde otro dispositivo, hablar en el canal.
Verificar por logs remotos (`sshoracle:/home/ubuntu/applogs/{uid}-{fecha}.log`):
Expected: (a) el isolate FGS sigue logueando, (b) sigue conectado a LiveKit, (c) se escucha el audio con la app cerrada.

- [ ] **Paso 6: Probar mic libre + reabrir (mapa)**

Acción manual: con la app cerrada, abrir grabadora de voz de Android → confirmar que graba (mic libre). Reabrir la app → confirmar que el **mapa de Google se ve** (no en blanco) y que NO hay `duplicateIdentity` en logs.
Expected: mic libre cuando no transmites; mapa OK; sin doble identidad.

- [ ] **Paso 7: Decisión gate (documentar resultado)**

Escribir el resultado en `docs/superpowers/specs/2026-06-06-zello-parity-radio-headless-design.md` (sección "Resultado spike"):
- ✅ Todo verde → continuar Fase 1 (enfoque A, este plan).
- ⚠️ LiveKit NO corre en el isolate → pivotear a enfoque B (2º FlutterEngine); re-planificar fases nativas.
- ⚠️ Mapa se rompe / doble identidad → ajustar diseño antes de Fase 1.

- [ ] **Paso 8: Borrar el spike**

Run:
```bash
git checkout main && git branch -D spike/livekit-in-fgs-isolate
```
El aprendizaje queda en el spec; el código se descarta (se reimplementa con TDD).

---

## FASE 1 — Protocolo de mensajes inter-isolate (TDD)

**Por qué primero:** es la columna vertebral testeable; UI↔handler se comunican por mensajes serializables (el isolate no comparte objetos Dart).

**Files:**
- Create: `lib/core/services/voice/radio_ipc.dart` (enums + (de)serialización)
- Test: `test/core/services/voice/radio_ipc_test.dart`

**Unidades:**
- `RadioCommand` (enum: `connect`, `disconnect`, `pttDown`, `pttUp`, `setChannel`) + payload (channelId, channelName, token).
- `RadioState` (enum: `idle`, `connecting`, `connected`, `speaking`, `receiving`, `reconnecting`, `error`) + payload (speakerName, errorMsg).
- `encodeCommand/decodeCommand`, `encodeState/decodeState` a `Map<String,dynamic>` (lo que viaja por `sendDataToTask`/`sendDataToMain`).

**Tareas (TDD, bite-sized):** test de round-trip de cada comando/estado (encode→decode == original); test de mensaje desconocido → ignorado (no excepción, para convivir con el `_kLocationTickSignal` del GPS). Implementar mínimo. Commit por unidad.

**Estrategia de test:** unitaria pura (sin Firestore ni LiveKit). Alta cobertura aquí porque es la frontera crítica.

---

## FASE 2 — `RadioTaskHandler` con LiveKit (isolate FGS)

**Files:**
- Modify: `lib/core/services/radio_foreground_service.dart` (`_RadioTaskHandler` deja de ser mínimo)
- Reuse: `lib/core/services/voice/livekit_voice_provider.dart` (instanciado DENTRO del handler)
- Test: `test/core/services/voice/radio_task_handler_test.dart` (lógica de estados con un `VoiceProvider` falso)

**Responsabilidad:** dueño único de la conexión LiveKit (R1). Procesa comandos vía `onReceiveData`, emite estado vía `sendDataToMain`. Idempotente (R3: doble `connect` al mismo canal = no-op).

**Tareas:**
- Auditar `LiveKitVoiceProvider`: que NO dependa de `BuildContext`/widgets ni del `resume` para R4/R5 (re-forzar altavoz/volumen por eventos LiveKit + `onRepeatEvent`, no por lifecycle de UI).
- Inyectar un `VoiceProvider` en `RadioTaskHandler` para testear la máquina de estados con un fake (TDD): `connect` idempotente, `pttDown`→mic on, `pttUp`→mic off (R4), `setChannel`=disconnect+connect secuencial, `disconnect` limpio.
- Mantener el tick de GPS existente (`onRepeatEvent` → `_kLocationTickSignal`) intacto.

**Estrategia de test:** unitaria con `VoiceProvider` fake (mocktail) para la máquina de estados; LiveKit real solo en pruebas de campo.

---

## FASE 3 — `RadioController` (cliente en el isolate UI) (TDD)

**Files:**
- Create: `lib/core/services/voice/radio_controller.dart`
- Test: `test/core/services/voice/radio_controller_test.dart`
- Modify: `lib/features/communication/.../walkie_talkie_page.dart` (usa el controller, no LiveKit directo)

**Responsabilidad:** API delgada para la UI. Envía comandos (`sendDataToTask`) y expone el estado del handler como `ValueListenable`/stream para pintar la pantalla. Al reabrir la app, se re-suscribe SIN reconectar (R1).

**Tareas (TDD):** test de que `connect()` envía el comando correcto; test de que un `RadioState` entrante actualiza el listenable; test de re-suscripción sin emitir `connect`. Implementar. Migrar `walkie_talkie_page` a consumir el controller.

---

## FASE 4 — `RadioPowerService`: ON/OFF y FGS compartido (TDD)

**Files:**
- Modify: `lib/core/services/radio_power_service.dart`
- Modify: `lib/core/widgets/availability_toggle.dart` (OFF general)
- Test: `test/core/services/radio_power_service_test.dart`

**Responsabilidad / reglas:**
- `turnOn` → arranca FGS (si no corre) + `RadioController.connect`.
- `turnOff` (OFF radio) → `RadioController.disconnect` + quitar overlay + **NO** detener el FGS si el GPS sigue activo (`RadioForegroundService.stopService` ya reconcilia: verificar que `_radioActive=false` no mate el servicio si `_locationActive=true`).
- OFF general (`availability_toggle`) → `goOffline()` + `turnOff()`.

**Tareas (TDD):** test "OFF radio con GPS activo → FGS sigue corriendo"; test "OFF radio con GPS inactivo → FGS se detiene"; test "OFF general apaga ambos". Usar fakes de `RadioForegroundService`/`RadioController`.

---

## FASE 5 — Overlay nativo → isolate del FGS (Kotlin)

**Files (leer en implementación, finalizar tras spike):**
- Modify: `android/.../MainActivity.kt`, `PttBridge.kt`, `OverlayPttService.kt`

**Responsabilidad:** el PTT del flotante debe llegar al **isolate del FGS** (no a la actividad, que con la app cerrada no existe). Hoy `PttBridge` usa el MethodChannel del engine de la actividad.

**Enfoque:** `OverlayPttService.kt` (evento PTT) → enviar al servicio del FGS → reenviar al isolate Dart vía `FlutterForegroundTask.sendDataToTask` equivalente nativo (o un `BroadcastReceiver`/binder al servicio del FGS). El handler Dart traduce a `pttDown`/`pttUp`. Mantener R2 (no cachear el engine de la actividad).

**Tareas:** mapear el flujo actual del overlay leyendo los 3 archivos; re-enrutar el canal PTT al servicio del FGS; manejar el caso app-cerrada (sin actividad). Pruebas: solo de campo (overlay es nativo + visual).

**Nota:** este es el bloque con más riesgo nativo; su detalle exacto depende del resultado del spike (A vs B).

---

## FASE 6 — Audio headless: R4 (mic libre) y R5 (altavoz/volumen) sin `resume`

**Files:**
- Modify: `lib/core/services/voice/livekit_voice_provider.dart`

**Responsabilidad:** garantizar que el re-forzado de altavoz/volumen y la liberación de mic funcionen con la app cerrada (sin eventos de lifecycle de UI). Disparar re-forzado por eventos de LiveKit (`reconnected`) y por el `onRepeatEvent` del FGS.

**Tareas:** identificar y eliminar dependencias de `AppLifecycleState.resumed` en el path de audio; mover el re-force a un método invocable desde el handler/tick. Pruebas: campo (R4 grabar en otra app; R5 botones de volumen con app cerrada).

---

## FASE 7 — Feature flag + rollout canary

**Files:**
- Modify: punto de arranque del radio (donde se elige headless vs actual)
- Config: `app_config/{flag}` en Firestore (patrón canary existente)

**Responsabilidad:** habilitar el motor-radio-headless por asociación/usuario; fallback al comportamiento actual sin recompilar.

**Tareas:** leer flag de Firestore; si OFF → comportamiento actual (radio en main isolate); si ON → headless. Probar en 1–2 conductores, validar checklist de campo, ampliar.

---

## Checklist de pruebas de campo (Fases 5–7, manual)

- [ ] Escuchar con app abierta
- [ ] Escuchar con app en background
- [ ] **Escuchar con app cerrada (swipe)**
- [ ] **Transmitir con flotante, app cerrada**
- [ ] Mic libre: grabar en otra app mientras escuchas (R4)
- [ ] Audio por altavoz + botones de volumen, app cerrada (R5)
- [ ] OFF radio con GPS activo → sigue en el mapa, radio apagado
- [ ] OFF general → todo apagado, mic 100% libre
- [ ] Reconexión tras avión ON/OFF
- [ ] Matar desde "apps recientes" → sigue / se relevanta (isSticky)
- [ ] Reabrir app → mapa intacto (R2), audio sin corte (R1)

---

## Notas de ejecución

- TDD estricto en Fases 1–4 (lógica determinista). Fases 5–6 son device-dependent → pruebas de campo con checklist + logs remotos.
- Commits frecuentes, mensajes en español, sin emojis (convención del repo).
- Tras Fase 0, **re-detallar Fases 1–7 con pasos bite-sized y código exacto** según el resultado del spike (enfoque A confirmado vs pivote a B).
