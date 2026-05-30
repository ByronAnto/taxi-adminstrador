import 'package:equatable/equatable.dart';

/// Entidad que contiene todos los datos agregados para reportes
class ReportData extends Equatable {
  /// Período del reporte ('Hoy', 'Semana', 'Mes', 'Año')
  final String period;
  final DateTime fromDate;
  final DateTime toDate;

  // KPIs principales
  final int totalTrips;
  final int completedTrips;
  final int cancelledTrips;
  final double totalRevenue;
  final double averageFare;
  final int activeDriversCount;

  /// Estimado monetario del periodo basado en la tarifa mínima de Quito
  /// (UTC-5): Σ fareForHour(horaLocal del createdAt) sobre las carreras
  /// finalizadas/completadas. Es independiente del `fare` real cobrado.
  final double estimatedRevenue;

  // Variación porcentual respecto al período anterior
  final double tripsTrend;
  final double revenueTrend;
  final double cancelledTrend;

  /// Carreras por hora del día {hora: cantidad}
  final Map<int, int> tripsByHour;

  /// Ingresos diarios {fecha_string: monto}
  final Map<String, double> dailyRevenue;

  /// Top conductores ordenados por carreras completadas
  final List<DriverReportItem> topDrivers;

  /// Distribución por método de pago {metodo: porcentaje 0.0-1.0}
  final Map<String, double> paymentMethodDistribution;

  /// Destinos más frecuentes
  final List<DestinationReportItem> frequentDestinations;

  /// Mapa de calor: día de la semana (1=Lun..7=Dom) x hora (0-23) → count.
  /// Estructura: `tripsByDayAndHour[1][8] = 23` significa que los lunes
  /// a las 8am hay en promedio 23 carreras (acumulado del periodo).
  final Map<int, Map<int, int>> tripsByDayAndHour;

  const ReportData({
    required this.period,
    required this.fromDate,
    required this.toDate,
    this.totalTrips = 0,
    this.completedTrips = 0,
    this.cancelledTrips = 0,
    this.totalRevenue = 0.0,
    this.averageFare = 0.0,
    this.activeDriversCount = 0,
    this.estimatedRevenue = 0.0,
    this.tripsTrend = 0.0,
    this.revenueTrend = 0.0,
    this.cancelledTrend = 0.0,
    this.tripsByHour = const {},
    this.dailyRevenue = const {},
    this.topDrivers = const [],
    this.paymentMethodDistribution = const {},
    this.frequentDestinations = const [],
    this.tripsByDayAndHour = const {},
  });

  @override
  List<Object?> get props => [
        period,
        fromDate,
        toDate,
        totalTrips,
        completedTrips,
        cancelledTrips,
        totalRevenue,
        averageFare,
        activeDriversCount,
        estimatedRevenue,
        tripsTrend,
        revenueTrend,
        cancelledTrend,
        tripsByHour,
        dailyRevenue,
        topDrivers,
        paymentMethodDistribution,
        frequentDestinations,
        tripsByDayAndHour,
      ];
}

/// Datos de un conductor para el reporte
class DriverReportItem extends Equatable {
  final String driverId;
  final String name;
  final int tripCount;
  final double income;
  final double rating;

  /// Hora con más carreras del conductor (0-23).
  final int peakHour;

  /// Cantidad de carreras en la hora pico.
  final int peakHourCount;

  /// Distribución de carreras por origen, ej: {standQueue: 12, street: 5}.
  final Map<String, int> bySource;

  const DriverReportItem({
    required this.driverId,
    required this.name,
    required this.tripCount,
    required this.income,
    this.rating = 0.0,
    this.peakHour = 0,
    this.peakHourCount = 0,
    this.bySource = const {},
  });

  @override
  List<Object?> get props =>
      [driverId, name, tripCount, income, rating, peakHour, peakHourCount, bySource];
}

/// Datos de un destino frecuente
class DestinationReportItem extends Equatable {
  final String address;
  final int count;

  const DestinationReportItem({
    required this.address,
    required this.count,
  });

  @override
  List<Object?> get props => [address, count];
}
