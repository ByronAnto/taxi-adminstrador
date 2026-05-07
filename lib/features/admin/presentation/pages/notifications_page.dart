import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';

/// Pantalla de notificaciones del admin.
///
/// - Admin: ve la lista + crea nuevas (inmediatas o programadas).
/// - Conductores/Operadoras: solo ven la lista filtrada por su audiencia.
///
/// Las inmediatas las despacha el cron `dispatchScheduledNotifications`
/// (cada 5 min) si tienen `scheduledAt <= now`. Si quieres dispatch
/// instantáneo el admin puede setear scheduledAt = now al crearla.
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }
    final user = auth.user;
    final isAdmin = user.role == AppConstants.roleAdmin;
    final aid = user.associationId;

    return Scaffold(
      appBar: AppBar(title: const Text('Notificaciones')),
      floatingActionButton: isAdmin
          ? FloatingActionButton.extended(
              onPressed: () => _showCreate(context, aid, user.uid),
              icon: const Icon(Icons.add),
              label: const Text('Nueva'),
            )
          : null,
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('notifications')
            .where('associationId', isEqualTo: aid)
            .orderBy('createdAt', descending: true)
            .limit(50)
            .snapshots(),
        builder: (context, snap) {
          final docs = snap.data?.docs ?? [];
          // Filtrar por audiencia para no-admins
          final visible = docs.where((d) {
            if (isAdmin) return true;
            final aud = (d.data()['audience'] as String?) ?? 'all';
            if (aud == 'all') return true;
            if (aud == 'drivers' && user.role == AppConstants.roleDriver) {
              return true;
            }
            if (aud == 'operadoras' &&
                user.role == AppConstants.roleOperator) {
              return true;
            }
            return false;
          }).toList();

          if (visible.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_off,
                      size: 64, color: Colors.grey[300]),
                  const SizedBox(height: 16),
                  Text('Sin notificaciones',
                      style:
                          TextStyle(color: Colors.grey[600], fontSize: 15)),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (_, i) {
              final n = visible[i].data();
              final created =
                  (n['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
              final status = n['status'] ?? 'scheduled';
              final aud = n['audience'] ?? 'all';
              return Card(
                child: ListTile(
                  leading: _statusIcon(status),
                  title: Text(n['title'] ?? '(sin título)'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if ((n['body'] ?? '').toString().isNotEmpty)
                        Text(n['body']),
                      const SizedBox(height: 4),
                      Text(
                        '${_audLabel(aud)} · ${DateFormat('dd MMM HH:mm').format(created)} · $status',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                  trailing: isAdmin
                      ? IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => visible[i].reference.delete(),
                        )
                      : null,
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _statusIcon(String status) {
    switch (status) {
      case 'dispatched':
        return Icon(Icons.check_circle, color: AppTheme.successColor);
      case 'failed':
        return Icon(Icons.error, color: AppTheme.errorColor);
      case 'scheduled':
      default:
        return const Icon(Icons.schedule);
    }
  }

  String _audLabel(String aud) {
    switch (aud) {
      case 'drivers':
        return 'Conductores';
      case 'operadoras':
        return 'Operadoras';
      case 'all':
      default:
        return 'Todos';
    }
  }

  void _showCreate(BuildContext context, String aid, String adminUid) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CreateNotificationForm(aid: aid, adminUid: adminUid),
    );
  }
}

class _CreateNotificationForm extends StatefulWidget {
  final String aid;
  final String adminUid;
  const _CreateNotificationForm({required this.aid, required this.adminUid});

  @override
  State<_CreateNotificationForm> createState() =>
      _CreateNotificationFormState();
}

class _CreateNotificationFormState extends State<_CreateNotificationForm> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _audience = 'all';
  bool _scheduled = false;
  DateTime _scheduledAt = DateTime.now().add(const Duration(hours: 1));
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final now = DateTime.now();
    final scheduleAt = _scheduled ? _scheduledAt : now;
    try {
      final id = const Uuid().v4();
      await FirebaseFirestore.instance.collection('notifications').doc(id).set({
        'associationId': widget.aid,
        'title': _title.text.trim(),
        'body': _body.text.trim(),
        'audience': _audience,
        'scheduledAt': Timestamp.fromDate(scheduleAt),
        'status': 'scheduled',
        'createdBy': widget.adminUid,
        'createdAt': Timestamp.fromDate(now),
      });
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notificación creada')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.errorColor,
        ));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Nueva notificación',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextFormField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Título *',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Requerido' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _body,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Mensaje',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _audience,
                decoration: const InputDecoration(
                  labelText: 'Audiencia',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('Todos')),
                  DropdownMenuItem(
                      value: 'drivers', child: Text('Solo conductores')),
                  DropdownMenuItem(
                      value: 'operadoras', child: Text('Solo operadoras')),
                ],
                onChanged: (v) => setState(() => _audience = v ?? 'all'),
              ),
              const SizedBox(height: 12),
              SwitchListTile.adaptive(
                title: const Text('Programar para más tarde'),
                value: _scheduled,
                onChanged: (v) => setState(() => _scheduled = v),
              ),
              if (_scheduled)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: Text(DateFormat('dd MMM yyyy · HH:mm')
                      .format(_scheduledAt)),
                  trailing: const Icon(Icons.edit),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _scheduledAt,
                      firstDate: DateTime.now(),
                      lastDate:
                          DateTime.now().add(const Duration(days: 365)),
                    );
                    if (d == null || !mounted) return;
                    if (!context.mounted) return;
                    final t = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(_scheduledAt),
                    );
                    if (t == null) return;
                    setState(() {
                      _scheduledAt =
                          DateTime(d.year, d.month, d.day, t.hour, t.minute);
                    });
                  },
                ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child:
                            CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                label: Text(_saving ? 'Guardando...' : 'Crear'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
