import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/payment_model.dart';
import '../bloc/payment_bloc.dart';

/// Página de administración de pagos (cuotas, cobros)
class PaymentsPage extends StatefulWidget {
  const PaymentsPage({super.key});

  @override
  State<PaymentsPage> createState() => _PaymentsPageState();
}

class _PaymentsPageState extends State<PaymentsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadPayments();
  }

  void _loadPayments() {
    final authState = context.read<AuthBloc>().state;
    if (authState is AuthAuthenticated) {
      context.read<PaymentBloc>().add(
            PaymentsWatchStarted(authState.user.uid),
          );
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<PaymentModel> _getPaymentsByStatus(PaymentState state, String status) {
    if (state is PaymentLoaded) {
      return state.payments.where((p) => p.status == status).toList();
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PaymentBloc, PaymentState>(
      listener: (context, state) {
        if (state is PaymentActionSuccess) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: AppTheme.statusFree,
            ),
          );
          _loadPayments();
        } else if (state is PaymentError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: AppTheme.errorColor,
            ),
          );
        }
      },
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Administración de Pagos'),
            bottom: TabBar(
              controller: _tabController,
              labelColor: AppTheme.onPrimaryColor,
              unselectedLabelColor: AppTheme.textSecondary,
              indicatorColor: AppTheme.secondaryColor,
              tabs: const [
                Tab(text: 'Pendientes'),
                Tab(text: 'Pagados'),
                Tab(text: 'Vencidos'),
              ],
            ),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _showCreatePaymentDialog(),
            icon: const Icon(Icons.add),
            label: const Text('Nuevo cobro'),
          ),
          body: state is PaymentLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    _buildPaymentSummary(state),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildPaymentList(
                              _getPaymentsByStatus(state, 'pendiente')),
                          _buildPaymentList(
                              _getPaymentsByStatus(state, 'pagado')),
                          _buildPaymentList(
                              _getPaymentsByStatus(state, 'vencido')),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildPaymentSummary(PaymentState state) {
    double total = 0;
    double collected = 0;

    if (state is PaymentLoaded) {
      total = state.payments.fold<double>(0, (sum, p) => sum + p.amount);
      collected = state.payments
          .where((p) => p.status == 'pagado')
          .fold<double>(0, (sum, p) => sum + p.amount);
    }
    final pending = total - collected;

    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: _summaryChip('Total', '\$${total.toStringAsFixed(2)}',
                AppTheme.secondaryColor),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _summaryChip('Cobrado', '\$${collected.toStringAsFixed(2)}',
                AppTheme.statusFree),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _summaryChip('Pendiente', '\$${pending.toStringAsFixed(2)}',
                AppTheme.warningColor),
          ),
        ],
      ),
    );
  }

  Widget _summaryChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 16, color: color)),
          Text(label,
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildPaymentList(List<PaymentModel> payments) {
    if (payments.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.payment, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('Sin pagos en esta categoría',
                style: TextStyle(color: Colors.grey[500], fontSize: 16)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: payments.length,
      itemBuilder: (context, index) {
        return _buildPaymentCard(payments[index]);
      },
    );
  }

  Widget _buildPaymentCard(PaymentModel payment) {
    Color statusColor;
    IconData statusIcon;

    switch (payment.status) {
      case PaymentStatus.validated:
        statusColor = AppTheme.statusFree;
        statusIcon = Icons.check_circle;
        break;
      case PaymentStatus.rejected:
        statusColor = AppTheme.errorColor;
        statusIcon = Icons.warning;
        break;
      case PaymentStatus.pending:
        statusColor = AppTheme.warningColor;
        statusIcon = Icons.schedule;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.15),
          child: Icon(statusIcon, color: statusColor),
        ),
        title: Text(payment.driverId,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(PaymentConcepts.label(payment.concept)),
            if (payment.dueDate != null)
              Text(
                'Vence: ${payment.dueDate!.toIso8601String().substring(0, 10)}',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary),
              ),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '\$${payment.amount.toStringAsFixed(2)}',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: statusColor),
            ),
            Text(
              payment.status.name.toUpperCase(),
              style: TextStyle(fontSize: 10, color: statusColor),
            ),
          ],
        ),
        onTap: () {
          if (payment.status == 'pendiente' || payment.status == 'vencido') {
            _showMarkPaidDialog(payment);
          }
        },
      ),
    );
  }

  void _showCreatePaymentDialog() {
    String? selectedDriverId;
    final amountController = TextEditingController();
    final conceptController = TextEditingController();

    // TODO: cuando se rediseñe esta pantalla, usar authState para
    // resolver associationId del usuario logueado.

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Nuevo Cobro'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'ID Conductor',
                    hintText: 'Ingrese el ID del conductor',
                  ),
                  onChanged: (v) =>
                      setDialogState(() => selectedDriverId = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  decoration: const InputDecoration(
                    labelText: 'Monto',
                    prefixText: '\$ ',
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: conceptController,
                  decoration:
                      const InputDecoration(labelText: 'Concepto'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar')),
            ElevatedButton(
              onPressed: () {
                if (amountController.text.isNotEmpty &&
                    selectedDriverId != null &&
                    selectedDriverId!.isNotEmpty) {
                  // TODO: esta pantalla se rediseña en próxima sesión
                  // junto con el nuevo flujo de pagos. associationId
                  // debe venir del AuthBloc, no hardcoded.
                  final payment = PaymentModel(
                    uid: const Uuid().v4(),
                    associationId: 'jipijapa',
                    driverId: selectedDriverId!,
                    amount:
                        double.tryParse(amountController.text) ?? 0,
                    concept: conceptController.text.isNotEmpty
                        ? conceptController.text
                        : 'cuota_mensual',
                    status: PaymentStatus.pending,
                    paymentDate: DateTime.now(),
                    dueDate:
                        DateTime.now().add(const Duration(days: 7)),
                    reportedAt: DateTime.now(),
                  );
                  context
                      .read<PaymentBloc>()
                      .add(PaymentCreateRequested(payment));
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Crear'),
            ),
          ],
        ),
      ),
    );
  }

  void _showMarkPaidDialog(PaymentModel payment) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Registrar Pago'),
        content: Text(
            '¿Marcar como pagado el cobro de \$${payment.amount.toStringAsFixed(2)} '
            'de ${payment.driverId}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () {
              context.read<PaymentBloc>().add(
                    PaymentMarkPaidRequested(
                      payment.uid,
                      paymentMethod: 'efectivo',
                    ),
                  );
              Navigator.pop(ctx);
            },
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
  }
}
