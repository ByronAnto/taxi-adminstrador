import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo de viaje para Firestore
class TripModel {
  final String uid;
  final String driverId;
  final String? vehicleId;
  final String? operatorId;
  final double pickupLatitude;
  final double pickupLongitude;
  final String pickupAddress;
  final double? dropoffLatitude;
  final double? dropoffLongitude;
  final String? dropoffAddress;
  final String status; // asignado, en_progreso, completado, cancelado
  final double? fare;
  final String paymentMethod; // efectivo, digital
  final DateTime startTime;
  final DateTime? endTime;
  final int? durationMinutes;
  final double? distanceKm;
  final String? notes;
  final DateTime createdAt;

  const TripModel({
    required this.uid,
    required this.driverId,
    this.vehicleId,
    this.operatorId,
    required this.pickupLatitude,
    required this.pickupLongitude,
    required this.pickupAddress,
    this.dropoffLatitude,
    this.dropoffLongitude,
    this.dropoffAddress,
    this.status = 'asignado',
    this.fare,
    this.paymentMethod = 'efectivo',
    required this.startTime,
    this.endTime,
    this.durationMinutes,
    this.distanceKm,
    this.notes,
    required this.createdAt,
  });

  factory TripModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return TripModel(
      uid: doc.id,
      driverId: data['driverId'] ?? '',
      vehicleId: data['vehicleId'],
      operatorId: data['operatorId'],
      pickupLatitude: (data['pickupLatitude'] ?? 0.0).toDouble(),
      pickupLongitude: (data['pickupLongitude'] ?? 0.0).toDouble(),
      pickupAddress: data['pickupAddress'] ?? '',
      dropoffLatitude: data['dropoffLatitude']?.toDouble(),
      dropoffLongitude: data['dropoffLongitude']?.toDouble(),
      dropoffAddress: data['dropoffAddress'],
      status: data['status'] ?? 'asignado',
      fare: data['fare']?.toDouble(),
      paymentMethod: data['paymentMethod'] ?? 'efectivo',
      startTime:
          (data['startTime'] as Timestamp?)?.toDate() ?? DateTime.now(),
      endTime: (data['endTime'] as Timestamp?)?.toDate(),
      durationMinutes: data['durationMinutes'],
      distanceKm: data['distanceKm']?.toDouble(),
      notes: data['notes'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'driverId': driverId,
      'vehicleId': vehicleId,
      'operatorId': operatorId,
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
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  TripModel copyWith({
    String? status,
    double? dropoffLatitude,
    double? dropoffLongitude,
    String? dropoffAddress,
    double? fare,
    DateTime? endTime,
    int? durationMinutes,
    double? distanceKm,
  }) {
    return TripModel(
      uid: uid,
      driverId: driverId,
      vehicleId: vehicleId,
      operatorId: operatorId,
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
      notes: notes,
      createdAt: createdAt,
    );
  }
}
