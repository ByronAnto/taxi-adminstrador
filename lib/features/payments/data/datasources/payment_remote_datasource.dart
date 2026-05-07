import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/payment_model.dart';
import '../../../../core/constants/app_constants.dart';

class PaymentRemoteDatasource {
  final FirebaseFirestore _firestore;

  PaymentRemoteDatasource({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference get _paymentsRef =>
      _firestore.collection(AppConstants.paymentsCollection);

  CollectionReference get _expensesRef =>
      _firestore.collection(AppConstants.expensesCollection);

  // ========== PAGOS ==========

  Stream<List<PaymentModel>> watchPaymentsByDriver(String driverId) {
    return _paymentsRef
        .where('driverId', isEqualTo: driverId)
        .orderBy('dueDate', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => PaymentModel.fromFirestore(doc)).toList());
  }

  Future<List<PaymentModel>> getPaymentsByStatus(String status, {String? driverId}) async {
    Query query = _paymentsRef.where('status', isEqualTo: status);
    if (driverId != null) {
      query = query.where('driverId', isEqualTo: driverId);
    }
    final snapshot = await query.orderBy('dueDate', descending: true).get();
    return snapshot.docs.map((doc) => PaymentModel.fromFirestore(doc)).toList();
  }

  Future<PaymentModel> getPaymentById(String paymentId) async {
    final doc = await _paymentsRef.doc(paymentId).get();
    if (!doc.exists) throw Exception('Pago no encontrado');
    return PaymentModel.fromFirestore(doc);
  }

  Future<void> createPayment(PaymentModel payment) async {
    await _paymentsRef.add(payment.toFirestore());
  }

  Future<void> markPaymentAsPaid(String paymentId, {String? receiptUrl, String? paymentMethod}) async {
    final updates = <String, dynamic>{
      'status': 'pagado',
      'paidDate': Timestamp.fromDate(DateTime.now()),
    };
    if (receiptUrl != null) updates['receiptUrl'] = receiptUrl;
    if (paymentMethod != null) updates['paymentMethod'] = paymentMethod;
    await _paymentsRef.doc(paymentId).update(updates);
  }

  // ========== GASTOS ==========

  Future<List<ExpenseModel>> getExpensesByDriver(String driverId, {DateTime? fromDate, DateTime? toDate}) async {
    Query query = _expensesRef.where('driverId', isEqualTo: driverId);
    if (fromDate != null) {
      query = query.where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(fromDate));
    }
    if (toDate != null) {
      query = query.where('date', isLessThanOrEqualTo: Timestamp.fromDate(toDate));
    }
    final snapshot = await query.orderBy('date', descending: true).get();
    return snapshot.docs.map((doc) => ExpenseModel.fromFirestore(doc)).toList();
  }

  Future<void> createExpense(ExpenseModel expense) async {
    await _expensesRef.add(expense.toFirestore());
  }

  Future<void> deleteExpense(String expenseId) async {
    await _expensesRef.doc(expenseId).delete();
  }

  // ========== RESUMEN ==========

  Future<Map<String, dynamic>> getFinancialSummary(String driverId) async {
    final paymentsSnap = await _paymentsRef
        .where('driverId', isEqualTo: driverId)
        .get();

    final expensesSnap = await _expensesRef
        .where('driverId', isEqualTo: driverId)
        .get();

    double totalPaid = 0;
    double totalPending = 0;
    double totalOverdue = 0;
    double totalExpenses = 0;

    for (final doc in paymentsSnap.docs) {
      final payment = PaymentModel.fromFirestore(doc);
      switch (payment.status) {
        case PaymentStatus.validated:
          totalPaid += payment.amount;
          break;
        case PaymentStatus.pending:
          totalPending += payment.amount;
          break;
        case PaymentStatus.rejected:
          totalOverdue += payment.amount;
          break;
      }
    }

    for (final doc in expensesSnap.docs) {
      final expense = ExpenseModel.fromFirestore(doc);
      totalExpenses += expense.amount;
    }

    return {
      'totalPaid': totalPaid,
      'totalPending': totalPending,
      'totalOverdue': totalOverdue,
      'totalExpenses': totalExpenses,
      'paymentCount': paymentsSnap.docs.length,
      'expenseCount': expensesSnap.docs.length,
    };
  }
}
