import 'package:cloud_firestore/cloud_firestore.dart';

/// Plan de suscripción configurable por el super-admin.
///
/// Vive en `/pricingTiers/{id}` y NO está hardcodeado.
/// El super-admin puede crear, editar y archivar planes sin redeploy.
class PricingTierModel {
  final String id;          // "basic" | "pro" | "enterprise" | custom
  final String name;        // mostrado al usuario
  final String description;

  final double monthlyPriceUsd;
  final double yearlyPriceUsd; // descuento anual

  final int maxDrivers;
  final int maxOperators;
  final int maxChannels;

  /// Limita minutos de Agora al mes. Cero o null = ilimitado.
  final int? maxAgoraMinutesPerMonth;

  /// Si true, el plan se ofrece a nuevas asociaciones.
  final bool isPublic;

  /// Orden en el que se muestran (asc).
  final int sortOrder;

  final DateTime createdAt;
  final DateTime updatedAt;

  const PricingTierModel({
    required this.id,
    required this.name,
    required this.description,
    required this.monthlyPriceUsd,
    required this.yearlyPriceUsd,
    required this.maxDrivers,
    required this.maxOperators,
    required this.maxChannels,
    this.maxAgoraMinutesPerMonth,
    this.isPublic = true,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PricingTierModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return PricingTierModel(
      id: doc.id,
      name: data['name'] ?? '',
      description: data['description'] ?? '',
      monthlyPriceUsd: (data['monthlyPriceUsd'] as num?)?.toDouble() ?? 0,
      yearlyPriceUsd: (data['yearlyPriceUsd'] as num?)?.toDouble() ?? 0,
      maxDrivers: data['maxDrivers'] ?? 0,
      maxOperators: data['maxOperators'] ?? 0,
      maxChannels: data['maxChannels'] ?? 0,
      maxAgoraMinutesPerMonth: data['maxAgoraMinutesPerMonth'] as int?,
      isPublic: data['isPublic'] ?? true,
      sortOrder: data['sortOrder'] ?? 0,
      createdAt:
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt:
          (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'name': name,
        'description': description,
        'monthlyPriceUsd': monthlyPriceUsd,
        'yearlyPriceUsd': yearlyPriceUsd,
        'maxDrivers': maxDrivers,
        'maxOperators': maxOperators,
        'maxChannels': maxChannels,
        'maxAgoraMinutesPerMonth': maxAgoraMinutesPerMonth,
        'isPublic': isPublic,
        'sortOrder': sortOrder,
        'createdAt': Timestamp.fromDate(createdAt),
        'updatedAt': Timestamp.fromDate(updatedAt),
      };
}
