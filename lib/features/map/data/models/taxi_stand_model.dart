import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo de una parada de taxis.
/// Admin y operadoras pueden configurar puntos de destino/parada en el mapa.
class TaxiStandModel {
  final String id;
  final String name;
  final String? address;
  final double latitude;
  final double longitude;
  final bool isActive;
  final String createdBy; // uid del admin/operadora que la creó
  final DateTime createdAt;
  final DateTime updatedAt;

  const TaxiStandModel({
    required this.id,
    required this.name,
    this.address,
    required this.latitude,
    required this.longitude,
    this.isActive = true,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  factory TaxiStandModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return TaxiStandModel(
      id: doc.id,
      name: data['name'] ?? '',
      address: data['address'],
      latitude: (data['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 0.0,
      isActive: data['isActive'] ?? true,
      createdBy: data['createdBy'] ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'isActive': isActive,
      'createdBy': createdBy,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }

  TaxiStandModel copyWith({
    String? id,
    String? name,
    String? address,
    double? latitude,
    double? longitude,
    bool? isActive,
    String? createdBy,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TaxiStandModel(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      isActive: isActive ?? this.isActive,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
