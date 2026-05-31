import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../constants/app_constants.dart';
import 'radio_foreground_service.dart';

/// Servicio global de ubicación del conductor.
///
/// Gestiona el GPS y push a Firestore independiente de la página de mapa.
/// - **Online** → GPS activo, status visible, operadora ve ubicación.
/// - **Offline** → GPS parado, status = desconectado.
///
/// Se inicializa tras login del conductor y persiste mientras la app vive.
///
/// Extiende [ChangeNotifier] para que otros módulos (walkie-talkie, etc.)
/// puedan suscribirse a cambios de online/offline.
class DriverLocationService extends ChangeNotifier {
  DriverLocationService._();
  static final DriverLocationService instance = DriverLocationService._();

  String? _driverId;
  String? _userId;
  bool _isOnline = false;
  bool _initialized = false;
  String _currentStatus = AppConstants.statusOffline;
  StreamSubscription<Position>? _positionSub;
  Timer? _heartbeatTimer;
  DateTime? _lastPush;
  DateTime? _lastFixAt;
  double? _lastLatitude;
  double? _lastLongitude;
  double? _lastAccuracy;

  /// Umbrales de calidad del fix.
  ///
  /// - [_maxAcceptableAccuracyMeters]: descarta fixes con error > 50 m.
  ///   Típicamente solo pasan los GPS reales o WiFi-based de buena calidad.
  ///   En interior sin GPS, el sistema reporta accuracy 80-200 m via
  ///   torres celulares — esos no nos sirven y ensucian el mapa.
  /// - [_jitterDistanceMeters]: si llega un fix que dice "te moviste 200 m
  ///   en 5 s" sin velocidad real, es jitter de la combinación GPS+cell.
  static const double _maxAcceptableAccuracyMeters = 50;
  static const double _jitterDistanceMeters = 200;
  static const Duration _jitterMaxAge = Duration(seconds: 5);

  /// Heartbeat: aunque el conductor esté quieto, refresca el doc cada
  /// 60 s para que la operadora vea "updatedAt" reciente y no piense
  /// que la app del conductor murió.
  static const Duration _heartbeatInterval = Duration(seconds: 60);

  /// True cuando la app del conductor está en background. El GPS sigue
  /// mandando (necesario para que la operadora siga viendo la unidad)
  /// pero a frecuencia más baja para ahorrar datos celulares: la
  /// operadora no necesita precisión de 10 s sobre un conductor que
  /// solo tiene la app dormida.
  bool _isBackgrounded = false;
  static const int _backgroundPushSeconds = 30;

  // ─── State machine: STATIONARY mode ───
  //
  // Si el conductor lleva 5 min sin moverse >100 m del anchor, asumimos
  // que está parado (en una parada, almorzando, casa, etc.). Entonces:
  //   - Cancelamos el position stream (el chip GPS deja de gastar batería).
  //   - Subimos el heartbeat de 60 s a 5 min.
  //   - No pusheamos nada salvo el heartbeat.
  // Cuando un heartbeat detecta un fix a >100 m del anchor, asumimos
  // que el conductor se movió → exit STATIONARY: reactivar stream +
  // heartbeat normal.
  //
  // Ahorro estimado: ~80% adicional en background para conductores
  // parados (típico en parada de cooperativa esperando radio).
  bool _isStationary = false;
  double? _stationaryAnchorLat;
  double? _stationaryAnchorLng;
  DateTime? _stationaryAnchorAt;
  static const double _stationaryRadiusMeters = 100;
  static const Duration _stationaryThreshold = Duration(minutes: 5);
  // 2 min: DEBE ser menor que el umbral del cron de presencia
  // (markStaleDriversOffline = 6 min) para que un conductor quieto/estacionado
  // NO sea marcado offline por falso "stale". Antes 5 min, que con el cron a
  // 3 min apagaba a los conductores parados aunque la app siguiera viva.
  static const Duration _stationaryHeartbeatInterval =
      Duration(minutes: 2);

  /// ¿Está el conductor en línea?
  bool get isOnline => _isOnline;

  /// True una vez que [initialize] resolvió (o intentó resolver) el driver
  /// doc. Mientras es false, todavía no sabemos el estado real online/offline
  /// del conductor — los consumidores (walkie-talkie) NO deben asumir
  /// "Desconectado" en esta ventana, o bloquearían el radio por una carrera
  /// de arranque (especialmente con datos móviles lentos).
  bool get isInitialized => _initialized;

  /// ID del documento driver en Firestore (null si no hay driver doc).
  String? get driverId => _driverId;

  /// Estado actual del conductor.
  String get currentStatus => _currentStatus;

  /// Última coordenada conocida.
  double? get lastLatitude => _lastLatitude;
  double? get lastLongitude => _lastLongitude;

  /// Última precisión conocida (radio en metros).
  double? get lastAccuracy => _lastAccuracy;

  /// Llamar cuando la app cambia de estado de ciclo de vida. En
  /// background subimos el throttle de 10 s a 30 s — sigue habiendo
  /// ubicación pero ~3x menos datos. La operadora ve "updatedAt" más
  /// espaciado pero la unidad no desaparece.
  void setAppBackgrounded(bool backgrounded) {
    if (_isBackgrounded == backgrounded) return;
    _isBackgrounded = backgrounded;
    debugPrint(
        '📍 [LocationService] App ${backgrounded ? "background" : "foreground"} — '
        'push cada ${backgrounded ? _backgroundPushSeconds : AppConstants.locationUpdateSeconds}s');
  }

  final _firestore = FirebaseFirestore.instance;

  // ─── Inicialización ──────────────────────────────────────

  /// Inicializa para un conductor autenticado.
  /// Busca el driver doc, sincroniza datos denormalizados y pone online.
  Future<void> initialize({
    required String userId,
    String? associationId,
    String? displayName,
    String? vehicleNumber,
    String? plate,
  }) async {
    // Si ya está inicializado para el mismo usuario, no repetir
    if (_driverId != null && _userId == userId && _isOnline) return;
    _userId = userId;

    try {
      final snapshot = await _firestore
          .collection(AppConstants.driversCollection)
          .where('userId', isEqualTo: userId)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        debugPrint(
            '📍 [LocationService] No driver doc para userId=$userId → creando…');
        // Auto-crear el documento de driver para este conductor
        final now = Timestamp.fromDate(DateTime.now());
        final newDocRef =
            _firestore.collection(AppConstants.driversCollection).doc();
        await newDocRef.set({
          'userId': userId,
          'associationId': associationId ?? '',
          'licenseNumber': '',
          'licenseType': '',
          'licenseExpiry': now,
          'status': AppConstants.statusFree,
          'currentLatitude': null,
          'currentLongitude': null,
          'rating': 5.0,
          'totalTrips': 0,
          'totalPoints': 0,
          'vehicleIds': <String>[],
          'activeVehicleId': null,
          'isActive': true,
          'createdAt': now,
          'updatedAt': now,
          'vehicleNumber': vehicleNumber ?? '',
          'plate': plate ?? '',
          'driverName': displayName ?? '',
        });
        _driverId = newDocRef.id;
        debugPrint(
            '📍 [LocationService] Driver doc CREADO → $_driverId');
      } else {
        _driverId = snapshot.docs.first.id;
        debugPrint('📍 [LocationService] Driver ID: $_driverId');
      }

      // Sincronizar campos denormalizados (nombre, placa, nro. vehículo).
      // associationId se rellena en docs viejos que no lo tenían (migración soft).
      final updates = <String, dynamic>{};
      if (vehicleNumber != null && vehicleNumber.isNotEmpty) {
        updates['vehicleNumber'] = vehicleNumber;
      }
      if (plate != null && plate.isNotEmpty) {
        updates['plate'] = plate;
      }
      if (displayName != null && displayName.isNotEmpty) {
        updates['driverName'] = displayName;
      }
      if (associationId != null && associationId.isNotEmpty) {
        updates['associationId'] = associationId;
      }
      if (updates.isNotEmpty) {
        await _firestore
            .collection(AppConstants.driversCollection)
            .doc(_driverId!)
            .update(updates);
        debugPrint('📍 [LocationService] Datos denormalizados: $updates');
      }

      // Auto-poner online en cada cold-start. Un conductor cuyo usuario
      // está activo (status='active' en su doc users/) debe SIEMPRE
      // aparecer en el mapa de la operadora cuando abre la app — no
      // esperarlo a tocar "Conectar". El toggle in-session sigue
      // funcionando para que el conductor pueda apagar GPS durante el
      // día si lo decide, pero no sobrevive a un cierre/abrir de app.
      await goOnline();
    } catch (e) {
      debugPrint('📍 [LocationService] Error initialize: $e');
    } finally {
      // Marcamos "inicializado" pase lo que pase: aunque la query a
      // Firestore haya fallado (datos móviles lentos en el Pixel), el
      // walkie-talkie necesita saber que ya intentamos resolver el estado
      // para dejar de mostrar "Modo Desconectado" de forma especulativa.
      // notifyListeners() despierta a los suscriptores (walkie page) para
      // que recalculen sus flags con el estado final.
      _initialized = true;
      notifyListeners();
    }
  }

  // ─── Online / Offline ────────────────────────────────────

  /// Reintenta resolver `_driverId` a partir de `_userId` cuando la query
  /// inicial de `initialize()` falló (red lenta/intermitente). No CREA el
  /// doc — eso lo hace `initialize()` con los datos denormalizados. Solo
  /// recupera el id de un doc existente para poder ponerse online.
  Future<void> _resolveDriverIdIfNeeded() async {
    if (_driverId != null || _userId == null) return;
    try {
      final snapshot = await _firestore
          .collection(AppConstants.driversCollection)
          .where('userId', isEqualTo: _userId)
          .limit(1)
          .get();
      if (snapshot.docs.isNotEmpty) {
        _driverId = snapshot.docs.first.id;
        debugPrint(
            '📍 [LocationService] Driver ID re-resuelto: $_driverId');
      }
    } catch (e) {
      debugPrint('📍 [LocationService] Error re-resolviendo driverId: $e');
    }
  }

  /// Pone al conductor EN LÍNEA: actualiza status y arranca GPS.
  Future<void> goOnline({String? status}) async {
    // Si el driver doc aún no se resolvió (p. ej. la query de Firestore en
    // initialize() falló por datos móviles lentos en el Pixel), intentamos
    // re-resolverlo aquí en vez de abortar silenciosamente. Sin esto,
    // _isOnline quedaba en false para siempre y el walkie mostraba "Modo
    // Desconectado" aunque el conductor SÍ estuviera disponible.
    if (_driverId == null) {
      await _resolveDriverIdIfNeeded();
      if (_driverId == null) return; // sin red / sin usuario: no podemos
    }
    _isOnline = true;
    _currentStatus = status ?? AppConstants.statusFree;

    try {
      await _firestore
          .collection(AppConstants.driversCollection)
          .doc(_driverId!)
          .update({
        'status': _currentStatus,
        'isActive': true,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });
    } catch (e) {
      debugPrint('📍 [LocationService] Error goOnline: $e');
    }

    await _requestPermissionAndStartGps();
    // Foreground service (tipo location) → mantiene el GPS vivo en background:
    // mientras "Activo General" esté ON, la unidad NUNCA deja de enviar
    // ubicación (admin/operadora siempre la ven). Comparte FGS con el radio.
    await RadioForegroundService.instance.setLocationTracking(true);
    notifyListeners();
    debugPrint(
        '📍 [LocationService] ✅ ONLINE → status=$_currentStatus, GPS activo');
  }

  /// Pone al conductor FUERA DE LÍNEA: para GPS, marca desconectado.
  ///
  /// Si [hardOffline] es true (caso logout/dispose), también marca
  /// `isActive=false` y limpia la última ubicación, para que la operadora
  /// NO siga viendo al conductor en el mapa con su última posición.
  Future<void> goOffline({bool hardOffline = false}) async {
    if (_driverId == null) return;
    _isOnline = false;
    _currentStatus = AppConstants.statusOffline;
    _stopGps();
    // Soltar el FGS por ubicación (si el radio tampoco lo usa, se apaga).
    RadioForegroundService.instance.setLocationTracking(false);

    try {
      final update = <String, dynamic>{
        'status': AppConstants.statusOffline,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      };
      if (hardOffline) {
        update['isActive'] = false;
        update['currentLatitude'] = null;
        update['currentLongitude'] = null;
        update['inQueueAt'] = null;
      }
      await _firestore
          .collection(AppConstants.driversCollection)
          .doc(_driverId!)
          .update(update);
    } catch (e) {
      debugPrint('📍 [LocationService] Error goOffline: $e');
    }

    notifyListeners();
    debugPrint('📍 [LocationService] ⛔ OFFLINE → GPS detenido');
  }

  /// Cambia el estado del conductor.
  /// Si es [statusOffline] → pasa a offline (para GPS).
  /// Si es cualquier otro estado → garantiza online + GPS activo.
  Future<void> updateStatus(String status) async {
    if (_driverId == null) return;

    if (status == AppConstants.statusOffline) {
      await goOffline();
      return;
    }

    _currentStatus = status;

    if (!_isOnline) {
      // Si estaba offline y pide un status online → encender todo
      await goOnline(status: status);
    } else {
      // Ya online → solo actualizar el status en Firestore
      try {
        await _firestore
            .collection(AppConstants.driversCollection)
            .doc(_driverId!)
            .update({
          'status': status,
          'updatedAt': Timestamp.fromDate(DateTime.now()),
        });
        debugPrint('📍 [LocationService] status → $status');
      } catch (e) {
        debugPrint('📍 [LocationService] Error updateStatus: $e');
      }
    }
  }

  /// Revive el pipeline de GPS si el SO lo mató en background.
  ///
  /// En background, Android (Doze/throttling de FGS) puede cancelar el
  /// position stream y/o congelar los timers del heartbeat: el conductor
  /// "desaparece" del mapa de la operadora a los pocos minutos. Este método,
  /// llamado al volver a foreground (`AppLifecycleState.resumed`), detecta si
  /// el pipeline murió y lo rearranca.
  ///
  /// Idempotente y barato: si el conductor no está online no hace nada; si todo
  /// el pipeline sigue vivo, tampoco toca nada.
  Future<void> ensureAlive() async {
    if (!_isOnline || _driverId == null) return;

    // Re-asegurar el FGS (tipo location) por si el SO lo tumbó. setLocationTracking
    // es idempotente (no relanza si ya está activo) y la guarda anti-crash vive
    // dentro del FGS.
    await RadioForegroundService.instance.setLocationTracking(true);

    if (_isStationary) {
      // En modo estacionario solo hay un heartbeat (el stream está cancelado a
      // propósito). Si Doze mató ese timer, el conductor deja de reportar incluso
      // su pulso → lo rearmamos. No reactivamos el stream completo aquí (eso lo
      // hará _onFix si detecta movimiento); rearmamos el heartbeat estacionario y
      // forzamos un pulso inmediato para refrescar `updatedAt`.
      if (_heartbeatTimer == null || !_heartbeatTimer!.isActive) {
        debugPrint('📍 [LocationService] ensureAlive: heartbeat estacionario '
            'muerto → rearmando');
        _heartbeatTimer = Timer.periodic(_stationaryHeartbeatInterval, (_) {
          _doStationaryHeartbeat();
        });
      }
      // Pulso inmediato al volver de background (no esperar al próximo tick).
      unawaited(_doStationaryHeartbeat());
      return;
    }

    // Modo ACTIVE: el stream o el heartbeat pueden haber muerto. Si cualquiera
    // de los dos no está vivo, rearrancamos TODO el pipeline (_startGps cancela
    // y recrea ambos + pide un fix inmediato).
    final streamDead = _positionSub == null;
    final heartbeatDead = _heartbeatTimer == null || !_heartbeatTimer!.isActive;
    if (streamDead || heartbeatDead) {
      debugPrint('📍 [LocationService] ensureAlive: pipeline GPS muerto '
          '(stream=${streamDead ? "muerto" : "vivo"}, '
          'heartbeat=${heartbeatDead ? "muerto" : "vivo"}) → rearrancando');
      _startGps();
    }
  }

  /// Pulso de ubicación disparado por el **tick periódico NATIVO** del
  /// foreground service (`onRepeatEvent` → `sendDataToMain`), NO por un
  /// `Timer` de Dart.
  ///
  /// Por qué existe: en background profundo Android congela los `Timer`
  /// de Dart del isolate principal (Doze / restricciones OEM). Eso dejaba
  /// sin disparar el heartbeat estacionario (un `Timer.periodic`), el
  /// conductor parado dejaba de pushear y el cron `markStaleDriversOffline`
  /// (6 min) lo marcaba `desconectado` aunque el radio siguiera vivo. El
  /// FGS nativo mantiene un wakelock y su `onRepeatEvent` SÍ sigue
  /// disparando bajo Doze, así que lo usamos como red de seguridad para
  /// garantizar un push dentro de la ventana del cron (< 6 min).
  ///
  /// Es idempotente y barato: si el conductor no está online no hace nada.
  /// Pide un fix fresco; si no lo logra, repushea la última posición
  /// conocida para refrescar `updatedAt`. Convive con los timers de Dart
  /// (cuando NO están congelados, ellos hacen el trabajo fino; este tick
  /// es el seguro que nunca se congela).
  Future<void> nativeHeartbeatPulse() async {
    if (!_isOnline || _driverId == null) return;
    debugPrint('📍 [LocationService] native FGS tick → pulso de ubicación '
        '(stationary=$_isStationary)');
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 8),
        ),
      );
      // Forzar el push: este tick es nuestro pulso garantizado, no puede
      // quedar bloqueado por el throttle adaptativo de _onFix.
      _lastPush = null;
      _onFix(pos, source: 'native-tick');
    } catch (_) {
      // Sin fix nuevo en este intento (interior/cell). Repushear lo último
      // conocido para que la operadora siga viendo la unidad viva y el cron
      // no la marque stale.
      if (_lastLatitude != null && _lastLongitude != null) {
        _lastPush = DateTime.now();
        await _pushLocation(
          _lastLatitude!,
          _lastLongitude!,
          accuracy: _lastAccuracy,
          stationary: _isStationary ? true : null,
        );
      }
    }
  }

  // ─── GPS interno ─────────────────────────────────────────

  Future<void> _requestPermissionAndStartGps() async {
    final perm = await Permission.locationWhenInUse.request();
    if (perm.isGranted) {
      _startGps();
    } else {
      debugPrint('📍 [LocationService] Permiso de ubicación DENEGADO');
    }
  }

  void _startGps() {
    _positionSub?.cancel();
    _heartbeatTimer?.cancel();

    // 1. Pre-warm: pedimos un fix inmediato sin esperar al stream.
    //    El primer fix del stream suele ser el último cacheado del SO
    //    (puede ser de hace varios minutos / km de distancia). Forzar
    //    un getCurrentPosition al arrancar evita esa staleness inicial.
    _requestImmediatePrewarmFix();

    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        // bestForNavigation activa el GPS chip al máximo (1 Hz, alta
        // precisión). Consume más batería pero la operadora ve
        // ubicaciones <10 m vs los 30-50 m de `high`.
        accuracy: LocationAccuracy.bestForNavigation,
        // Filtro de distancia: no emite hasta que el conductor se mueva
        // 5 m. Reduce ruido del fix cuando está quieto.
        distanceFilter: 5,
      ),
    ).listen(
      (position) => _onFix(position, source: 'stream'),
      onError: (e) {
        debugPrint('📍 [LocationService] GPS stream error: $e');
      },
    );

    // 2. Heartbeat: cada 60 s republicamos la última posición conocida
    //    (con un fix actualizado si está disponible). Esto mantiene el
    //    `updatedAt` fresco para la operadora, importante cuando el
    //    conductor está parado en una parada y el `distanceFilter`
    //    bloquea el stream.
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) async {
      if (!_isOnline || _driverId == null) return;
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            timeLimit: Duration(seconds: 6),
          ),
        );
        _onFix(pos, source: 'heartbeat');
      } catch (_) {
        // Si el getCurrentPosition falla, repushear lo último conocido
        // así la operadora ve el doc "vivo".
        if (_lastLatitude != null && _lastLongitude != null) {
          _lastPush = DateTime.now();
          _pushLocation(
            _lastLatitude!,
            _lastLongitude!,
            accuracy: _lastAccuracy,
          );
        }
      }
    });

    debugPrint('📍 [LocationService] GPS stream iniciado (bestForNavigation)');
  }

  /// Pide un fix de alta precisión SIN bloquear. Usado al iniciar.
  Future<void> _requestImmediatePrewarmFix() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 8),
        ),
      );
      _onFix(pos, source: 'prewarm');
    } catch (e) {
      debugPrint('📍 [LocationService] prewarm fix falló: $e');
    }
  }

  /// Recibe un fix de cualquier fuente (stream / heartbeat / prewarm) y
  /// aplica filtros de calidad antes de aceptarlo y persistirlo.
  void _onFix(Position position, {required String source}) {
    if (!_isOnline || _driverId == null) return;

    // Filtro 1: descartar fixes muy imprecisos (cellid o WiFi malo).
    if (position.accuracy > _maxAcceptableAccuracyMeters) {
      debugPrint(
          '📍 [LocationService] descartado fix $source: '
          'accuracy=${position.accuracy.toStringAsFixed(0)}m');
      return;
    }

    // Filtro 2: anti-jitter — saltos imposibles en poco tiempo.
    final now = DateTime.now();
    if (_lastLatitude != null &&
        _lastLongitude != null &&
        _lastFixAt != null &&
        now.difference(_lastFixAt!) < _jitterMaxAge) {
      final jumped = _haversineMeters(
        _lastLatitude!,
        _lastLongitude!,
        position.latitude,
        position.longitude,
      );
      if (jumped > _jitterDistanceMeters) {
        debugPrint(
            '📍 [LocationService] descartado fix $source: '
            'salto de ${jumped.toStringAsFixed(0)}m en '
            '${now.difference(_lastFixAt!).inSeconds}s');
        return;
      }
    }

    _lastLatitude = position.latitude;
    _lastLongitude = position.longitude;
    _lastAccuracy = position.accuracy;
    _lastFixAt = now;

    // ─── State machine: STATIONARY ───
    // Si llegamos acá viniendo de stationary (heartbeat woke us up),
    // chequeamos la distancia al anchor. Si se movió >100m, salimos
    // de stationary y reactivamos el stream.
    if (_isStationary) {
      final dFromAnchor = (_stationaryAnchorLat != null &&
              _stationaryAnchorLng != null)
          ? _haversineMeters(_stationaryAnchorLat!, _stationaryAnchorLng!,
              position.latitude, position.longitude)
          : double.infinity;
      if (dFromAnchor > _stationaryRadiusMeters) {
        debugPrint('📍 [LocationService] EXIT stationary: '
            '${dFromAnchor.toStringAsFixed(0)}m del anchor → reactivar stream');
        _exitStationary();
      } else {
        // Sigue parado, solo actualizamos updatedAt vía heartbeat —
        // no pusheamos cada vez para no inflar costos.
        return;
      }
    } else {
      // En modo ACTIVE: ¿se ha movido >100 m del anchor? Si sí, reset
      // el anchor (sigue moviéndose). Si no, comprobar si pasaron 5 min
      // → entrar a stationary.
      if (_stationaryAnchorLat == null) {
        _stationaryAnchorLat = position.latitude;
        _stationaryAnchorLng = position.longitude;
        _stationaryAnchorAt = now;
      } else {
        final dFromAnchor = _haversineMeters(_stationaryAnchorLat!,
            _stationaryAnchorLng!, position.latitude, position.longitude);
        if (dFromAnchor > _stationaryRadiusMeters) {
          // Se movió: nuevo anchor.
          _stationaryAnchorLat = position.latitude;
          _stationaryAnchorLng = position.longitude;
          _stationaryAnchorAt = now;
        } else if (_stationaryAnchorAt != null &&
            now.difference(_stationaryAnchorAt!) >= _stationaryThreshold) {
          // 5 min sin alejarse del anchor → STATIONARY.
          debugPrint('📍 [LocationService] ENTER stationary: '
              '5 min sin alejarse de anchor');
          _enterStationary();
          return;
        }
      }
    }

    // Throttle adaptativo: 10 s en foreground (responsivo para que la
    // operadora vea movimiento en vivo), 30 s en background (ahorro de
    // datos cuando el conductor tiene la app dormida).
    final pushIntervalSec = _isBackgrounded
        ? _backgroundPushSeconds
        : AppConstants.locationUpdateSeconds;
    if (_lastPush == null ||
        now.difference(_lastPush!).inSeconds >= pushIntervalSec) {
      _lastPush = now;
      _pushLocation(
        position.latitude,
        position.longitude,
        accuracy: position.accuracy,
        speed: position.speed,
        heading: position.heading,
      );
    }
  }

  /// Apaga el stream + sube heartbeat a 5 min. Marca el doc con
  /// `stationaryMode: true` para que el admin pueda ver "parado N min".
  void _enterStationary() {
    if (_isStationary) return;
    _isStationary = true;
    _positionSub?.cancel();
    _positionSub = null;
    // Reemplazar heartbeat con uno de 5 min.
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_stationaryHeartbeatInterval, (_) {
      _doStationaryHeartbeat();
    });
    // Persistir el modo y la última pos (con flag).
    if (_lastLatitude != null && _lastLongitude != null) {
      _pushLocation(
        _lastLatitude!,
        _lastLongitude!,
        accuracy: _lastAccuracy,
        stationary: true,
      );
      _lastPush = DateTime.now();
    }
  }

  /// Reactiva el stream + heartbeat normal. Push inmediato del fix que
  /// nos despertó.
  void _exitStationary() {
    if (!_isStationary) return;
    _isStationary = false;
    _stationaryAnchorLat = null;
    _stationaryAnchorLng = null;
    _stationaryAnchorAt = null;
    _heartbeatTimer?.cancel();
    // Reiniciar el stream y heartbeat normales como en _startGps.
    _startGps();
  }

  /// Heartbeat especial para modo STATIONARY: pide un fix y lo manda
  /// a _onFix, que decide si seguir parado o despertar.
  Future<void> _doStationaryHeartbeat() async {
    if (!_isOnline || _driverId == null) return;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 8),
        ),
      );
      // Forzar push aunque el throttle no se cumpla (es nuestro pulso
      // único en stationary, la operadora necesita ver updatedAt fresco).
      _lastPush = null;
      _onFix(pos, source: 'heartbeat-stationary');
    } catch (_) {
      // Sin GPS en este intento: solo refrescamos updatedAt para que la
      // operadora siga viendo la unidad "viva".
      if (_lastLatitude != null && _lastLongitude != null) {
        _pushLocation(
          _lastLatitude!,
          _lastLongitude!,
          accuracy: _lastAccuracy,
          stationary: true,
        );
      }
    }
  }

  /// Distancia haversine en metros (versión local para evitar import
  /// circular con core/utils/geo_utils que está en kilómetros).
  static double _haversineMeters(
      double lat1, double lng1, double lat2, double lng2) {
    const double r = 6371000; // metros
    const pi180 = 3.141592653589793 / 180;
    final dLat = (lat2 - lat1) * pi180;
    final dLng = (lng2 - lng1) * pi180;
    final s = (dLat / 2);
    final t = (dLng / 2);
    final a = (math.sin(s) * math.sin(s)) +
        math.cos(lat1 * pi180) *
            math.cos(lat2 * pi180) *
            (math.sin(t) * math.sin(t));
    return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  Future<void> _pushLocation(
    double lat,
    double lng, {
    double? accuracy,
    double? speed,
    double? heading,
    bool? stationary,
  }) async {
    try {
      final data = <String, dynamic>{
        'currentLatitude': lat,
        'currentLongitude': lng,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      };
      // Metadata GPS opcional. Permite que el mapa muestre círculo de
      // incertidumbre + flecha de dirección de movimiento, y que en
      // debug se vea por qué un fix se aceptó.
      if (accuracy != null) data['locationAccuracy'] = accuracy;
      if (speed != null && speed >= 0) data['locationSpeed'] = speed;
      if (heading != null && heading >= 0) data['locationHeading'] = heading;
      // Marca si el conductor está en modo "parado" (state-machine de
      // ahorro). El admin puede mostrarlo como un ícono "🅿️ parado" para
      // distinguir del que se está moviendo.
      if (stationary != null) data['stationaryMode'] = stationary;
      await _firestore
          .collection(AppConstants.driversCollection)
          .doc(_driverId!)
          .update(data);
      debugPrint(
          '📍 [LocationService] push ($lat, $lng) acc=${accuracy?.toStringAsFixed(0)}m'
          '${stationary == true ? " [stationary]" : ""}');
    } catch (e) {
      debugPrint('📍 [LocationService] Error push GPS: $e');
    }
  }

  void _stopGps() {
    _positionSub?.cancel();
    _positionSub = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastPush = null;
    _lastFixAt = null;
    _isStationary = false;
    _stationaryAnchorLat = null;
    _stationaryAnchorLng = null;
    _stationaryAnchorAt = null;
    debugPrint('📍 [LocationService] GPS stream detenido');
  }

  // ─── Limpieza ────────────────────────────────────────────

  /// Reset total: se usa al hacer logout.
  /// Marca al doc del driver como offline + isActive=false + sin posición,
  /// para que la operadora deje de verlo de inmediato en el mapa.
  Future<void> reset() async {
    if (_driverId != null) {
      _isOnline = true;
      await goOffline(hardOffline: true);
    }
    _driverId = null;
    _userId = null;
    _initialized = false;
    _lastLatitude = null;
    _lastLongitude = null;
    _lastAccuracy = null;
  }

  /// Limpieza al cerrar la app.
  @override
  void dispose() {
    _stopGps();
    _driverId = null;
    _userId = null;
    super.dispose();
  }
}
