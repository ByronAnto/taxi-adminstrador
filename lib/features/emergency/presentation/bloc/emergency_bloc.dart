import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/models/emergency_model.dart';
import '../../domain/usecases/emergency_usecases.dart';

// ============ EVENTS ============

abstract class EmergencyEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class EmergencyWatchStarted extends EmergencyEvent {}

class EmergencyUpdated extends EmergencyEvent {
  final List<EmergencyModel> emergencies;
  EmergencyUpdated(this.emergencies);
  @override
  List<Object?> get props => [emergencies];
}

class EmergencyCreateRequested extends EmergencyEvent {
  final EmergencyModel emergency;
  EmergencyCreateRequested(this.emergency);
  @override
  List<Object?> get props => [emergency.driverId];
}

class EmergencyLocationUpdateRequested extends EmergencyEvent {
  final String emergencyId;
  final double latitude;
  final double longitude;
  EmergencyLocationUpdateRequested(this.emergencyId, this.latitude, this.longitude);
  @override
  List<Object?> get props => [emergencyId, latitude, longitude];
}

class EmergencyResolveRequested extends EmergencyEvent {
  final String emergencyId;
  final String resolvedBy;
  final String? notes;
  EmergencyResolveRequested(this.emergencyId, this.resolvedBy, {this.notes});
  @override
  List<Object?> get props => [emergencyId, resolvedBy];
}

class EmergencyCancelRequested extends EmergencyEvent {
  final String emergencyId;
  EmergencyCancelRequested(this.emergencyId);
  @override
  List<Object?> get props => [emergencyId];
}

class EmergencyHistoryRequested extends EmergencyEvent {
  final int limit;
  EmergencyHistoryRequested({this.limit = 50});
  @override
  List<Object?> get props => [limit];
}

class EmergencyCheckActiveRequested extends EmergencyEvent {
  final String driverId;
  EmergencyCheckActiveRequested(this.driverId);
  @override
  List<Object?> get props => [driverId];
}

// ============ STATES ============

abstract class EmergencyState extends Equatable {
  @override
  List<Object?> get props => [];
}

class EmergencyInitial extends EmergencyState {}

class EmergencyLoading extends EmergencyState {}

class EmergencyLoaded extends EmergencyState {
  final List<EmergencyModel> activeEmergencies;
  final List<EmergencyModel> history;
  final EmergencyModel? myActiveEmergency;

  EmergencyLoaded({
    this.activeEmergencies = const [],
    this.history = const [],
    this.myActiveEmergency,
  });

  @override
  List<Object?> get props => [activeEmergencies, history, myActiveEmergency];

  EmergencyLoaded copyWith({
    List<EmergencyModel>? activeEmergencies,
    List<EmergencyModel>? history,
    EmergencyModel? myActiveEmergency,
    bool clearMyActive = false,
  }) {
    return EmergencyLoaded(
      activeEmergencies: activeEmergencies ?? this.activeEmergencies,
      history: history ?? this.history,
      myActiveEmergency:
          clearMyActive ? null : (myActiveEmergency ?? this.myActiveEmergency),
    );
  }
}

class EmergencyActionSuccess extends EmergencyState {
  final String message;
  EmergencyActionSuccess(this.message);
  @override
  List<Object?> get props => [message];
}

class EmergencyError extends EmergencyState {
  final String message;
  EmergencyError(this.message);
  @override
  List<Object?> get props => [message];
}

// ============ BLOC ============

class EmergencyBloc extends Bloc<EmergencyEvent, EmergencyState> {
  final WatchActiveEmergenciesUseCase watchActiveEmergencies;
  final CreateEmergencyUseCase createEmergency;
  final UpdateEmergencyLocationUseCase updateEmergencyLocation;
  final ResolveEmergencyUseCase resolveEmergency;
  final CancelEmergencyUseCase cancelEmergency;
  final GetEmergencyHistoryUseCase getEmergencyHistory;
  final GetActiveEmergencyByDriverUseCase getActiveByDriver;

  StreamSubscription<List<EmergencyModel>>? _emergencySubscription;

  EmergencyBloc({
    required this.watchActiveEmergencies,
    required this.createEmergency,
    required this.updateEmergencyLocation,
    required this.resolveEmergency,
    required this.cancelEmergency,
    required this.getEmergencyHistory,
    required this.getActiveByDriver,
  }) : super(EmergencyInitial()) {
    on<EmergencyWatchStarted>(_onWatchStarted);
    on<EmergencyUpdated>(_onUpdated);
    on<EmergencyCreateRequested>(_onCreateEmergency);
    on<EmergencyLocationUpdateRequested>(_onUpdateLocation);
    on<EmergencyResolveRequested>(_onResolve);
    on<EmergencyCancelRequested>(_onCancel);
    on<EmergencyHistoryRequested>(_onLoadHistory);
    on<EmergencyCheckActiveRequested>(_onCheckActive);
  }

  Future<void> _onWatchStarted(
    EmergencyWatchStarted event,
    Emitter<EmergencyState> emit,
  ) async {
    await _emergencySubscription?.cancel();
    _emergencySubscription = watchActiveEmergencies().listen(
      (emergencies) => add(EmergencyUpdated(emergencies)),
    );
  }

  void _onUpdated(
    EmergencyUpdated event,
    Emitter<EmergencyState> emit,
  ) {
    final current = state;
    if (current is EmergencyLoaded) {
      emit(current.copyWith(activeEmergencies: event.emergencies));
    } else {
      emit(EmergencyLoaded(activeEmergencies: event.emergencies));
    }
  }

  Future<void> _onCreateEmergency(
    EmergencyCreateRequested event,
    Emitter<EmergencyState> emit,
  ) async {
    try {
      await createEmergency(event.emergency);
      emit(EmergencyActionSuccess('¡Alerta de emergencia activada!'));
    } catch (e) {
      emit(EmergencyError('Error al activar emergencia: $e'));
    }
  }

  Future<void> _onUpdateLocation(
    EmergencyLocationUpdateRequested event,
    Emitter<EmergencyState> emit,
  ) async {
    try {
      await updateEmergencyLocation(UpdateEmergencyLocationParams(
        emergencyId: event.emergencyId,
        latitude: event.latitude,
        longitude: event.longitude,
      ));
    } catch (e) {
      // Silently fail location updates to avoid flooding errors
    }
  }

  Future<void> _onResolve(
    EmergencyResolveRequested event,
    Emitter<EmergencyState> emit,
  ) async {
    try {
      await resolveEmergency(ResolveEmergencyParams(
        emergencyId: event.emergencyId,
        resolvedBy: event.resolvedBy,
        notes: event.notes,
      ));
      emit(EmergencyActionSuccess('Emergencia resuelta'));
    } catch (e) {
      emit(EmergencyError('Error al resolver emergencia: $e'));
    }
  }

  Future<void> _onCancel(
    EmergencyCancelRequested event,
    Emitter<EmergencyState> emit,
  ) async {
    try {
      await cancelEmergency(event.emergencyId);
      final current = state;
      if (current is EmergencyLoaded) {
        emit(current.copyWith(clearMyActive: true));
      }
      emit(EmergencyActionSuccess('Alerta de emergencia desactivada'));
    } catch (e) {
      emit(EmergencyError('Error al cancelar emergencia: $e'));
    }
  }

  Future<void> _onLoadHistory(
    EmergencyHistoryRequested event,
    Emitter<EmergencyState> emit,
  ) async {
    try {
      final history = await getEmergencyHistory(event.limit);
      final current = state;
      if (current is EmergencyLoaded) {
        emit(current.copyWith(history: history));
      } else {
        emit(EmergencyLoaded(history: history));
      }
    } catch (e) {
      emit(EmergencyError('Error al cargar historial: $e'));
    }
  }

  Future<void> _onCheckActive(
    EmergencyCheckActiveRequested event,
    Emitter<EmergencyState> emit,
  ) async {
    try {
      final active = await getActiveByDriver(event.driverId);
      final current = state;
      if (current is EmergencyLoaded) {
        emit(current.copyWith(myActiveEmergency: active));
      } else {
        emit(EmergencyLoaded(myActiveEmergency: active));
      }
    } catch (e) {
      emit(EmergencyError('Error al verificar emergencia activa: $e'));
    }
  }

  @override
  Future<void> close() {
    _emergencySubscription?.cancel();
    return super.close();
  }
}
