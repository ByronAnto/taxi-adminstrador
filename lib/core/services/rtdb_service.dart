import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

/// Servicio central de **Realtime Database (RTDB)** para lo EFÍMERO.
///
/// La migración a RTDB cubre SOLO dos cosas de baja durabilidad y alta
/// rotación, donde `onDisconnect()` aporta el beneficio clave de
/// auto-liberación si el celular muere o pierde datos:
///   1. El **lock del PTT** (quién habla en cada canal) → `/channelLocks`.
///   2. La **presencia/ubicación GPS en vivo** de los conductores →
///      `/presence`.
///
/// TODO lo durable (canales, miembros, históricos, etc.) SE QUEDA EN
/// FIRESTORE. Este servicio NO reemplaza Firestore: durante la transición
/// es un camino ADICIONAL, activado por flags de rollback.
///
/// ── ROLLBACK (flags en `app_config/rtdb`) ──
/// Doc Firestore `app_config/rtdb = { lockEnabled: bool, presenceEnabled:
/// bool }`. DEFAULT ausente/false = comportamiento actual INTACTO (camino
/// Firestore). Mismo patrón que `app_config/duesEnforcement.mode`.
///
/// La lectura del flag se CACHEA al boot (un `get` inicial + un snapshot
/// listener en tiempo real); los getters síncronos `lockEnabled` /
/// `presenceEnabled` exponen el valor cacheado, para NO leer Firestore por
/// operación. Espejo de `remote_log_service.dart`.
///
/// ── databaseURL explícita ──
/// `firebase_options.dart` NO incluye `databaseURL`, así que apuntamos a la
/// instancia con `FirebaseDatabase.instanceFor(databaseURL:)` para evitar
/// que el SDK infiera una URL incorrecta.
class RtdbService {
  RtdbService._();

  /// Singleton. Los implementadores del lock/presencia inyectan
  /// `RtdbService.instance.database` o usan los helpers de refs.
  static final RtdbService instance = RtdbService._();

  /// URL de la instancia RTDB ya creada y ACTIVA (us-central1).
  static const String databaseUrl =
      'https://taxis-f0f51-default-rtdb.firebaseio.com';

  // ── Flag central de rollback (Firestore: `app_config/rtdb`) ──
  static const String _configCollection = 'app_config';
  static const String _configDoc = 'rtdb';

  /// Instancia de RTDB apuntando explícitamente a [databaseUrl]. Lazy para
  /// no tocar Firebase antes de `Firebase.initializeApp()`.
  FirebaseDatabase? _database;

  /// Gates cacheados desde el flag central. Default = false (apagado):
  /// hasta que el flag los habilite, los caminos RTDB NO se activan y el
  /// comportamiento Firestore queda intacto.
  bool _lockEnabled = false;
  bool _presenceEnabled = false;

  bool _initialized = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _configSub;

  /// Instancia RTDB (singleton perezoso) apuntando a [databaseUrl].
  FirebaseDatabase get database => _database ??= FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: databaseUrl,
      );

  /// ¿Está habilitado el camino RTDB para el **lock del PTT**?
  /// Síncrono, lee el valor cacheado. Default false.
  bool get lockEnabled => _lockEnabled;

  /// ¿Está habilitado el camino RTDB para la **presencia/ubicación**?
  /// Síncrono, lee el valor cacheado. Default false.
  bool get presenceEnabled => _presenceEnabled;

  /// Ref al lock de un canal: `/channelLocks/{associationId}/{channelId}`.
  /// Estructura del nodo: `{ uid, name, since }` (since = ServerValue.timestamp).
  DatabaseReference channelLockRef(String associationId, String channelId) =>
      database.ref('channelLocks/$associationId/$channelId');

  /// Ref a la presencia de un conductor: `/presence/{associationId}/{uid}`.
  /// Estructura del nodo: `{ online, lat, lng, speed, ..., updatedAt }`.
  DatabaseReference presenceRef(String associationId, String uid) =>
      database.ref('presence/$associationId/$uid');

  /// Arranca el servicio: hace un `get` inicial del flag y abre el snapshot
  /// listener. Idempotente y NUNCA debe romper el boot. Llamar en `main.dart`
  /// tras `Firebase.initializeApp()`.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Forzar persistencia local de RTDB: ayuda a que onDisconnect() se
    // mantenga registrado a través de reconexiones de red.
    try {
      database.setPersistenceEnabled(true);
    } catch (_) {
      // Algunas plataformas/llamadas dobles lanzan; es inofensivo ignorar.
    }

    // Get inicial: aplica el flag cuanto antes (antes de que el listener
    // emita). Si falla (sesión no lista), queda en default false y el
    // listener lo corregirá al re-suscribirse.
    try {
      final snap = await FirebaseFirestore.instance
          .collection(_configCollection)
          .doc(_configDoc)
          .get();
      _applyConfig(snap.data());
    } catch (_) {
      _applyConfig(null);
    }

    _startConfigListener();
  }

  /// Escucha `app_config/rtdb` en tiempo real y recalcula los gates.
  /// Default seguro: cualquier error/doc inexistente => ambos en false.
  ///
  /// El stream MUERE con el error (típico: permission-denied porque la
  /// sesión aún NO estaba lista al arrancar). Lo re-suscribimos tras un
  /// delay: una vez autenticado, funciona. Sin esto los gates quedarían en
  /// false para siempre. Espejo de `remote_log_service.dart`.
  void _startConfigListener() {
    _configSub?.cancel();
    _configSub = null;
    try {
      _configSub = FirebaseFirestore.instance
          .collection(_configCollection)
          .doc(_configDoc)
          .snapshots()
          .listen(
        (snap) => _applyConfig(snap.data()),
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
      _applyConfig(null);
      Future.delayed(const Duration(seconds: 5), () {
        if (_initialized && _configSub == null) _startConfigListener();
      });
    }
  }

  /// Recalcula los gates a partir del doc del flag central.
  /// Doc inexistente/nulo => ambos false (comportamiento Firestore intacto).
  void _applyConfig(Map<String, dynamic>? data) {
    _lockEnabled = data != null && data['lockEnabled'] == true;
    _presenceEnabled = data != null && data['presenceEnabled'] == true;
    if (kDebugMode) {
      debugPrint(
        '[RtdbService] flags → lockEnabled=$_lockEnabled '
        'presenceEnabled=$_presenceEnabled',
      );
    }
  }

  /// Cierra el listener del flag. Normalmente no se llama (vive todo el
  /// proceso), pero está disponible para tests/teardown.
  Future<void> dispose() async {
    await _configSub?.cancel();
    _configSub = null;
    _initialized = false;
  }
}
