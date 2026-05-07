import 'package:cloud_firestore/cloud_firestore.dart';

/// Estado del usuario dentro de su asociación.
///
/// - `active`: cuenta normal con acceso completo según su rol.
/// - `pendingApproval`: auto-registro pendiente de aprobación admin.
/// - `rejected`: auto-registro rechazado por el admin.
/// - `suspended`: legacy. Equivalente a `disabledByAdmin`. Se conserva por
///   retrocompatibilidad pero el flujo nuevo usa `disabledByAdmin`.
/// - `paymentPending`: el plan de la asociación venció hace ≤ N días
///   (período de gracia). El conductor sigue operando normalmente pero ve
///   un banner de aviso.
/// - `paymentBlocked`: vencido + pasado el período de gracia, o el conductor
///   no pagó su cuota mensual. La app entra en modo SOLO PAGO: única
///   pantalla disponible es la de subir comprobante.
/// - `disabledByAdmin`: el admin lo desactivó manualmente. Mismo bloqueo
///   visual que `paymentBlocked` pero sin opción de subir pago.
enum UserStatus {
  active,
  pendingApproval,
  rejected,
  suspended,
  paymentPending,
  paymentBlocked,
  disabledByAdmin,
}

/// Modelo de usuario para Firestore.
///
/// Multi-tenant: cada usuario pertenece a UNA asociación
/// (campo [associationId]). Las reglas Firestore filtran por este campo.
class UserModel {
  final String uid;

  /// Slug de la asociación a la que pertenece. Vacío solo para super-admin.
  final String associationId;

  final String name;
  final String lastname;
  final String cedula;
  final String email;
  final String phone;
  final String role;        // 'admin' | 'operadora' | 'conductor' | 'superAdmin'
  final UserStatus status;
  final String? photoUrl;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Trazabilidad de aprobación (auto-registro)
  final String? approvedBy;
  final DateTime? approvedAt;

  // Campos de conductor / vehículo
  final String placa;
  final String cooperativa;
  final String codigoCooperativa;
  final String numeroVehiculo;
  final String? fotoVehiculo;
  final String? fotoLicenciaFrontal;
  final String? fotoLicenciaTrasera;

  const UserModel({
    required this.uid,
    required this.associationId,
    required this.name,
    required this.lastname,
    required this.cedula,
    required this.email,
    required this.phone,
    required this.role,
    this.status = UserStatus.active,
    this.photoUrl,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
    this.approvedBy,
    this.approvedAt,
    this.placa = '',
    this.cooperativa = '',
    this.codigoCooperativa = '',
    this.numeroVehiculo = '',
    this.fotoVehiculo,
    this.fotoLicenciaFrontal,
    this.fotoLicenciaTrasera,
  });

  bool get isPending => status == UserStatus.pendingApproval;
  bool get isApproved => status == UserStatus.active;

  /// True si el usuario debe ver la pantalla de "cuenta bloqueada" en vez
  /// del flujo normal de la app. Cubre suspended (legacy), paymentBlocked y
  /// disabledByAdmin.
  bool get isBlocked =>
      status == UserStatus.paymentBlocked ||
      status == UserStatus.disabledByAdmin ||
      status == UserStatus.suspended;

  /// True si el usuario puede subir comprobante de pago para reactivarse.
  /// Solo `paymentBlocked` lo permite; `disabledByAdmin` no.
  bool get canUploadPayment => status == UserStatus.paymentBlocked;

  /// True si el plan de la asociación está en período de gracia (banner).
  bool get hasPaymentWarning => status == UserStatus.paymentPending;

  factory UserModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return UserModel(
      uid: doc.id,
      associationId: data['associationId'] ?? '',
      name: data['name'] ?? '',
      lastname: data['lastname'] ?? '',
      cedula: data['cedula'] ?? '',
      email: data['email'] ?? '',
      phone: data['phone'] ?? '',
      role: data['role'] ?? 'conductor',
      status: _statusFromString(data['status']),
      photoUrl: data['photoUrl'],
      isActive: data['isActive'] ?? true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      approvedBy: data['approvedBy'],
      approvedAt: (data['approvedAt'] as Timestamp?)?.toDate(),
      placa: data['placa'] ?? '',
      cooperativa: data['cooperativa'] ?? '',
      codigoCooperativa: data['codigoCooperativa'] ?? '',
      numeroVehiculo: data['numeroVehiculo'] ?? '',
      fotoVehiculo: data['fotoVehiculo'],
      fotoLicenciaFrontal: data['fotoLicenciaFrontal'],
      fotoLicenciaTrasera: data['fotoLicenciaTrasera'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'associationId': associationId,
      'name': name,
      'lastname': lastname,
      'cedula': cedula,
      'email': email,
      'phone': phone,
      'role': role,
      'status': status.name,
      'photoUrl': photoUrl,
      'isActive': isActive,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'approvedBy': approvedBy,
      'approvedAt':
          approvedAt != null ? Timestamp.fromDate(approvedAt!) : null,
      'placa': placa,
      'cooperativa': cooperativa,
      'codigoCooperativa': codigoCooperativa,
      'numeroVehiculo': numeroVehiculo,
      'fotoVehiculo': fotoVehiculo,
      'fotoLicenciaFrontal': fotoLicenciaFrontal,
      'fotoLicenciaTrasera': fotoLicenciaTrasera,
    };
  }

  UserModel copyWith({
    String? associationId,
    String? name,
    String? lastname,
    String? cedula,
    String? email,
    String? phone,
    String? role,
    UserStatus? status,
    String? photoUrl,
    bool? isActive,
    String? approvedBy,
    DateTime? approvedAt,
    String? placa,
    String? cooperativa,
    String? codigoCooperativa,
    String? numeroVehiculo,
    String? fotoVehiculo,
    String? fotoLicenciaFrontal,
    String? fotoLicenciaTrasera,
  }) {
    return UserModel(
      uid: uid,
      associationId: associationId ?? this.associationId,
      name: name ?? this.name,
      lastname: lastname ?? this.lastname,
      cedula: cedula ?? this.cedula,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      status: status ?? this.status,
      photoUrl: photoUrl ?? this.photoUrl,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      approvedBy: approvedBy ?? this.approvedBy,
      approvedAt: approvedAt ?? this.approvedAt,
      placa: placa ?? this.placa,
      cooperativa: cooperativa ?? this.cooperativa,
      codigoCooperativa: codigoCooperativa ?? this.codigoCooperativa,
      numeroVehiculo: numeroVehiculo ?? this.numeroVehiculo,
      fotoVehiculo: fotoVehiculo ?? this.fotoVehiculo,
      fotoLicenciaFrontal: fotoLicenciaFrontal ?? this.fotoLicenciaFrontal,
      fotoLicenciaTrasera: fotoLicenciaTrasera ?? this.fotoLicenciaTrasera,
    );
  }

  static UserStatus _statusFromString(dynamic value) {
    switch (value) {
      case 'pendingApproval':
        return UserStatus.pendingApproval;
      case 'rejected':
        return UserStatus.rejected;
      case 'suspended':
        return UserStatus.suspended;
      case 'paymentPending':
        return UserStatus.paymentPending;
      case 'paymentBlocked':
        return UserStatus.paymentBlocked;
      case 'disabledByAdmin':
        return UserStatus.disabledByAdmin;
      case 'active':
      default:
        return UserStatus.active;
    }
  }
}
