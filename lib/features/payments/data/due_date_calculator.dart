import '../../associations/data/models/association_model.dart';
import '../../auth/data/models/user_model.dart';
import 'models/payment_model.dart';

/// Espejo de `functions/lib/dueDate.js`. Mantener en sync.
/// Calcula la próxima fecha de vencimiento de la cuota del conductor.
///
/// BillingConfig usa campos planos:
///   cfg.periodEvery  (int)
///   cfg.periodUnit   (BillingPeriodUnit enum: day|week|month|year)
///   cfg.dueDay       (int — día del mes 1-28 para month, día semana 1-7 para week)
class DueDateCalculator {
  /// Mapeo nombre → índice 0-based con domingo=0 para semana ISO.
  /// dueDay en week es 1=lunes … 7=domingo, consistente con DateTime.weekday.
  /// alignToDueDay recibe dueDay como int directamente.

  /// Alinea [base] al próximo día de vencimiento.
  ///
  /// [inclusive] = true: si [base] cae exactamente sobre el dueDay lo acepta
  /// como válido (caso recurrente desde lastPayment.validatedAt).
  /// [inclusive] = false: salta a la próxima ocurrencia aunque base coincida
  /// (caso primera cuota desde approvedAt).
  static DateTime alignToDueDay(
    DateTime base,
    int dueDay,
    BillingPeriodUnit unit, {
    bool inclusive = false,
  }) {
    final d = DateTime.utc(base.year, base.month, base.day);

    switch (unit) {
      case BillingPeriodUnit.week:
        // DateTime.weekday: lun=1, dom=7 — mismo convenio que dueDay.
        final dDow = d.weekday; // 1-7
        var diff = (dueDay - dDow + 7) % 7;
        if (diff == 0 && !inclusive) diff = 7;
        return d.add(Duration(days: diff));

      case BillingPeriodUnit.month:
        final targetDay = dueDay.clamp(1, 28);
        if (d.day < targetDay) {
          return DateTime.utc(d.year, d.month, targetDay);
        }
        if (d.day == targetDay && inclusive) {
          return d;
        }
        // Pin a día 1 para evitar overflow (ej. Jan 31 → Feb).
        return DateTime.utc(d.year, d.month + 1, targetDay);

      case BillingPeriodUnit.year:
        final targetDay = dueDay.clamp(1, 28);
        final candidate = DateTime.utc(d.year, 1, targetDay);
        if (candidate.isAfter(d) || (inclusive && candidate == d)) {
          return candidate;
        }
        return DateTime.utc(d.year + 1, 1, targetDay);

      case BillingPeriodUnit.day:
        // Para 'day' el dueDay no aplica — simplemente +1 día.
        return d.add(const Duration(days: 1));
    }
  }

  /// Calcula la próxima fecha de vencimiento del usuario.
  ///
  /// [lastPayment] debe ser el último pago validated y NO voided (el caller
  /// es responsable de filtrar correctamente).
  ///
  /// Retorna null si no hay base de tiempo disponible (approvedAt == null).
  static DateTime? computeNextDueDate({
    required UserModel user,
    required BillingConfig cfg,
    PaymentModel? lastPayment,
  }) {
    final every = cfg.periodEvery < 1 ? 1 : cfg.periodEvery;

    if (lastPayment == null) {
      // Primera cuota: base = approvedAt, inclusive = false.
      final base = user.approvedAt;
      if (base == null) return null;
      return alignToDueDay(base, cfg.dueDay, cfg.periodUnit, inclusive: false);
    }

    // Cuotas recurrentes: base = validatedAt del último pago.
    final base = lastPayment.validatedAt;
    if (base == null) return null;

    // Avanzar un período completo.
    final DateTime advanced;
    switch (cfg.periodUnit) {
      case BillingPeriodUnit.day:
        advanced = base.add(Duration(days: every));
      case BillingPeriodUnit.week:
        advanced = base.add(Duration(days: every * 7));
      case BillingPeriodUnit.month:
        // Pin a día 1 para evitar overflow de mes.
        final pinned = DateTime.utc(base.year, base.month, 1);
        advanced = DateTime.utc(pinned.year, pinned.month + every, base.day.clamp(1, 28));
      case BillingPeriodUnit.year:
        advanced = DateTime.utc(base.year + every, base.month, base.day);
    }

    return alignToDueDay(advanced, cfg.dueDay, cfg.periodUnit, inclusive: true);
  }

  /// Monto prorrateado para la primera cuota cuando el conductor ingresa a
  /// mitad del período (ej. miércoles con cuota semanal los lunes).
  ///
  /// Si approvedAt es null, retorna el monto completo sin prorrateo.
  static double proratedFirstAmount({
    required UserModel user,
    required BillingConfig cfg,
  }) {
    final approved = user.approvedAt;
    if (approved == null) return cfg.amount;

    final firstDue = alignToDueDay(
      approved,
      cfg.dueDay,
      cfg.periodUnit,
      inclusive: false,
    );

    final days = firstDue.difference(
      DateTime.utc(approved.year, approved.month, approved.day),
    ).inDays;

    if (days <= 0) return cfg.amount;

    final periodDays = _periodDays(cfg);
    if (periodDays <= 0) return cfg.amount;

    final pro = (cfg.amount / periodDays) * days;
    return pro > cfg.amount ? cfg.amount : pro;
  }

  static int _periodDays(BillingConfig cfg) {
    final every = cfg.periodEvery < 1 ? 1 : cfg.periodEvery;
    switch (cfg.periodUnit) {
      case BillingPeriodUnit.day:
        return every;
      case BillingPeriodUnit.week:
        return every * 7;
      case BillingPeriodUnit.month:
        return every * 30;
      case BillingPeriodUnit.year:
        return every * 365;
    }
  }
}
