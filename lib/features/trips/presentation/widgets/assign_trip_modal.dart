import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/stand_queue_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/trip_model.dart';
import '../bloc/trip_bloc.dart';

/// Modal para que la operadora asigne una carrera a un conductor.
///
/// Se abre desde el walkie-talkie con `showAssignTripModal(context)`.
/// Filtra conductores online de la misma asociación, permite elegir uno y
/// capturar datos mínimos del cliente. Crea el doc en `trips/{}` con
/// `source = apkOperadora`, `status = asignado`.
///
/// También incrementa una métrica diaria en
/// `operadora_metrics/{operadoraId}_{yyyy-mm-dd}` con un contador de
/// carreras asignadas (atómico).
class AssignTripModal extends StatefulWidget {
  const AssignTripModal({super.key});

  @override
  State<AssignTripModal> createState() => _AssignTripModalState();
}

class _AssignTripModalState extends State<AssignTripModal> {
  final _formKey = GlobalKey<FormState>();
  final _clientNameController = TextEditingController();
  final _clientPhoneController = TextEditingController();
  final _pickupAddressController = TextEditingController();
  final _notesController = TextEditingController();

  String? _selectedDriverDocId;
  String? _selectedDriverUserId;
  String? _selectedDriverName;
  bool _submitting = false;

  @override
  void dispose() {
    _clientNameController.dispose();
    _clientPhoneController.dispose();
    _pickupAddressController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Stream de conductores online (status != desconectado) de la asociación.
  Stream<QuerySnapshot<Map<String, dynamic>>> _onlineDriversStream(
      String associationId) {
    return FirebaseFirestore.instance
        .collection(AppConstants.driversCollection)
        .where('associationId', isEqualTo: associationId)
        .where('status', whereNotIn: [AppConstants.statusOffline]).snapshots();
  }

  Future<void> _submit({
    required String operatorId,
    required String operatorName,
    required String associationId,
  }) async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedDriverUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selecciona un conductor'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _submitting = true);
    HapticFeedback.mediumImpact();

    final now = DateTime.now();
    final trip = TripModel(
      uid: const Uuid().v4(),
      associationId: associationId,
      driverId: _selectedDriverUserId!,
      driverName: _selectedDriverName,
      operatorId: operatorId,
      operatorName: operatorName,
      clienteNombre: _clientNameController.text.trim().isEmpty
          ? null
          : _clientNameController.text.trim(),
      clienteTelefono: _clientPhoneController.text.trim().isEmpty
          ? null
          : _clientPhoneController.text.trim(),
      pickupLatitude: 0.0,
      pickupLongitude: 0.0,
      pickupAddress: _pickupAddressController.text.trim(),
      status: TripStatus.asignado,
      source: TripSource.apkOperadora,
      startTime: now,
      notes:
          _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
      createdAt: now,
    );

    // Crear el viaje vía bloc.
    if (mounted) context.read<TripBloc>().add(TripCreateRequested(trip));

    // Si el conductor estaba en la cola de la parada, sacarlo (ya tiene
    // cliente asignado, no debe seguir esperando).
    if (_selectedDriverDocId != null) {
      try {
        await StandQueueService.instance.leaveQueue(_selectedDriverDocId!);
      } catch (_) {}
    }

    // Incrementar métrica diaria de la operadora (best-effort).
    try {
      final dateKey =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final metricRef = FirebaseFirestore.instance
          .collection('operadora_metrics')
          .doc('${operatorId}_$dateKey');
      await metricRef.set({
        'associationId': associationId,
        'operatorId': operatorId,
        'operatorName': operatorName,
        'date': dateKey,
        'tripsAssigned': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('AssignTripModal: error métrica $e');
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Carrera asignada a ${_selectedDriverName ?? "conductor"}',
        ),
        backgroundColor: AppTheme.successColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) {
      return const SizedBox.shrink();
    }
    final operator_ = auth.user;
    final aid = operator_.associationId;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Icon(Icons.assignment_ind, color: AppTheme.primaryColor),
                    const SizedBox(width: 8),
                    const Text(
                      'Asignar carrera',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildDriverDropdown(aid),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _pickupAddressController,
                  decoration: const InputDecoration(
                    labelText: 'Dirección de recogida *',
                    prefixIcon: Icon(Icons.location_on),
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.next,
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Requerido' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _clientNameController,
                  decoration: const InputDecoration(
                    labelText: 'Nombre del cliente',
                    prefixIcon: Icon(Icons.person),
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _clientPhoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Teléfono del cliente',
                    prefixIcon: Icon(Icons.phone),
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notesController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Notas (opcional)',
                    prefixIcon: Icon(Icons.notes),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _submitting
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('Cancelar'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: _submitting
                            ? null
                            : () => _submit(
                                  operatorId: operator_.uid,
                                  operatorName:
                                      '${operator_.name} ${operator_.lastname}'
                                          .trim(),
                                  associationId: aid,
                                ),
                        icon: _submitting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.check),
                        label: Text(_submitting ? 'Asignando...' : 'Asignar'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDriverDropdown(String associationId) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _onlineDriversStream(associationId),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const LinearProgressIndicator();
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orange.shade800),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'No hay conductores en línea ahora mismo.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          );
        }

        return DropdownButtonFormField<String>(
          initialValue: _selectedDriverDocId,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Conductor *',
            prefixIcon: Icon(Icons.directions_car),
            border: OutlineInputBorder(),
          ),
          validator: (v) =>
              (v == null || v.isEmpty) ? 'Selecciona un conductor' : null,
          items: docs.map((d) {
            final data = d.data();
            final name = (data['driverName'] as String?) ?? 'Conductor';
            final num_ = (data['vehicleNumber'] as String?) ?? '';
            final status = (data['status'] as String?) ?? '';
            final label =
                '${num_.isNotEmpty ? '#$num_ · ' : ''}$name · $status';
            return DropdownMenuItem<String>(
              value: d.id,
              child: Text(label, overflow: TextOverflow.ellipsis),
            );
          }).toList(),
          onChanged: (v) {
            if (v == null) return;
            final doc = docs.firstWhere((d) => d.id == v);
            final data = doc.data();
            setState(() {
              _selectedDriverDocId = v;
              _selectedDriverUserId = data['userId'] as String?;
              _selectedDriverName = data['driverName'] as String?;
            });
          },
        );
      },
    );
  }
}

/// Helper para abrir el modal desde cualquier pantalla.
Future<bool?> showAssignTripModal(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const AssignTripModal(),
  );
}
