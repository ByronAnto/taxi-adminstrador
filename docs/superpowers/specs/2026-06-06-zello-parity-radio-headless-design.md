# Spec — Paridad Zello: radio que sobrevive al cierre de la app

- **Fecha:** 2026-06-06
- **Proyecto:** taxi_jipijapa (Flutter + Firebase, radio PTT sobre LiveKit)
- **Estado:** Diseño aprobado, pendiente plan de implementación
- **Branch del spec:** `docs/zello-parity-radio`

## 1. Problema

Cuando el conductor **cierra la app con swipe** (o el sistema la mata al "limpiar
apps llenas"), el radio **se rompe**: deja de escuchar el canal y el botón
flotante PTT queda visible pero no transmite.

Causa raíz (verificada en sesiones previas): la conexión de voz y el canal del
overlay (`com.taxijipijapa/overlay`, MethodChannel en `MainActivity.kt`) están
atados al **FlutterEngine de la actividad**. Al cerrar la app, la actividad se
destruye → el engine y el canal mueren → el radio cae.

El intento de atajo (cachear el FlutterEngine principal) **rompe el PlatformView
de Google Maps** (mapa en blanco); se probó en build 4100 y se revirtió (4101).

## 2. Objetivo (paridad Zello completa)

Mientras el radio esté encendido, el conductor debe poder **escuchar el canal y
transmitir con el botón flotante AUNQUE la app esté cerrada**. Solo se apaga
cuando se apaga el radio (o el switch general). Equivalente a Zello.

### No-objetivos (fuera de alcance de este spec)
- Migración de SDK: **todo es LiveKit** (Agora queda como legado muerto; su
  remoción es trabajo aparte).
- Rediseño visual del flotante o de la pantalla del walkie.
- Apertura de UDP 7882 en Oracle (pendiente operativo aparte, mejora cold-start).

## 3. Reglas duras (invariantes)

- **R1 — Una sola conexión:** la conexión LiveKit vive SIEMPRE en un único lugar
  (el isolate del Foreground Service). Nunca dos motores conectados con la misma
  identidad (evita `duplicateIdentity`). La UI solo controla/observa.
- **R2 — No romper el mapa:** NO se cachea el FlutterEngine de la actividad. El
  motor de UI (con el `google_maps_flutter` PlatformView) sigue atado a la
  actividad de forma estándar.
- **R3 — Solo OFF apaga:** lo único que apaga el radio es el **OFF del radio**
  (`RadioPowerService.turnOff`) o el **OFF general** ("Activo"). Ni el swipe, ni
  Doze, ni perder señal, ni reabrir la app lo apagan (a lo sumo reconectan).
- **R4 — Mic libre:** conectado o escuchando, el micrófono NUNCA está tomado.
  Solo se captura entre `pttDown` y `pttUp`. (Hoy `LiveKitVoiceProvider` lo logra
  con `setMicrophoneEnabled(true)` una vez para negociar y `false` inmediato;
  PTT alterna true/false). Romper esto es bug bloqueante.
- **R5 — Audio:** siempre por **altavoz**, stream **multimedia**
  (`AndroidAudioConfiguration.media`, STREAM_MUSIC) → los botones físicos de
  volumen lo controlan; con boost de ganancia persistido (slider 100–400 →
  x1.0–x4.0). El re-forzado de altavoz/volumen NO debe depender del `resume` de
  la pantalla (que no ocurre con la app cerrada); debe colgar de eventos de
  LiveKit + el tick del FGS.

## 4. Enfoque elegido

**Isolate del Foreground Service** (`flutter_foreground_task`). El radio (conexión
LiveKit + PTT + audio) corre dentro del isolate del FGS, que es lo que Android
mantiene vivo con la notificación persistente y sobrevive al swipe. Descartados:
2º FlutterEngine headless (mucho más Kotlin) y radio 100% nativo (enorme).

> El FGS es **compartido**: ya hospeda el latido de GPS (`RadioForegroundService`
> + `onRepeatEvent` → `nativeHeartbeatPulse`). El radio se suma al MISMO isolate.

## 5. Arquitectura

```
┌─────────────────────────────┐   mensajes   ┌──────────────────────────────────┐
│  MOTOR UI (actividad)       │  comando/    │  ISOLATE DEL FOREGROUND SERVICE   │
│  - Pantalla walkie + Mapa   │   estado     │  (vivo por notif. persistente;    │
│  - RadioController (cliente) │ ◄──────────► │   sobrevive al swipe)             │
│    NO tiene la conexión      │              │  - RadioTaskHandler               │
└─────────────────────────────┘              │    · LiveKitVoiceProvider (ÚNICA) │
            ▲ eventos PTT                     │    · audio altavoz / mic en PTT   │
┌───────────┴────────────┐                    │    · GPS heartbeat (ya existe)    │
│ Overlay flotante (PTT)  │ ───────────────►  └──────────────────────────────────┘
│ OverlayPttService.kt    │   al isolate
└─────────────────────────┘
```

## 6. Componentes y responsabilidades

| # | Componente | Dónde | Responsabilidad | Estado |
|---|-----------|-------|-----------------|--------|
| 1 | `RadioTaskHandler` | Isolate FGS | Dueño único de la conexión LiveKit. Procesa comandos (`connect`, `disconnect`, `pttDown`, `pttUp`, `setChannel`) y publica estado (`conectado`, `hablando`, `recibiendo`, `reconectando`, `error`). Idempotente. | nuevo |
| 2 | `RadioController` | Motor UI | Cliente delgado: la pantalla y el `RadioPowerService` hablan con esto. Envía comandos al handler y escucha estado para pintar UI. | nuevo (absorbe parte de overlay/power) |
| 3 | Protocolo de mensajes | ambos | Enums comando/estado serializables sobre `FlutterForegroundTask.sendDataToTask` ↔ `addTaskDataCallback`. Convive con los mensajes de GPS ya existentes. | extender |
| 4 | Puente del overlay | Nativo (Kotlin) | `OverlayPttService.kt` + `PttBridge.kt` re-enrutados para que el PTT del flotante llegue al **isolate del FGS**, no a la actividad. | modificar |
| 5 | `LiveKitVoiceProvider` | Isolate FGS | Se reutiliza tal cual; ahora se instancia dentro del handler. Auditar que no dependa de `BuildContext`/widgets ni del `resume` para R4/R5. | reusar/auditar |
| 6 | `RadioPowerService` | Motor UI | Switch ON/OFF del radio. OFF = `disconnect` + quitar overlay + liberar mic, **sin** matar el FGS si el GPS sigue activo. | ajustar |

**Frontera limpia:** la UI nunca toca LiveKit directo; solo manda comandos y
pinta estado. Eso permite que el radio siga vivo sin UI (app cerrada) y hace cada
pieza testeable por separado.

## 7. Flujo de datos

**A. Encender radio (app abierta):** `RadioController` → arranca FGS → isolate
crea `RadioTaskHandler` → conecta LiveKit al canal de la asociación → estado
`conectado` → UI pinta "En el canal". Ya escucha.

**B. Cierre con swipe:** Android destruye la actividad (UI + mapa). El FGS y su
isolate NO mueren. La conexión vive en el isolate → sigue escuchando. El flotante
queda visible.

**C. Hablar con el flotante (app cerrada) — núcleo:** mantener presionado →
`OverlayPttService.kt` captura → `PttBridge.kt` envía **al isolate** → handler
`pttDown` → `setMicrophoneEnabled(true)` → transmite. Soltar → `pttUp` →
`setMicrophoneEnabled(false)` → mic libre.

**D. Apagar:**
- *OFF radio:* `RadioPowerService.turnOff` → comando `disconnect` → LiveKit
  desconecta limpio + quita overlay + libera mic. **FGS sigue** si el GPS está
  activo.
- *OFF general ("Activo"):* `goOffline()` (GPS) + `disconnect` (radio). Si nada
  más usa el FGS → se detiene → muere el isolate → mic 100% libre.

**Borde — reabrir con radio vivo:** la UI renace y el `RadioController` se
**re-suscribe** al estado del handler que ya estaba corriendo. No reconecta
LiveKit (R1) → sin corte de audio, sin doble identidad.

## 8. Errores y ciclo de vida

| Situación | Manejo |
|---|---|
| Pierde señal / reconecta | Handler escucha eventos LiveKit → reconexión con backoff; re-fuerza altavoz/volumen (R5) |
| Android mata el FGS | `isSticky` + restart; notificación persistente + tipo `microphone`; pedir excluir de optimización de batería |
| Permiso overlay revocado | Validar `SYSTEM_ALERT_WINDOW` al encender; abrir ajustes (`openSystemAlertWindowSettings`) |
| Permiso mic revocado | Handler captura fallo de publish → estado `error`; escuchar sigue |
| Doble arranque | Handler idempotente: si ya hay conexión al mismo canal, ignora |
| Cambio de canal | `setChannel` = `disconnect` y `connect` secuenciales (nunca solapados) |
| Doze / batería | El radio vive en el FGS (wakelock), no en timers de Dart → inmune |

## 9. Pruebas

**Unitarias (TDD):** serialización del protocolo comando/estado; máquina de
estados del handler (connect/ptt/disconnect idempotentes); regla "OFF radio no
mata el FGS si el GPS sigue activo".

**Manuales de campo (checklist):** los 4 escenarios (abrir / swipe / PTT cerrado
/ OFF); **R4 mic libre** (grabar en otra app mientras escuchas); **R5 altavoz +
botones de volumen**; reconexión (avión ON/OFF); matar desde "apps recientes";
reabrir sin corte de audio; mapa intacto al reabrir (R2).

## 10. Rollout seguro

Detrás de un **flag por asociación** (patrón canary/shadow ya usado en el
proyecto): habilitar el motor-radio-headless primero en 1–2 conductores, validar
en campo, luego ampliar. Si falla, el flag revierte al comportamiento actual sin
recompilar.

## 11. Fase 0 — Spike (antes de construir)

**Riesgo bloqueante:** que `livekit_client` (WebRTC) funcione dentro del isolate
de `flutter_foreground_task` con sus plugins registrados.

**Spike (~1 día):** arrancar el FGS isolate → conectar a un canal LiveKit de
prueba → reproducir audio → **cerrar app con swipe** → verificar por logs
remotos: (a) sigue conectado, (b) sigue escuchando, (c) mic libre, (d) mapa OK al
reabrir. Si funciona → plan completo. Si no → pivotear a 2º FlutterEngine
(enfoque B), mismo diseño lógico.

## 12. Archivos clave a tocar

- `lib/core/services/radio_foreground_service.dart` (host del isolate)
- `lib/core/services/overlay_ptt_service.dart` → parte migra a `RadioController`
- `lib/core/services/radio_power_service.dart` (ON/OFF, no matar FGS si GPS sigue)
- `lib/core/services/voice/livekit_voice_provider.dart` (auditar headless: R4/R5)
- `lib/features/communication/.../walkie_talkie_page.dart` (usar `RadioController`)
- `android/.../MainActivity.kt`, `PttBridge.kt`, `OverlayPttService.kt` (overlay → isolate)
- Nuevos: `RadioTaskHandler`, `RadioController`, protocolo de mensajes.

## 13. Dependencias / pendientes relacionados

- Operativo: abrir **UDP 7882** en el Security List de Oracle (cold-start <1s).
- Memoria relacionada: `taxis-zello-parity-radio-engine`, `taxis-radio-field-fixes`,
  `taxis-fcm-notifications`.
