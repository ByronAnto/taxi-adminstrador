import 'package:cloud_firestore/cloud_firestore.dart';

import '../constants/app_constants.dart';

/// Escribe la **presencia + ubicación** del conductor en Firestore.
///
/// Unidad aislada (inyectable) extraída de `DriverLocationService._pushLocation`
/// para poder testear el comportamiento de presencia sin depender de Geolocator
/// ni del singleton. `DriverLocationService` delega aquí cada push.
class DriverPresenceWriter {
  DriverPresenceWriter(this._firestore);

  final FirebaseFirestore _firestore;

  /// Persiste un update de ubicación para [driverId].
  ///
  /// [online] indica si la app considera al conductor en línea en ese momento.
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
  }
}
