import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo de conductor para Firestore
class DriverModel {
  final String uid;
  final String userId;
  final String licenseNumber;
  final String licenseType;
  final DateTime licenseExpiry;
  final String status;
  final double? currentLatitude;
  final double? currentLongitude;
  final double rating;
  final int totalTrips;
  final int totalPoints;
  final List<String> vehicleIds;
  final String? activeVehicleId;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Campos denormalizados para el mapa (vienen del UserModel)
  final String vehicleNumber; // número de unidad Jipijapa
  final String plate;         // placa del vehículo
  final String driverName;    // nombre completo del conductor

  const DriverModel({
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
    this.vehicleNumber = '',
    this.plate = '',
    this.driverName = '',
  });

  factory DriverModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return DriverModel(
      uid: doc.id,
      userId: data['userId'] ?? '',
      licenseNumber: data['licenseNumber'] ?? '',
      licenseType: data['licenseType'] ?? '',
      licenseExpiry:
          (data['licenseExpiry'] as Timestamp?)?.toDate() ?? DateTime.now(),
      status: data['status'] ?? 'desconectado',
      currentLatitude: data['currentLatitude']?.toDouble(),
      currentLongitude: data['currentLongitude']?.toDouble(),
      rating: (data['rating'] ?? 5.0).toDouble(),
      totalTrips: data['totalTrips'] ?? 0,
      totalPoints: data['totalPoints'] ?? 0,
      vehicleIds: List<String>.from(data['vehicleIds'] ?? []),
      activeVehicleId: data['activeVehicleId'],
      isActive: data['isActive'] ?? true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      vehicleNumber: data['vehicleNumber'] ?? '',
      plate: data['plate'] ?? '',
      driverName: data['driverName'] ?? '',
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'licenseNumber': licenseNumber,
      'licenseType': licenseType,
      'licenseExpiry': Timestamp.fromDate(licenseExpiry),
      'status': status,
      'currentLatitude': currentLatitude,
      'currentLongitude': currentLongitude,
      'rating': rating,
      'totalTrips': totalTrips,
      'totalPoints': totalPoints,
      'vehicleIds': vehicleIds,
      'activeVehicleId': activeVehicleId,
      'isActive': isActive,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'vehicleNumber': vehicleNumber,
      'plate': plate,
      'driverName': driverName,
    };
  }

  DriverModel copyWith({
    String? status,
    double? currentLatitude,
    double? currentLongitude,
    double? rating,
    int? totalTrips,
    int? totalPoints,
    List<String>? vehicleIds,
    String? activeVehicleId,
    bool? isActive,
    String? vehicleNumber,
    String? plate,
    String? driverName,
  }) {
    return DriverModel(
      uid: uid,
      userId: userId,
      licenseNumber: licenseNumber,
      licenseType: licenseType,
      licenseExpiry: licenseExpiry,
      status: status ?? this.status,
      currentLatitude: currentLatitude ?? this.currentLatitude,
      currentLongitude: currentLongitude ?? this.currentLongitude,
      rating: rating ?? this.rating,
      totalTrips: totalTrips ?? this.totalTrips,
      totalPoints: totalPoints ?? this.totalPoints,
      vehicleIds: vehicleIds ?? this.vehicleIds,
      activeVehicleId: activeVehicleId ?? this.activeVehicleId,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      vehicleNumber: vehicleNumber ?? this.vehicleNumber,
      plate: plate ?? this.plate,
      driverName: driverName ?? this.driverName,
    );
  }
}
