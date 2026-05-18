import 'package:cloud_firestore/cloud_firestore.dart';

/// Estado de un pago reportado por el conductor.
enum PaymentStatus { pending, validated, rejected }

/// Método de pago del comprobante.
enum PaymentMethod { transferencia, deposito, efectivo }

/// Bancos ecuatorianos soportados en el dropdown.
class PaymentBanks {
  PaymentBanks._();
  static const List<String> ecuador = [
    'Pichincha',
    'Pacífico',
    'Guayaquil',
    'Bolivariano',
    'Internacional',
    'ProduBanco',
    'JEP',
    'BanEcuador',
    'Loja',
    'Solidario',
    'Otros',
  ];
}

/// Detalle del comprobante adjunto al pago.
///
/// Si [method] es `efectivo`, se llena [deliveredTo]. Si es transferencia
/// o depósito, se llenan [bank], [transactionRef], [transactionDate] y
/// opcionalmente [photoUrl].
class PaymentProof {
  final PaymentMethod method;

  /// Banco (uno de [PaymentBanks.ecuador]). Solo si method != efectivo.
  final String? bank;

  /// Si bank == 'Otros', nombre libre escrito por el conductor.
  final String? bankOther;

  /// Número de comprobante / papeleta. Solo si method != efectivo.
  final String? transactionRef;

  /// Fecha en la que se hizo la transferencia/depósito.
  final DateTime? transactionDate;

  /// A quién se entregó el efectivo (operadora, admin, etc.).
  /// Solo si method == efectivo.
  final String? deliveredTo;

  /// URL del comprobante en Cloud Storage. Opcional.
  final String? photoUrl;

  /// Cuándo se debe purgar el blob (Storage).
  /// Si null, no se purga (admin opcionalmente lo desactivó).
  final DateTime? photoExpiresAt;

  /// True si el blob ya se purgó pero el doc Firestore sigue.
  final bool photoExpired;

  const PaymentProof({
    required this.method,
    this.bank,
    this.bankOther,
    this.transactionRef,
    this.transactionDate,
    this.deliveredTo,
    this.photoUrl,
    this.photoExpiresAt,
    this.photoExpired = false,
  });

  factory PaymentProof.fromMap(Map<String, dynamic>? data) {
    if (data == null) {
      return const PaymentProof(method: PaymentMethod.efectivo);
    }
    return PaymentProof(
      method: _methodFromString(data['method'] as String?),
      bank: data['bank'] as String?,
      bankOther: data['bankOther'] as String?,
      transactionRef: data['transactionRef'] as String?,
      transactionDate:
          (data['transactionDate'] as Timestamp?)?.toDate(),
      deliveredTo: data['deliveredTo'] as String?,
      photoUrl: data['photoUrl'] as String?,
      photoExpiresAt: (data['photoExpiresAt'] as Timestamp?)?.toDate(),
      photoExpired: data['photoExpired'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'method': method.name,
        'bank': bank,
        'bankOther': bankOther,
        'transactionRef': transactionRef,
        'transactionDate':
            transactionDate != null ? Timestamp.fromDate(transactionDate!) : null,
        'deliveredTo': deliveredTo,
        'photoUrl': photoUrl,
        'photoExpiresAt':
            photoExpiresAt != null ? Timestamp.fromDate(photoExpiresAt!) : null,
        'photoExpired': photoExpired,
      };

  /// Etiqueta humana del banco (incluye "Otros" + nombre libre).
  String get bankLabel {
    if (method == PaymentMethod.efectivo) return '—';
    if (bank == 'Otros' && bankOther != null && bankOther!.isNotEmpty) {
      return bankOther!;
    }
    return bank ?? '';
  }

  static PaymentMethod _methodFromString(String? value) {
    switch (value) {
      case 'transferencia':
        return PaymentMethod.transferencia;
      case 'deposito':
        return PaymentMethod.deposito;
      case 'efectivo':
      default:
        return PaymentMethod.efectivo;
    }
  }
}

/// Pago que un conductor reporta a la asociación (cuota, multa, etc.).
///
/// Multi-tenant: campo [associationId] obligatorio.
class PaymentModel {
  final String uid;
  final String associationId;
  final String driverId;

  /// Denormalizado del conductor al momento del reporte. Permite mostrar
  /// nombre + unidad en la lista del admin sin hacer un lookup adicional.
  /// Puede ser null en docs antiguos creados antes de la denormalización.
  final String? driverName;
  final String? driverVehicleNumber;

  final double amount;

  /// cuota_mensual | cuota_semanal | multa | deuda | incentivo | ayuda
  final String concept;

  final PaymentStatus status;

  /// Fecha del pago real (la que reporta el conductor).
  final DateTime paymentDate;

  /// Fecha de vencimiento (si aplica).
  final DateTime? dueDate;

  /// Notas del conductor o del admin.
  final String? notes;

  final PaymentProof? proof;

  // Auditoría
  final DateTime reportedAt;
  final String? validatedBy;
  final DateTime? validatedAt;
  final String? rejectionReason;

  /// True si fue **emitido por admin/operadora** como un cobro one-off
  /// (multa, ayuda, deuda, cuota extra) en vez de generado automáticamente
  /// por el ciclo de cuotas. El conductor ve estos como "Por pagar" y
  /// debe reportarlos con comprobante.
  final bool isOneOff;

  /// uid del admin/operadora que emitió el cobro (solo si isOneOff=true).
  final String? emittedBy;

  /// Nombre legible del que emitió, para auditoría rápida.
  final String? emittedByName;

  /// Cuándo se emitió el cobro (server timestamp en creación).
  final DateTime? emittedAt;

  // Campos de anulación
  /// Cuándo fue anulado el pago (si aplica). Si no es null, el pago está anulado.
  final DateTime? voidedAt;

  /// UID del admin que anuló el pago.
  final String? voidedBy;

  /// Motivo de la anulación.
  final String? voidReason;

  /// True cuando este pago es una membresía de asociación (admin → super-admin).
  final bool targetSuperAdmin;

  const PaymentModel({
    required this.uid,
    required this.associationId,
    required this.driverId,
    this.driverName,
    this.driverVehicleNumber,
    required this.amount,
    required this.concept,
    this.status = PaymentStatus.pending,
    required this.paymentDate,
    this.dueDate,
    this.notes,
    this.proof,
    required this.reportedAt,
    this.validatedBy,
    this.validatedAt,
    this.rejectionReason,
    this.isOneOff = false,
    this.emittedBy,
    this.emittedByName,
    this.emittedAt,
    this.voidedAt,
    this.voidedBy,
    this.voidReason,
    this.targetSuperAdmin = false,
  });

  /// True si el conductor todavía no ha reportado el pago de un cobro
  /// emitido por admin (sin proof). Esto distingue "Por pagar" (cobro
  /// pendiente que NO se ha pagado) vs "Pendiente de validación" (ya
  /// reportó pero no validaron).
  bool get isUnpaidCharge =>
      isOneOff && status == PaymentStatus.pending && proof == null;

  bool get isPending => status == PaymentStatus.pending;
  bool get isValidated => status == PaymentStatus.validated;
  bool get isRejected => status == PaymentStatus.rejected;

  /// True si el pago fue anulado por un admin.
  bool get isVoided => voidedAt != null;

  /// True si el pago está validado Y no ha sido anulado.
  bool get isEffectivelyValidated =>
      status == PaymentStatus.validated && !isVoided;

  factory PaymentModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return PaymentModel(
      uid: doc.id,
      associationId: data['associationId'] as String? ?? '',
      driverId: data['driverId'] as String? ?? '',
      driverName: data['driverName'] as String?,
      driverVehicleNumber: data['driverVehicleNumber'] as String?,
      amount: (data['amount'] as num?)?.toDouble() ?? 0.0,
      concept: data['concept'] as String? ?? 'cuota_mensual',
      status: _statusFromString(data['status']),
      paymentDate:
          (data['paymentDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      dueDate: (data['dueDate'] as Timestamp?)?.toDate(),
      notes: data['notes'] as String?,
      proof: data['proof'] != null
          ? PaymentProof.fromMap(data['proof'] as Map<String, dynamic>)
          : null,
      reportedAt:
          (data['reportedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      validatedBy: data['validatedBy'] as String?,
      validatedAt: (data['validatedAt'] as Timestamp?)?.toDate(),
      rejectionReason: data['rejectionReason'] as String?,
      isOneOff: data['isOneOff'] as bool? ?? false,
      emittedBy: data['emittedBy'] as String?,
      emittedByName: data['emittedByName'] as String?,
      emittedAt: (data['emittedAt'] as Timestamp?)?.toDate(),
      voidedAt: (data['voidedAt'] as Timestamp?)?.toDate(),
      voidedBy: data['voidedBy'] as String?,
      voidReason: data['voidReason'] as String?,
      targetSuperAdmin: data['targetSuperAdmin'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'associationId': associationId,
      'driverId': driverId,
      'driverName': driverName,
      'driverVehicleNumber': driverVehicleNumber,
      'amount': amount,
      'concept': concept,
      'status': status.name,
      'paymentDate': Timestamp.fromDate(paymentDate),
      'dueDate': dueDate != null ? Timestamp.fromDate(dueDate!) : null,
      'notes': notes,
      'proof': proof?.toMap(),
      'reportedAt': Timestamp.fromDate(reportedAt),
      'validatedBy': validatedBy,
      'validatedAt':
          validatedAt != null ? Timestamp.fromDate(validatedAt!) : null,
      'rejectionReason': rejectionReason,
      'isOneOff': isOneOff,
      'emittedBy': emittedBy,
      'emittedByName': emittedByName,
      'emittedAt':
          emittedAt != null ? Timestamp.fromDate(emittedAt!) : null,
      if (voidedAt != null) 'voidedAt': Timestamp.fromDate(voidedAt!),
      if (voidedBy != null) 'voidedBy': voidedBy,
      if (voidReason != null) 'voidReason': voidReason,
      'targetSuperAdmin': targetSuperAdmin,
    };
  }

  static PaymentStatus _statusFromString(dynamic value) {
    switch (value) {
      case 'validated':
      case 'pagado':
        return PaymentStatus.validated;
      case 'rejected':
        return PaymentStatus.rejected;
      case 'pending':
      case 'pendiente':
      default:
        return PaymentStatus.pending;
    }
  }
}

/// Etiquetas humanas para los conceptos de pago.
class PaymentConcepts {
  PaymentConcepts._();

  /// Membresía que el admin de una asociación paga al super-admin.
  static const String membresiaAsociacion = 'membresia_asociacion';

  static const Map<String, String> labels = {
    'cuota_mensual': 'Cuota mensual',
    'cuota_semanal': 'Cuota semanal',
    'multa': 'Multa',
    'deuda': 'Deuda',
    'incentivo': 'Incentivo',
    'ayuda': 'Ayuda',
    'membresia_asociacion': 'Membresía asociación',
  };
  static String label(String concept) => labels[concept] ?? concept;
}

/// Modelo de gasto del conductor (sin cambios respecto a v1).
class ExpenseModel {
  final String uid;
  final String driverId;
  final String category;
  final double amount;
  final String description;
  final String? receiptUrl;
  final DateTime date;
  final DateTime createdAt;

  const ExpenseModel({
    required this.uid,
    required this.driverId,
    required this.category,
    required this.amount,
    required this.description,
    this.receiptUrl,
    required this.date,
    required this.createdAt,
  });

  factory ExpenseModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ExpenseModel(
      uid: doc.id,
      driverId: data['driverId'] ?? '',
      category: data['category'] ?? '',
      amount: (data['amount'] ?? 0.0).toDouble(),
      description: data['description'] ?? '',
      receiptUrl: data['receiptUrl'],
      date: (data['date'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'driverId': driverId,
      'category': category,
      'amount': amount,
      'description': description,
      'receiptUrl': receiptUrl,
      'date': Timestamp.fromDate(date),
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}
