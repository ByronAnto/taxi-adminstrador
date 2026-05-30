import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../../users/data/models/driver_model.dart';
import '../../data/models/taxi_stand_model.dart';
import '../../domain/usecases/map_usecases.dart';

// ============ EVENTS ============

abstract class MapEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class MapDriversWatchStarted extends MapEvent {}

class MapDriversUpdated extends MapEvent {
  final List<DriverModel> drivers;
  MapDriversUpdated(this.drivers);
  @override
  List<Object?> get props => [drivers];
}

class MapUpdateLocation extends MapEvent {
  final String driverId;
  final double latitude;
  final double longitude;
  MapUpdateLocation({required this.driverId, required this.latitude, required this.longitude});
  @override
  List<Object?> get props => [driverId, latitude, longitude];
}

class MapUpdateDriverStatus extends MapEvent {
  final String driverId;
  final String status;
  MapUpdateDriverStatus({required this.driverId, required this.status});
  @override
  List<Object?> get props => [driverId, status];
}

class MapLoadNearbyDrivers extends MapEvent {
  final double latitude;
  final double longitude;
  final double radiusKm;
  MapLoadNearbyDrivers({required this.latitude, required this.longitude, this.radiusKm = 2.0});
  @override
  List<Object?> get props => [latitude, longitude, radiusKm];
}

// ─── Taxi Stand events ───

class MapTaxiStandsWatchStarted extends MapEvent {}

class MapTaxiStandsUpdated extends MapEvent {
  final List<TaxiStandModel> stands;
  MapTaxiStandsUpdated(this.stands);
  @override
  List<Object?> get props => [stands];
}

class MapCreateTaxiStand extends MapEvent {
  final TaxiStandModel stand;
  MapCreateTaxiStand(this.stand);
  @override
  List<Object?> get props => [stand];
}

class MapUpdateTaxiStand extends MapEvent {
  final TaxiStandModel stand;
  MapUpdateTaxiStand(this.stand);
  @override
  List<Object?> get props => [stand];
}

class MapDeleteTaxiStand extends MapEvent {
  final String standId;
  MapDeleteTaxiStand(this.standId);
  @override
  List<Object?> get props => [standId];
}

// ============ STATES ============

abstract class MapState extends Equatable {
  @override
  List<Object?> get props => [];
}

class MapInitial extends MapState {}

class MapLoading extends MapState {}

class MapLoaded extends MapState {
  final List<DriverModel> activeDrivers;
  final List<DriverModel> nearbyDrivers;
  final List<TaxiStandModel> taxiStands;

  MapLoaded({
    this.activeDrivers = const [],
    this.nearbyDrivers = const [],
    this.taxiStands = const [],
  });

  @override
  List<Object?> get props => [activeDrivers, nearbyDrivers, taxiStands];

  MapLoaded copyWith({
    List<DriverModel>? activeDrivers,
    List<DriverModel>? nearbyDrivers,
    List<TaxiStandModel>? taxiStands,
  }) {
    return MapLoaded(
      activeDrivers: activeDrivers ?? this.activeDrivers,
      nearbyDrivers: nearbyDrivers ?? this.nearbyDrivers,
      taxiStands: taxiStands ?? this.taxiStands,
    );
  }
}

class MapError extends MapState {
  final String message;
  MapError(this.message);
  @override
  List<Object?> get props => [message];
}

// ============ BLOC ============

class MapBloc extends Bloc<MapEvent, MapState> {
  final WatchActiveDriversUseCase watchActiveDrivers;
  final UpdateDriverLocationUseCase updateDriverLocation;
  final UpdateDriverStatusUseCase updateDriverStatus;
  final GetNearbyDriversUseCase getNearbyDrivers;
  final WatchTaxiStandsUseCase watchTaxiStands;
  final CreateTaxiStandUseCase createTaxiStand;
  final UpdateTaxiStandUseCase updateTaxiStandUseCase;
  final DeleteTaxiStandUseCase deleteTaxiStandUseCase;

  StreamSubscription<List<DriverModel>>? _driversSubscription;
  StreamSubscription<List<TaxiStandModel>>? _standsSubscription;

  MapBloc({
    required this.watchActiveDrivers,
    required this.updateDriverLocation,
    required this.updateDriverStatus,
    required this.getNearbyDrivers,
    required this.watchTaxiStands,
    required this.createTaxiStand,
    required this.updateTaxiStandUseCase,
    required this.deleteTaxiStandUseCase,
  }) : super(MapInitial()) {
    on<MapDriversWatchStarted>(_onWatchStarted);
    on<MapDriversUpdated>(_onDriversUpdated);
    on<MapUpdateLocation>(_onUpdateLocation);
    on<MapUpdateDriverStatus>(_onUpdateStatus);
    on<MapLoadNearbyDrivers>(_onLoadNearby);
    on<MapTaxiStandsWatchStarted>(_onStandsWatchStarted);
    on<MapTaxiStandsUpdated>(_onStandsUpdated);
    on<MapCreateTaxiStand>(_onCreateStand);
    on<MapUpdateTaxiStand>(_onUpdateStand);
    on<MapDeleteTaxiStand>(_onDeleteStand);
  }

  Future<void> _onWatchStarted(
    MapDriversWatchStarted event,
    Emitter<MapState> emit,
  ) async {
    emit(MapLoading());
    _subscribeDrivers();
  }

  /// Suscribe (o re-suscribe) el stream de conductores activos de forma
  /// resiliente: ante un error transitorio del listener (reconexión de
  /// Firestore, refresh de token, blip de red) NO borramos la lista actual
  /// —para que el mapa no quede sin unidades— y nos re-suscribimos tras un
  /// breve retardo, recuperando solos sin tener que reiniciar la app.
  void _subscribeDrivers() {
    _driversSubscription?.cancel();
    _driversSubscription = watchActiveDrivers().listen(
      (drivers) => add(MapDriversUpdated(drivers)),
      onError: (_) {
        Future.delayed(const Duration(seconds: 3), () {
          if (!isClosed) _subscribeDrivers();
        });
      },
    );
  }

  void _onDriversUpdated(
    MapDriversUpdated event,
    Emitter<MapState> emit,
  ) {
    final current = state;
    if (current is MapLoaded) {
      emit(current.copyWith(activeDrivers: event.drivers));
    } else {
      emit(MapLoaded(activeDrivers: event.drivers));
    }
  }

  Future<void> _onUpdateLocation(
    MapUpdateLocation event,
    Emitter<MapState> emit,
  ) async {
    try {
      await updateDriverLocation(UpdateLocationParams(
        driverId: event.driverId,
        latitude: event.latitude,
        longitude: event.longitude,
      ));
    } catch (_) {
      // Silencioso: fallo transitorio de GPS push no debe romper el mapa
    }
  }

  Future<void> _onUpdateStatus(
    MapUpdateDriverStatus event,
    Emitter<MapState> emit,
  ) async {
    try {
      await updateDriverStatus(UpdateStatusParams(
        driverId: event.driverId,
        status: event.status,
      ));
    } catch (_) {
      // Silencioso: fallo transitorio no debe romper el mapa
    }
  }

  Future<void> _onLoadNearby(
    MapLoadNearbyDrivers event,
    Emitter<MapState> emit,
  ) async {
    try {
      final nearby = await getNearbyDrivers(NearbyDriversParams(
        latitude: event.latitude,
        longitude: event.longitude,
        radiusKm: event.radiusKm,
      ));
      final current = state;
      if (current is MapLoaded) {
        emit(current.copyWith(nearbyDrivers: nearby));
      } else {
        emit(MapLoaded(nearbyDrivers: nearby));
      }
    } catch (e) {
      emit(MapError('Error al buscar conductores cercanos: $e'));
    }
  }

  // ─── Taxi Stands handlers ───

  Future<void> _onStandsWatchStarted(
    MapTaxiStandsWatchStarted event,
    Emitter<MapState> emit,
  ) async {
    _subscribeStands();
  }

  /// Igual que [_subscribeDrivers]: resiliente a errores transitorios del
  /// listener (no borra las paradas; se re-suscribe solo).
  void _subscribeStands() {
    _standsSubscription?.cancel();
    _standsSubscription = watchTaxiStands().listen(
      (stands) => add(MapTaxiStandsUpdated(stands)),
      onError: (_) {
        Future.delayed(const Duration(seconds: 3), () {
          if (!isClosed) _subscribeStands();
        });
      },
    );
  }

  void _onStandsUpdated(
    MapTaxiStandsUpdated event,
    Emitter<MapState> emit,
  ) {
    final current = state;
    if (current is MapLoaded) {
      emit(current.copyWith(taxiStands: event.stands));
    } else {
      emit(MapLoaded(taxiStands: event.stands));
    }
  }

  Future<void> _onCreateStand(
    MapCreateTaxiStand event,
    Emitter<MapState> emit,
  ) async {
    try {
      await createTaxiStand(event.stand);
    } catch (e) {
      emit(MapError('Error al crear parada: $e'));
    }
  }

  Future<void> _onUpdateStand(
    MapUpdateTaxiStand event,
    Emitter<MapState> emit,
  ) async {
    try {
      await updateTaxiStandUseCase(event.stand);
    } catch (e) {
      emit(MapError('Error al actualizar parada: $e'));
    }
  }

  Future<void> _onDeleteStand(
    MapDeleteTaxiStand event,
    Emitter<MapState> emit,
  ) async {
    try {
      await deleteTaxiStandUseCase(event.standId);
    } catch (e) {
      emit(MapError('Error al eliminar parada: $e'));
    }
  }

  @override
  Future<void> close() {
    _driversSubscription?.cancel();
    _standsSubscription?.cancel();
    return super.close();
  }
}
