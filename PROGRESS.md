# Avances de la sesión — Walkie-Talkie fix (autónomo)

**Fecha:** 2026-05-06
**Modo:** Autónomo. Byron descansa, revisa mañana.

---

## Diagnóstico

### Bug raíz: el mic queda ocupado bloqueando otras apps
- **Causa principal**: `AndroidManifest.xml` declara el foreground service `com.pravera.flutter_foreground_task.service.ForegroundService` con `android:foregroundServiceType="microphone|mediaPlayback"`. Cuando este servicio arranca (al seleccionar canal), Android marca al sistema "esta app usa el micrófono" — incluso si Agora ya liberó el hardware con `enableLocalAudio(false)`. Apps como Zello/WhatsApp ven el mic ocupado.
- **Causa secundaria**: al entrar a la pestaña del radio, automáticamente se inicializa Agora, se une a un canal y arranca el foreground service. No hay control explícito.

### Lo que pidió el usuario
1. Botón ON/OFF para activar/desactivar el walkie-talkie.
2. Selector de canal funcional.
3. Que el mic quede libre cuando el radio no está activo.

### Decisiones tomadas autónomamente
- **OFF = totalmente desconectado**: libera mic 100%, detiene foreground service, sale del canal Agora, destruye el engine.
- **Default**: OFF al abrir la app por primera vez. Luego se persiste el último estado en SharedPreferences.
- **Selector de canal**: visible siempre, pero solo se conecta a Agora cuando el toggle está en ON.
- **Foreground service tipo "microphone"**: solo se mantiene cuando el radio está ON. Cuando OFF, se detiene completamente para liberar el "tag" de mic.

---

## Estado de implementación

- [x] git init y baseline (pendiente — bloqueado por gitleaks pre-commit)
- [ ] .gitleaksignore para Firebase API keys (no son secretos reales)
- [ ] PROGRESS.md (este archivo)
- [ ] Implementar `RadioPowerService` con SharedPreferences
- [ ] Refactor `walkie_talkie_page.dart`: sólo conectar Agora si ON
- [ ] Verificar análisis con flutter analyze
- [ ] Compilar APK debug y verificar
- [ ] Commits incrementales (uno por etapa)

---

## Siguientes pasos si se acaban tokens

1. Continuar leyendo desde aquí — todos los TodoWrite del agente están sincronizados con esta lista.
2. El `agora_service.dart` y `walkie_talkie_page.dart` ya están leídos completos. No es necesario re-explorar.
3. Empezar por el `.gitleaksignore` para desbloquear los commits.
