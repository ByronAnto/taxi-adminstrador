import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'current_user_context.dart';

/// Servicio singleton que controla si el walkie-talkie está encendido (ON)
/// o apagado (OFF).
///
/// Cuando OFF: la app NO inicializa Agora, NO se une a canales, NO arranca el
/// foreground service de "microphone", y por tanto el sistema operativo libera
/// el micrófono al 100% para que otras apps (Zello, WhatsApp, grabadora) lo
/// puedan usar.
///
/// Cuando ON: el comportamiento normal del walkie-talkie (escucha, PTT, etc).
///
/// El estado se persiste en SharedPreferences. Por defecto: OFF (más
/// conservador — el conductor decide cuándo encenderlo).
class RadioPowerService extends ChangeNotifier {
  RadioPowerService._();
  static final RadioPowerService instance = RadioPowerService._();

  static const String _prefsKey = 'radio.power.isOn';
  static const String _prefsLastChannelId = 'radio.power.lastChannelId';
  static const String _prefsLastChannelName = 'radio.power.lastChannelName';
  // uid del conductor que dejó el radio encendido. Se usa para restaurar el
  // estado ON SOLO si reabre el mismo usuario (no heredar entre conductores).
  static const String _prefsOwnerUid = 'radio.power.ownerUid';

  bool _isOn = false;
  bool _initialized = false;
  String? _lastChannelId;
  String? _lastChannelName;

  bool get isOn => _isOn;
  bool get isOff => !_isOn;
  bool get isInitialized => _initialized;

  /// Último canal con el que el radio estuvo activo (persistido).
  /// Sirve para reanudar la conexión a Agora tras un cold-start si el
  /// usuario había dejado el radio encendido.
  String? get lastChannelId => _lastChannelId;
  String? get lastChannelName => _lastChannelName;

  /// Carga el estado persistido. Solo recuerda `lastChannelId` y
  /// `lastChannelName` (memoria del último canal usado), pero NO
  /// restaura `isOn=true` automáticamente: el conductor debe tocar el
  /// switch para encender.
  ///
  /// Decisión arquitectónica: el auto-resume agresivo causaba que al
  /// reabrir la app un conductor que cerró su sesión "Desconectado"
  /// se encontrara con el radio prendido y enviando audio sin haberlo
  /// pedido. Mejor que la app arranque OFF; cuando enciende, ya
  /// conectamos al `lastChannelId` recordado para que sea un solo tap.
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _lastChannelId = prefs.getString(_prefsLastChannelId);
      _lastChannelName = prefs.getString(_prefsLastChannelName);
    } catch (_) {
      // ignorar — sin canal recordado, el user lo elige al encender
    }
    _isOn = false;
    _initialized = true;
    notifyListeners();
  }

  /// Restaura el estado ON del radio tras login — comportamiento Zello: si el
  /// conductor dejó el radio encendido y cerró/min la app, al reabrir vuelve
  /// a quedar encendido y reconecta solo al último canal.
  ///
  /// SEGURIDAD: solo restaura ON si el `uid` actual coincide con el que dejó
  /// el radio encendido (evita que otro conductor en el mismo equipo herede
  /// el radio prendido — el bug que motivó arrancar siempre en OFF). El
  /// reconnect al canal lo hace el walkie cuando este estado queda ON.
  Future<void> restoreForUser(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final persistedOn = prefs.getBool(_prefsKey) ?? false;
      final owner = prefs.getString(_prefsOwnerUid);
      final shouldRestore = persistedOn && uid.isNotEmpty && owner == uid;
      if (shouldRestore != _isOn) {
        _isOn = shouldRestore;
        notifyListeners();
      } else {
        _isOn = shouldRestore;
      }
    } catch (_) {
      // sin restauración — queda OFF
    }
  }

  /// Enciende el radio. [channelId] y [channelName] se persisten para
  /// poder reanudar la conexión tras kill del isolate Flutter.
  Future<void> turnOn({String? channelId, String? channelName}) async {
    final wasOn = _isOn;
    _isOn = true;
    if (channelId != null) _lastChannelId = channelId;
    if (channelName != null) _lastChannelName = channelName;
    await _persist();
    if (!wasOn || channelId != null || channelName != null) {
      notifyListeners();
    }
  }

  Future<void> turnOff() async {
    if (!_isOn) return;
    _isOn = false;
    await _persist();
    notifyListeners();
  }

  Future<void> toggle() async {
    if (_isOn) {
      await turnOff();
    } else {
      await turnOn();
    }
  }

  /// Actualiza solo el canal recordado, sin cambiar el estado on/off.
  /// Útil cuando el usuario cambia de canal con el radio ya encendido.
  Future<void> setLastChannel(String channelId, String? channelName) async {
    if (_lastChannelId == channelId && _lastChannelName == channelName) return;
    _lastChannelId = channelId;
    _lastChannelName = channelName;
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, _isOn);
      // Guardar el dueño del estado (para restoreForUser). Si está ON, el
      // dueño es el usuario actual; al apagar conservamos el último dueño.
      final uid = CurrentUserContext.instance.uid;
      if (_isOn && uid != null && uid.isNotEmpty) {
        await prefs.setString(_prefsOwnerUid, uid);
      }
      if (_lastChannelId != null) {
        await prefs.setString(_prefsLastChannelId, _lastChannelId!);
      } else {
        await prefs.remove(_prefsLastChannelId);
      }
      if (_lastChannelName != null) {
        await prefs.setString(_prefsLastChannelName, _lastChannelName!);
      } else {
        await prefs.remove(_prefsLastChannelName);
      }
    } catch (_) {
      // Si falla la persistencia no rompemos la UI;
      // se reintenta en el próximo cambio.
    }
  }
}
