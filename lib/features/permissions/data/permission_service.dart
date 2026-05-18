import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

import '../../auth/data/models/user_model.dart';
import '../../associations/data/models/association_model.dart';
import 'models/permission_record.dart';

/// Resultado del cálculo de cierre de permiso.
class PermissionCloseQuote {
  /// Días faltantes a cobrar en el periodo de cuota actual (donde cae
  /// el regreso). Si el conductor regresa antes del fin de período,
  /// son los días desde el regreso hasta el fin del período.
  final int daysToCharge;
  final int periodLengthDays;
  final double cuotaAmount;
  final double amountToCharge;
  final DateTime periodStart;
  final DateTime periodEnd;

  /// Si es 0, no se cobra nada (regresó después del periodo).
  bool get hasCharge => amountToCharge > 0;

  const PermissionCloseQuote({
    required this.daysToCharge,
    required this.periodLengthDays,
    required this.cuotaAmount,
    required this.amountToCharge,
    required this.periodStart,
    required this.periodEnd,
  });
}

/// Gestión de permisos temporales del conductor.
///
/// - `grant(...)` crea un permiso activo. Mientras dure, el cierre
///   semanal pinta a la unidad como PERMISO y no cuenta NO PAGO.
/// - `quoteClose(...)` calcula cuánto cobrar al cerrar el permiso
///   por los días del periodo donde el conductor regresó. Pure function,
///   no escribe nada — el admin ve el preview.
/// - `closeAndCharge(...)` cierra el permiso y, si corresponde, crea
///   un payment one-off (`concept=cuota_proporcional`, `isOneOff=true`)
///   para que el conductor lo pague.
class PermissionService {
  PermissionService._();
  static final PermissionService instance = PermissionService._();

  final _firestore = FirebaseFirestore.instance;

  /// Crea un permiso activo para el conductor.
  Future<PermissionRecord> grant({
    required UserModel driver,
    required UserModel approver,
    required DateTime startDate,
    DateTime? expectedEndDate,
    String? reason,
  }) async {
    final id = const Uuid().v4();
    final fullName = '${driver.name} ${driver.lastname}'.trim();
    final record = PermissionRecord(
      id: id,
      associationId: driver.associationId,
      driverId: driver.uid,
      driverName: fullName.isEmpty ? null : fullName,
      driverVehicleNumber:
          driver.numeroVehiculo.isEmpty ? null : driver.numeroVehiculo,
      startDate: startDate,
      expectedEndDate: expectedEndDate,
      reason: reason,
      status: PermissionStatus.active,
      approvedBy: approver.uid,
      approvedAt: DateTime.now(),
    );
    await _firestore
        .collection('permissions')
        .doc(id)
        .set(record.toFirestore());
    return record;
  }

  /// Stream de permisos activos por asociación. Útil para mapear
  /// driverId → si está en permiso hoy.
  Stream<List<PermissionRecord>> watchActivePermissions(String aid) {
    return _firestore
        .collection('permissions')
        .where('associationId', isEqualTo: aid)
        .where('status', isEqualTo: 'active')
        .snapshots()
        .map((snap) =>
            snap.docs.map(PermissionRecord.fromFirestore).toList());
  }

  /// Devuelve el permiso ACTIVO de un conductor (si existe).
  Future<PermissionRecord?> activeFor(String driverId) async {
    final snap = await _firestore
        .collection('permissions')
        .where('driverId', isEqualTo: driverId)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    return PermissionRecord.fromFirestore(snap.docs.first);
  }

  /// Calcula el cobro proporcional al cerrar el permiso en [returnDate].
  ///
  /// Estrategia:
  /// - El conductor regresa en una fecha que cae dentro de un periodo
  ///   de cuota (semana / mes según [billingConfig]).
  /// - Cobramos por los días desde el regreso hasta el fin de ese
  ///   periodo, prorrateando la cuota completa.
  /// - Periodos COMPLETOS dentro del rango de permiso se omiten (no
  ///   se cobra nada por ellos — eso es la idea del permiso).
  ///
  /// Ejemplo: cuota $10/semana, conductor regresa miércoles. Días por
  /// cobrar = mié + jue + vie + sáb + dom = 5. Cobro = 10/7 × 5 ≈ $7.14.
  PermissionCloseQuote quoteClose({
    required PermissionRecord permission,
    required DateTime returnDate,
    required BillingConfig billingConfig,
  }) {
    final cuota = billingConfig.amount;
    final returnDay =
        DateTime(returnDate.year, returnDate.month, returnDate.day);

    // Determinar el periodo de cuota actual (el que contiene returnDate).
    final (periodStart, periodEnd, periodLength) =
        _periodFor(returnDay, billingConfig);

    // Días que el conductor sí va a trabajar en este periodo.
    final dayAfterEnd = periodEnd.add(const Duration(days: 1));
    final diffDays = dayAfterEnd.difference(returnDay).inDays;
    final daysToCharge =
        diffDays < 0 ? 0 : (diffDays > periodLength ? periodLength : diffDays);

    final perDay = cuota / periodLength;
    final amountToCharge =
        (daysToCharge * perDay).clamp(0, cuota * 2).toDouble();

    return PermissionCloseQuote(
      daysToCharge: daysToCharge,
      periodLengthDays: periodLength,
      cuotaAmount: cuota,
      amountToCharge: amountToCharge,
      periodStart: periodStart,
      periodEnd: periodEnd,
    );
  }

  /// Cierra el permiso y, si [generateCharge] es true y la cotización
  /// arroja monto > 0, genera un payment one-off para que el conductor
  /// pague los días faltantes del periodo.
  Future<PermissionRecord> closeAndCharge({
    required PermissionRecord permission,
    required UserModel approver,
    required DateTime returnDate,
    required PermissionCloseQuote quote,
    required bool generateCharge,
    required UserModel driver,
  }) async {
    String? chargeId;

    if (generateCharge && quote.hasCharge) {
      // Crear el cobro one-off (proporcional). El conductor lo verá en
      // su /my-payments con badge POR PAGAR.
      chargeId = const Uuid().v4();
      final now = DateTime.now();
      await _firestore.collection('payments').doc(chargeId).set({
        'associationId': permission.associationId,
        'driverId': permission.driverId,
        'driverName':
            '${driver.name} ${driver.lastname}'.trim(),
        'driverVehicleNumber':
            driver.numeroVehiculo.isEmpty ? null : driver.numeroVehiculo,
        'amount': quote.amountToCharge,
        'concept': 'cuota_proporcional',
        'status': 'pending',
        'paymentDate': Timestamp.fromDate(now),
        'dueDate': Timestamp.fromDate(quote.periodEnd),
        'notes':
            'Regreso de permiso: ${quote.daysToCharge} días × \$${(quote.cuotaAmount / quote.periodLengthDays).toStringAsFixed(2)}/día.'
            '${permission.reason != null ? " (motivo permiso: ${permission.reason})" : ""}',
        'proof': null,
        'reportedAt': Timestamp.fromDate(now),
        'isOneOff': true,
        'emittedBy': approver.uid,
        'emittedByName': '${approver.name} ${approver.lastname}'.trim(),
        'emittedAt': FieldValue.serverTimestamp(),
        'fromPermissionId': permission.id,
      });
    }

    // Actualizar el permiso a closed.
    await _firestore
        .collection('permissions')
        .doc(permission.id)
        .update({
      'status': 'closed',
      'actualReturnDate': Timestamp.fromDate(returnDate),
      'closedBy': approver.uid,
      'closedAt': FieldValue.serverTimestamp(),
      if (chargeId != null) 'proratedChargeId': chargeId,
    });

    return PermissionRecord(
      id: permission.id,
      associationId: permission.associationId,
      driverId: permission.driverId,
      driverName: permission.driverName,
      driverVehicleNumber: permission.driverVehicleNumber,
      startDate: permission.startDate,
      expectedEndDate: permission.expectedEndDate,
      reason: permission.reason,
      status: PermissionStatus.closed,
      approvedBy: permission.approvedBy,
      approvedAt: permission.approvedAt,
      actualReturnDate: returnDate,
      closedBy: approver.uid,
      closedAt: DateTime.now(),
      proratedChargeId: chargeId,
    );
  }

  /// Calcula el periodo de cuota que contiene [date] según billing.
  ///
  /// Devuelve (periodStart, periodEnd inclusivo, lengthInDays).
  ///
  /// Nota: para `month` se asume que `dueDay` indica fin de mes; un
  /// modelo más fino podría considerar quincenas, etc.
  (DateTime, DateTime, int) _periodFor(
      DateTime date, BillingConfig cfg) {
    if (cfg.periodUnit == BillingPeriodUnit.day) {
      return (date, date, 1);
    }
    if (cfg.periodUnit == BillingPeriodUnit.week) {
      // Lunes a domingo.
      final monday = date.subtract(Duration(days: date.weekday - 1));
      final sunday = monday.add(const Duration(days: 6));
      return (
        DateTime(monday.year, monday.month, monday.day),
        DateTime(sunday.year, sunday.month, sunday.day),
        7,
      );
    }
    if (cfg.periodUnit == BillingPeriodUnit.month) {
      final start = DateTime(date.year, date.month, 1);
      final end = DateTime(date.year, date.month + 1, 0);
      return (start, end, end.day);
    }
    // year — raro pero por completitud
    final start = DateTime(date.year, 1, 1);
    final end = DateTime(date.year, 12, 31);
    return (start, end, 365);
  }
}
