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
          _updateStatus(ConnectivityStatus.disconnected);
        } else {
          // Tiene red, pero ¿tiene internet real?
          await _verifyInternetAccess();
        }
      },
    );

    // Verificación periódica cada 15 segundos (detecta intermitencia)
    _periodicCheck = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _checkConnectivity(),
    );
  }

  /// Verificación completa: red + internet real.
  Future<void> _checkConnectivity() async {
    try {
      final results = await _connectivity.checkConnectivity();
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);

      if (!hasNetwork) {
        _updateStatus(ConnectivityStatus.disconnected);
        return;
      }

      await _verifyInternetAccess();
    } catch (e) {
      _logger.w('Error verificando conectividad: $e');
      _updateStatus(ConnectivityStatus.disconnected);
    }
  }

  /// Verifica internet REAL haciendo una petición HTTP.
  ///
  /// DNS puede estar cacheado y responder "ok" incluso sin datos.
  /// Por eso hacemos un HTTP HEAD a un servidor rápido y ligero.
  Future<void> _verifyInternetAccess() async {
    try {
      // Primero DNS rápido (descarta caso obvio sin red)
      final dns = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 3));
      if (dns.isEmpty || dns[0].rawAddress.isEmpty) {
        _updateStatus(ConnectivityStatus.disconnected);
        return;
      }

      // Luego HTTP real — si esto responde, hay internet de verdad
      final response = await http
          .head(Uri.parse('https://www.google.com/generate_204'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode >= 200 && response.statusCode < 400) {
        _updateStatus(ConnectivityStatus.connected);
      } else {
        _updateStatus(ConnectivityStatus.disconnected);
      }
    } on SocketException catch (_) {
      _updateStatus(ConnectivityStatus.disconnected);
    } on TimeoutException catch (_) {
      _updateStatus(ConnectivityStatus.disconnected);
    } on http.ClientException catch (_) {
      _updateStatus(ConnectivityStatus.disconnected);
    } catch (_) {
      _updateStatus(ConnectivityStatus.disconnected);
    }
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
