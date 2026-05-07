/// Constantes globales de la aplicación
class AppConstants {
  AppConstants._();

  // Nombre de la app (genérico, multi-tenant). El nombre real
  // de cada asociación viene del documento associations/{aid}.name.
  static const String appName = 'Taxis App';
  static const String appVersion = '1.0.0';

  // Ubicación de fallback (Quito centro). Cada asociación puede
  // tener su propia ubicación configurada en el panel admin.
  static const double baseLatitude = -0.1676;
  static const double baseLongitude = -78.4839;
  static const String baseAddress = '';

  // Roles de usuario
  static const String roleAdmin = 'admin';
  static const String roleDriver = 'conductor';
  static const String roleOperator = 'operadora';

  // Estados del conductor
  static const String statusFree = 'libre';
  static const String statusBusy = 'con_pasajero';
  static const String statusReturning = 'en_camino_base';
  static const String statusOffline = 'desconectado';

  // Colecciones de Firestore
  static const String usersCollection = 'users';
  static const String driversCollection = 'drivers';
  static const String vehiclesCollection = 'vehicles';
  static const String tripsCollection = 'trips';
  static const String paymentsCollection = 'payments';
  static const String channelsCollection = 'channels';
  static const String messagesCollection = 'messages';
  static const String emergenciesCollection = 'emergencies';
  static const String expensesCollection = 'expenses';
  static const String taxiStandsCollection = 'taxi_stands';
  static const String competitorTripsCollection = 'competitor_trips';
  static const String incentivesCollection = 'incentives';

  // Límites
  static const int maxVehiclesPerDriver = 3;
  static const int etaRefreshSeconds = 30;
  static const int locationUpdateSeconds = 10;
  static const double nearbyRadiusKm = 2.0;

  // Audio (Walkie-Talkie)
  static const int audioSampleRate = 44100;
  static const int audioBitRate = 128000;
}
