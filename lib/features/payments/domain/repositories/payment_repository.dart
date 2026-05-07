import '../../data/models/payment_model.dart';

/// Interfaz abstracta del repositorio de pagos y gastos
abstract class PaymentRepository {
  /// Observar pagos de un conductor en tiempo real
  Stream<List<PaymentModel>> watchPaymentsByDriver(String driverId);

  /// Obtener pagos filtrados por estado
  Future<List<PaymentModel>> getPaymentsByStatus(String status, {String? driverId});

  /// Obtener un pago por ID
  Future<PaymentModel> getPaymentById(String paymentId);

  /// Crear un nuevo pago/cuota
  Future<void> createPayment(PaymentModel payment);

  /// Marcar un pago como pagado
  Future<void> markPaymentAsPaid(String paymentId, {String? receiptUrl, String? paymentMethod});

  /// Obtener gastos de un conductor
  Future<List<ExpenseModel>> getExpensesByDriver(String driverId, {DateTime? fromDate, DateTime? toDate});

  /// Registrar un gasto
  Future<void> createExpense(ExpenseModel expense);

  /// Eliminar un gasto
  Future<void> deleteExpense(String expenseId);

  /// Obtener resumen financiero de un conductor
  Future<Map<String, dynamic>> getFinancialSummary(String driverId);
}
