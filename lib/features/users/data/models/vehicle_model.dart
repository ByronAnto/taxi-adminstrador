import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo de vehículo para Firestore
class VehicleModel {
  final String uid;
  final String driverId;
  final String plate;
  final String brand;
  final String model;
  final int year;
  final String color;
  final String type; // sedan, suv, etc.
  final String cooperativeNumber; // número de la cooperativa
  final bool isActive;
  final String? photoUrl;
  final DateTime createdAt;
  final DateTime updatedAt;

  const VehicleModel({
    required this.uid,
    required this.driverId,
    required this.plate,
    required this.brand,
    required this.model,
    required this.year,
    required this.color,
    this.type = 'sedan',
    required this.cooperativeNumber,
    this.isActive = true,
    this.photoUrl,
    required this.createdAt,
    required this.updatedAt,
  });

  factory VehicleModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return VehicleModel(
      uid: doc.id,
      driverId: data['driverId'] ?? '',
      plate: data['plate'] ?? '',
      brand: data['brand'] ?? '',
      model: data['model'] ?? '',
      year: data['year'] ?? 0,
      color: data['color'] ?? '',
      type: data['type'] ?? 'sedan',
      cooperativeNumber: data['cooperativeNumber'] ?? '',
      isActive: data['isActive'] ?? true,
      photoUrl: data['photoUrl'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'driverId': driverId,
      'plate': plate,
      'brand': brand,
      'model': model,
      'year': year,
      'color': color,
      'type': type,
      'cooperativeNumber': cooperativeNumber,
      'isActive': isActive,
      'photoUrl': photoUrl,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }
}
