import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../constants/app_constants.dart';
import 'rtdb_service.dart';

/// Escribe la **presencia + ubicación** del conductor en Firestore.
///
/// Unidad aislada (inyectable) extraída de `DriverLocationService._pushLocation`
/// para poder testear el comportamiento de presencia sin depender de Geolocator
/// ni del singleton. `DriverLocationService` delega aquí cada push.
///
/// ── Dual-write a RTDB (aditivo, gated por flag) ──
/// Cuando `RtdbService.instance.presenceEnabled` está ON y se conocen
/// `uid`+`associationId`, ADEMÁS de la escritura Firestore (que NO se quita
/// ni se reduce) publica la ubicación en vivo en `/presence/{aid}/{uid}`. El
/// flag OFF (default) deja el camino Firestore 100% intacto. Ver
/// `rtdb_service.dart` y `database.rules.json`.
class DriverPresenceWriter {
  /// [database] es opcional para no romper los tests existentes ni el camino
  /// Firestore; si es null, se resuelve perezosamente desde `RtdbService`
  /// SOLO cuando el flag de presencia esté activo (así un test sin RTDB que
  /// nunca activa el flag jamás toca Firebase RTDB).
  DriverPresenceWriter(this._firestore, {FirebaseDatabase? database})
      : _injectedDatabase = database;

  final FirebaseFirestore _firestore;
  final FirebaseDatabase? _injectedDatabase;

  /// Resuelve la instancia RTDB: la inyectada (tests) o la del singleton.
  FirebaseDatabase get _database =>
      _injectedDatabase ?? RtdbService.instance.database;

  /// Persiste un update de ubicación para [driverId].
  ///
  /// [online] indica si la app considera al conductor en línea en ese momento.
  ///
  /// [uid] (auth uid) y [associationId] habilitan el dual-write RTDB en
  /// `/presence/{associationId}/{uid}`; si alguno es null/vacío o el flag
  /// `presenceEnabled` está OFF, NO se toca RTDB (solo Firestore).
  Future<void> pushLocation(
    String driverId,
    double lat,
    double lng, {
    required bool online,
    required String status,
    double? accuracy,
    double? speed,
    double? heading,
    bool? stationary,
    String? uid,
    String? associationId,
  }) async {
    final data = <String, dynamic>{
      'currentLatitude': lat,
      'currentLongitude': lng,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    };
    if (accuracy != null) data['locationAccuracy'] = accuracy;
    if (speed != null && speed >= 0) data['locationSpeed'] = speed;
    if (heading != null && heading >= 0) data['locationHeading'] = heading;
    if (stationary != null) data['stationaryMode'] = stationary;

    // Self-heal de presencia: mientras la app se considere online, cada push
    // RE-AFIRMA isActive=true + status. Si el cron `markStaleDriversOffline`
    // habia marcado al conductor offline (por >6 min sin updatedAt: tunel, sin
    // senal, interior), el primer push tras recuperar senal lo reactiva solo.
    // Sin esto, _pushLocation solo refrescaba coords/updatedAt y el doc quedaba
    // isActive=false para siempre (invisible en el mapa) hasta un OFF->ON manual.
    if (online) {
      data['isActive'] = true;
      data['status'] = status;
    }

    await _firestore
        .collection(AppConstants.driversCollection)
        .doc(driverId)
        .update(data);

    // ── Dual-write RTDB (aditivo) ──
    // Solo si el flag está ON y tenemos las claves del path multi-tenant.
    // NUNCA debe romper el push Firestore (ya completado arriba): cualquier
    // error RTDB se traga y se loguea.
    await _maybePushRtdb(
      driverId: driverId,
      lat: lat,
      lng: lng,
      online: online,
      status: status,
      accuracy: accuracy,
      speed: speed,
      heading: heading,
      stationary: stationary,
      uid: uid,
      associationId: associationId,
    );
  }

  /// Espejo en RTDB del último fix, gated por `presenceEnabled`. Escribe SOLO
  /// las llaves contempladas por las reglas (`$other: validate=false` rechaza
  /// cualquier otra). `updatedAt` va con `ServerValue.timestamp` porque la
  /// regla lo fuerza con `.validate (=== now)`.
  Future<void> _maybePushRtdb({
    required String driverId,
    required double lat,
    required double lng,
    required bool online,
    required String status,
    double? accuracy,
    double? speed,
    double? heading,
    bool? stationary,
    String? uid,
    String? associationId,
  }) async {
    if (!RtdbService.instance.presenceEnabled) return;
    if (uid == null || uid.isEmpty) return;
    if (associationId == null || associationId.isEmpty) return;

    final node = <String, dynamic>{
      'online': online,
      'lat': lat,
      'lng': lng,
      'status': status,
      'driverId': driverId,
      // Forzado por la regla: debe ser === now (ServerValue.timestamp en ms).
      'updatedAt': ServerValue.timestamp,
    };
    if (accuracy != null) node['accuracy'] = accuracy;
    if (speed != null && speed >= 0) node['speed'] = speed;
    if (heading != null && heading >= 0) node['heading'] = heading;
    if (stationary != null) node['stationary'] = stationary;

    try {
      await _database
          .ref('presence/$associationId/$uid')
          .update(node);
    } catch (e) {
      // El push Firestore ya quedó persistido; el camino RTDB es aditivo y no
      // debe degradar la presencia real. Solo logueamos.
      if (kDebugMode) {
        debugPrint('📍 [PresenceWriter] dual-write RTDB falló (no crítico): $e');
      }
    }
  }
}
