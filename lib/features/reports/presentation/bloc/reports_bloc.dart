import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../domain/entities/report_data.dart';
import '../../domain/usecases/reports_usecases.dart';

// ============ EVENTS ============

abstract class ReportsEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

/// Solicita cargar el reporte para un período.
///
/// [associationId] es obligatorio para que la consulta de `trips` filtre por
/// tenant (las reglas de Firestore deniegan consultas sin este filtro a
/// usuarios no-superadmin). Lo provee la página desde el usuario autenticado.
class ReportsLoadRequested extends ReportsEvent {
  final String period;
  final String associationId;
  ReportsLoadRequested({this.period = 'Hoy', required this.associationId});
  @override
  List<Object?> get props => [period, associationId];
}

// ============ STATES ============

abstract class ReportsState extends Equatable {
  @override
  List<Object?> get props => [];
}

class ReportsInitial extends ReportsState {}

class ReportsLoading extends ReportsState {}

class ReportsLoaded extends ReportsState {
  final ReportData reportData;

  ReportsLoaded(this.reportData);

  @override
  List<Object?> get props => [reportData];
}

class ReportsError extends ReportsState {
  final String message;
  ReportsError(this.message);
  @override
  List<Object?> get props => [message];
}

// ============ BLOC ============

class ReportsBloc extends Bloc<ReportsEvent, ReportsState> {
  final GetReportDataUseCase getReportData;

  ReportsBloc({required this.getReportData}) : super(ReportsInitial()) {
    on<ReportsLoadRequested>(_onLoadRequested);
  }

  Future<void> _onLoadRequested(
    ReportsLoadRequested event,
    Emitter<ReportsState> emit,
  ) async {
    // Sin tenant no podemos consultar (la query sería denegada por reglas).
    if (event.associationId.isEmpty) {
      emit(ReportsError('No se pudo determinar la asociación del usuario.'));
      return;
    }
    emit(ReportsLoading());
    try {
      final now = DateTime.now();
      final (fromDate, toDate) = _periodToDateRange(event.period, now);

      final data = await getReportData(
        associationId: event.associationId,
        period: event.period,
        fromDate: fromDate,
        toDate: toDate,
      );
      emit(ReportsLoaded(data));
    } catch (e) {
      emit(ReportsError('Error al cargar reportes: $e'));
    }
  }

  /// Convierte un período a rango de fechas
  (DateTime, DateTime) _periodToDateRange(String period, DateTime now) {
    switch (period) {
      case 'Hoy':
        final from = DateTime(now.year, now.month, now.day);
        return (from, now);
      case 'Semana':
        final from = now.subtract(Duration(days: now.weekday - 1));
        return (DateTime(from.year, from.month, from.day), now);
      case 'Mes':
        final from = DateTime(now.year, now.month, 1);
        return (from, now);
      case 'Año':
        final from = DateTime(now.year, 1, 1);
        return (from, now);
      default:
        final from = DateTime(now.year, now.month, now.day);
        return (from, now);
    }
  }
}
