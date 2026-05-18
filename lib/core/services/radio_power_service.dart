import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
