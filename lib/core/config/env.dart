/// Configuración de entorno centralizada.
///
/// Las claves se inyectan en tiempo de compilación mediante `--dart-define`:
/// ```sh
/// flutter run --dart-define=GOOGLE_MAPS_API_KEY=AIza...
/// flutter build apk --dart-define=GOOGLE_MAPS_API_KEY=AIza...
/// ```
///
/// Nunca incluyas valores reales en el código fuente.
class Env {
  Env._();

  /// Google Maps SDK key — inyectada vía `--dart-define`.
  static const String googleMapsApiKey = String.fromEnvironment(
    'GOOGLE_MAPS_API_KEY',
    defaultValue: '',
  );

  /// `true` cuando se compiló con todas las claves requeridas.
  static bool get isConfigured => googleMapsApiKey.isNotEmpty;
}
