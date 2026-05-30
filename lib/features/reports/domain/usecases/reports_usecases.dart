import '../entities/report_data.dart';
import '../repositories/reports_repository.dart';

/// Caso de uso: Obtener datos del reporte para un período
class GetReportDataUseCase {
  final ReportsRepository repository;

  GetReportDataUseCase(this.repository);

  Future<ReportData> call({
    required String associationId,
    required String period,
    required DateTime fromDate,
    required DateTime toDate,
  }) =>
      repository.getReportData(
        associationId: associationId,
        period: period,
        fromDate: fromDate,
        toDate: toDate,
      );
}
