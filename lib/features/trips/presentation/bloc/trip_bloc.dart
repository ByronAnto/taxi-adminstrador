import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/models/trip_model.dart';
import '../../domain/usecases/trip_usecases.dart';

// ============ EVENTS ============

abstract class TripEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class TripsWatchStarted extends TripEvent {
  final String? driverId;
  TripsWatchStarted({this.driverId});
  @override
  List<Object?> get props => [driverId];
}

class TripsUpdated extends TripEvent {
  final List<TripModel> trips;
  TripsUpdated(this.trips);
  @override
  List<Object?> get props => [trips];
}

class TripCreateRequested extends TripEvent {
  final TripModel trip;
  TripCreateRequested(this.trip);
  @override
  List<Object?> get props => [trip];
}

class TripCompleteRequested extends TripEvent {
  final CompleteTripParams params;
  TripCompleteRequested(this.params);
  @override
  List<Object?> get props => [params.tripId];
}

class TripFinalizeRequested extends TripEvent {
  final String tripId;

  /// Si la carrera vino de un `tripRequests/{id}`, lo pasamos para
  /// reflejar el cierre también en esa colección (la lee el portal web).
  final String? tripRequestId;
  TripFinalizeRequested(this.tripId, {this.tripRequestId});
  @override
  List<Object?> get props => [tripId, tripRequestId];
}

class TripCancelRequested extends TripEvent {
  final String tripId;
  final String? reason;

  /// Si la carrera vino de un `tripRequests/{id}`, lo pasamos para reflejar
  /// también allí la cancelación (la lee el portal web del cliente).
  final String? tripRequestId;
  TripCancelRequested(this.tripId, {this.reason, this.tripRequestId});
  @override
  List<Object?> get props => [tripId, reason, tripRequestId];
}

class TripHistoryLoadRequested extends TripEvent {
  final String? driverId;
  final DateTime? fromDate;
  final DateTime? toDate;
  TripHistoryLoadRequested({this.driverId, this.fromDate, this.toDate});
  @override
  List<Object?> get props => [driverId, fromDate, toDate];
}

class TripStatsLoadRequested extends TripEvent {
  final String driverId;
  TripStatsLoadRequested(this.driverId);
  @override
  List<Object?> get props => [driverId];
}

// ============ STATES ============

abstract class TripState extends Equatable {
  @override
  List<Object?> get props => [];
}

class TripInitial extends TripState {}

class TripLoading extends TripState {}

class TripsLoaded extends TripState {
  final List<TripModel> activeTrips;
  final List<TripModel> historyTrips;
  final Map<String, dynamic>? stats;

  TripsLoaded({
    this.activeTrips = const [],
    this.historyTrips = const [],
    this.stats,
  });

  @override
  List<Object?> get props => [activeTrips, historyTrips, stats];

  TripsLoaded copyWith({
    List<TripModel>? activeTrips,
    List<TripModel>? historyTrips,
    Map<String, dynamic>? stats,
  }) {
    return TripsLoaded(
      activeTrips: activeTrips ?? this.activeTrips,
      historyTrips: historyTrips ?? this.historyTrips,
      stats: stats ?? this.stats,
    );
  }
}

class TripActionSuccess extends TripState {
  final String message;
  TripActionSuccess(this.message);
  @override
  List<Object?> get props => [message];
}

class TripError extends TripState {
  final String message;
  TripError(this.message);
  @override
  List<Object?> get props => [message];
}

// ============ BLOC ============

class TripBloc extends Bloc<TripEvent, TripState> {
  final WatchActiveTripsUseCase watchActiveTrips;
  final WatchDriverTripsUseCase watchDriverTrips;
  final CreateTripUseCase createTrip;
  final CompleteTripUseCase completeTrip;
  final FinalizeTripUseCase finalizeTrip;
  final CancelTripUseCase cancelTrip;
  final GetTripsHistoryUseCase getTripsHistory;
  final GetDriverTripStatsUseCase getDriverTripStats;

  StreamSubscription<List<TripModel>>? _tripsSubscription;

  TripBloc({
    required this.watchActiveTrips,
    required this.watchDriverTrips,
    required this.createTrip,
    required this.completeTrip,
    required this.finalizeTrip,
    required this.cancelTrip,
    required this.getTripsHistory,
    required this.getDriverTripStats,
  }) : super(TripInitial()) {
    on<TripsWatchStarted>(_onWatchStarted);
    on<TripsUpdated>(_onTripsUpdated);
    on<TripCreateRequested>(_onCreateRequested);
    on<TripCompleteRequested>(_onCompleteRequested);
    on<TripFinalizeRequested>(_onFinalizeRequested);
    on<TripCancelRequested>(_onCancelRequested);
    on<TripHistoryLoadRequested>(_onHistoryRequested);
    on<TripStatsLoadRequested>(_onStatsRequested);
  }

  Future<void> _onWatchStarted(
    TripsWatchStarted event,
    Emitter<TripState> emit,
  ) async {
    emit(TripLoading());
    await _tripsSubscription?.cancel();

    final stream = event.driverId != null
        ? watchDriverTrips(event.driverId!)
        : watchActiveTrips();

    _tripsSubscription = stream.listen(
      (trips) => add(TripsUpdated(trips)),
      onError: (error) => add(TripsUpdated(const [])),
    );
  }

  void _onTripsUpdated(
    TripsUpdated event,
    Emitter<TripState> emit,
  ) {
    final current = state;
    if (current is TripsLoaded) {
      emit(current.copyWith(activeTrips: event.trips));
    } else {
      emit(TripsLoaded(activeTrips: event.trips));
    }
  }

  Future<void> _onCreateRequested(
    TripCreateRequested event,
    Emitter<TripState> emit,
  ) async {
    try {
      await createTrip(event.trip);
      emit(TripActionSuccess('Carrera creada exitosamente'));
    } catch (e) {
      emit(TripError('Error al crear la carrera: $e'));
    }
  }

  Future<void> _onCompleteRequested(
    TripCompleteRequested event,
    Emitter<TripState> emit,
  ) async {
    try {
      await completeTrip(event.params);
      emit(TripActionSuccess('Carrera completada'));
    } catch (e) {
      emit(TripError('Error al completar la carrera: $e'));
    }
  }

  Future<void> _onFinalizeRequested(
    TripFinalizeRequested event,
    Emitter<TripState> emit,
  ) async {
    try {
      await finalizeTrip(event.tripId, tripRequestId: event.tripRequestId);
      emit(TripActionSuccess('Viaje finalizado'));
    } catch (e) {
      emit(TripError('Error al finalizar la carrera: $e'));
    }
  }

  Future<void> _onCancelRequested(
    TripCancelRequested event,
    Emitter<TripState> emit,
  ) async {
    try {
      await cancelTrip(event.tripId,
          reason: event.reason, tripRequestId: event.tripRequestId);
      emit(TripActionSuccess('Carrera cancelada'));
    } catch (e) {
      emit(TripError('Error al cancelar la carrera: $e'));
    }
  }

  Future<void> _onHistoryRequested(
    TripHistoryLoadRequested event,
    Emitter<TripState> emit,
  ) async {
    try {
      final history = await getTripsHistory(
        driverId: event.driverId,
        fromDate: event.fromDate,
        toDate: event.toDate,
      );
      final current = state;
      if (current is TripsLoaded) {
        emit(current.copyWith(historyTrips: history));
      } else {
        emit(TripsLoaded(historyTrips: history));
      }
    } catch (e) {
      emit(TripError('Error al cargar historial: $e'));
    }
  }

  Future<void> _onStatsRequested(
    TripStatsLoadRequested event,
    Emitter<TripState> emit,
  ) async {
    try {
      final stats = await getDriverTripStats(event.driverId);
      final current = state;
      if (current is TripsLoaded) {
        emit(current.copyWith(stats: stats));
      } else {
        emit(TripsLoaded(stats: stats));
      }
    } catch (e) {
      emit(TripError('Error al cargar estadísticas: $e'));
    }
  }

  @override
  Future<void> close() {
    _tripsSubscription?.cancel();
    return super.close();
  }
}
