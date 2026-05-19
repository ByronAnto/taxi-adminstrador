import 'package:cloud_firestore/cloud_firestore.dart';

enum VehicleChangeStatus { pending, approved, rejected }

class VehicleChangeRequest {
  final String uid;
  final String driverId;
  final String driverName;
  final String associationId;
  final VehicleChangeStatus status;

  final String oldPlate;
  final String oldVehicleNumber;
  final String? oldFotoVehiculo;

  final String newPlate;
  final String newVehicleNumber;
  final String? newFotoVehiculo;

  final String reason;

  final String? approvedBy;
  final String? approvedByName;
  final DateTime? approvedAt;

  final String? rejectedBy;
  final String? rejectedByName;
  final DateTime? rejectedAt;
  final String? rejectReason;

  final DateTime createdAt;
  final DateTime updatedAt;

  const VehicleChangeRequest({
    required this.uid,
    required this.driverId,
    required this.driverName,
    required this.associationId,
    required this.status,
    required this.oldPlate,
    required this.oldVehicleNumber,
    this.oldFotoVehiculo,
    required this.newPlate,
    required this.newVehicleNumber,
    this.newFotoVehiculo,
    required this.reason,
    this.approvedBy,
    this.approvedByName,
    this.approvedAt,
    this.rejectedBy,
    this.rejectedByName,
    this.rejectedAt,
    this.rejectReason,
    required this.createdAt,
    required this.updatedAt,
  });

  factory VehicleChangeRequest.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return VehicleChangeRequest(
      uid: doc.id,
      driverId: data['driverId'] ?? '',
      driverName: data['driverName'] ?? '',
      associationId: data['associationId'] ?? '',
      status: _statusFromString(data['status']),
      oldPlate: data['oldPlate'] ?? '',
      oldVehicleNumber: data['oldVehicleNumber'] ?? '',
      oldFotoVehiculo: data['oldFotoVehiculo'],
      newPlate: data['newPlate'] ?? '',
      newVehicleNumber: data['newVehicleNumber'] ?? '',
      newFotoVehiculo: data['newFotoVehiculo'],
      reason: data['reason'] ?? '',
      approvedBy: data['approvedBy'],
      approvedByName: data['approvedByName'],
      approvedAt: (data['approvedAt'] as Timestamp?)?.toDate(),
      rejectedBy: data['rejectedBy'],
      rejectedByName: data['rejectedByName'],
      rejectedAt: (data['rejectedAt'] as Timestamp?)?.toDate(),
      rejectReason: data['rejectReason'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  static VehicleChangeStatus _statusFromString(dynamic v) {
    switch (v) {
      case 'approved':
        return VehicleChangeStatus.approved;
      case 'rejected':
        return VehicleChangeStatus.rejected;
      default:
        return VehicleChangeStatus.pending;
    }
  }
}
