import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/data/models/user_model.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';

/// Pantalla de gestión de socios (admin de asociación y super-admin).
///
/// - El **admin** ve solo a los socios de SU asociación.
/// - El **super-admin** puede pasar `[associationId]` por query param
///   para ver y gestionar cualquier asociación (rescate).
class MembersPage extends StatefulWidget {
  /// Si null, se infiere del [AuthBloc] (caso admin de asociación).
  final String? associationId;

  const MembersPage({super.key, this.associationId});

  @override
  State<MembersPage> createState() => _MembersPageState();
}

enum _StatusFilter { all, pending, active, suspended, rejected }

class _MembersPageState extends State<MembersPage> {
  final _firestore = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instance;
  final _searchController = TextEditingController();

  _StatusFilter _filter = _StatusFilter.all;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String? _resolveAssociationId(BuildContext context) {
    if (widget.associationId != null && widget.associationId!.isNotEmpty) {
      return widget.associationId;
    }
    final authState = context.read<AuthBloc>().state;
    if (authState is AuthAuthenticated) {
      return authState.user.associationId;
    }
    return null;
  }

  bool _isSuperAdmin(BuildContext context) {
    final authState = context.read<AuthBloc>().state;
    if (authState is! AuthAuthenticated) return false;
    return authState.user.email == 'brealpeaymara@gmail.com';
  }

  String? _currentUid(BuildContext context) {
    final authState = context.read<AuthBloc>().state;
    if (authState is AuthAuthenticated) return authState.user.uid;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final aid = _resolveAssociationId(context);

    if (aid == null || aid.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Socios')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No se pudo determinar la asociación. Inicia sesión nuevamente.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Socios'),
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go(_isSuperAdmin(context) ? '/super' : '/home'),
        ),
      ),
      body: Column(
        children: [
          _buildHeader(aid),
          _buildFilters(),
          const Divider(height: 1),
          Expanded(child: _buildList(aid, context)),
        ],
      ),
    );
  }

  Widget _buildHeader(String aid) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 20),
                hintText: 'Buscar nombre, cédula, email...',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.secondaryColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              aid,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return SizedBox(
      height: 50,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: _StatusFilter.values.map((f) {
          final selected = _filter == f;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(_filterLabel(f)),
              selected: selected,
              onSelected: (_) => setState(() => _filter = f),
            ),
          );
        }).toList(),
      ),
    );
  }

  String _filterLabel(_StatusFilter f) {
    switch (f) {
      case _StatusFilter.all:
        return 'Todos';
      case _StatusFilter.pending:
        return 'Pendientes';
      case _StatusFilter.active:
        return 'Activos';
      case _StatusFilter.suspended:
        return 'Suspendidos';
      case _StatusFilter.rejected:
        return 'Rechazados';
    }
  }

  Widget _buildList(String aid, BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('users')
          .where('associationId', isEqualTo: aid)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Error cargando socios: ${snapshot.error}',
                style: const TextStyle(color: Colors.red),
              ),
            ),
          );
        }

        final docs = snapshot.data?.docs ?? [];
        final users = docs.map((d) => UserModel.fromFirestore(d)).toList();

        // Filtros
        final filtered = users.where((u) {
          // Status
          switch (_filter) {
            case _StatusFilter.all:
              break;
            case _StatusFilter.pending:
              if (u.status != UserStatus.pendingApproval) return false;
              break;
            case _StatusFilter.active:
              if (u.status != UserStatus.active) return false;
              break;
            case _StatusFilter.suspended:
              if (u.status != UserStatus.suspended) return false;
              break;
            case _StatusFilter.rejected:
              if (u.status != UserStatus.rejected) return false;
              break;
          }
          // Search
          if (_query.isEmpty) return true;
          final hay =
              '${u.name} ${u.lastname} ${u.cedula} ${u.email}'.toLowerCase();
          return hay.contains(_query);
        }).toList();

        // Ordenar: admin primero, luego pending, luego activos
        filtered.sort((a, b) {
          int rank(UserModel u) {
            if (u.role == AppConstants.roleAdmin) return 0;
            if (u.status == UserStatus.pendingApproval) return 1;
            if (u.role == AppConstants.roleOperator) return 2;
            return 3;
          }
          final r = rank(a).compareTo(rank(b));
          if (r != 0) return r;
          return '${a.name} ${a.lastname}'
              .compareTo('${b.name} ${b.lastname}');
        });

        if (filtered.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _query.isNotEmpty
                    ? 'Sin resultados para "$_query".'
                    : 'No hay socios con ese filtro.',
                style: const TextStyle(color: Colors.black54),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: filtered.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) => _buildMemberTile(filtered[i], aid, context),
        );
      },
    );
  }

  Widget _buildMemberTile(UserModel u, String aid, BuildContext context) {
    final isAdmin = u.role == AppConstants.roleAdmin;
    final isMe = u.uid == _currentUid(context);

    final statusColor = switch (u.status) {
      UserStatus.active => Colors.green,
      UserStatus.pendingApproval => Colors.orange,
      UserStatus.paymentPending => Colors.amber.shade800,
      UserStatus.paymentBlocked => Colors.red.shade900,
      UserStatus.disabledByAdmin => Colors.red.shade900,
      UserStatus.suspended => Colors.red,
      UserStatus.rejected => Colors.grey,
    };

    final statusLabel = switch (u.status) {
      UserStatus.active => 'Activo',
      UserStatus.pendingApproval => 'Pendiente',
      UserStatus.paymentPending => 'Pago pendiente',
      UserStatus.paymentBlocked => 'Bloqueado · pago',
      UserStatus.disabledByAdmin => 'Desactivado',
      UserStatus.suspended => 'Suspendido',
      UserStatus.rejected => 'Rechazado',
    };

    final initials = '${u.name.isNotEmpty ? u.name[0] : ''}'
            '${u.lastname.isNotEmpty ? u.lastname[0] : ''}'
        .toUpperCase();

    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: statusColor.withValues(alpha: 0.15),
            child: Text(
              initials.isEmpty ? '?' : initials,
              style: TextStyle(
                  color: statusColor, fontWeight: FontWeight.bold),
            ),
          ),
          if (isAdmin)
            Positioned(
              bottom: -2,
              right: -2,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Colors.amber,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.shield,
                    size: 12, color: Colors.white),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              '${u.name} ${u.lastname}'.trim().isEmpty
                  ? u.email
                  : '${u.name} ${u.lastname}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (isMe)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Text('(yo)', style: TextStyle(fontSize: 11)),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_roleLabel(u.role)} · $statusLabel · '
            '${u.numeroVehiculo.isNotEmpty ? "Veh ${u.numeroVehiculo}" : u.cedula}',
            style: const TextStyle(fontSize: 12),
          ),
          Text(u.email,
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ],
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        onSelected: (action) => _onMemberAction(action, u, aid),
        itemBuilder: (_) => _menuItemsFor(u, isMe),
      ),
      onTap: () => _showMemberDetail(u, aid),
    );
  }

  Future<void> _showMemberDetail(UserModel u, String aid) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _MemberDetailDialog(
        user: u,
        onAction: (action) {
          Navigator.pop(context);
          _onMemberAction(action, u, aid);
        },
        actions: _menuItemsFor(u, u.uid == _currentUid(context)),
      ),
    );
  }

  String _roleLabel(String role) {
    switch (role) {
      case AppConstants.roleAdmin:
        return 'Admin';
      case AppConstants.roleOperator:
        return 'Operadora';
      case AppConstants.roleDriver:
        return 'Conductor';
      default:
        return role;
    }
  }

  List<PopupMenuEntry<String>> _menuItemsFor(UserModel u, bool isMe) {
    final items = <PopupMenuEntry<String>>[];

    if (u.status == UserStatus.pendingApproval) {
      items.add(const PopupMenuItem(
        value: 'approve',
        child: Row(children: [
          Icon(Icons.check_circle, size: 18, color: Colors.green),
          SizedBox(width: 8),
          Text('Aprobar'),
        ]),
      ));
      items.add(const PopupMenuItem(
        value: 'reject',
        child: Row(children: [
          Icon(Icons.cancel, size: 18, color: Colors.red),
          SizedBox(width: 8),
          Text('Rechazar'),
        ]),
      ));
      items.add(const PopupMenuDivider());
    }

    if (u.status == UserStatus.active && !isMe) {
      items.add(const PopupMenuItem(
        value: 'suspend',
        child: Row(children: [
          Icon(Icons.block, size: 18),
          SizedBox(width: 8),
          Text('Suspender'),
        ]),
      ));
    }

    // Reactivar cubre: suspended (legacy), paymentBlocked (mora) y
    // disabledByAdmin (admin lo desactivó). Vuelve el status a 'active'.
    if (u.status == UserStatus.suspended ||
        u.status == UserStatus.paymentBlocked ||
        u.status == UserStatus.disabledByAdmin ||
        u.status == UserStatus.paymentPending) {
      items.add(const PopupMenuItem(
        value: 'reactivate',
        child: Row(children: [
          Icon(Icons.refresh, size: 18, color: Colors.green),
          SizedBox(width: 8),
          Text('Activar / Reactivar'),
        ]),
      ));
    }

    if (u.status == UserStatus.rejected) {
      items.add(const PopupMenuItem(
        value: 'approve',
        child: Row(children: [
          Icon(Icons.check_circle, size: 18, color: Colors.green),
          SizedBox(width: 8),
          Text('Re-aprobar'),
        ]),
      ));
    }

    if (u.status == UserStatus.active &&
        u.role != AppConstants.roleAdmin &&
        !isMe) {
      items.add(const PopupMenuItem(
        value: 'make_admin',
        child: Row(children: [
          Icon(Icons.shield, size: 18, color: Colors.amber),
          SizedBox(width: 8),
          Text('Hacer administrador'),
        ]),
      ));
    }

    // Editar datos: siempre disponible para cualquier socio
    if (items.isNotEmpty) items.add(const PopupMenuDivider());
    items.add(const PopupMenuItem(
      value: 'edit',
      child: Row(children: [
        Icon(Icons.edit, size: 18),
        SizedBox(width: 8),
        Text('Editar datos'),
      ]),
    ));

    // Eliminar permanente — solo si NO es admin actual y NO soy yo
    if (u.role != AppConstants.roleAdmin && !isMe) {
      items.add(const PopupMenuItem(
        value: 'delete',
        child: Row(children: [
          Icon(Icons.delete_forever, size: 18, color: Colors.red),
          SizedBox(width: 8),
          Text('Eliminar', style: TextStyle(color: Colors.red)),
        ]),
      ));
    }

    return items;
  }

  Future<void> _onMemberAction(
      String action, UserModel u, String aid) async {
    switch (action) {
      case 'approve':
        await _callFn(
          'approveDriver',
          {'driverUid': u.uid},
          successMsg: '${u.name} aprobado.',
        );
        break;
      case 'reject':
        final reason = await _askReason();
        if (reason == null) return;
        await _callFn(
          'rejectDriver',
          {'driverUid': u.uid, 'reason': reason},
          successMsg: '${u.name} rechazado.',
        );
        break;
      case 'suspend':
        await _callFn(
          'setUserStatus',
          {'userUid': u.uid, 'status': 'suspended'},
          successMsg: '${u.name} suspendido.',
        );
        break;
      case 'reactivate':
        await _callFn(
          'setUserStatus',
          {'userUid': u.uid, 'status': 'active'},
          successMsg: '${u.name} reactivado.',
        );
        break;
      case 'make_admin':
        await _confirmTransferAdmin(u);
        break;
      case 'edit':
        await _showEditDialog(u);
        break;
      case 'delete':
        await _confirmDelete(u);
        break;
    }
  }

  /// Doble confirmación de borrado permanente.
  Future<void> _confirmDelete(UserModel u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Eliminar permanentemente?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Vas a borrar la cuenta de ${u.name} ${u.lastname} '
              '(${u.email}).',
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade300),
              ),
              child: const Text(
                'Esta acción NO se puede deshacer:\n'
                '• Se borra el documento del usuario.\n'
                '• Se borra su cuenta de Firebase Auth.\n'
                '• Sus viajes y pagos previos quedan en la base de datos '
                'sin propietario.\n\n'
                'Si solo quieres bloquearlo temporalmente, usa "Suspender" '
                'en su lugar.',
                style: TextStyle(fontSize: 12),
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
    if (ok != true) return;

    await _callFn(
      'deleteUser',
      {'userUid': u.uid},
      successMsg: '${u.name} eliminado permanentemente.',
    );
  }

  Future<void> _showEditDialog(UserModel u) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _EditMemberDialog(
        user: u,
        functions: _functions,
      ),
    );
  }

  Future<String?> _askReason() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Motivo del rechazo'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Opcional, ayuda al usuario a entender el motivo',
          ),
          maxLines: 2,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Rechazar')),
        ],
      ),
    );
    return ok == true ? controller.text.trim() : null;
  }

  Future<void> _confirmTransferAdmin(UserModel u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Hacer administrador?'),
        content: Text(
          '${u.name} ${u.lastname} pasará a ser el administrador de la '
          'asociación.\n\n'
          'El administrador actual quedará como conductor.\n\n'
          'Esta acción se aplica de inmediato.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirmar transferencia'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await _callFn(
      'transferAdmin',
      {'newAdminUid': u.uid},
      successMsg: '${u.name} ahora es el administrador.',
    );
  }

  Future<void> _callFn(
    String name,
    Map<String, dynamic> data, {
    required String successMsg,
  }) async {
    try {
      await _functions.httpsCallable(name).call(data);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(successMsg), backgroundColor: Colors.green),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: ${e.message ?? e.code}'),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

// ─────────────────── Edit Member Dialog ───────────────────

class _EditMemberDialog extends StatefulWidget {
  final UserModel user;
  final FirebaseFunctions functions;

  const _EditMemberDialog({required this.user, required this.functions});

  @override
  State<_EditMemberDialog> createState() => _EditMemberDialogState();
}

class _EditMemberDialogState extends State<_EditMemberDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _lastname;
  late final TextEditingController _cedula;
  late final TextEditingController _phone;
  late final TextEditingController _placa;
  late final TextEditingController _cooperativa;
  late final TextEditingController _codigoCooperativa;
  late final TextEditingController _numeroVehiculo;
  bool _busy = false;

  bool get _isDriver => widget.user.role == 'conductor';

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _name = TextEditingController(text: u.name);
    _lastname = TextEditingController(text: u.lastname);
    _cedula = TextEditingController(text: u.cedula);
    _phone = TextEditingController(text: u.phone);
    _placa = TextEditingController(text: u.placa);
    _cooperativa = TextEditingController(text: u.cooperativa);
    _codigoCooperativa = TextEditingController(text: u.codigoCooperativa);
    _numeroVehiculo = TextEditingController(text: u.numeroVehiculo);
  }

  @override
  void dispose() {
    _name.dispose();
    _lastname.dispose();
    _cedula.dispose();
    _phone.dispose();
    _placa.dispose();
    _cooperativa.dispose();
    _codigoCooperativa.dispose();
    _numeroVehiculo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Editar · ${widget.user.email}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration:
                          const InputDecoration(labelText: 'Nombres'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _lastname,
                      textCapitalization: TextCapitalization.words,
                      decoration:
                          const InputDecoration(labelText: 'Apellidos'),
                    ),
                  ),
                ]),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _cedula,
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'Cédula'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration:
                          const InputDecoration(labelText: 'Teléfono'),
                    ),
                  ),
                ]),
                if (_isDriver) ...[
                  const Divider(height: 32),
                  const Text('Vehículo',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  TextFormField(
                    controller: _cooperativa,
                    textCapitalization: TextCapitalization.words,
                    decoration:
                        const InputDecoration(labelText: 'Cooperativa'),
                  ),
                  TextFormField(
                    controller: _codigoCooperativa,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                        labelText: 'Código de cooperativa'),
                  ),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _placa,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                            labelText: 'Placa'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: _numeroVehiculo,
                        decoration: const InputDecoration(
                            labelText: 'N° Vehículo'),
                      ),
                    ),
                  ]),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Email, rol y status no se editan aquí. '
                  'Para cambiar el rol usa "Hacer administrador". '
                  'Para suspender/reactivar usa el menú principal.',
                  style: TextStyle(fontSize: 11, color: Colors.black54),
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
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Guardar'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final fields = <String, dynamic>{
        'name': _name.text.trim(),
        'lastname': _lastname.text.trim(),
        'cedula': _cedula.text.trim(),
        'phone': _phone.text.trim(),
      };
      if (_isDriver) {
        fields.addAll({
          'placa': _placa.text.trim().toUpperCase(),
          'cooperativa': _cooperativa.text.trim(),
          'codigoCooperativa': _codigoCooperativa.text.trim(),
          'numeroVehiculo': _numeroVehiculo.text.trim(),
        });
      }

      await widget.functions.httpsCallable('updateUser').call({
        'userUid': widget.user.uid,
        'fields': fields,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Datos actualizados.'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: ${e.message ?? e.code}'),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ─────────────────── Member Detail Dialog ───────────────────

class _MemberDetailDialog extends StatelessWidget {
  final UserModel user;
  final List<PopupMenuEntry<String>> actions;
  final void Function(String action) onAction;

  const _MemberDetailDialog({
    required this.user,
    required this.actions,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (user.status) {
      UserStatus.active => Colors.green,
      UserStatus.pendingApproval => Colors.orange,
      UserStatus.paymentPending => Colors.amber.shade800,
      UserStatus.paymentBlocked => Colors.red.shade900,
      UserStatus.disabledByAdmin => Colors.red.shade900,
      UserStatus.suspended => Colors.red,
      UserStatus.rejected => Colors.grey,
    };
    final statusLabel = switch (user.status) {
      UserStatus.active => 'Activo',
      UserStatus.pendingApproval => 'Pendiente',
      UserStatus.paymentPending => 'Pago pendiente',
      UserStatus.paymentBlocked => 'Bloqueado · pago',
      UserStatus.disabledByAdmin => 'Desactivado',
      UserStatus.suspended => 'Suspendido',
      UserStatus.rejected => 'Rechazado',
    };
    final initials = '${user.name.isNotEmpty ? user.name[0] : ''}'
            '${user.lastname.isNotEmpty ? user.lastname[0] : ''}'
        .toUpperCase();
    final isDriver = user.role == AppConstants.roleDriver;
    final isAdmin = user.role == AppConstants.roleAdmin;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              color: AppTheme.primaryColor,
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: Colors.white24,
                    child: Text(
                      initials.isEmpty ? '?' : initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${user.name} ${user.lastname}'.trim().isEmpty
                              ? user.email
                              : '${user.name} ${user.lastname}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${_roleLabel(user.role)} · $statusLabel',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Body
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (isAdmin)
                    Container(
                      padding: const EdgeInsets.all(8),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.amber.shade200),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.shield,
                              size: 18, color: Colors.amber),
                          const SizedBox(width: 8),
                          const Text(
                            'Administrador actual de la asociación',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  _section('Datos personales'),
                  _info('Email', user.email),
                  _info('Cédula', user.cedula.isEmpty ? '—' : user.cedula),
                  _info('Teléfono', user.phone.isEmpty ? '—' : user.phone),
                  if (isDriver || isAdmin) ...[
                    const SizedBox(height: 12),
                    _section('Vehículo'),
                    _info('Cooperativa',
                        user.cooperativa.isEmpty ? '—' : user.cooperativa),
                    _info('Cód. cooperativa',
                        user.codigoCooperativa.isEmpty
                            ? '—'
                            : user.codigoCooperativa),
                    _info('Placa', user.placa.isEmpty ? '—' : user.placa),
                    _info('N° vehículo',
                        user.numeroVehiculo.isEmpty
                            ? '—'
                            : user.numeroVehiculo),
                  ],
                  if (isDriver || isAdmin) ...[
                    const SizedBox(height: 12),
                    _section('Documentos'),
                    _photosRow(context, user),
                  ],
                  // TODO: mostrar motivo de rechazo cuando UserModel
                  // exponga el campo rejectionReason.
                ],
              ),
            ),
            // Acciones (mismo menú del tile)
            if (actions.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Color(0xFFE0E0E0)),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    PopupMenuButton<String>(
                      onSelected: onAction,
                      itemBuilder: (_) => actions,
                      child: ElevatedButton.icon(
                        onPressed: null,
                        icon: const Icon(Icons.more_vert, size: 18),
                        label: const Text('Acciones'),
                        style: ElevatedButton.styleFrom(
                          disabledBackgroundColor:
                              AppTheme.primaryColor,
                          disabledForegroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _roleLabel(String role) {
    switch (role) {
      case AppConstants.roleAdmin:
        return 'Admin';
      case AppConstants.roleOperator:
        return 'Operadora';
      case AppConstants.roleDriver:
        return 'Conductor';
      default:
        return role;
    }
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 13,
          color: AppTheme.primaryColor,
        ),
      ),
    );
  }

  Widget _info(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                  color: Colors.black54, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  Widget _photosRow(BuildContext context, UserModel u) {
    final photos = <_PhotoEntry>[
      _PhotoEntry('Vehículo', u.fotoVehiculo, Icons.directions_car),
      _PhotoEntry('Lic. frontal', u.fotoLicenciaFrontal, Icons.credit_card),
      _PhotoEntry('Lic. trasera', u.fotoLicenciaTrasera, Icons.credit_card),
    ];
    return Row(
      children: photos
          .map((p) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _photoCard(context, p),
                ),
              ))
          .toList(),
    );
  }

  Widget _photoCard(BuildContext context, _PhotoEntry p) {
    final hasPhoto = p.url != null && p.url!.isNotEmpty;
    return InkWell(
      onTap: hasPhoto
          ? () => _openFullScreen(context, p.url!, p.label)
          : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 110,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: hasPhoto ? null : Colors.grey.shade100,
          border: Border.all(
            color: hasPhoto ? Colors.green : Colors.grey.shade300,
            width: hasPhoto ? 2 : 1,
          ),
          image: hasPhoto
              ? DecorationImage(
                  image: NetworkImage(p.url!), fit: BoxFit.cover)
              : null,
        ),
        child: !hasPhoto
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(p.icon, color: Colors.grey, size: 28),
                  const SizedBox(height: 4),
                  Text(
                    'Sin foto',
                    style: TextStyle(
                        fontSize: 10, color: Colors.grey.shade600),
                  ),
                ],
              )
            : Stack(
                children: [
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      color: Colors.black54,
                      child: Text(
                        p.label,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  void _openFullScreen(BuildContext context, String url, String label) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image,
                        color: Colors.white, size: 48),
                  ),
                  loadingBuilder: (_, child, progress) {
                    if (progress == null) return child;
                    return const Center(
                      child:
                          CircularProgressIndicator(color: Colors.white),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 40,
              left: 16,
              child: Text(
                label,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            Positioned(
              top: 32,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoEntry {
  final String label;
  final String? url;
  final IconData icon;
  _PhotoEntry(this.label, this.url, this.icon);
}
