import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';

/// Pantalla del admin para editar los conceptos de pago de la asociación.
///
/// Modela: cuota_mensual/semanal/diaria son las MEMBRESÍAS (cuotas que el
/// conductor paga al grupo recurrentemente). Adicionalmente el admin puede
/// gestionar conceptos como `multa`, `reingreso`, `cuota_navidena`,
/// `ayuda_calamidad`, etc.
///
/// Storage: `associations/{aid}.paymentConcepts` (Map de id a label).
/// Si el doc no tiene el campo, mostramos los defaults.
class PaymentConceptsPage extends StatefulWidget {
  const PaymentConceptsPage({super.key});

  @override
  State<PaymentConceptsPage> createState() => _PaymentConceptsPageState();
}

class _PaymentConceptsPageState extends State<PaymentConceptsPage> {
  /// Conceptos por defecto. El admin puede agregar más o renombrar estos.
  /// Las cuotas (cuota_*) son protegidas — son las membresías y siempre
  /// existen porque el cron checkDriverDues las usa para validar pagos.
  static const Map<String, String> _defaults = {
    'cuota_diaria': 'Cuota diaria',
    'cuota_semanal': 'Cuota semanal',
    'cuota_mensual': 'Cuota mensual',
    'multa': 'Multa',
    'reingreso': 'Reingreso',
    'cuota_navidena': 'Cuota navideña',
    'ayuda_calamidad': 'Ayuda calamidad',
    'incentivo': 'Incentivo',
    'ayuda': 'Ayuda',
  };

  static const _protectedIds = {
    'cuota_diaria',
    'cuota_semanal',
    'cuota_mensual',
  };

  Map<String, String> _concepts = {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
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
      final raw = doc.data()?['paymentConcepts'];
      if (raw is Map) {
        _concepts = raw.map((k, v) => MapEntry(k.toString(), v.toString()));
      } else {
        _concepts = Map.from(_defaults);
      }
    } catch (_) {
      _concepts = Map.from(_defaults);
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
        'paymentConcepts': _concepts,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Conceptos guardados')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error: $e'),
              backgroundColor: AppTheme.errorColor),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _add() async {
    final idCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuevo concepto de pago'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idCtrl,
              decoration: const InputDecoration(
                labelText: 'ID interno (sin espacios)',
                hintText: 'ej. inscripcion_socio',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: labelCtrl,
              decoration: const InputDecoration(
                labelText: 'Etiqueta visible',
                hintText: 'ej. Inscripción de socio',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Agregar')),
        ],
      ),
    );
    if (result != true) return;
    final id = idCtrl.text.trim().toLowerCase().replaceAll(' ', '_');
    final label = labelCtrl.text.trim();
    if (id.isEmpty || label.isEmpty) return;
    setState(() {
      _concepts[id] = label;
    });
  }

  Future<void> _edit(String id, String currentLabel) async {
    final ctrl = TextEditingController(text: currentLabel);
    final newLabel = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Editar etiqueta'),
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
              child: const Text('Guardar')),
        ],
      ),
    );
    if (newLabel == null || newLabel.isEmpty) return;
    setState(() => _concepts[id] = newLabel);
  }

  void _remove(String id) {
    if (_protectedIds.contains(id)) return;
    setState(() => _concepts.remove(id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conceptos de pago'),
        actions: [
          IconButton(
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
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Nuevo'),
      ),
      body: _loading
          ? const LoadingState()
          : Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  color: AppTheme.infoColor.withValues(alpha: 0.1),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          color: AppTheme.infoColor, size: 20),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Las cuotas (diaria/semanal/mensual) son protegidas: '
                          'no se pueden borrar porque el cron usa una de ellas '
                          'para validar la membresía mensual del conductor.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    children: _concepts.entries.map((e) {
                      final isProtected = _protectedIds.contains(e.key);
                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.xs),
                        child: ListTile(
                          leading: Icon(
                            isProtected
                                ? Icons.lock
                                : Icons.attach_money,
                            color: isProtected
                                ? AppTheme.statusOffline
                                : Theme.of(context).colorScheme.primary,
                          ),
                          title: Text(e.value),
                          subtitle: Text('id: ${e.key}',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(fontFamily: 'monospace')),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit, size: 20),
                                onPressed: () => _edit(e.key, e.value),
                              ),
                              if (!isProtected)
                                IconButton(
                                  icon: const Icon(Icons.delete,
                                      size: 20,
                                      color: AppTheme.errorColor),
                                  onPressed: () => _remove(e.key),
                                ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
    );
  }
}
