import 'package:equatable/equatable.dart';

/// Entidad de conductor (extiende el usuario con datos específicos)
class DriverEntity extends Equatable {
  final String uid;
  final String userId;
  final String licenseNumber;
  final String licenseType;
  final DateTime licenseExpiry;
  final String status; // libre, con_pasajero, en_camino_base, desconectado
  final double? currentLatitude;
  final double? currentLongitude;
  final double rating;
  final int totalTrips;
  final int totalPoints; // programa de incentivos
  final List<String> vehicleIds;
  final String? activeVehicleId;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  const DriverEntity({
    required this.uid,
    required this.userId,
    required this.licenseNumber,
    required this.licenseType,
    required this.licenseExpiry,
    this.status = 'desconectado',
    this.currentLatitude,
    this.currentLongitude,
    this.rating = 5.0,
    this.totalTrips = 0,
    this.totalPoints = 0,
    this.vehicleIds = const [],
    this.activeVehicleId,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  });

  @override
  List<Object?> get props => [uid, userId, licenseNumber];
}
