import 'package:cloud_firestore/cloud_firestore.dart';

/// Estado de la suscripción de una asociación.
enum AssociationStatus { trial, active, suspended, cancelled }

/// Unidad temporal del periodo de cobro.
enum BillingPeriodUnit { day, week, month, year }

/// Configuración del cobro de cuotas a los conductores.
///
/// Cada asociación define su propia política. Estos valores se editan
/// desde el panel admin (pantalla "Configuración de pagos").
class BillingConfig {
  /// Monto por defecto de la cuota (en USD).
  final double amount;

  /// Concepto por defecto cuando el conductor reporta un pago.
  /// Valores válidos: cuota_mensual, cuota_semanal, multa, deuda,
  /// incentivo, ayuda.
  final String defaultConcept;

  /// Cada cuántas unidades vence la cuota.
  /// Combina con [periodUnit] para formar el periodo:
  ///   every=1, unit=day    → diario
  ///   every=1, unit=week   → semanal
  ///   every=2, unit=week   → quincenal
  ///   every=1, unit=month  → mensual
  ///   every=2, unit=month  → bimestral
  ///   every=1, unit=year   → anual
  final int periodEvery;
  final BillingPeriodUnit periodUnit;

  /// Día del periodo en el que vence la cuota:
  /// - Para `month`: día del mes (1-28).
  /// - Para `week`: día de la semana (1=lunes ... 7=domingo).
  /// - Para `day`/`year`: ignorado.
  final int dueDay;

  /// Si true, las cuotas vencidas no pagadas acumulan deuda visible
  /// en el panel del conductor. Si false, solo se muestra la próxima.
  final bool allowDebtCarryOver;

  /// Días que se conserva el blob del comprobante en Cloud Storage
  /// antes de purgarse automáticamente. El doc Firestore queda
  /// permanente para auditoría.
  final int proofRetentionDays;

  /// Si true, el conductor puede adjuntar foto del comprobante.
  /// Si false, solo formulario sin foto.
  final bool allowProofPhoto;

  const BillingConfig({
    this.amount = 0.0,
    this.defaultConcept = 'cuota_mensual',
    this.periodEvery = 1,
    this.periodUnit = BillingPeriodUnit.month,
    this.dueDay = 1,
    this.allowDebtCarryOver = false,
    this.proofRetentionDays = 90,
    this.allowProofPhoto = true,
  });

  factory BillingConfig.fromMap(Map<String, dynamic>? data) {
    if (data == null) return const BillingConfig();
    final period = (data['period'] as Map<String, dynamic>?) ?? const {};
    return BillingConfig(
      amount: (data['amount'] as num?)?.toDouble() ?? 0.0,
      defaultConcept: data['defaultConcept'] as String? ?? 'cuota_mensual',
      periodEvery: (period['every'] as num?)?.toInt() ?? 1,
      periodUnit: _unitFromString(period['unit'] as String?),
      dueDay: (data['dueDay'] as num?)?.toInt() ?? 1,
      allowDebtCarryOver: data['allowDebtCarryOver'] as bool? ?? false,
      proofRetentionDays:
          (data['proofRetentionDays'] as num?)?.toInt() ?? 90,
      allowProofPhoto: data['allowProofPhoto'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toMap() => {
        'amount': amount,
        'defaultConcept': defaultConcept,
        'period': {
          'every': periodEvery,
          'unit': periodUnit.name,
        },
        'dueDay': dueDay,
        'allowDebtCarryOver': allowDebtCarryOver,
        'proofRetentionDays': proofRetentionDays,
        'allowProofPhoto': allowProofPhoto,
      };

  BillingConfig copyWith({
    double? amount,
    String? defaultConcept,
    int? periodEvery,
    BillingPeriodUnit? periodUnit,
    int? dueDay,
    bool? allowDebtCarryOver,
    int? proofRetentionDays,
    bool? allowProofPhoto,
  }) {
    return BillingConfig(
      amount: amount ?? this.amount,
      defaultConcept: defaultConcept ?? this.defaultConcept,
      periodEvery: periodEvery ?? this.periodEvery,
      periodUnit: periodUnit ?? this.periodUnit,
      dueDay: dueDay ?? this.dueDay,
      allowDebtCarryOver: allowDebtCarryOver ?? this.allowDebtCarryOver,
      proofRetentionDays: proofRetentionDays ?? this.proofRetentionDays,
      allowProofPhoto: allowProofPhoto ?? this.allowProofPhoto,
    );
  }

  /// Etiqueta legible del periodo: "Mensual", "Cada 2 semanas", etc.
  String get periodLabel {
    final unitLabels = {
      BillingPeriodUnit.day: ['día', 'días'],
      BillingPeriodUnit.week: ['semana', 'semanas'],
      BillingPeriodUnit.month: ['mes', 'meses'],
      BillingPeriodUnit.year: ['año', 'años'],
    };
    final labels = unitLabels[periodUnit]!;
    if (periodEvery == 1) {
      switch (periodUnit) {
        case BillingPeriodUnit.day:
          return 'Diario';
        case BillingPeriodUnit.week:
          return 'Semanal';
        case BillingPeriodUnit.month:
          return 'Mensual';
        case BillingPeriodUnit.year:
          return 'Anual';
      }
    }
    return 'Cada $periodEvery ${labels[1]}';
  }

  static BillingPeriodUnit _unitFromString(String? value) {
    switch (value) {
      case 'day':
        return BillingPeriodUnit.day;
      case 'week':
        return BillingPeriodUnit.week;
      case 'year':
        return BillingPeriodUnit.year;
      case 'month':
      default:
        return BillingPeriodUnit.month;
    }
  }
}

/// Tema visual personalizado de cada asociación (white-label).
class AssociationTheme {
  final String primaryColor;   // hex "#1565C0"
  final String secondaryColor; // hex
  final String accentColor;    // hex
  final String? logoUrl;       // imagen del logo

  const AssociationTheme({
    required this.primaryColor,
    required this.secondaryColor,
    required this.accentColor,
    this.logoUrl,
  });

  factory AssociationTheme.fromMap(Map<String, dynamic>? data) {
    return AssociationTheme(
      primaryColor: data?['primaryColor'] ?? '#1565C0',
      secondaryColor: data?['secondaryColor'] ?? '#FFC107',
      accentColor: data?['accentColor'] ?? '#0D47A1',
      logoUrl: data?['logoUrl'],
    );
  }

  Map<String, dynamic> toMap() => {
        'primaryColor': primaryColor,
        'secondaryColor': secondaryColor,
        'accentColor': accentColor,
        'logoUrl': logoUrl,
      };

  static const AssociationTheme defaultTheme = AssociationTheme(
    primaryColor: '#1565C0',
    secondaryColor: '#FFC107',
    accentColor: '#0D47A1',
  );
}

/// Documento principal de cada asociación (multi-tenancy).
///
/// Cada doc tiene un slug interno (`id`) y un `code` corto público
/// que los conductores escriben al registrarse.
/// Ubicación física de la parada principal de la asociación + radio
/// permitido para que un conductor se sume a la cola.
///
/// Si `lat`/`lng` están en null, la asociación NO tiene parada
/// configurada y la validación de distancia queda deshabilitada
/// (cualquier conductor puede entrar a la cola desde cualquier lugar,
/// como funcionaba antes).
class StandLocation {
  final double? lat;
  final double? lng;

  /// Radio permitido en KM. Default 1 km.
  /// Si el conductor está dentro de este radio, puede entrar a la cola.
  final double radiusKm;

  /// Etiqueta opcional de la parada (ej. "Parque central").
  final String? label;

  const StandLocation({
    this.lat,
    this.lng,
    this.radiusKm = 1.0,
    this.label,
  });

  bool get isConfigured => lat != null && lng != null;

  factory StandLocation.fromMap(Map<String, dynamic>? data) {
    if (data == null) return const StandLocation();
    return StandLocation(
      lat: (data['lat'] as num?)?.toDouble(),
      lng: (data['lng'] as num?)?.toDouble(),
      radiusKm: (data['radiusKm'] as num?)?.toDouble() ?? 1.0,
      label: data['label'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
        'lat': lat,
        'lng': lng,
        'radiusKm': radiusKm,
        'label': label,
      };

  StandLocation copyWith({
    double? lat,
    double? lng,
    double? radiusKm,
    String? label,
  }) =>
      StandLocation(
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        radiusKm: radiusKm ?? this.radiusKm,
        label: label ?? this.label,
      );
}

class AssociationModel {
  /// Slug interno único, ej. "jipijapa", "la-roldos".
  final String id;

  /// Código corto público para registro de socios, ej. "JIPI", "ROLD".
  /// Único globalmente, en mayúsculas.
  final String code;

  final String name;
  final String city;
  final String? phone;
  final String? email;

  final AssociationStatus status;
  final String pricingTierId; // referencia a /pricingTiers/{id}

  final DateTime? trialEndsAt;
  final DateTime? paidUntil;
  final DateTime? suspendedAt;
  final String? suspendedReason; // 'expired_paid_until' | 'expired_trial' | 'manual'
  final int maxDrivers;        // límite del plan
  final int maxOperators;
  final int maxChannels;

  final String ownerUid;       // uid del admin de la asociación
  final AssociationTheme theme;
  final BillingConfig billingConfig;
  final StandLocation standLocation;

  final DateTime createdAt;
  final DateTime updatedAt;

  const AssociationModel({
    required this.id,
    required this.code,
    required this.name,
    required this.city,
    this.phone,
    this.email,
    required this.status,
    required this.pricingTierId,
    this.trialEndsAt,
    this.paidUntil,
    this.suspendedAt,
    this.suspendedReason,
    required this.maxDrivers,
    required this.maxOperators,
    required this.maxChannels,
    required this.ownerUid,
    required this.theme,
    this.billingConfig = const BillingConfig(),
    this.standLocation = const StandLocation(),
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isActive =>
      status == AssociationStatus.active || status == AssociationStatus.trial;

  bool get isInTrial => status == AssociationStatus.trial;

  factory AssociationModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return AssociationModel(
      id: doc.id,
      code: data['code'] ?? '',
      name: data['name'] ?? '',
      city: data['city'] ?? '',
      phone: data['phone'],
      email: data['email'],
      status: _statusFromString(data['status']),
      pricingTierId: data['pricingTierId'] ?? 'basic',
      trialEndsAt: (data['trialEndsAt'] as Timestamp?)?.toDate(),
      paidUntil: (data['paidUntil'] as Timestamp?)?.toDate(),
      suspendedAt: (data['suspendedAt'] as Timestamp?)?.toDate(),
      suspendedReason: data['suspendedReason'] as String?,
      maxDrivers: data['maxDrivers'] ?? 30,
      maxOperators: data['maxOperators'] ?? 1,
      maxChannels: data['maxChannels'] ?? 3,
      ownerUid: data['ownerUid'] ?? '',
      theme: AssociationTheme.fromMap(data['theme'] as Map<String, dynamic>?),
      billingConfig:
          BillingConfig.fromMap(data['billingConfig'] as Map<String, dynamic>?),
      standLocation: StandLocation.fromMap(
          data['standLocation'] as Map<String, dynamic>?),
      createdAt:
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt:
          (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'code': code,
      'name': name,
      'city': city,
      'phone': phone,
      'email': email,
      'status': status.name,
      'pricingTierId': pricingTierId,
      'trialEndsAt':
          trialEndsAt != null ? Timestamp.fromDate(trialEndsAt!) : null,
      'paidUntil':
          paidUntil != null ? Timestamp.fromDate(paidUntil!) : null,
      if (suspendedAt != null) 'suspendedAt': Timestamp.fromDate(suspendedAt!),
      if (suspendedReason != null) 'suspendedReason': suspendedReason,
      'maxDrivers': maxDrivers,
      'maxOperators': maxOperators,
      'maxChannels': maxChannels,
      'ownerUid': ownerUid,
      'theme': theme.toMap(),
      'billingConfig': billingConfig.toMap(),
      'standLocation': standLocation.toMap(),
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }

  static AssociationStatus _statusFromString(dynamic value) {
    switch (value) {
      case 'trial':
        return AssociationStatus.trial;
      case 'active':
        return AssociationStatus.active;
      case 'suspended':
        return AssociationStatus.suspended;
      case 'cancelled':
        return AssociationStatus.cancelled;
      default:
        return AssociationStatus.trial;
    }
  }
}
