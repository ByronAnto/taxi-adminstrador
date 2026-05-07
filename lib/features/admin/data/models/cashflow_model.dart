import 'package:cloud_firestore/cloud_firestore.dart';

enum CashflowType { ingreso, egreso }

/// Movimiento contable (ingreso o egreso) de una asociación.
/// Multi-tenant por [associationId]. Solo admin del tenant puede CRUD.
class CashflowMovement {
  final String uid;
  final String associationId;

  final CashflowType tipo;

  /// Categoría libre, configurada por la asociación en
  /// associations/{aid}.cashflowCategories.
  final String categoria;
  final String? subcategoria;

  /// Siempre positivo. El signo lo da [tipo].
  final double monto;

  final DateTime fecha;

  /// 'efectivo' | 'transferencia' | 'deposito' | null
  final String? metodoPago;

  /// Para egresos: a quién se pagó (operadora, proveedor, etc.).
  final String? beneficiario;

  final String? descripcion;
  final String? comprobanteUrl;

  /// userId del admin que registró.
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  const CashflowMovement({
    required this.uid,
    required this.associationId,
    required this.tipo,
    required this.categoria,
    this.subcategoria,
    required this.monto,
    required this.fecha,
    this.metodoPago,
    this.beneficiario,
    this.descripcion,
    this.comprobanteUrl,
    required this.createdBy,
    required this.createdAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  bool get isIngreso => tipo == CashflowType.ingreso;
  bool get isEgreso => tipo == CashflowType.egreso;

  factory CashflowMovement.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return CashflowMovement(
      uid: doc.id,
      associationId: data['associationId'] ?? '',
      tipo: data['tipo'] == 'egreso'
          ? CashflowType.egreso
          : CashflowType.ingreso,
      categoria: data['categoria'] ?? '',
      subcategoria: data['subcategoria'],
      monto: (data['monto'] ?? 0).toDouble(),
      fecha: (data['fecha'] as Timestamp?)?.toDate() ?? DateTime.now(),
      metodoPago: data['metodoPago'],
      beneficiario: data['beneficiario'],
      descripcion: data['descripcion'],
      comprobanteUrl: data['comprobanteUrl'],
      createdBy: data['createdBy'] ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'associationId': associationId,
      'tipo': tipo.name,
      'categoria': categoria,
      'subcategoria': subcategoria,
      'monto': monto,
      'fecha': Timestamp.fromDate(fecha),
      'metodoPago': metodoPago,
      'beneficiario': beneficiario,
      'descripcion': descripcion,
      'comprobanteUrl': comprobanteUrl,
      'createdBy': createdBy,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }
}

/// Plantilla de categorías por defecto, copiada al doc
/// associations/{aid}.cashflowCategories cuando un admin lo edita por
/// primera vez. El admin puede agregar/quitar libremente desde allí.
class DefaultCashflowCategories {
  DefaultCashflowCategories._();

  static const List<String> ingresos = [
    'Cuotas mensuales',
    'Cuotas semanales',
    'Multas',
    'Recargas',
    'Inscripción de socio',
    'Eventos',
    'Otros ingresos',
  ];

  static const List<String> egresos = [
    'Sueldo operadoras',
    'Mantenimiento radio',
    'Servicios (luz, agua, internet)',
    'Arriendo oficina',
    'Insumos',
    'Impuestos',
    'Eventos',
    'Otros egresos',
  ];
}
