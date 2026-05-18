import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../associations/data/models/association_model.dart';
import '../../../associations/data/models/pricing_tier_model.dart';

/// Panel de super-admin (solo Byron / proveedor del SaaS).
///
/// Aquí se administran asociaciones, planes y se ejecutan migraciones.
/// El acceso se restringe por email en `_isSuperAdmin`.
class SuperAdminPage extends StatefulWidget {
  const SuperAdminPage({super.key});

  @override
  State<SuperAdminPage> createState() => _SuperAdminPageState();
}

class _SuperAdminPageState extends State<SuperAdminPage> {
  final _functions = FirebaseFunctions.instance;
  final _firestore = FirebaseFirestore.instance;

  bool _seedingDefaults = false;
  bool _migrating = false;
  bool _purging = false;
  String? _lastResult;

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthBloc>().state;

    if (authState is! AuthAuthenticated) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_isSuperAdmin(authState.user.email)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Acceso denegado')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No tienes permisos de super-administrador.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Super-Admin'),
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.home),
          onPressed: () => context.go('/home'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSectionCard(
            title: 'Inicialización',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Ejecuta estas acciones UNA SOLA VEZ al estrenar el SaaS.',
                  style: TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _seedingDefaults ? null : _seedDefaults,
                  icon: _seedingDefaults
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.eco),
                  label: const Text(
                    'Sembrar planes y asociación Jipijapa',
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _migrating
                      ? null
                      : () => _confirmAndRun(
                            'Migrar todos los documentos existentes a la asociación "jipijapa". Esto solo se ejecuta una vez.',
                            _migrateToMultitenant,
                          ),
                  icon: _migrating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_sync),
                  label: const Text('Migrar datos a multi-tenant'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _purging ? null : _purgeProofsNow,
                  icon: _purging
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_sweep),
                  label: const Text('Purgar comprobantes vencidos'),
                ),
                if (_lastResult != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Text(
                      _lastResult!,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionCard(
            title: 'Asociaciones',
            trailing: ElevatedButton.icon(
              onPressed: () => _showCreateAssociationDialog(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Nueva'),
            ),
            child: _buildAssociationsList(),
          ),
          const SizedBox(height: 16),
          _buildSectionCard(
            title: 'Planes (Pricing Tiers)',
            trailing: ElevatedButton.icon(
              onPressed: () => _showPricingTierDialog(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Nuevo'),
            ),
            child: _buildPricingTiersList(),
          ),
          const SizedBox(height: 16),
          _buildSectionCard(
            title: 'Configuración global',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.message),
                  label: const Text('Editar mensaje del banner de vencimiento'),
                  onPressed: () => _editBannerMessage(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────── Sections ───────────────────

  Widget _buildSectionCard({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const Divider(height: 24),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildAssociationsList() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('associations')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Aún no hay asociaciones. Siembra los datos default o crea una nueva.',
              style: TextStyle(color: Colors.black54),
            ),
          );
        }

        return Column(
          children: docs
              .map((doc) => _buildAssociationTile(
                    AssociationModel.fromFirestore(doc),
                  ))
              .toList(),
        );
      },
    );
  }

  Widget _buildAssociationTile(AssociationModel a) {
    final statusColor = switch (a.status) {
      AssociationStatus.active => Colors.green,
      AssociationStatus.trial => Colors.orange,
      AssociationStatus.suspended => Colors.red,
      AssociationStatus.cancelled => Colors.grey,
    };

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: statusColor.withValues(alpha: 0.15),
        child: Text(
          a.code.isNotEmpty ? a.code.substring(0, 1) : '?',
          style: TextStyle(color: statusColor, fontWeight: FontWeight.bold),
        ),
      ),
      title: Text('${a.name} · ${a.code}'),
      subtitle: Text(
        '${a.city} · ${a.status.name} · ${a.pricingTierId} · '
        '${a.maxDrivers} max drivers',
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (action) => _onAssociationAction(action, a),
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'view_members',
            child: Row(children: [
              Icon(Icons.people, size: 18),
              SizedBox(width: 8),
              Text('Ver socios'),
            ]),
          ),
          const PopupMenuItem(
            value: 'change_plan',
            child: Row(children: [
              Icon(Icons.swap_horiz, size: 18),
              SizedBox(width: 8),
              Text('Cambiar plan'),
            ]),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'activate', child: Text('Activar')),
          const PopupMenuItem(value: 'suspend', child: Text('Suspender')),
          const PopupMenuItem(value: 'cancel', child: Text('Cancelar')),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'edit',
            child: Row(children: [
              Icon(Icons.edit, size: 18),
              SizedBox(width: 8),
              Text('Editar datos'),
            ]),
          ),
          const PopupMenuItem(value: 'copy_id', child: Text('Copiar ID')),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'delete',
            child: Row(children: [
              Icon(Icons.delete, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('Borrar definitivo',
                  style: TextStyle(color: Colors.red)),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _buildPricingTiersList() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('pricingTiers')
          .orderBy('sortOrder')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Sin planes. Siembra los datos default arriba.',
              style: TextStyle(color: Colors.black54),
            ),
          );
        }

        return Column(
          children: docs.map((doc) {
            final tier = PricingTierModel.fromFirestore(doc);
            return ListTile(
              title: Row(
                children: [
                  Expanded(child: Text(tier.name)),
                  tier.isPublic
                      ? const Chip(
                          label: Text('Público',
                              style: TextStyle(fontSize: 10)),
                          backgroundColor: Color(0xFFE8F5E9),
                          padding: EdgeInsets.zero,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        )
                      : const Chip(
                          label: Text('Oculto',
                              style: TextStyle(fontSize: 10)),
                          backgroundColor: Color(0xFFFFEBEE),
                          padding: EdgeInsets.zero,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                ],
              ),
              subtitle: Text(
                '${tier.id} · \$${tier.monthlyPriceUsd}/mes · '
                'hasta ${tier.maxDrivers} drivers, '
                '${tier.maxChannels} canales',
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (action) => _onTierAction(action, tier),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: Row(children: [
                      Icon(Icons.edit, size: 18),
                      SizedBox(width: 8),
                      Text('Editar'),
                    ]),
                  ),
                  PopupMenuItem(
                    value: tier.isPublic ? 'hide' : 'publish',
                    child: Row(children: [
                      Icon(
                        tier.isPublic
                            ? Icons.visibility_off
                            : Icons.visibility,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(tier.isPublic ? 'Ocultar' : 'Publicar'),
                    ]),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(children: [
                      Icon(Icons.delete, size: 18, color: Colors.red),
                      SizedBox(width: 8),
                      Text('Eliminar', style: TextStyle(color: Colors.red)),
                    ]),
                  ),
                ],
              ),
              onTap: () => _showPricingTierDialog(existing: tier),
            );
          }).toList(),
        );
      },
    );
  }

  // ─────────────────── Actions ───────────────────

  bool _isSuperAdmin(String email) {
    // Debe coincidir con SUPER_ADMIN_EMAILS en functions/index.js
    return email == 'brealpeaymara@gmail.com';
  }

  Future<void> _seedDefaults() async {
    setState(() {
      _seedingDefaults = true;
      _lastResult = null;
    });
    try {
      final result = await _functions.httpsCallable('seedDefaults').call();
      setState(() => _lastResult = 'seedDefaults OK: ${result.data}');
      _showSnack('Planes y asociación Jipijapa sembrados.', Colors.green);
    } on FirebaseFunctionsException catch (e) {
      setState(() => _lastResult = 'Error: ${e.code} ${e.message}');
      _showSnack('Error: ${e.message}', Colors.red);
    } finally {
      if (mounted) setState(() => _seedingDefaults = false);
    }
  }

  Future<void> _migrateToMultitenant() async {
    setState(() {
      _migrating = true;
      _lastResult = null;
    });
    try {
      final result = await _functions.httpsCallable('migrateToMultitenant').call(
        {'associationId': 'jipijapa', 'dryRun': false},
      );
      setState(() =>
          _lastResult = 'migrateToMultitenant OK: ${result.data}');
      _showSnack('Migración completada.', Colors.green);
    } on FirebaseFunctionsException catch (e) {
      setState(() => _lastResult = 'Error: ${e.code} ${e.message}');
      _showSnack('Error: ${e.message}', Colors.red);
    } finally {
      if (mounted) setState(() => _migrating = false);
    }
  }

  Future<void> _purgeProofsNow() async {
    setState(() {
      _purging = true;
      _lastResult = null;
    });
    try {
      final result =
          await _functions.httpsCallable('purgeExpiredProofsNow').call();
      final data = result.data as Map?;
      setState(() => _lastResult = 'Purga manual: ${data ?? result.data}');
      _showSnack(
        'Purga ejecutada. Borrados: ${data?["blobsDeleted"] ?? "?"}',
        Colors.green,
      );
    } on FirebaseFunctionsException catch (e) {
      setState(() => _lastResult = 'Error: ${e.code} ${e.message}');
      _showSnack('Error: ${e.message}', Colors.red);
    } finally {
      if (mounted) setState(() => _purging = false);
    }
  }

  Future<void> _confirmAndRun(String message, Future<void> Function() run) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Estás seguro?'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ejecutar'),
          ),
        ],
      ),
    );
    if (ok == true) await run();
  }

  Future<void> _onAssociationAction(String action, AssociationModel a) async {
    switch (action) {
      case 'copy_id':
        await Clipboard.setData(ClipboardData(text: a.id));
        _showSnack('ID copiado: ${a.id}', Colors.blue);
        break;
      case 'suspend':
        await _firestore
            .collection('associations')
            .doc(a.id)
            .update({'status': 'suspended', 'updatedAt': FieldValue.serverTimestamp()});
        _showSnack('Suspendida.', Colors.orange);
        break;
      case 'activate':
        await _firestore
            .collection('associations')
            .doc(a.id)
            .update({'status': 'active', 'updatedAt': FieldValue.serverTimestamp()});
        _showSnack('Activada.', Colors.green);
        break;
      case 'cancel':
        await _firestore
            .collection('associations')
            .doc(a.id)
            .update({'status': 'cancelled', 'updatedAt': FieldValue.serverTimestamp()});
        _showSnack('Cancelada.', Colors.red);
        break;
      case 'change_plan':
        await _showChangePlanDialog(a);
        break;
      case 'view_members':
        if (mounted) context.go('/members?aid=${a.id}');
        break;
      case 'edit':
        await _showEditAssociationDialog(a);
        break;
      case 'delete':
        await _confirmDeleteAssociation(a);
        break;
    }
  }

  Future<void> _showEditAssociationDialog(AssociationModel a) async {
    final nameCtrl = TextEditingController(text: a.name);
    final cityCtrl = TextEditingController(text: a.city);
    final emailCtrl = TextEditingController(text: a.email);
    final phoneCtrl = TextEditingController(text: a.phone ?? '');
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Editar ${a.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nombre',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: cityCtrl,
                decoration: const InputDecoration(
                  labelText: 'Ciudad',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email contacto',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Teléfono',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result != true) return;
    try {
      await _firestore.collection('associations').doc(a.id).update({
        'name': nameCtrl.text.trim(),
        'city': cityCtrl.text.trim(),
        'email': emailCtrl.text.trim(),
        'phone': phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) _showSnack('Asociación actualizada', Colors.green);
    } catch (e) {
      if (mounted) _showSnack('Error: $e', Colors.red);
    }
  }

  Future<void> _confirmDeleteAssociation(AssociationModel a) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar asociación'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '⚠️ Esto eliminará el doc associations/${a.id}. Los usuarios, viajes, pagos, canales y demás docs etiquetados con associationId="${a.id}" NO se borran automáticamente.',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            const Text(
              'Para confirmar escribe el código de la asociación:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: ctrl,
              decoration: InputDecoration(
                hintText: a.code,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () {
              if (ctrl.text.trim().toUpperCase() == a.code.toUpperCase()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('BORRAR'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _firestore.collection('associations').doc(a.id).delete();
      if (mounted) _showSnack('Asociación borrada', Colors.red);
    } catch (e) {
      if (mounted) _showSnack('Error: $e', Colors.red);
    }
  }

  /// Diálogo para cambiar el plan de una asociación. Lista todos los
  /// pricingTiers (incluso ocultos), permite seleccionar uno, y al
  /// guardar actualiza pricingTierId + límites en el doc.
  Future<void> _showChangePlanDialog(AssociationModel a) async {
    final tiersSnap = await _firestore
        .collection('pricingTiers')
        .orderBy('sortOrder')
        .get();

    if (!mounted) return;

    final tiers = tiersSnap.docs
        .map((d) => PricingTierModel.fromFirestore(d))
        .toList();

    if (tiers.isEmpty) {
      _showSnack(
        'No hay planes disponibles. Siembra los datos default primero.',
        Colors.orange,
      );
      return;
    }

    String selectedTierId = a.pricingTierId;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Cambiar plan · ${a.name}'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Plan actual: ${a.pricingTierId}',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  RadioGroup<String>(
                    groupValue: selectedTierId,
                    onChanged: (v) {
                      if (v != null) {
                        setDialogState(() => selectedTierId = v);
                      }
                    },
                    child: Column(
                      children: tiers
                          .map(
                            (t) => RadioListTile<String>(
                              value: t.id,
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '${t.name} — \$${t.monthlyPriceUsd}/mes',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (!t.isPublic)
                                    const Chip(
                                      label: Text('Oculto',
                                          style: TextStyle(fontSize: 10)),
                                      backgroundColor: Color(0xFFFFEBEE),
                                      padding: EdgeInsets.zero,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                ],
                              ),
                              subtitle: Text(
                                'Hasta ${t.maxDrivers} conductores · '
                                '${t.maxOperators} operadora(s) · '
                                '${t.maxChannels} canales'
                                '${t.maxAgoraMinutesPerMonth != null ? "\nMáx ${t.maxAgoraMinutesPerMonth} min Agora/mes" : ""}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              isThreeLine: t.maxAgoraMinutesPerMonth != null,
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: selectedTierId == a.pricingTierId
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    final newTier = tiers.firstWhere((t) => t.id == selectedTierId);

    try {
      await _firestore.collection('associations').doc(a.id).update({
        'pricingTierId': newTier.id,
        'maxDrivers': newTier.maxDrivers,
        'maxOperators': newTier.maxOperators,
        'maxChannels': newTier.maxChannels,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _showSnack(
        'Plan cambiado a ${newTier.name} (\$${newTier.monthlyPriceUsd}/mes)',
        Colors.green,
      );
    } catch (e) {
      _showSnack('Error al cambiar plan: $e', Colors.red);
    }
  }

  Future<void> _showCreateAssociationDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _CreateAssociationDialog(functions: _functions),
    );
  }

  /// Abre el diálogo de plan. Si [existing] es null → crear, si no → editar.
  Future<void> _showPricingTierDialog({PricingTierModel? existing}) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _PricingTierDialog(
        firestore: _firestore,
        existing: existing,
      ),
    );
  }

  Future<void> _onTierAction(String action, PricingTierModel tier) async {
    final ref = _firestore.collection('pricingTiers').doc(tier.id);

    switch (action) {
      case 'edit':
        await _showPricingTierDialog(existing: tier);
        break;

      case 'hide':
      case 'publish':
        await ref.update({
          'isPublic': action == 'publish',
          'updatedAt': FieldValue.serverTimestamp(),
        });
        _showSnack(
          action == 'publish' ? 'Plan publicado.' : 'Plan ocultado.',
          Colors.blue,
        );
        break;

      case 'delete':
        // Verifica que ninguna asociación use este plan
        final inUse = await _firestore
            .collection('associations')
            .where('pricingTierId', isEqualTo: tier.id)
            .limit(1)
            .get();
        if (inUse.docs.isNotEmpty) {
          _showSnack(
            'No se puede eliminar: hay asociaciones usando este plan. Cámbialas primero.',
            Colors.red,
          );
          return;
        }

        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('¿Eliminar plan?'),
            content: Text(
              'Vas a eliminar permanentemente el plan "${tier.name}" '
              '(id: ${tier.id}). Esta acción no se puede deshacer.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Eliminar'),
              ),
            ],
          ),
        );

        if (ok == true) {
          await ref.delete();
          _showSnack('Plan eliminado.', Colors.red);
        }
        break;
    }
  }

  void _showSnack(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  // ─────────────────── Configuración global ───────────────────

  Future<void> _editBannerMessage(BuildContext context) async {
    final fs = FirebaseFirestore.instance;
    final snap = await fs.collection('app_config').doc('global').get();
    final current = snap.data()?['dueDateBannerMessage'] as String? ??
        'Recuerde pagar {amount} antes de las 00:00 del {dueDate} o será bloqueado.';
    final ctrl = TextEditingController(text: current);

    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final saved = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mensaje del banner'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Placeholders soportados:\n{amount}, {dueDate}',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            TextField(controller: ctrl, maxLines: 4),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    if (saved == null) return;

    await fs.collection('app_config').doc('global').set({
      'dueDateBannerMessage': saved,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (!context.mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Mensaje guardado')),
    );
  }
}

// ─────────────────── Create Association Dialog ───────────────────

class _CreateAssociationDialog extends StatefulWidget {
  final FirebaseFunctions functions;
  const _CreateAssociationDialog({required this.functions});

  @override
  State<_CreateAssociationDialog> createState() =>
      _CreateAssociationDialogState();
}

class _CreateAssociationDialogState extends State<_CreateAssociationDialog> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _city = TextEditingController(text: 'Quito');
  final _phone = TextEditingController();
  final _adminEmail = TextEditingController();
  final _adminName = TextEditingController();
  final _adminLastname = TextEditingController();
  String _tierId = 'basic';
  int _trialDays = 30;
  bool _busy = false;
  Map<String, dynamic>? _result;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _city.dispose();
    _phone.dispose();
    _adminEmail.dispose();
    _adminName.dispose();
    _adminLastname.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nueva Asociación'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: _result == null ? _buildForm() : _buildResult(),
        ),
      ),
      actions: _result == null
          ? [
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Crear'),
              ),
            ]
          : [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Listo'),
              ),
            ],
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _code,
            decoration: const InputDecoration(
              labelText: 'Código (3-10 chars, ej: ROLD)',
              helperText: 'Único globalmente, en mayúsculas',
            ),
            textCapitalization: TextCapitalization.characters,
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Requerido';
              final t = v.trim();
              if (t.length < 3 || t.length > 10) return '3-10 caracteres';
              if (!RegExp(r'^[A-Z0-9]+$').hasMatch(t.toUpperCase())) {
                return 'Solo letras y números';
              }
              return null;
            },
          ),
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Nombre'),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Requerido' : null,
          ),
          TextFormField(
            controller: _city,
            decoration: const InputDecoration(labelText: 'Ciudad'),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Requerido' : null,
          ),
          TextFormField(
            controller: _phone,
            decoration:
                const InputDecoration(labelText: 'Teléfono (opcional)'),
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _tierId,
            decoration: const InputDecoration(labelText: 'Plan'),
            items: const [
              DropdownMenuItem(value: 'trial', child: Text('Trial')),
              DropdownMenuItem(value: 'basic', child: Text('Básico')),
              DropdownMenuItem(value: 'pro', child: Text('Profesional')),
              DropdownMenuItem(value: 'enterprise', child: Text('Empresarial')),
            ],
            onChanged: (v) => setState(() => _tierId = v ?? 'basic'),
          ),
          TextFormField(
            initialValue: _trialDays.toString(),
            decoration:
                const InputDecoration(labelText: 'Días de trial'),
            keyboardType: TextInputType.number,
            onChanged: (v) =>
                _trialDays = int.tryParse(v) ?? 30,
          ),
          const Divider(height: 32),
          const Text(
            'Admin de la asociación',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          TextFormField(
            controller: _adminEmail,
            decoration: const InputDecoration(labelText: 'Email del admin'),
            keyboardType: TextInputType.emailAddress,
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Requerido';
              if (!v.contains('@')) return 'Email inválido';
              return null;
            },
          ),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _adminName,
                  decoration:
                      const InputDecoration(labelText: 'Nombre'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  controller: _adminLastname,
                  decoration:
                      const InputDecoration(labelText: 'Apellido'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    final r = _result!;
    final tempPassword = r['tempPassword'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 48),
        const SizedBox(height: 12),
        const Text(
          'Asociación creada con éxito.',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 12),
        _buildResultRow('ID interno', r['associationId']),
        _buildResultRow('Código', r['code']),
        _buildResultRow('Admin email', r['adminEmail']),
        if (tempPassword != null)
          _buildResultRow('Password temporal', tempPassword,
              copyable: true, highlight: true),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.amber.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.amber.shade200),
          ),
          child: const Text(
            '⚠️ COPIA Y ENVÍA estos datos al admin AHORA. '
            'El password temporal solo se muestra una vez.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildResultRow(String label, String? value,
      {bool copyable = false, bool highlight = false}) {
    if (value == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text('$label:',
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontFamily: 'monospace',
                color: highlight ? Colors.red.shade700 : null,
                fontWeight: highlight ? FontWeight.bold : null,
              ),
            ),
          ),
          if (copyable)
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: value));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copiado al portapapeles')),
                  );
                }
              },
            ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _busy = true);
    try {
      final result = await widget.functions.httpsCallable('createAssociation').call({
        'code': _code.text.trim().toUpperCase(),
        'name': _name.text.trim(),
        'city': _city.text.trim(),
        'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        'pricingTierId': _tierId,
        'adminEmail': _adminEmail.text.trim(),
        'adminName': _adminName.text.trim(),
        'adminLastname': _adminLastname.text.trim(),
        'trialDays': _trialDays,
      });
      setState(() => _result = Map<String, dynamic>.from(result.data as Map));
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.message ?? e.code}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ─────────────────── Pricing Tier Dialog (crear / editar) ───────────────────

class _PricingTierDialog extends StatefulWidget {
  final FirebaseFirestore firestore;
  final PricingTierModel? existing;

  const _PricingTierDialog({
    required this.firestore,
    this.existing,
  });

  @override
  State<_PricingTierDialog> createState() => _PricingTierDialogState();
}

class _PricingTierDialogState extends State<_PricingTierDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _id;
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _monthly;
  late final TextEditingController _yearly;
  late final TextEditingController _maxDrivers;
  late final TextEditingController _maxOperators;
  late final TextEditingController _maxChannels;
  late final TextEditingController _maxAgora;
  late final TextEditingController _sortOrder;
  bool _isPublic = true;
  bool _busy = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _id = TextEditingController(text: e?.id ?? '');
    _name = TextEditingController(text: e?.name ?? '');
    _description = TextEditingController(text: e?.description ?? '');
    _monthly = TextEditingController(
        text: e?.monthlyPriceUsd.toStringAsFixed(2) ?? '0.00');
    _yearly = TextEditingController(
        text: e?.yearlyPriceUsd.toStringAsFixed(2) ?? '0.00');
    _maxDrivers =
        TextEditingController(text: (e?.maxDrivers ?? 30).toString());
    _maxOperators =
        TextEditingController(text: (e?.maxOperators ?? 1).toString());
    _maxChannels =
        TextEditingController(text: (e?.maxChannels ?? 3).toString());
    _maxAgora = TextEditingController(
        text: e?.maxAgoraMinutesPerMonth?.toString() ?? '');
    _sortOrder =
        TextEditingController(text: (e?.sortOrder ?? 0).toString());
    _isPublic = e?.isPublic ?? true;
  }

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _description.dispose();
    _monthly.dispose();
    _yearly.dispose();
    _maxDrivers.dispose();
    _maxOperators.dispose();
    _maxChannels.dispose();
    _maxAgora.dispose();
    _sortOrder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Editar plan · ${widget.existing!.id}' : 'Nuevo plan'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _id,
                  enabled: !_isEdit,
                  decoration: const InputDecoration(
                    labelText: 'ID (slug)',
                    helperText: 'Ej: basic, pro, enterprise. Único, minúsculas.',
                  ),
                  validator: (v) {
                    if (_isEdit) return null;
                    if (v == null || v.trim().isEmpty) return 'Requerido';
                    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(v.trim())) {
                      return 'Solo minúsculas, números, guion y guion bajo';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  controller: _name,
                  decoration:
                      const InputDecoration(labelText: 'Nombre visible'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Requerido' : null,
                ),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: 'Descripción'),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _monthly,
                        decoration: const InputDecoration(
                          labelText: 'Precio mensual (USD)',
                          prefixText: '\$ ',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: _validatePositiveNum,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _yearly,
                        decoration: const InputDecoration(
                          labelText: 'Precio anual (USD)',
                          prefixText: '\$ ',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: _validatePositiveNum,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 32),
                const Text(
                  'Límites',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _maxDrivers,
                        decoration:
                            const InputDecoration(labelText: 'Max drivers'),
                        keyboardType: TextInputType.number,
                        validator: _validatePositiveInt,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _maxOperators,
                        decoration: const InputDecoration(
                            labelText: 'Max operadoras'),
                        keyboardType: TextInputType.number,
                        validator: _validatePositiveInt,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _maxChannels,
                        decoration:
                            const InputDecoration(labelText: 'Max canales'),
                        keyboardType: TextInputType.number,
                        validator: _validatePositiveInt,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _maxAgora,
                        decoration: const InputDecoration(
                          labelText: 'Min Agora/mes',
                          helperText: 'Vacío = ilimitado',
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _sortOrder,
                        decoration: const InputDecoration(
                          labelText: 'Orden (asc)',
                          helperText: '0 = primero, 999 = último',
                        ),
                        keyboardType: TextInputType.number,
                        validator: _validatePositiveInt,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Público',
                            style: TextStyle(fontSize: 14)),
                        subtitle: Text(
                          _isPublic
                              ? 'Visible para nuevas asociaciones'
                              : 'Oculto del catálogo',
                          style: const TextStyle(fontSize: 11),
                        ),
                        value: _isPublic,
                        onChanged: (v) => setState(() => _isPublic = v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isEdit ? 'Guardar' : 'Crear'),
        ),
      ],
    );
  }

  String? _validatePositiveNum(String? v) {
    if (v == null || v.trim().isEmpty) return 'Requerido';
    final n = double.tryParse(v);
    if (n == null) return 'Número inválido';
    if (n < 0) return 'Debe ser ≥ 0';
    return null;
  }

  String? _validatePositiveInt(String? v) {
    if (v == null || v.trim().isEmpty) return 'Requerido';
    final n = int.tryParse(v);
    if (n == null) return 'Entero inválido';
    if (n < 0) return 'Debe ser ≥ 0';
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _busy = true);
    try {
      final id = _id.text.trim();
      final ref = widget.firestore.collection('pricingTiers').doc(id);

      // Si es nuevo, validar que el id no exista
      if (!_isEdit) {
        final existing = await ref.get();
        if (existing.exists) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Ya existe un plan con id "$id".'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
      }

      final maxAgoraText = _maxAgora.text.trim();
      final data = <String, dynamic>{
        'name': _name.text.trim(),
        'description': _description.text.trim(),
        'monthlyPriceUsd': double.parse(_monthly.text.trim()),
        'yearlyPriceUsd': double.parse(_yearly.text.trim()),
        'maxDrivers': int.parse(_maxDrivers.text.trim()),
        'maxOperators': int.parse(_maxOperators.text.trim()),
        'maxChannels': int.parse(_maxChannels.text.trim()),
        'maxAgoraMinutesPerMonth':
            maxAgoraText.isEmpty ? null : int.parse(maxAgoraText),
        'isPublic': _isPublic,
        'sortOrder': int.parse(_sortOrder.text.trim()),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (_isEdit) {
        await ref.update(data);
      } else {
        data['createdAt'] = FieldValue.serverTimestamp();
        await ref.set(data);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isEdit ? 'Plan actualizado.' : 'Plan creado.'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
