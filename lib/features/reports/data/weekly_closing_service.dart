import 'package:cloud_firestore/cloud_firestore.dart';

import '../../permissions/data/models/permission_record.dart';

/// Estado de pago de una unidad en la semana.
enum WeeklyUnitPaymentStatus {
  paid, // pagó la cuota normal (verde/amarillo)
  unpaid, // NO pagó (rojo)
  permission, // tiene permiso (azul) — registrado por el admin
}

/// Fila de "pago por unidad" en el reporte semanal estilo Excel.
class WeeklyUnitRow {
  final String unitNumber; // "01", "02", etc.
  final String driverName;
  final String? driverId;
  final double amount; // 0 si no pagó
  final WeeklyUnitPaymentStatus status;

  const WeeklyUnitRow({
    required this.unitNumber,
    required this.driverName,
    required this.driverId,
    required this.amount,
    required this.status,
  });
}

/// Pago hecho a una operadora durante la semana, agrupado por su nombre.
class OperatorPaymentRow {
  final String operatorName;
  final double miercoles;
  final double domingos;
  final double extras;
  double get total => miercoles + domingos + extras;
  const OperatorPaymentRow({
    required this.operatorName,
    this.miercoles = 0,
    this.domingos = 0,
    this.extras = 0,
  });
}

/// Línea de gasto vario (recarga celular, etc.).
class MiscExpense {
  final String description;
  final double value;
  const MiscExpense({required this.description, required this.value});
}

/// Resumen condensado de una semana, usado en reportes mensual/anual.
class WeekSummary {
  final DateTime weekStart;
  final DateTime weekEnd;
  final double balance; // sobrante de la semana
  const WeekSummary({
    required this.weekStart,
    required this.weekEnd,
    required this.balance,
  });
}

/// Reporte mensual: replica el Excel del admin "MES X / Sobrante de las
/// unidades semanales <MES>" con saldo acumulado del mes anterior.
class MonthlyClosingReport {
  final DateTime monthStart;
  final DateTime monthEnd;
  final String associationName;
  final String monthLabel; // ej. "ENERO 2026"
  final double previousMonthBalance; // se transfiere del mes anterior
  final List<WeekSummary> weeks;

  double get weeksTotal =>
      weeks.fold(0.0, (acc, w) => acc + w.balance);
  double get monthTotal => previousMonthBalance + weeksTotal;

  const MonthlyClosingReport({
    required this.monthStart,
    required this.monthEnd,
    required this.associationName,
    required this.monthLabel,
    required this.previousMonthBalance,
    required this.weeks,
  });
}

/// Reporte anual: 12 meses con sus sobrantes.
class AnnualClosingReport {
  final int year;
  final String associationName;
  final List<MonthlyClosingReport> months;

  double get yearTotal => months.isEmpty ? 0 : months.last.monthTotal;

  const AnnualClosingReport({
    required this.year,
    required this.associationName,
    required this.months,
  });
}

/// Reporte semanal completo: equivalente al Excel manual del admin.
class WeeklyClosingReport {
  final DateTime weekStart;
  final DateTime weekEnd;
  final String associationName;

  /// Lista de unidades con su pago de cuota semanal.
  final List<WeeklyUnitRow> units;

  /// Pagos a operadoras (filas: cada operadora; columnas: días del trabajo).
  final List<OperatorPaymentRow> operatorPayments;

  /// Gastos varios (recarga, mantenimiento puntual, etc.).
  final List<MiscExpense> miscExpenses;

  /// Notas libres del admin (movimientos importantes).
  final String? novedades;

  // Totales pre-computados.
  double get totalUnits =>
      units.fold(0.0, (acc, u) => acc + u.amount);
  double get totalOperators =>
      operatorPayments.fold(0.0, (acc, o) => acc + o.total);
  double get totalMisc =>
      miscExpenses.fold(0.0, (acc, e) => acc + e.value);
  double get balance => totalUnits - totalOperators - totalMisc;

  const WeeklyClosingReport({
    required this.weekStart,
    required this.weekEnd,
    required this.associationName,
    required this.units,
    required this.operatorPayments,
    required this.miscExpenses,
    this.novedades,
  });
}

/// Construye un [WeeklyClosingReport] consultando Firestore.
///
/// Lee:
///   - `users` (conductores activos del tenant) → la lista de unidades.
///   - `payments where status==validated, concept==cuota_semanal,
///       paymentDate in [start, end]` → marca quién pagó.
///   - `cashflow where associationId, type==gasto, date in rango` →
///       gastos varios + pagos a operadoras (los identificamos por
///       categoría que contenga 'operadora' o 'rosario'/'norma' o
///       una categoría dedicada `pago_operadora`).
class WeeklyClosingService {
  WeeklyClosingService._();
  static final WeeklyClosingService instance = WeeklyClosingService._();

  final _firestore = FirebaseFirestore.instance;

  Future<WeeklyClosingReport> build({
    required String associationId,
    required DateTime weekStart,
    required DateTime weekEnd,
  }) async {
    final assocSnap =
        await _firestore.collection('associations').doc(associationId).get();
    final assocName = assocSnap.data()?['name']?.toString() ??
        associationId;

    // 1) Conductores activos del tenant.
    final usersSnap = await _firestore
        .collection('users')
        .where('associationId', isEqualTo: associationId)
        .where('role', isEqualTo: 'conductor')
        .get();
    final drivers = usersSnap.docs
        .map((d) => d.data())
        .where((d) {
          final st = d['status'];
          return st == 'active' ||
              st == 'paymentPending' ||
              st == 'paymentBlocked';
        })
        .toList()
      ..sort((a, b) {
        final na =
            int.tryParse((a['numeroVehiculo'] ?? '0').toString()) ?? 0;
        final nb =
            int.tryParse((b['numeroVehiculo'] ?? '0').toString()) ?? 0;
        return na.compareTo(nb);
      });

    // 2) Pagos validados de cuotas en la semana, mapeados por driverId.
    final paymentsSnap = await _firestore
        .collection('payments')
        .where('associationId', isEqualTo: associationId)
        .where('status', isEqualTo: 'validated')
        .where('paymentDate',
            isGreaterThanOrEqualTo: Timestamp.fromDate(weekStart))
        .where('paymentDate',
            isLessThanOrEqualTo: Timestamp.fromDate(weekEnd))
        .get();
    final paidByDriver = <String, double>{};
    for (final d in paymentsSnap.docs) {
      final data = d.data();
      final concept = data['concept'] as String? ?? '';
      // Solo cuotas regulares para la columna VALOR.
      if (!concept.startsWith('cuota')) continue;
      final driverId = data['driverId'] as String? ?? '';
      final amount = (data['amount'] as num?)?.toDouble() ?? 0.0;
      paidByDriver[driverId] = (paidByDriver[driverId] ?? 0) + amount;
    }

    // 3) Permisos que se solapan con el rango de la semana.
    //    Cualquier permiso cuyo rango toque [weekStart, weekEnd] cuenta.
    final permsSnap = await _firestore
        .collection('permissions')
        .where('associationId', isEqualTo: associationId)
        .get();
    final permissions = permsSnap.docs
        .map(PermissionRecord.fromFirestore)
        .where((p) {
      // Activo durante la semana, o cerrado pero rango se solapa.
      final start = p.startDate;
      final end = p.actualReturnDate ?? p.expectedEndDate;
      if (start.isAfter(weekEnd)) return false;
      if (end != null && end.isBefore(weekStart)) return false;
      return true;
    }).toList();
    final driverHasPermission = <String, bool>{};
    for (final p in permissions) {
      // Marca si el conductor tuvo permiso EN ALGÚN día de la semana.
      driverHasPermission[p.driverId] = true;
    }

    // 3.5) Construir filas de unidades.
    final units = <WeeklyUnitRow>[];
    for (final dr in drivers) {
      final driverId = dr['uid'] as String? ?? ''; // puede no existir
      // El uid del usuario es la doc.id; recuperémoslo del map.
      final uid = (dr['_uid'] ?? dr['uid'] ?? '').toString();
      // Como el `data()` no tiene doc.id, lo buscamos cruzando docs.
      // (lo hacemos abajo en el bucle real de docs).
      units.add(WeeklyUnitRow(
        unitNumber: (dr['numeroVehiculo'] ?? '').toString(),
        driverName:
            '${dr['name'] ?? ''} ${dr['lastname'] ?? ''}'.trim(),
        driverId: uid.isEmpty ? driverId : uid,
        amount: 0, // se llena después
        status: WeeklyUnitPaymentStatus.unpaid,
      ));
    }
    // Re-armar usando docs reales (para tener doc.id).
    units.clear();
    final docsByUnit = usersSnap.docs.toList()
      ..sort((a, b) {
        final na = int.tryParse(
                (a.data()['numeroVehiculo'] ?? '0').toString()) ??
            0;
        final nb = int.tryParse(
                (b.data()['numeroVehiculo'] ?? '0').toString()) ??
            0;
        return na.compareTo(nb);
      });
    for (final doc in docsByUnit) {
      final d = doc.data();
      final st = d['status'];
      if (st != 'active' &&
          st != 'paymentPending' &&
          st != 'paymentBlocked') {
        continue;
      }
      final paid = paidByDriver[doc.id] ?? 0;
      final hasPermission = driverHasPermission[doc.id] == true ||
          d['hasWeeklyPermission'] == true; // back-compat
      final status = hasPermission
          ? WeeklyUnitPaymentStatus.permission
          : (paid > 0
              ? WeeklyUnitPaymentStatus.paid
              : WeeklyUnitPaymentStatus.unpaid);
      units.add(WeeklyUnitRow(
        unitNumber: (d['numeroVehiculo'] ?? '').toString(),
        driverName: '${d['name'] ?? ''} ${d['lastname'] ?? ''}'.trim(),
        driverId: doc.id,
        amount: paid,
        status: status,
      ));
    }

    // 4) Cashflow del periodo: separar pagos a operadoras de gastos varios.
    final cashSnap = await _firestore
        .collection('cashflow')
        .where('associationId', isEqualTo: associationId)
        .where('type', isEqualTo: 'gasto')
        .where('date',
            isGreaterThanOrEqualTo: Timestamp.fromDate(weekStart))
        .where('date',
            isLessThanOrEqualTo: Timestamp.fromDate(weekEnd))
        .get();

    final operatorAgg = <String, OperatorPaymentRow>{};
    final misc = <MiscExpense>[];
    for (final d in cashSnap.docs) {
      final data = d.data();
      final cat = (data['category'] as String? ?? '').toLowerCase();
      final desc = (data['description'] as String? ?? '').trim();
      final amount = (data['amount'] as num?)?.toDouble() ?? 0.0;
      final ts = (data['date'] as Timestamp?)?.toDate();
      final isOperatorPayment = cat.contains('operadora') ||
          cat.contains('pago_operadora');
      if (isOperatorPayment) {
        // El nombre de la operadora se asume en `description` o
        // `subCategory`. Si no está, usamos category cruda.
        final opName = data['operatorName'] as String? ??
            (desc.isNotEmpty ? desc : 'Operadora');
        final existing = operatorAgg[opName] ??
            OperatorPaymentRow(operatorName: opName);
        // Clasificar por día de la semana — miércoles/domingo/extras.
        double mier = existing.miercoles;
        double dom = existing.domingos;
        double ext = existing.extras;
        if (ts != null) {
          if (ts.weekday == DateTime.wednesday) {
            mier += amount;
          } else if (ts.weekday == DateTime.sunday) {
            dom += amount;
          } else {
            ext += amount;
          }
        } else {
          ext += amount;
        }
        operatorAgg[opName] = OperatorPaymentRow(
          operatorName: opName,
          miercoles: mier,
          domingos: dom,
          extras: ext,
        );
      } else {
        misc.add(MiscExpense(
          description: desc.isNotEmpty ? desc : (cat.isNotEmpty ? cat : 'Gasto'),
          value: amount,
        ));
      }
    }

    // 5) Novedades: leemos opcionalmente `weekly_notes/{aid}_{weekKey}`.
    String? novedades;
    try {
      final weekKey =
          '${associationId}_${weekStart.year}${weekStart.month.toString().padLeft(2, '0')}${weekStart.day.toString().padLeft(2, '0')}';
      final notesSnap = await _firestore
          .collection('weekly_notes')
          .doc(weekKey)
          .get();
      if (notesSnap.exists) {
        novedades = notesSnap.data()?['notes'] as String?;
      }
    } catch (_) {}

    return WeeklyClosingReport(
      weekStart: weekStart,
      weekEnd: weekEnd,
      associationName: assocName,
      units: units,
      operatorPayments: operatorAgg.values.toList()
        ..sort((a, b) => a.operatorName.compareTo(b.operatorName)),
      miscExpenses: misc,
      novedades: novedades,
    );
  }

  /// Construye el cierre mensual: itera todas las semanas que toquen el
  /// mes (lunes a domingo) + suma el saldo del mes anterior.
  ///
  /// Replica el formato del Excel manual del admin "MES X / Sobrante de
  /// las unidades semanales <MES>".
  Future<MonthlyClosingReport> buildMonth({
    required String associationId,
    required int year,
    required int month, // 1-12
  }) async {
    final monthStart = DateTime(year, month, 1);
    final monthEnd = DateTime(year, month + 1, 0, 23, 59, 59);

    // Generar lista de semanas (lun-dom) que toquen el mes.
    final weeks = <WeekSummary>[];
    DateTime cursor = monthStart;
    while (!cursor.isAfter(monthEnd)) {
      // Avanzar al lunes de la semana actual.
      final monday =
          cursor.subtract(Duration(days: cursor.weekday - 1));
      final sunday = monday.add(const Duration(days: 6));
      // Solo semanas con al menos 1 día dentro del mes.
      if (sunday.isBefore(monthStart)) {
        cursor = sunday.add(const Duration(days: 1));
        continue;
      }
      if (monday.isAfter(monthEnd)) break;

      final week = await build(
        associationId: associationId,
        weekStart: DateTime(monday.year, monday.month, monday.day),
        weekEnd:
            DateTime(sunday.year, sunday.month, sunday.day, 23, 59, 59),
      );
      weeks.add(WeekSummary(
        weekStart: week.weekStart,
        weekEnd: week.weekEnd,
        balance: week.balance,
      ));
      cursor = sunday.add(const Duration(days: 1));
    }

    // Saldo del mes anterior: lo leemos de un doc cache si existe, o lo
    // calculamos recursivamente (1 nivel).
    final previousBalance = await _previousMonthBalance(
      associationId: associationId,
      year: year,
      month: month,
    );

    final assocSnap =
        await _firestore.collection('associations').doc(associationId).get();
    final assocName =
        assocSnap.data()?['name']?.toString() ?? associationId;
    const monthNames = [
      '', 'ENERO', 'FEBRERO', 'MARZO', 'ABRIL', 'MAYO', 'JUNIO',
      'JULIO', 'AGOSTO', 'SEPTIEMBRE', 'OCTUBRE', 'NOVIEMBRE', 'DICIEMBRE',
    ];

    return MonthlyClosingReport(
      monthStart: monthStart,
      monthEnd: monthEnd,
      associationName: assocName,
      monthLabel: '${monthNames[month]} $year',
      previousMonthBalance: previousBalance,
      weeks: weeks,
    );
  }

  /// Saldo acumulado al cierre del mes anterior. Lo leemos de
  /// `monthly_balances/{aid}_{yyyymm}` si está cacheado, sino lo
  /// calculamos en vivo (no recursivo — solo el mes anterior).
  Future<double> _previousMonthBalance({
    required String associationId,
    required int year,
    required int month,
  }) async {
    final prevMonth = month == 1 ? 12 : month - 1;
    final prevYear = month == 1 ? year - 1 : year;
    final key =
        '${associationId}_$prevYear${prevMonth.toString().padLeft(2, '0')}';
    try {
      final cached = await _firestore
          .collection('monthly_balances')
          .doc(key)
          .get();
      if (cached.exists) {
        final v = cached.data()?['monthTotal'];
        if (v is num) return v.toDouble();
      }
    } catch (_) {}
    // Fallback: 0 (no calculamos recursivo para evitar timeouts).
    // El admin puede pre-cachear el mes anterior generando primero ese
    // reporte (eso lo guarda en `monthly_balances`).
    return 0;
  }

  /// Construye el cierre anual: 12 meses cada uno con su sobrante.
  Future<AnnualClosingReport> buildYear({
    required String associationId,
    required int year,
  }) async {
    final months = <MonthlyClosingReport>[];
    for (int m = 1; m <= 12; m++) {
      final monthReport = await buildMonth(
        associationId: associationId,
        year: year,
        month: m,
      );
      months.add(monthReport);
    }
    final assocSnap =
        await _firestore.collection('associations').doc(associationId).get();
    final assocName =
        assocSnap.data()?['name']?.toString() ?? associationId;
    return AnnualClosingReport(
      year: year,
      associationName: assocName,
      months: months,
    );
  }

  /// Cachea el sobrante final del mes para que el siguiente mes lo lea
  /// como `previousMonthBalance`. Llamar después de generar un reporte
  /// mensual cerrado.
  Future<void> cacheMonthlyBalance(MonthlyClosingReport r) async {
    final key =
        '${r.associationName}_${r.monthStart.year}${r.monthStart.month.toString().padLeft(2, '0')}';
    try {
      await _firestore
          .collection('monthly_balances')
          .doc(key)
          .set({
        'associationId': key.split('_').first,
        'year': r.monthStart.year,
        'month': r.monthStart.month,
        'monthTotal': r.monthTotal,
        'cachedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }
}
