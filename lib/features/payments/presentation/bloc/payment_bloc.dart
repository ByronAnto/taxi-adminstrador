import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/models/payment_model.dart';
import '../../domain/usecases/payment_usecases.dart';

// ============ EVENTS ============

abstract class PaymentEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class PaymentsWatchStarted extends PaymentEvent {
  final String driverId;
  PaymentsWatchStarted(this.driverId);
  @override
  List<Object?> get props => [driverId];
}

class PaymentsUpdated extends PaymentEvent {
  final List<PaymentModel> payments;
  PaymentsUpdated(this.payments);
  @override
  List<Object?> get props => [payments];
}

class PaymentCreateRequested extends PaymentEvent {
  final PaymentModel payment;
  PaymentCreateRequested(this.payment);
  @override
  List<Object?> get props => [payment.uid];
}

class PaymentMarkPaidRequested extends PaymentEvent {
  final String paymentId;
  final String? receiptUrl;
  final String? paymentMethod;
  PaymentMarkPaidRequested(this.paymentId, {this.receiptUrl, this.paymentMethod});
  @override
  List<Object?> get props => [paymentId];
}

class ExpensesLoadRequested extends PaymentEvent {
  final String driverId;
  final DateTime? fromDate;
  final DateTime? toDate;
  ExpensesLoadRequested(this.driverId, {this.fromDate, this.toDate});
  @override
  List<Object?> get props => [driverId, fromDate, toDate];
}

class ExpenseCreateRequested extends PaymentEvent {
  final ExpenseModel expense;
  ExpenseCreateRequested(this.expense);
  @override
  List<Object?> get props => [expense.uid];
}

class ExpenseDeleteRequested extends PaymentEvent {
  final String expenseId;
  ExpenseDeleteRequested(this.expenseId);
  @override
  List<Object?> get props => [expenseId];
}

class FinancialSummaryRequested extends PaymentEvent {
  final String driverId;
  FinancialSummaryRequested(this.driverId);
  @override
  List<Object?> get props => [driverId];
}

// ============ STATES ============

abstract class PaymentState extends Equatable {
  @override
  List<Object?> get props => [];
}

class PaymentInitial extends PaymentState {}

class PaymentLoading extends PaymentState {}

class PaymentLoaded extends PaymentState {
  final List<PaymentModel> payments;
  final List<ExpenseModel> expenses;
  final Map<String, dynamic>? summary;

  PaymentLoaded({
    this.payments = const [],
    this.expenses = const [],
    this.summary,
  });

  @override
  List<Object?> get props => [payments, expenses, summary];

  PaymentLoaded copyWith({
    List<PaymentModel>? payments,
    List<ExpenseModel>? expenses,
    Map<String, dynamic>? summary,
  }) {
    return PaymentLoaded(
      payments: payments ?? this.payments,
      expenses: expenses ?? this.expenses,
      summary: summary ?? this.summary,
    );
  }
}

class PaymentActionSuccess extends PaymentState {
  final String message;
  PaymentActionSuccess(this.message);
  @override
  List<Object?> get props => [message];
}

class PaymentError extends PaymentState {
  final String message;
  PaymentError(this.message);
  @override
  List<Object?> get props => [message];
}

// ============ BLOC ============

class PaymentBloc extends Bloc<PaymentEvent, PaymentState> {
  final WatchPaymentsUseCase watchPayments;
  final CreatePaymentUseCase createPayment;
  final MarkPaymentPaidUseCase markPaymentPaid;
  final GetExpensesUseCase getExpenses;
  final CreateExpenseUseCase createExpense;
  final DeleteExpenseUseCase deleteExpense;
  final GetFinancialSummaryUseCase getFinancialSummary;

  StreamSubscription<List<PaymentModel>>? _paymentsSubscription;

  PaymentBloc({
    required this.watchPayments,
    required this.createPayment,
    required this.markPaymentPaid,
    required this.getExpenses,
    required this.createExpense,
    required this.deleteExpense,
    required this.getFinancialSummary,
  }) : super(PaymentInitial()) {
    on<PaymentsWatchStarted>(_onWatchStarted);
    on<PaymentsUpdated>(_onPaymentsUpdated);
    on<PaymentCreateRequested>(_onCreateRequested);
    on<PaymentMarkPaidRequested>(_onMarkPaidRequested);
    on<ExpensesLoadRequested>(_onExpensesRequested);
    on<ExpenseCreateRequested>(_onExpenseCreateRequested);
    on<ExpenseDeleteRequested>(_onExpenseDeleteRequested);
    on<FinancialSummaryRequested>(_onSummaryRequested);
  }

  Future<void> _onWatchStarted(
    PaymentsWatchStarted event,
    Emitter<PaymentState> emit,
  ) async {
    emit(PaymentLoading());
    await _paymentsSubscription?.cancel();
    _paymentsSubscription = watchPayments(event.driverId).listen(
      (payments) => add(PaymentsUpdated(payments)),
      onError: (error) => add(PaymentsUpdated(const [])),
    );
  }

  void _onPaymentsUpdated(
    PaymentsUpdated event,
    Emitter<PaymentState> emit,
  ) {
    final current = state;
    if (current is PaymentLoaded) {
      emit(current.copyWith(payments: event.payments));
    } else {
      emit(PaymentLoaded(payments: event.payments));
    }
  }

  Future<void> _onCreateRequested(
    PaymentCreateRequested event,
    Emitter<PaymentState> emit,
  ) async {
    try {
      await createPayment(event.payment);
      emit(PaymentActionSuccess('Pago creado exitosamente'));
    } catch (e) {
      emit(PaymentError('Error al crear pago: $e'));
    }
  }

  Future<void> _onMarkPaidRequested(
    PaymentMarkPaidRequested event,
    Emitter<PaymentState> emit,
  ) async {
    try {
      await markPaymentPaid(MarkPaymentPaidParams(
        paymentId: event.paymentId,
        receiptUrl: event.receiptUrl,
        paymentMethod: event.paymentMethod,
      ));
      emit(PaymentActionSuccess('Pago marcado como pagado'));
    } catch (e) {
      emit(PaymentError('Error al marcar pago: $e'));
    }
  }

  Future<void> _onExpensesRequested(
    ExpensesLoadRequested event,
    Emitter<PaymentState> emit,
  ) async {
    try {
      final expenses = await getExpenses(GetExpensesParams(
        driverId: event.driverId,
        fromDate: event.fromDate,
        toDate: event.toDate,
      ));
      final current = state;
      if (current is PaymentLoaded) {
        emit(current.copyWith(expenses: expenses));
      } else {
        emit(PaymentLoaded(expenses: expenses));
      }
    } catch (e) {
      emit(PaymentError('Error al cargar gastos: $e'));
    }
  }

  Future<void> _onExpenseCreateRequested(
    ExpenseCreateRequested event,
    Emitter<PaymentState> emit,
  ) async {
    try {
      await createExpense(event.expense);
      emit(PaymentActionSuccess('Gasto registrado'));
    } catch (e) {
      emit(PaymentError('Error al registrar gasto: $e'));
    }
  }

  Future<void> _onExpenseDeleteRequested(
    ExpenseDeleteRequested event,
    Emitter<PaymentState> emit,
  ) async {
    try {
      await deleteExpense(event.expenseId);
      emit(PaymentActionSuccess('Gasto eliminado'));
    } catch (e) {
      emit(PaymentError('Error al eliminar gasto: $e'));
    }
  }

  Future<void> _onSummaryRequested(
    FinancialSummaryRequested event,
    Emitter<PaymentState> emit,
  ) async {
    try {
      final summary = await getFinancialSummary(event.driverId);
      final current = state;
      if (current is PaymentLoaded) {
        emit(current.copyWith(summary: summary));
      } else {
        emit(PaymentLoaded(summary: summary));
      }
    } catch (e) {
      emit(PaymentError('Error al cargar resumen: $e'));
    }
  }

  @override
  Future<void> close() {
    _paymentsSubscription?.cancel();
    return super.close();
  }
}
