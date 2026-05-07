import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

class EmergencyModel extends Equatable {
  final String uid;
  final String driverId;
  final String driverName;
  final double latitude;
  final double longitude;
  final String? address;
  final String status; // active, resolved, cancelled
  final String? resolvedBy;
  final String? notes;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  const EmergencyModel({
    required this.uid,
    required this.driverId,
    required this.driverName,
    required this.latitude,
    required this.longitude,
    this.address,
    required this.status,
    this.resolvedBy,
    this.notes,
    required this.createdAt,
    this.resolvedAt,
  });

  factory EmergencyModel.fromMap(Map<String, dynamic> map, String id) {
    return EmergencyModel(
      uid: id,
      driverId: map['driverId'] ?? '',
      driverName: map['driverName'] ?? '',
      latitude: (map['latitude'] ?? 0).toDouble(),
      longitude: (map['longitude'] ?? 0).toDouble(),
      address: map['address'],
      status: map['status'] ?? 'active',
      resolvedBy: map['resolvedBy'],
      notes: map['notes'],
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      resolvedAt: (map['resolvedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'driverId': driverId,
      'driverName': driverName,
      'latitude': latitude,
      'longitude': longitude,
      'address': address,
      'status': status,
      'resolvedBy': resolvedBy,
      'notes': notes,
      'createdAt': Timestamp.fromDate(createdAt),
      'resolvedAt': resolvedAt != null ? Timestamp.fromDate(resolvedAt!) : null,
    };
  }

  EmergencyModel copyWith({
    String? uid,
    String? driverId,
    String? driverName,
    double? latitude,
    double? longitude,
    String? address,
    String? status,
    String? resolvedBy,
    String? notes,
    DateTime? createdAt,
    DateTime? resolvedAt,
  }) {
    return EmergencyModel(
      uid: uid ?? this.uid,
      driverId: driverId ?? this.driverId,
      driverName: driverName ?? this.driverName,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      address: address ?? this.address,
      status: status ?? this.status,
      resolvedBy: resolvedBy ?? this.resolvedBy,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
    );
  }

  @override
  List<Object?> get props => [uid, driverId, status, createdAt];
}
