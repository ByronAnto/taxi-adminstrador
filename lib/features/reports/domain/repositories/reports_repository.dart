import '../entities/report_data.dart';

/// Contrato del repositorio de reportes
abstract class ReportsRepository {
  /// Obtener datos agregados del reporte para un período
  Future<ReportData> getReportData({
    required String associationId,
    required String period,
    required DateTime fromDate,
    required DateTime toDate,
  });

  /// Obtener el rango de fechas del período anterior (para calcular tendencias)
  ({DateTime from, DateTime to}) getPreviousPeriodDates({
    required String period,
    required DateTime fromDate,
    required DateTime toDate,
  });
}
