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

  bool _isOn = false;
  bool _initialized = false;

  bool get isOn => _isOn;
  bool get isOff => !_isOn;
  bool get isInitialized => _initialized;

  /// Carga el último estado persistido. Llamar al iniciar la app
  /// (idealmente desde main()).
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _isOn = prefs.getBool(_prefsKey) ?? false;
    } catch (_) {
      _isOn = false;
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> turnOn() async {
    if (_isOn) return;
    _isOn = true;
    await _persist();
    notifyListeners();
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

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, _isOn);
    } catch (_) {
      // Si falla la persistencia no rompemos la UI;
      // se reintenta en el próximo cambio.
    }
  }
}
