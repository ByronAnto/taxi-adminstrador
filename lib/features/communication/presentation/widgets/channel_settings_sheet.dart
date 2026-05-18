import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/data/models/user_model.dart';
import '../../data/models/channel_model.dart';

/// Bottom-sheet para configurar **miembros y default** de un canal
/// privado.
///
/// Solo admin/operadora pueden abrirlo (long-press en el chip del
/// canal). Permite:
///   - Toggle del tipo (público / privado)
///   - Lista de socios de la asociación con checkbox para añadir/quitar
///     a `memberIds`
///   - Toggles "Default para conductores / operadoras / admin" → escribe
///     `defaultForRoles` en el canal. Cuando un usuario abre Radio, su
///     rol determina cuál canal queda pre-seleccionado.
///
/// Persiste directo en `channels/{id}` con merge.
Future<void> showChannelSettingsSheet(
  BuildContext context, {
  required ChannelModel channel,
  required String aid,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ChannelSettingsSheet(channel: channel, aid: aid),
  );
}

class _ChannelSettingsSheet extends StatefulWidget {
  final ChannelModel channel;
  final String aid;

  const _ChannelSettingsSheet({required this.channel, required this.aid});

  @override
  State<_ChannelSettingsSheet> createState() => _ChannelSettingsSheetState();
}

class _ChannelSettingsSheetState extends State<_ChannelSettingsSheet> {
  late String _type;
  late Set<String> _memberIds;
  late Set<String> _defaultForRoles;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _type = widget.channel.type;
    _memberIds = Set<String>.from(widget.channel.memberIds);
    _defaultForRoles = Set<String>.from(widget.channel.defaultForRoles);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // Forzar refresh del ID token: si el JWT cacheado tiene claims
      // viejos (status/role desactualizado), las reglas Firestore
      // rechazan el write con PERMISSION_DENIED. Pidiendo el token
      // fresco garantizamos que viaje con los claims correctos.
      try {
        await FirebaseAuth.instance.currentUser?.getIdToken(true);
      } catch (_) {}

      await FirebaseFirestore.instance
          .collection('channels')
          .doc(widget.channel.uid)
          .set({
        'type': _type,
        'memberIds': _memberIds.toList(),
        'defaultForRoles': _defaultForRoles.toList(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Configuración del canal guardada'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    } on FirebaseException catch (e) {
      if (!mounted) return;
      final msg = e.code == 'permission-denied'
          ? 'Sin permisos para moderar este canal. Cierra sesión y vuelve a entrar.'
          : 'Error: ${e.message ?? e.code}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppTheme.errorColor),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.settings, color: AppTheme.primaryColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Configurar canal',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        widget.channel.name,
                        style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade700,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                children: [
                  _buildTypeSection(),
                  const SizedBox(height: 20),
                  _buildDefaultsSection(),
                  const SizedBox(height: 20),
                  if (_type == 'privado') _buildMembersSection(),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save),
                    label: Text(_saving ? 'Guardando…' : 'Guardar'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Tipo de canal',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'publico',
              label: Text('Público'),
              icon: Icon(Icons.public),
            ),
            ButtonSegment(
              value: 'privado',
              label: Text('Privado'),
              icon: Icon(Icons.lock),
            ),
          ],
          selected: {_type},
          onSelectionChanged: (s) async {
            final newType = s.first;
            setState(() => _type = newType);
            // Cuando se pasa a privado SIN miembros, se auto-poblan con
            // todos los socios activos del tenant para que nadie quede
            // bloqueado sin querer. El admin puede ajustar abajo.
            if (newType == 'privado' && _memberIds.isEmpty) {
              final snap = await FirebaseFirestore.instance
                  .collection('users')
                  .where('associationId', isEqualTo: widget.aid)
                  .get();
              if (!mounted) return;
              setState(() {
                for (final d in snap.docs) {
                  final status = d.data()['status'] as String?;
                  if (status == 'active' ||
                      status == 'paymentPending' ||
                      status == 'paymentBlocked') {
                    _memberIds.add(d.id);
                  }
                }
              });
            }
          },
        ),
        const SizedBox(height: 4),
        Text(
          _type == 'publico'
              ? 'Todos los socios de la asociación pueden entrar.'
              : 'Solo los miembros que selecciones abajo entran.',
          style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
              fontStyle: FontStyle.italic),
        ),
      ],
    );
  }

  Widget _buildDefaultsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Canal por defecto para…',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
          'Cuando un usuario de este rol entra al Radio, este canal '
          'queda pre-seleccionado. Los demás canales requieren un click '
          'extra para cambiarse.',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
        ),
        const SizedBox(height: 8),
        _roleSwitch('conductor', 'Conductores', Icons.local_taxi),
        _roleSwitch('operadora', 'Operadoras', Icons.headset_mic),
        _roleSwitch('admin', 'Administradores', Icons.shield),
      ],
    );
  }

  Widget _roleSwitch(String role, String label, IconData icon) {
    final on = _defaultForRoles.contains(role);
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      dense: true,
      secondary: Icon(icon, color: AppTheme.primaryColor),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      value: on,
      onChanged: (v) => setState(() {
        if (v) {
          _defaultForRoles.add(role);
        } else {
          _defaultForRoles.remove(role);
        }
      }),
    );
  }

  Widget _buildMembersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Miembros del canal',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
            const Spacer(),
            Text('${_memberIds.length} seleccionados',
                style: TextStyle(
                    fontSize: 11, color: Colors.grey.shade600)),
          ],
        ),
        const SizedBox(height: 8),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .where('associationId', isEqualTo: widget.aid)
              .snapshots(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final users = (snap.data?.docs ?? [])
                .map((d) => UserModel.fromFirestore(d))
                .where((u) => u.status == UserStatus.active ||
                    u.status == UserStatus.paymentPending ||
                    u.status == UserStatus.paymentBlocked)
                .toList()
              ..sort((a, b) {
                final r = _roleOrder(a.role).compareTo(_roleOrder(b.role));
                if (r != 0) return r;
                return a.name.compareTo(b.name);
              });

            if (users.isEmpty) {
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    'Sin socios para mostrar.',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ),
              );
            }

            return Column(
              children: [
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => setState(() {
                        for (final u in users) {
                          _memberIds.add(u.uid);
                        }
                      }),
                      icon: const Icon(Icons.select_all, size: 16),
                      label: const Text('Todos',
                          style: TextStyle(fontSize: 11)),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(() {
                        for (final u in users) {
                          if (u.role == AppConstants.roleOperator ||
                              u.role == AppConstants.roleAdmin) {
                            _memberIds.add(u.uid);
                          } else {
                            _memberIds.remove(u.uid);
                          }
                        }
                      }),
                      icon: const Icon(Icons.headset_mic, size: 16),
                      label: const Text('Solo operadoras + admin',
                          style: TextStyle(fontSize: 11)),
                    ),
                    TextButton.icon(
                      onPressed: () =>
                          setState(() => _memberIds.clear()),
                      icon: const Icon(Icons.clear, size: 16),
                      label: const Text('Ninguno',
                          style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
                ...users.map(_userTile),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _userTile(UserModel u) {
    final on = _memberIds.contains(u.uid);
    final color = switch (u.role) {
      AppConstants.roleAdmin => Colors.red.shade700,
      AppConstants.roleOperator => Colors.purple.shade700,
      _ => AppTheme.primaryColor,
    };
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: on,
      onChanged: (v) => setState(() {
        if (v ?? false) {
          _memberIds.add(u.uid);
        } else {
          _memberIds.remove(u.uid);
        }
      }),
      title: Text('${u.name} ${u.lastname}'.trim(),
          style: const TextStyle(fontSize: 14)),
      subtitle: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _roleLabel(u.role),
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: color),
            ),
          ),
          if (u.numeroVehiculo.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text('Unidad #${u.numeroVehiculo}',
                style: TextStyle(
                    fontSize: 11, color: Colors.grey.shade700)),
          ],
        ],
      ),
    );
  }

  int _roleOrder(String r) {
    switch (r) {
      case AppConstants.roleAdmin:
        return 0;
      case AppConstants.roleOperator:
        return 1;
      default:
        return 2;
    }
  }

  String _roleLabel(String r) {
    switch (r) {
      case AppConstants.roleAdmin:
        return 'ADMIN';
      case AppConstants.roleOperator:
        return 'OPERADORA';
      case AppConstants.roleDriver:
        return 'CONDUCTOR';
      default:
        return r.toUpperCase();
    }
  }
}
