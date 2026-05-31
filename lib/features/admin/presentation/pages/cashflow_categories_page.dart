import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/cashflow_model.dart';

/// Pantalla del admin para editar categorías de ingresos y egresos de la
/// asociación. Las categorías viven en
/// `associations/{aid}.cashflowCategories.{ingresos[], egresos[]}`.
///
/// Si el doc no tiene el campo todavía, mostramos las defaults (de
/// [DefaultCashflowCategories]) y al primer "guardar" el doc se actualiza.
class CashflowCategoriesPage extends StatefulWidget {
  const CashflowCategoriesPage({super.key});

  @override
  State<CashflowCategoriesPage> createState() =>
      _CashflowCategoriesPageState();
}

class _CashflowCategoriesPageState extends State<CashflowCategoriesPage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  List<String> _ingresos = [];
  List<String> _egresos = [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  String? get _aid {
    final auth = context.read<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return null;
    return auth.user.associationId;
  }

  Future<void> _load() async {
    final aid = _aid;
    if (aid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .get();
      final cf = doc.data()?['cashflowCategories'] as Map<String, dynamic>?;
      _ingresos = (cf?['ingresos'] as List?)?.cast<String>() ??
          List.from(DefaultCashflowCategories.ingresos);
      _egresos = (cf?['egresos'] as List?)?.cast<String>() ??
          List.from(DefaultCashflowCategories.egresos);
    } catch (_) {
      _ingresos = List.from(DefaultCashflowCategories.ingresos);
      _egresos = List.from(DefaultCashflowCategories.egresos);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final aid = _aid;
    if (aid == null) return;
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .update({
        'cashflowCategories': {
          'ingresos': _ingresos,
          'egresos': _egresos,
        },
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Categorías guardadas')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addCategory(bool isIngreso) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isIngreso ? 'Nueva categoría de ingreso' : 'Nueva categoría de egreso'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Ej. Comisiones, Sueldos, ...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Agregar'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    setState(() {
      if (isIngreso) {
        if (!_ingresos.contains(result)) _ingresos.add(result);
      } else {
        if (!_egresos.contains(result)) _egresos.add(result);
      }
    });
  }

  void _removeCategory(bool isIngreso, String name) {
    setState(() {
      if (isIngreso) {
        _ingresos.remove(name);
      } else {
        _egresos.remove(name);
      }
    });
  }

  Future<void> _editCategory(bool isIngreso, String oldName) async {
    final ctrl = TextEditingController(text: oldName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Editar categoría'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || result == oldName) return;
    setState(() {
      final list = isIngreso ? _ingresos : _egresos;
      final idx = list.indexOf(oldName);
      if (idx >= 0) list[idx] = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Categorías de Caja'),
        actions: [
          IconButton(
            tooltip: 'Guardar',
            icon: _saving
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  )
                : const Icon(Icons.save),
            onPressed: _saving ? null : _save,
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Ingresos', icon: Icon(Icons.trending_up)),
            Tab(text: 'Egresos', icon: Icon(Icons.trending_down)),
          ],
        ),
      ),
      body: _loading
          ? const LoadingState()
          : TabBarView(
              controller: _tab,
              children: [
                _buildList(true, _ingresos),
                _buildList(false, _egresos),
              ],
            ),
    );
  }

  Widget _buildList(bool isIngreso, List<String> cats) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: ElevatedButton.icon(
            onPressed: () => _addCategory(isIngreso),
            icon: const Icon(Icons.add),
            label: Text(isIngreso
                ? 'Agregar categoría de ingreso'
                : 'Agregar categoría de egreso'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ),
        Expanded(
          child: cats.isEmpty
              ? const EmptyState(
                  icon: Icons.category_outlined,
                  title: 'Sin categorías',
                )
              : ListView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  itemCount: cats.length,
                  itemBuilder: (_, i) {
                    final c = cats[i];
                    return Card(
                      child: ListTile(
                        leading: Icon(
                          isIngreso
                              ? Icons.trending_up
                              : Icons.trending_down,
                          color: isIngreso
                              ? AppTheme.successColor
                              : AppTheme.errorColor,
                        ),
                        title: Text(c),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              onPressed: () => _editCategory(isIngreso, c),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete,
                                  size: 20, color: AppTheme.errorColor),
                              onPressed: () => _removeCategory(isIngreso, c),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
