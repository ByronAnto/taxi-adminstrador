import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_jipijapa/core/constants/app_constants.dart';
import 'package:taxi_jipijapa/core/services/driver_presence_writer.dart';

void main() {
  late FakeFirebaseFirestore fs;
  late DriverPresenceWriter writer;
  const driverId = 'driver-1';

  /// Estado inicial: el cron `markStaleDriversOffline` ya marcó al conductor
  /// offline (isActive=false, status=desconectado) por >6 min sin updatedAt.
  setUp(() async {
    fs = FakeFirebaseFirestore();
    writer = DriverPresenceWriter(fs);
    await fs.collection(AppConstants.driversCollection).doc(driverId).set({
      'userId': 'u1',
      'associationId': 'jipijapa',
      'isActive': false,
      'status': AppConstants.statusOffline,
      'currentLatitude': -0.13,
      'currentLongitude': -78.49,
    });
  });

  Future<Map<String, dynamic>> readDoc() async => (await fs
          .collection(AppConstants.driversCollection)
          .doc(driverId)
          .get())
      .data()!;

  test(
      'recupera senal: un push estando online RE-ACTIVA al conductor que el cron '
      'marco offline', () async {
    // La app sigue creyendose online y, al volver la senal, empuja ubicacion.
    await writer.pushLocation(
      driverId,
      -0.1291,
      -78.4994,
      online: true,
      status: AppConstants.statusFree,
      accuracy: 8,
    );

    final data = await readDoc();
    expect(data['currentLatitude'], -0.1291); // la posicion si se actualiza
    expect(
      data['isActive'],
      true,
      reason: 'tras recuperar senal el push debe re-afirmar la presencia',
    );
    expect(
      data['status'],
      AppConstants.statusFree,
      reason: 'debe volver de "desconectado" al status real del conductor',
    );
  });

  test('apagado intencional: un push estando offline NO reactiva la presencia',
      () async {
    await writer.pushLocation(
      driverId,
      -0.1291,
      -78.4994,
      online: false,
      status: AppConstants.statusOffline,
    );

    final data = await readDoc();
    expect(data['isActive'], false);
    expect(data['status'], AppConstants.statusOffline);
  });
}
