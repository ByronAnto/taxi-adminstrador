import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Servicio de **logging remoto** para depurar pruebas de campo SIN USB.
///
/// Captura TODO lo que pasa por `print`/`debugPrint`/el paquete `logger`
/// (vía la zona de `runZonedGuarded` en `main.dart`), más los errores no
/// atrapados (`FlutterError.onError` y `PlatformDispatcher.onError`), los
/// acumula en un buffer acotado en memoria y los envía en lotes al endpoint
/// de Oracle cada ~20s.
///
/// Diseño resiliente a falta de señal: si el POST falla (offline/timeout),
/// las líneas NO enviadas se MANTIENEN en el buffer (acotado) para reintentar
/// al reconectar. El servidor agrupa por usuario/día.
///
/// ENVÍO APAGADO POR DEFECTO (control central, NO por dispositivo):
/// el servicio SIEMPRE captura al buffer local en memoria, pero SOLO sube
/// (POST) cuando el flag central `app_config/remoteLogging` lo habilita.
/// Si está apagado, los logs se quedan en el teléfono. Esto permite activar
/// el envío "cuando algo pasa" desde un único lugar (Firestore), sin tocar
/// cada dispositivo. El flag se escucha en tiempo real (`snapshots()`) y al
/// pasar de apagado→encendido se hace un `flush()` inmediato para subir el
/// historial reciente ya acumulado en el buffer. Default seguro: si el doc
/// no existe o falla la lectura → NO se envía.
///
/// IMPORTANTE: dentro del propio envío NO se usa `capture`/`print` para
/// evitar bucles de logging.
class RemoteLogService {
  RemoteLogService._();
  static final RemoteLogService instance = RemoteLogService._();

  // ── Configuración del endpoint (interno; está bien hardcodear el token) ──
  static const String _endpoint = 'https://livekit.it-services.center/logs';
  static const String _token =
      '88852143cc951681e450b18f644cd7339658f5c4cb93e721';

  // ── Parámetros del buffer/envío ──
  /// Máximo de líneas en memoria. Si se llena, se descartan las más viejas.
  static const int _maxBufferLines = 800;

  /// Cantidad máxima de líneas por POST (para no mandar lotes gigantes tras
  /// un periodo largo sin señal).
  static const int _maxLinesPerFlush = 400;

  /// Intervalo del flush periódico.
  static const Duration _flushInterval = Duration(seconds: 20);

  /// Timeout corto del POST.
  static const Duration _httpTimeout = Duration(seconds: 8);

  static const String _kDeviceIdKey = 'remote_log_device_id';

  // ── Flag central de envío (Firestore: `app_config/remoteLogging`) ──
  /// Colección/doc del flag central. Campos esperados:
  ///   { enabled: bool, onlyUser?: string (uid), until?: Timestamp }
  static const String _configCollection = 'app_config';
  static const String _configDoc = 'remoteLogging';

  // ── Estado interno ──
  final List<String> _buffer = <String>[];
  Timer? _timer;
  bool _initialized = false;
  bool _sending = false; // evita flush concurrentes

  /// Gate de envío calculado desde el flag central. Default = false
  /// (apagado): hasta que el flag lo habilite, los logs NO se suben.
  bool _sendEnabled = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _configSub;

  /// Último doc del flag central recibido (cache). Sirve para recalcular el
  /// gate cuando cambia el usuario (el filtro `onlyUser` depende del uid).
  Map<String, dynamic>? _lastConfig;

  String _deviceId = '';
  String? _model; // modelo del dispositivo (best-effort)
  String _user = 'anon';
  String _uid = ''; // uid real (para el filtro `onlyUser` del flag central)
  String _role = 'anon';
  String _ver = '1.0.0+1'; // fallback; se sobrescribe en init() con PackageInfo

  /// Arranca el servicio: resuelve contexto (device/ver) y enciende el timer.
  /// Es idempotente y NUNCA debe romper el arranque si Oracle no responde.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Resolver deviceId estable (persistido). No reutilizamos el de
    // SingleSessionService porque ése rota en cada login.
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString(_kDeviceIdKey);
      if (id == null || id.isEmpty) {
        id = const Uuid().v4();
        await prefs.setString(_kDeviceIdKey, id);
      }
      _deviceId = id;
    } catch (_) {
      // Si SharedPreferences falla, generamos uno volátil para esta sesión.
      _deviceId = const Uuid().v4();
    }

    // Modelo del dispositivo (best-effort, sin agregar device_info_plus).
    _model = _platformLabel();

    // Versión de la app vía package_info_plus (ya es dependencia).
    try {
      final info = await PackageInfo.fromPlatform();
      _ver = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Mantener el fallback _ver.
    }

    // Suscripción en tiempo real al flag central de envío.
    _startConfigListener();

    // Timer periódico de envío en lotes (respeta `_sendEnabled`).
    _timer?.cancel();
    _timer = Timer.periodic(_flushInterval, (_) => flush());
  }

  /// Escucha `app_config/remoteLogging` en tiempo real y recalcula el gate.
  /// Default seguro: cualquier error/doc inexistente => NO enviar.
  void _startConfigListener() {
    // Cancelamos cualquier suscripción previa (muerta) y re-suscribimos.
    _configSub?.cancel();
    _configSub = null;
    try {
      _configSub = FirebaseFirestore.instance
          .collection(_configCollection)
          .doc(_configDoc)
          .snapshots()
          .listen(
        (snap) => _applyConfig(snap.data()),
        // Falla de lectura (típico: permission-denied porque la sesión aún
        // NO estaba lista al arrancar). El stream MUERE con el error, así que
        // lo re-suscribimos tras un delay: una vez autenticado, funciona.
        // Sin esto, el gate quedaba en false para siempre y NUNCA enviaba.
        onError: (_) {
          _applyConfig(null);
          _configSub?.cancel();
          _configSub = null;
          Future.delayed(const Duration(seconds: 5), () {
            if (_initialized && _configSub == null) _startConfigListener();
          });
        },
      );
    } catch (_) {
      _sendEnabled = false;
      Future.delayed(const Duration(seconds: 5), () {
        if (_initialized && _configSub == null) _startConfigListener();
      });
    }
  }

  /// Recalcula `_sendEnabled` a partir del doc del flag central.
  ///   enabled == true
  ///   && (onlyUser vacío || onlyUser == miUid)
  ///   && (until == null || now < until)
  /// Si el gate pasa de apagado→encendido, dispara un flush inmediato para
  /// subir el historial reciente ya acumulado en el buffer.
  void _applyConfig(Map<String, dynamic>? data) {
    _lastConfig = data;
    final bool prev = _sendEnabled;
    _sendEnabled = _computeEnabled(data);
    if (!prev && _sendEnabled) {
      // false → true: subir de inmediato lo que ya estaba en el buffer.
      unawaited(flush());
    }
  }

  bool _computeEnabled(Map<String, dynamic>? data) {
    if (data == null) return false; // doc inexistente => apagado
    if (data['enabled'] != true) return false;

    // onlyUser: si está presente y no vacío, SOLO ese uid envía.
    final only = data['onlyUser'];
    if (only is String && only.isNotEmpty) {
      if (only != _uid) return false;
    }

    // until: apagado automático tras esa hora.
    final until = data['until'];
    if (until is Timestamp) {
      if (!DateTime.now().isBefore(until.toDate())) return false;
    }
    return true;
  }

  /// Setea el usuario/rol tras el login (engánchalo en el listener de
  /// AuthAuthenticated en main.dart). Mientras no haya usuario va "anon".
  void setUser(String uid, String role) {
    _uid = uid;
    _user = uid.isEmpty ? 'anon' : uid;
    _role = role.isEmpty ? 'anon' : role;
    // El filtro `onlyUser` del flag depende del uid: recalcular el gate con
    // el último doc cacheado (el stream no reemite por sí solo al cambiar de
    // usuario). Reusa la misma lógica de flush inmediato si pasa a habilitado.
    _applyConfig(_lastConfig);
  }

  /// Limpia el usuario al cerrar sesión (vuelve a "anon").
  void clearUser() {
    _uid = '';
    _user = 'anon';
    _role = 'anon';
    // Si el flag estaba restringido a un uid, al salir deja de enviar.
    _applyConfig(_lastConfig);
  }

  /// Agrega una línea al buffer con timestamp HH:mm:ss. NO hace POST.
  /// Acotado: si el buffer se llena, descarta las líneas más viejas.
  void capture(String line) {
    if (line.isEmpty) return;
    final ts = _timestamp();
    _buffer.add('$ts $line');
    _trimBuffer();
  }

  /// Captura un error + stacktrace (errores no atrapados). Encola y dispara
  /// un flush inmediato para no perder el crash si la app muere enseguida.
  void captureError(Object error, StackTrace? stack) {
    final ts = _timestamp();
    _buffer.add('$ts ERROR: $error');
    if (stack != null) {
      _buffer.add(stack.toString());
    }
    _trimBuffer();
    // Flush inmediato (fire-and-forget) para no perder el crash.
    unawaited(flush());
  }

  /// Envía el lote pendiente al endpoint si hay líneas. Si el POST tiene
  /// éxito, quita del buffer las líneas enviadas; si falla, las MANTIENE
  /// (acotado) para reintentar luego.
  Future<void> flush() async {
    // Gate central: si el envío NO está habilitado por `app_config/
    // remoteLogging`, NO subimos nada — los logs se quedan en el buffer
    // local (en el teléfono). Default seguro = apagado.
    if (!_sendEnabled) return;
    if (_sending) return; // ya hay un flush en curso
    if (_buffer.isEmpty) return;

    _sending = true;
    try {
      // Tomamos una "foto" del lote a enviar (hasta _maxLinesPerFlush).
      final int count =
          _buffer.length > _maxLinesPerFlush ? _maxLinesPerFlush : _buffer.length;
      final List<String> batch = List<String>.from(_buffer.take(count));

      final body = jsonEncode(<String, dynamic>{
        'device': _model == null ? _deviceId : '$_model/$_deviceId',
        'user': _user,
        'role': _role,
        'ver': _ver,
        'lines': batch,
      });

      final resp = await http
          .post(
            Uri.parse(_endpoint),
            headers: const <String, String>{
              'Authorization': 'Bearer $_token',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(_httpTimeout);

      if (resp.statusCode == 200) {
        // Éxito: quitar SOLO las líneas que enviamos (pudieron entrar líneas
        // nuevas al buffer mientras se enviaba).
        if (count <= _buffer.length) {
          _buffer.removeRange(0, count);
        } else {
          _buffer.clear();
        }
      }
      // Si no es 200, dejamos el buffer intacto para reintentar en el próximo
      // ciclo. No registramos nada (evitar bucles de logging).
    } catch (_) {
      // Offline/timeout/error de red → mantenemos el buffer para reintentar.
      // NO usar capture/print aquí (evita bucles).
    } finally {
      _sending = false;
    }
  }

  // ── Helpers internos ──

  void _trimBuffer() {
    final int excess = _buffer.length - _maxBufferLines;
    if (excess > 0) {
      _buffer.removeRange(0, excess);
    }
  }

  String _timestamp() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  String _platformLabel() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isLinux) return 'linux';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
    } catch (_) {}
    return 'unknown';
  }
}
