import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_jipijapa/core/services/location_fix_policy.dart';

void main() {
  const maxAcc = 50.0; // _maxAcceptableAccuracyMeters

  test('online + fix bueno (<=50m) -> push (mueve marcador)', () {
    final d = decideFix(
      online: true,
      accuracyMeters: 8,
      maxAccuracyMeters: maxAcc,
      hasLastKnown: true,
    );
    expect(d, FixDecision.push);
  });

  test(
      'online + fix impreciso (>50m, bajo techo) + hay ultima posicion -> '
      'keepAlive (refresca presencia, NO se cae del mapa)', () {
    final d = decideFix(
      online: true,
      accuracyMeters: 200,
      maxAccuracyMeters: maxAcc,
      hasLastKnown: true,
    );
    expect(d, FixDecision.keepAlive);
  });

  test('online + sin fix (null) + hay ultima posicion -> keepAlive', () {
    final d = decideFix(
      online: true,
      accuracyMeters: null,
      maxAccuracyMeters: maxAcc,
      hasLastKnown: true,
    );
    expect(d, FixDecision.keepAlive);
  });

  test('online + fix impreciso + SIN ultima posicion -> ignore (nada que mandar)',
      () {
    final d = decideFix(
      online: true,
      accuracyMeters: 200,
      maxAccuracyMeters: maxAcc,
      hasLastKnown: false,
    );
    expect(d, FixDecision.ignore);
  });

  test('offline -> ignore (respeta apagado intencional)', () {
    final d = decideFix(
      online: false,
      accuracyMeters: 8,
      maxAccuracyMeters: maxAcc,
      hasLastKnown: true,
    );
    expect(d, FixDecision.ignore);
  });
}
