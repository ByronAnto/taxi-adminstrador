import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

/// Estado de conectividad de la app.
enum ConnectivityStatus {
  /// Conectado a internet (WiFi, datos móviles, etc.)
  connected,

  /// Sin conexión a internet
  disconnected,
}

/// Servicio singleton que monitorea la conectividad a internet.
///
/// Usa `connectivity_plus` para detectar cambios de red y verifica
/// con un lookup DNS real para confirmar que hay internet efectivo.
class ConnectivityService extends ChangeNotifier {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  final Connectivity _connectivity = Connectivity();
  final Logger _logger = Logger();

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  ConnectivityStatus _status = ConnectivityStatus.connected;
  Timer? _periodicCheck;

  /// Nº de probes de internet fallidos seguidos. En datos móviles un timeout
  /// puntual (radio despertando, congestión, TLS lento) es normal y NO debe
  /// cortar el radio. Solo declaramos "sin red" tras 2 fallos consecutivos;
  /// un único éxito lo resetea a 0.
  int _failedProbes = 0;

  ConnectivityStatus get status => _status;
  bool get isConnected => _status == ConnectivityStatus.connected;

  /// Inicia el monitoreo de conectividad.
  Future<void> initialize() async {
    // Verificación inicial
    await _checkConnectivity();

    // Escuchar cambios de red
    _subscription = _connectivity.onConnectivityChanged.listen(
      (results) async {
        final hasNetwork = results.any((r) => r != ConnectivityResult.none);

        if (!hasNetwork) {
          // El SO dice que NO hay interfaz de red → offline definitivo.
          _failedProbes = 0;
          _updateStatus(ConnectivityStatus.disconnected);
        } else {
          // Tiene red, pero ¿tiene internet real?
          await _verifyInternetAccess();
        }
      },
    );

    // Verificación periódica cada 10 segundos (detecta intermitencia y
    // recupera rápido tras un falso negativo en datos móviles).
    _periodicCheck = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkConnectivity(),
    );
  }

  /// Verificación completa: red + internet real.
  Future<void> _checkConnectivity() async {
    try {
      final results = await _connectivity.checkConnectivity();
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);

      if (!hasNetwork) {
        // Sin interfaz de red → offline definitivo (sin debounce).
        _failedProbes = 0;
        _updateStatus(ConnectivityStatus.disconnected);
        return;
      }

      await _verifyInternetAccess();
    } catch (e) {
      _logger.w('Error verificando conectividad: $e');
      _registerProbeFailure();
    }
  }

  /// Verifica internet REAL. El SO ya confirmó que hay interfaz de red; este
  /// probe confirma que hay salida a internet.
  ///
  /// Con debounce: un probe exitoso restaura "conectado" al instante; un
  /// fallo NO corta el radio de inmediato (ver [_registerProbeFailure]).
  Future<void> _verifyInternetAccess() async {
    if (await _probeInternet()) {
      _failedProbes = 0;
      _updateStatus(ConnectivityStatus.connected);
    } else {
      _registerProbeFailure();
    }
  }

  /// Hace el probe HTTP al endpoint canónico de detección de internet con
  /// fallback. HTTPS porque Android (targetSdk 36) bloquea cleartext por
  /// defecto. 204/2xx/3xx = internet OK.
  Future<bool> _probeInternet() async {
    const endpoints = [
      'https://connectivitycheck.gstatic.com/generate_204',
      'https://clients3.google.com/generate_204',
    ];
    for (final url in endpoints) {
      try {
        final r = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 8));
        if (r.statusCode >= 200 && r.statusCode < 400) return true;
      } on SocketException catch (_) {
        // probar siguiente endpoint
      } on TimeoutException catch (_) {
        // probar siguiente endpoint
      } on http.ClientException catch (_) {
        // probar siguiente endpoint
      } catch (_) {
        // probar siguiente endpoint
      }
    }
    return false;
  }

  /// Registra un fallo de probe. Solo declara "sin red" tras 2 fallos
  /// CONSECUTIVOS — así un timeout puntual en datos móviles no deshabilita
  /// el radio. Si aún no llega al umbral, mantiene el estado actual (optimista).
  void _registerProbeFailure() {
    _failedProbes++;
    if (_failedProbes >= 2) {
      _updateStatus(ConnectivityStatus.disconnected);
    }
    // Primer fallo: mantenemos el estado actual (no cortamos el radio aún).
  }

  void _updateStatus(ConnectivityStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      _logger.i(
        newStatus == ConnectivityStatus.connected
            ? '🟢 Conexión a internet restaurada'
            : '🔴 Sin conexión a internet',
      );
      notifyListeners();
    }
  }

  /// Fuerza una re-verificación (ej. cuando el usuario pulsa "reintentar").
  Future<void> retry() async => _checkConnectivity();

  @override
  void dispose() {
    _subscription?.cancel();
    _periodicCheck?.cancel();
    super.dispose();
  }
}
