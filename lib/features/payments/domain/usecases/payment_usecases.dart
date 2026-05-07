import 'package:equatable/equatable.dart';
import '../../../../core/usecases/usecase.dart';
import '../../data/models/payment_model.dart';
import '../repositories/payment_repository.dart';

// ========== Watch Payments ==========

class WatchPaymentsUseCase {
  final PaymentRepository repository;
  WatchPaymentsUseCase(this.repository);
  Stream<List<PaymentModel>> call(String driverId) =>
      repository.watchPaymentsByDriver(driverId);
}

// ========== Get Payments By Status ==========

class GetPaymentsByStatusParams extends Equatable {
  final String status;
  final String? driverId;
  const GetPaymentsByStatusParams({required this.status, this.driverId});
  @override
  List<Object?> get props => [status, driverId];
}

class GetPaymentsByStatusUseCase implements UseCase<List<PaymentModel>, GetPaymentsByStatusParams> {
  final PaymentRepository repository;
  GetPaymentsByStatusUseCase(this.repository);
  @override
  Future<List<PaymentModel>> call(GetPaymentsByStatusParams params) =>
      repository.getPaymentsByStatus(params.status, driverId: params.driverId);
}

// ========== Create Payment ==========

class CreatePaymentUseCase implements UseCase<void, PaymentModel> {
  final PaymentRepository repository;
  CreatePaymentUseCase(this.repository);
  @override
  Future<void> call(PaymentModel payment) =>
      repository.createPayment(payment);
}

// ========== Mark Payment As Paid ==========

class MarkPaymentPaidParams extends Equatable {
  final String paymentId;
  final String? receiptUrl;
  final String? paymentMethod;
  const MarkPaymentPaidParams({required this.paymentId, this.receiptUrl, this.paymentMethod});
  @override
  List<Object?> get props => [paymentId, receiptUrl, paymentMethod];
}

class MarkPaymentPaidUseCase implements UseCase<void, MarkPaymentPaidParams> {
  final PaymentRepository repository;
  MarkPaymentPaidUseCase(this.repository);
  @override
  Future<void> call(MarkPaymentPaidParams params) =>
      repository.markPaymentAsPaid(params.paymentId, receiptUrl: params.receiptUrl, paymentMethod: params.paymentMethod);
}

// ========== Get Expenses ==========

class GetExpensesParams extends Equatable {
  final String driverId;
  final DateTime? fromDate;
  final DateTime? toDate;
  const GetExpensesParams({required this.driverId, this.fromDate, this.toDate});
  @override
  List<Object?> get props => [driverId, fromDate, toDate];
}

class GetExpensesUseCase implements UseCase<List<ExpenseModel>, GetExpensesParams> {
  final PaymentRepository repository;
  GetExpensesUseCase(this.repository);
  @override
  Future<List<ExpenseModel>> call(GetExpensesParams params) =>
      repository.getExpensesByDriver(params.driverId, fromDate: params.fromDate, toDate: params.toDate);
}

// ========== Create Expense ==========

class CreateExpenseUseCase implements UseCase<void, ExpenseModel> {
  final PaymentRepository repository;
  CreateExpenseUseCase(this.repository);
  @override
  Future<void> call(ExpenseModel expense) =>
      repository.createExpense(expense);
}

// ========== Delete Expense ==========

class DeleteExpenseUseCase implements UseCase<void, String> {
  final PaymentRepository repository;
  DeleteExpenseUseCase(this.repository);
  @override
  Future<void> call(String expenseId) =>
      repository.deleteExpense(expenseId);
}

// ========== Get Financial Summary ==========

class GetFinancialSummaryUseCase implements UseCase<Map<String, dynamic>, String> {
  final PaymentRepository repository;
  GetFinancialSummaryUseCase(this.repository);
  @override
  Future<Map<String, dynamic>> call(String driverId) =>
      repository.getFinancialSummary(driverId);
}
