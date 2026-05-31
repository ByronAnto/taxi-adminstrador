import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/payment_model.dart';
import '../bloc/payment_bloc.dart';

/// Página de registro y control de gastos del conductor
class ExpensesPage extends StatefulWidget {
  const ExpensesPage({super.key});

  @override
  State<ExpensesPage> createState() => _ExpensesPageState();
}

class _ExpensesPageState extends State<ExpensesPage> {
  String _selectedCategory = 'todos';

  final Map<String, IconData> _categoryIcons = {
    'gasolina': Icons.local_gas_station,
    'mantenimiento': Icons.build,
    'lavado': Icons.local_car_wash,
    'peaje': Icons.toll,
    'otro': Icons.receipt_long,
  };

  // Colores categóricos cohesivos (paleta del design system).
  final Map<String, Color> _categoryColors = {
    'gasolina': AppTheme.categorical[6], // orange
    'mantenimiento': AppTheme.categorical[0], // indigo
    'lavado': AppTheme.categorical[4], // cyan
    'peaje': AppTheme.categorical[2], // purple
    'otro': AppTheme.statusOffline, // gris neutro
  };

  @override
  void initState() {
    super.initState();
    _loadExpenses();
  }

  void _loadExpenses() {
    final authState = context.read<AuthBloc>().state;
    if (authState is AuthAuthenticated) {
      context.read<PaymentBloc>().add(
            ExpensesLoadRequested(authState.user.uid),
          );
    }
  }

  List<ExpenseModel> _filteredExpenses(PaymentState state) {
    if (state is! PaymentLoaded) return [];
    final all = state.expenses;
    if (_selectedCategory == 'todos') return all;
    return all.where((e) => e.category == _selectedCategory).toList();
  }

  double _totalForCategory(List<ExpenseModel> expenses, String cat) {
    final list =
        cat == 'todos' ? expenses : expenses.where((e) => e.category == cat);
    return list.fold<double>(0, (sum, e) => sum + e.amount);
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
          _loadExpenses();
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
        final expenses =
            state is PaymentLoaded ? state.expenses : <ExpenseModel>[];
        final filtered = _filteredExpenses(state);

        return Scaffold(
          appBar: AppBar(title: const Text('Mis Gastos')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _showAddExpenseDialog(),
            icon: const Icon(Icons.add),
            label: const Text('Nuevo gasto'),
          ),
          body: state is PaymentLoading
              ? const LoadingState(message: 'Cargando gastos…')
              : state is PaymentError
                  ? ErrorState(
                      message: state.message,
                      onRetry: _loadExpenses,
                    )
                  : Column(
                      children: [
                        // Summary cards
                        Padding(
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          child: Row(
                            children: [
                              Expanded(
                                child: _summaryCard(
                                  context,
                                  'Total',
                                  '\$${_totalForCategory(expenses, 'todos').toStringAsFixed(2)}',
                                  Theme.of(context).colorScheme.secondary,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: _summaryCard(
                                  context,
                                  'Gasolina',
                                  '\$${_totalForCategory(expenses, 'gasolina').toStringAsFixed(2)}',
                                  _categoryColors['gasolina']!,
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Category filter chips
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                _buildFilterChip('todos', 'Todos'),
                                ..._categoryIcons.keys.map(
                                  (cat) => _buildFilterChip(
                                    cat,
                                    cat[0].toUpperCase() + cat.substring(1),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),

                        // Expense list
                        Expanded(
                          child: filtered.isEmpty
                              ? const EmptyState(
                                  icon: Icons.receipt_long,
                                  title: 'Sin gastos registrados',
                                  subtitle:
                                      'Toca "Nuevo gasto" para registrar el primero.',
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.all(AppSpacing.md),
                                  itemCount: filtered.length,
                                  itemBuilder: (ctx, i) =>
                                      _buildExpenseCard(filtered[i]),
                                ),
                        ),
                      ],
                    ),
        );
      },
    );
  }

  Widget _summaryCard(
      BuildContext context, String label, String value, Color color) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Text(value,
              style: textTheme.titleMedium?.copyWith(color: color)),
          Text(label,
              style: textTheme.labelSmall
                  ?.copyWith(color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String category, String label) {
    final isSelected = _selectedCategory == category;
    final secondary = Theme.of(context).colorScheme.secondary;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: FilterChip(
        selected: isSelected,
        label: Text(label),
        selectedColor: secondary.withValues(alpha: 0.2),
        checkmarkColor: secondary,
        onSelected: (_) => setState(() => _selectedCategory = category),
      ),
    );
  }

  Widget _buildExpenseCard(ExpenseModel expense) {
    final color = _categoryColors[expense.category] ?? AppTheme.statusOffline;
    final icon = _categoryIcons[expense.category] ?? Icons.receipt_long;

    return Dismissible(
      key: Key(expense.uid),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: AppTheme.errorColor,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Eliminar gasto'),
            content: const Text('¿Desea eliminar este gasto?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Eliminar')),
            ],
          ),
        );
      },
      onDismissed: (_) {
        context.read<PaymentBloc>().add(ExpenseDeleteRequested(expense.uid));
      },
      child: Card(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.15),
            child: Icon(icon, color: color),
          ),
          title: Text(
            expense.category[0].toUpperCase() + expense.category.substring(1),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (expense.description.isNotEmpty) Text(expense.description),
              Text(
                expense.date.toIso8601String().substring(0, 10),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.textSecondary),
              ),
            ],
          ),
          trailing: Text(
            '\$${expense.amount.toStringAsFixed(2)}',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: color),
          ),
        ),
      ),
    );
  }

  void _showAddExpenseDialog() {
    String selectedCat = 'gasolina';
    final amountCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    final authState = context.read<AuthBloc>().state;
    final driverId =
        authState is AuthAuthenticated ? authState.user.uid : '';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Registrar Gasto'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: selectedCat,
                  decoration: const InputDecoration(labelText: 'Categoría'),
                  items: _categoryIcons.keys
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Row(
                              children: [
                                Icon(_categoryIcons[c], size: 18),
                                const SizedBox(width: 8),
                                Text(c[0].toUpperCase() + c.substring(1)),
                              ],
                            ),
                          ))
                      .toList(),
                  onChanged: (v) =>
                      setDialogState(() => selectedCat = v ?? selectedCat),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Monto',
                    prefixText: '\$ ',
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Descripción'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () {
                if (amountCtrl.text.isNotEmpty) {
                  final expense = ExpenseModel(
                    uid: const Uuid().v4(),
                    driverId: driverId,
                    category: selectedCat,
                    amount: double.tryParse(amountCtrl.text) ?? 0,
                    description: descCtrl.text,
                    date: DateTime.now(),
                    createdAt: DateTime.now(),
                  );
                  context
                      .read<PaymentBloc>()
                      .add(ExpenseCreateRequested(expense));
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
  }
}
