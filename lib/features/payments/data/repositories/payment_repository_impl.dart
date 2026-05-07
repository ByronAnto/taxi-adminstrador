import '../../domain/repositories/payment_repository.dart';
import '../datasources/payment_remote_datasource.dart';
import '../models/payment_model.dart';

class PaymentRepositoryImpl implements PaymentRepository {
  final PaymentRemoteDatasource _datasource;

  PaymentRepositoryImpl(this._datasource);

  @override
  Stream<List<PaymentModel>> watchPaymentsByDriver(String driverId) =>
      _datasource.watchPaymentsByDriver(driverId);

  @override
  Future<List<PaymentModel>> getPaymentsByStatus(String status, {String? driverId}) =>
      _datasource.getPaymentsByStatus(status, driverId: driverId);

  @override
  Future<PaymentModel> getPaymentById(String paymentId) =>
      _datasource.getPaymentById(paymentId);

  @override
  Future<void> createPayment(PaymentModel payment) =>
      _datasource.createPayment(payment);

  @override
  Future<void> markPaymentAsPaid(String paymentId, {String? receiptUrl, String? paymentMethod}) =>
      _datasource.markPaymentAsPaid(paymentId, receiptUrl: receiptUrl, paymentMethod: paymentMethod);

  @override
  Future<List<ExpenseModel>> getExpensesByDriver(String driverId, {DateTime? fromDate, DateTime? toDate}) =>
      _datasource.getExpensesByDriver(driverId, fromDate: fromDate, toDate: toDate);

  @override
  Future<void> createExpense(ExpenseModel expense) =>
      _datasource.createExpense(expense);

  @override
  Future<void> deleteExpense(String expenseId) =>
      _datasource.deleteExpense(expenseId);

  @override
  Future<Map<String, dynamic>> getFinancialSummary(String driverId) =>
      _datasource.getFinancialSummary(driverId);
}
