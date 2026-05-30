import '../../domain/entities/report_data.dart';
import '../../domain/repositories/reports_repository.dart';
import '../datasources/reports_remote_datasource.dart';

/// Implementación del repositorio de reportes
class ReportsRepositoryImpl implements ReportsRepository {
  final ReportsRemoteDatasource remoteDatasource;

  ReportsRepositoryImpl({required this.remoteDatasource});

  @override
  Future<ReportData> getReportData({
    required String associationId,
    required String period,
    required DateTime fromDate,
    required DateTime toDate,
  }) {
    final prev = getPreviousPeriodDates(
      period: period,
      fromDate: fromDate,
      toDate: toDate,
    );
    return remoteDatasource.getReportData(
      associationId: associationId,
      period: period,
      fromDate: fromDate,
      toDate: toDate,
      prevFrom: prev.from,
      prevTo: prev.to,
    );
  }

  @override
  ({DateTime from, DateTime to}) getPreviousPeriodDates({
    required String period,
    required DateTime fromDate,
    required DateTime toDate,
  }) {
    final duration = toDate.difference(fromDate);
    return (
      from: fromDate.subtract(duration),
      to: fromDate.subtract(const Duration(seconds: 1)),
    );
  }
}
