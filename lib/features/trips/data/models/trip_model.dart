import 'package:cloud_firestore/cloud_firestore.dart';

/// Estados de un viaje. Mantenidos como String para compat con docs antiguos
/// y para que las reglas Firestore puedan validarlos sin reflexión.
class TripStatus {
  TripStatus._();
  static const solicitado = 'solicitado';
  static const asignado = 'asignado';
  static const enRuta = 'enRuta';
  static const enProgreso = 'en_progreso'; // legacy
  static const finalizado = 'finalizado';
  static const completado = 'completado'; // legacy alias
  static const cancelado = 'cancelado';

  static const all = [
    solicitado,
    asignado,
    enRuta,
    enProgreso,
    finalizado,
    completado,
    cancelado,
  ];
}

/// Origen del viaje (de dónde se creó el documento).
class TripSource {
  TripSource._();

  /// Conductor pulsó "+1 carrera" en su app.
  static const manual = 'manual';

  /// Operadora asignó desde el modal del walkie-talkie.
  static const apkOperadora = 'apkOperadora';

  /// El conductor recibió la carrera por canal de radio.
  static const walkieTalkie = 'walkieTalkie';

  /// Solicitud creada desde el portal web del cliente.
  static const webCliente = 'webCliente';
}

/// Modelo de viaje para Firestore. Multi-tenant por [associationId].
///
/// El modelo unifica los reportes del conductor, las métricas de operadora
/// y la contabilidad del admin (ver Dominio C del PROMPT_MAESTRO).
class TripModel {
  final String uid;

  /// Multi-tenant: slug de la asociación. Vacío en docs legacy migrados.
  final String associationId;

  final String driverId;

  /// Nombre denormalizado del conductor (para mostrar en listas sin join).
  final String? driverName;

  final String? vehicleId;

  /// Operadora que asignó la carrera (si aplica).
  final String? operatorId;
  final String? operatorName;

  // Datos del cliente final (opcionales: el conductor puede no saberlos).
  final String? clienteNombre;
  final String? clienteTelefono;

  final double pickupLatitude;
  final double pickupLongitude;
  final String pickupAddress;
  final double? dropoffLatitude;
  final double? dropoffLongitude;
  final String? dropoffAddress;

  final String status;
  final double? fare;
  final String paymentMethod; // efectivo, digital
  final DateTime startTime;
  final DateTime? endTime;
  final int? durationMinutes;
  final double? distanceKm;
  final String? notes;

  /// Origen del documento (uno de [TripSource]).
  final String source;

  final DateTime createdAt;
  final DateTime updatedAt;

  const TripModel({
    required this.uid,
    this.associationId = '',
    required this.driverId,
    this.driverName,
    this.vehicleId,
    this.operatorId,
    this.operatorName,
    this.clienteNombre,
    this.clienteTelefono,
    required this.pickupLatitude,
    required this.pickupLongitude,
    required this.pickupAddress,
    this.dropoffLatitude,
    this.dropoffLongitude,
    this.dropoffAddress,
    this.status = TripStatus.asignado,
    this.fare,
    this.paymentMethod = 'efectivo',
    required this.startTime,
    this.endTime,
    this.durationMinutes,
    this.distanceKm,
    this.notes,
    this.source = TripSource.manual,
    required this.createdAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  /// True si el viaje cuenta como "completado" para reportes y estadísticas.
  bool get isFinished =>
      status == TripStatus.finalizado || status == TripStatus.completado;

  factory TripModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return TripModel(
      uid: doc.id,
      associationId: data['associationId'] ?? '',
      driverId: data['driverId'] ?? '',
      driverName: data['driverName'],
      vehicleId: data['vehicleId'],
      operatorId: data['operatorId'],
      operatorName: data['operatorName'],
      clienteNombre: data['clienteNombre'],
      clienteTelefono: data['clienteTelefono'],
      pickupLatitude: (data['pickupLatitude'] ?? 0.0).toDouble(),
      pickupLongitude: (data['pickupLongitude'] ?? 0.0).toDouble(),
      pickupAddress: data['pickupAddress'] ?? '',
      dropoffLatitude: data['dropoffLatitude']?.toDouble(),
      dropoffLongitude: data['dropoffLongitude']?.toDouble(),
      dropoffAddress: data['dropoffAddress'],
      status: data['status'] ?? TripStatus.asignado,
      fare: data['fare']?.toDouble(),
      paymentMethod: data['paymentMethod'] ?? 'efectivo',
      startTime:
          (data['startTime'] as Timestamp?)?.toDate() ?? DateTime.now(),
      endTime: (data['endTime'] as Timestamp?)?.toDate(),
      durationMinutes: data['durationMinutes'],
      distanceKm: data['distanceKm']?.toDouble(),
      notes: data['notes'],
      source: data['source'] ?? TripSource.manual,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'associationId': associationId,
      'driverId': driverId,
      'driverName': driverName,
      'vehicleId': vehicleId,
      'operatorId': operatorId,
      'operatorName': operatorName,
      'clienteNombre': clienteNombre,
      'clienteTelefono': clienteTelefono,
      'pickupLatitude': pickupLatitude,
      'pickupLongitude': pickupLongitude,
      'pickupAddress': pickupAddress,
      'dropoffLatitude': dropoffLatitude,
      'dropoffLongitude': dropoffLongitude,
      'dropoffAddress': dropoffAddress,
      'status': status,
      'fare': fare,
      'paymentMethod': paymentMethod,
      'startTime': Timestamp.fromDate(startTime),
      'endTime': endTime != null ? Timestamp.fromDate(endTime!) : null,
      'durationMinutes': durationMinutes,
      'distanceKm': distanceKm,
      'notes': notes,
      'source': source,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }

  TripModel copyWith({
    String? associationId,
    String? driverName,
    String? operatorId,
    String? operatorName,
    String? clienteNombre,
    String? clienteTelefono,
    String? status,
    double? dropoffLatitude,
    double? dropoffLongitude,
    String? dropoffAddress,
    double? fare,
    DateTime? endTime,
    int? durationMinutes,
    double? distanceKm,
    String? notes,
    String? source,
  }) {
    return TripModel(
      uid: uid,
      associationId: associationId ?? this.associationId,
      driverId: driverId,
      driverName: driverName ?? this.driverName,
      vehicleId: vehicleId,
      operatorId: operatorId ?? this.operatorId,
      operatorName: operatorName ?? this.operatorName,
      clienteNombre: clienteNombre ?? this.clienteNombre,
      clienteTelefono: clienteTelefono ?? this.clienteTelefono,
      pickupLatitude: pickupLatitude,
      pickupLongitude: pickupLongitude,
      pickupAddress: pickupAddress,
      dropoffLatitude: dropoffLatitude ?? this.dropoffLatitude,
      dropoffLongitude: dropoffLongitude ?? this.dropoffLongitude,
      dropoffAddress: dropoffAddress ?? this.dropoffAddress,
      status: status ?? this.status,
      fare: fare ?? this.fare,
      paymentMethod: paymentMethod,
      startTime: startTime,
      endTime: endTime ?? this.endTime,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      distanceKm: distanceKm ?? this.distanceKm,
      notes: notes ?? this.notes,
      source: source ?? this.source,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}
