import 'package:cloud_firestore/cloud_firestore.dart';

/// Estado de un permiso temporal del conductor.
enum PermissionStatus { active, closed }

/// Permiso temporal: el conductor avisa que no va a trabajar X días.
/// Mientras esté `active`, su cuota recurrente se "congela" — el
/// cierre semanal lo marca como PERMISO (azul) y no cuenta NO PAGO.
///
/// Cuando regresa antes de tiempo (o el admin lo cierra), se calcula
/// el cobro proporcional por los días trabajados en el periodo de cuota
/// y se genera un payment one-off `concept=cuota_proporcional`.
class PermissionRecord {
  final String id;
  final String associationId;
  final String driverId;

  /// Nombre denormalizado para listas / reportes sin lookup adicional.
  final String? driverName;
  final String? driverVehicleNumber;

  /// Fecha de inicio (inclusive). El conductor pasa a "permiso" desde
  /// el día completo de este timestamp.
  final DateTime startDate;

  /// Fecha de fin esperada (inclusive). Si null, abierto/indefinido.
  final DateTime? expectedEndDate;

  /// Razón / motivo en texto libre.
  final String? reason;

  final PermissionStatus status;

  // Auditoría
  final String approvedBy;
  final DateTime approvedAt;

  /// Si el permiso fue cerrado antes de la fecha esperada (regreso
  /// anticipado), esta es la fecha real de regreso.
  final DateTime? actualReturnDate;
  final String? closedBy;
  final DateTime? closedAt;

  /// Si al cerrar se generó un cobro proporcional, su id queda acá
  /// para auditoría.
  final String? proratedChargeId;

  const PermissionRecord({
    required this.id,
    required this.associationId,
    required this.driverId,
    this.driverName,
    this.driverVehicleNumber,
    required this.startDate,
    this.expectedEndDate,
    this.reason,
    this.status = PermissionStatus.active,
    required this.approvedBy,
    required this.approvedAt,
    this.actualReturnDate,
    this.closedBy,
    this.closedAt,
    this.proratedChargeId,
  });

  bool get isActive => status == PermissionStatus.active;

  /// True si la fecha [d] cae dentro del rango del permiso (inclusive).
  bool coversDate(DateTime d) {
    final at = DateTime(d.year, d.month, d.day);
    final start = DateTime(startDate.year, startDate.month, startDate.day);
    if (at.isBefore(start)) return false;
    final endRef = actualReturnDate ?? expectedEndDate;
    if (endRef == null) return true;
    final end = DateTime(endRef.year, endRef.month, endRef.day);
    // El día del regreso ya NO cuenta como permiso (regresó a trabajar).
    if (actualReturnDate != null) {
      return at.isBefore(end);
    }
    // expectedEndDate es inclusivo (fecha "hasta").
    return !at.isAfter(end);
  }

  factory PermissionRecord.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return PermissionRecord(
      id: doc.id,
      associationId: data['associationId'] as String? ?? '',
      driverId: data['driverId'] as String? ?? '',
      driverName: data['driverName'] as String?,
      driverVehicleNumber: data['driverVehicleNumber'] as String?,
      startDate:
          (data['startDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      expectedEndDate:
          (data['expectedEndDate'] as Timestamp?)?.toDate(),
      reason: data['reason'] as String?,
      status: data['status'] == 'closed'
          ? PermissionStatus.closed
          : PermissionStatus.active,
      approvedBy: data['approvedBy'] as String? ?? '',
      approvedAt:
          (data['approvedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      actualReturnDate:
          (data['actualReturnDate'] as Timestamp?)?.toDate(),
      closedBy: data['closedBy'] as String?,
      closedAt: (data['closedAt'] as Timestamp?)?.toDate(),
      proratedChargeId: data['proratedChargeId'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'associationId': associationId,
        'driverId': driverId,
        'driverName': driverName,
        'driverVehicleNumber': driverVehicleNumber,
        'startDate': Timestamp.fromDate(startDate),
        'expectedEndDate': expectedEndDate != null
            ? Timestamp.fromDate(expectedEndDate!)
            : null,
        'reason': reason,
        'status': status.name,
        'approvedBy': approvedBy,
        'approvedAt': Timestamp.fromDate(approvedAt),
        'actualReturnDate': actualReturnDate != null
            ? Timestamp.fromDate(actualReturnDate!)
            : null,
        'closedBy': closedBy,
        'closedAt':
            closedAt != null ? Timestamp.fromDate(closedAt!) : null,
        'proratedChargeId': proratedChargeId,
      };
}
