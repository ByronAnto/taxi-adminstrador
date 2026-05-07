import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../trips/data/models/trip_model.dart';

/// Panel de solicitudes de carrera (tripRequests).
///
/// Visible solo para operadora/admin. Las solicitudes pueden venir del
/// futuro portal web del cliente (Fase 6) o del propio admin manualmente
/// (por ahora). Aquí la operadora las ve, asigna a un conductor online y
/// las marca como asignadas (creando el doc en `trips/`).
class TripRequestsPage extends StatelessWidget {
  const TripRequestsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }
    final user = auth.user;
    final aid = user.associationId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Solicitudes de carrera'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreate(context, aid),
        icon: const Icon(Icons.add),
        label: const Text('Nueva'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('tripRequests')
            .where('associationId', isEqualTo: aid)
            .where('estado', whereIn: ['pendiente', 'asignada'])
            .orderBy('cuandoSolicitado', descending: true)
            .limit(50)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(child: Text('Sin solicitudes pendientes'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (_, i) {
              final r = docs[i].data();
              final estado = r['estado'] ?? 'pendiente';
              final cuando =
                  (r['cuandoSolicitado'] as Timestamp?)?.toDate() ??
                      DateTime.now();
              final paraCuando = (r['paraCuando'] as Timestamp?)?.toDate();
              final origen = r['origen'] as Map<String, dynamic>?;
              final destino = r['destino'] as Map<String, dynamic>?;
              return Card(
                child: ListTile(
                  leading: Icon(
                    estado == 'asignada'
                        ? Icons.check_circle
                        : Icons.schedule,
                    color: estado == 'asignada'
                        ? AppTheme.successColor
                        : Colors.orange,
                  ),
                  title: Text(r['clienteNombre'] ?? 'Cliente sin nombre'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if ((r['clienteTelefono'] ?? '').toString().isNotEmpty)
                        Text('📞 ${r['clienteTelefono']}'),
                      Text('📍 ${origen?['address'] ?? '(sin origen)'}'),
                      if (destino != null && destino['address'] != null)
                        Text('🏁 ${destino['address']}'),
                      const SizedBox(height: 4),
                      Text(
                        'Solicitada: ${DateFormat('dd MMM HH:mm').format(cuando)}'
                        '${paraCuando != null && paraCuando.isAfter(DateTime.now()) ? ' · Para: ${DateFormat('dd MMM HH:mm').format(paraCuando)}' : ''}',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                  trailing: estado == 'pendiente'
                      ? FilledButton.tonal(
                          onPressed: () => _assignRequest(
                              context, docs[i].reference, r, user.uid,
                              '${user.name} ${user.lastname}'.trim(), aid),
                          child: const Text('Asignar'),
                        )
                      : Text(estado),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _assignRequest(
    BuildContext context,
    DocumentReference<Map<String, dynamic>> reqRef,
    Map<String, dynamic> reqData,
    String operatorId,
    String operatorName,
    String aid,
  ) async {
    // Reusa el modal de asignación: aquí mostramos un dropdown simple de
    // conductores online y al confirmar creamos trip + actualizamos el req.
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _AssignFromRequestSheet(aid: aid, requestData: reqData),
    );
    if (selected == null) return;
    if (!context.mounted) return;

    // selected viene como "driverDocId|userId|driverName"
    final parts = selected.split('|');
    if (parts.length != 3) return;
    final driverUserId = parts[1];
    final driverName = parts[2];

    final now = DateTime.now();
    final tripId = const Uuid().v4();
    final origen = reqData['origen'] as Map<String, dynamic>?;
    final destino = reqData['destino'] as Map<String, dynamic>?;

    final trip = TripModel(
      uid: tripId,
      associationId: aid,
      driverId: driverUserId,
      driverName: driverName,
      operatorId: operatorId,
      operatorName: operatorName,
      clienteNombre: reqData['clienteNombre'],
      clienteTelefono: reqData['clienteTelefono'],
      pickupLatitude: (origen?['lat'] ?? 0.0).toDouble(),
      pickupLongitude: (origen?['lng'] ?? 0.0).toDouble(),
      pickupAddress: origen?['address'] ?? '',
      dropoffLatitude: destino != null ? (destino['lat'] ?? 0.0).toDouble() : null,
      dropoffLongitude:
          destino != null ? (destino['lng'] ?? 0.0).toDouble() : null,
      dropoffAddress: destino?['address'],
      status: TripStatus.asignado,
      source: TripSource.webCliente,
      startTime: now,
      notes: reqData['notas'],
      createdAt: now,
    );

    final messenger = ScaffoldMessenger.of(context);
    try {
      // Atomicidad básica: 2 writes secuenciales (no batch porque trip y
      // tripRequest son colecciones distintas; con reglas amplias para
      // operadora, esto es suficiente para nuestro tamaño).
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(tripId)
          .set(trip.toFirestore());
      await reqRef.update({
        'estado': 'asignada',
        'asignadoA': driverUserId,
        'asignadoTripId': tripId,
        'asignadoAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text('Carrera asignada a $driverName'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  void _showCreate(BuildContext context, String aid) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CreateRequestForm(aid: aid),
    );
  }
}

class _AssignFromRequestSheet extends StatelessWidget {
  final String aid;
  final Map<String, dynamic> requestData;
  const _AssignFromRequestSheet(
      {required this.aid, required this.requestData});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Selecciona un conductor en línea',
              style:
                  TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection(AppConstants.driversCollection)
                .where('associationId', isEqualTo: aid)
                .where('status',
                    whereNotIn: [AppConstants.statusOffline]).snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const LinearProgressIndicator();
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No hay conductores en línea ahora.'),
                );
              }
              return ListView.builder(
                shrinkWrap: true,
                itemCount: docs.length,
                itemBuilder: (_, i) {
                  final d = docs[i].data();
                  final name = d['driverName'] ?? 'Conductor';
                  final num_ = d['vehicleNumber'] ?? '';
                  final status = d['status'] ?? '';
                  final userId = d['userId'] ?? '';
                  return ListTile(
                    leading: const Icon(Icons.directions_car),
                    title: Text(num_.isNotEmpty ? '#$num_ · $name' : name),
                    subtitle: Text(status),
                    onTap: () {
                      Navigator.of(context).pop('${docs[i].id}|$userId|$name');
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CreateRequestForm extends StatefulWidget {
  final String aid;
  const _CreateRequestForm({required this.aid});

  @override
  State<_CreateRequestForm> createState() => _CreateRequestFormState();
}

class _CreateRequestFormState extends State<_CreateRequestForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _destAddress = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _destAddress.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final id = const Uuid().v4();
      await FirebaseFirestore.instance
          .collection('tripRequests')
          .doc(id)
          .set({
        'associationId': widget.aid,
        'clienteNombre': _name.text.trim(),
        'clienteTelefono': _phone.text.trim(),
        'origen': {
          'lat': 0.0,
          'lng': 0.0,
          'address': _address.text.trim(),
        },
        'destino': _destAddress.text.trim().isEmpty
            ? null
            : {
                'lat': 0.0,
                'lng': 0.0,
                'address': _destAddress.text.trim(),
              },
        'cuandoSolicitado': FieldValue.serverTimestamp(),
        'paraCuando': FieldValue.serverTimestamp(),
        'estado': 'pendiente',
        'notas':
            _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
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
              const Text('Nueva solicitud',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Cliente *',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Requerido' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Teléfono',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _address,
                decoration: const InputDecoration(
                  labelText: 'Dirección de recogida *',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Requerido' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _destAddress,
                decoration: const InputDecoration(
                  labelText: 'Destino (opcional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notes,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notas',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Guardando…' : 'Crear solicitud'),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
