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

/// Modal de "Carrera rápida en la calle".
///
/// Use case (Byron): la operadora está en la calle, le ofrece el servicio a
/// un cliente y lo manda con una unidad del grupo. Solo se necesita:
///   - elegir el # de unidad (1 tap)
///   - opcionalmente el código del cliente (otro tap, escribirlo)
/// Resultado: registro contable en `trips` con `source = TripSource.street`
/// para luego saber cuántas se asignaron por unidad y operadora.
///
/// Diseñado para ser ultra rápido: grid de chips grandes con # de unidad.
class QuickStreetAssignModal extends StatefulWidget {
  const QuickStreetAssignModal({super.key});

  @override
  State<QuickStreetAssignModal> createState() => _QuickStreetAssignModalState();
}

class _QuickStreetAssignModalState extends State<QuickStreetAssignModal> {
  final _clientCodeCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _clientCodeCtrl.dispose();
    super.dispose();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _onlineDriversStream(
      String aid) {
    return FirebaseFirestore.instance
        .collection(AppConstants.driversCollection)
        .where('associationId', isEqualTo: aid)
        .where('status', whereNotIn: [AppConstants.statusOffline]).snapshots();
  }

  Future<void> _assign({
    required String associationId,
    required String operatorId,
    required String operatorName,
    required String driverDocId,
    required String driverUserId,
    required String driverName,
    required String vehicleNumber,
  }) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    HapticFeedback.mediumImpact();

    final now = DateTime.now();
    final trip = TripModel(
      uid: const Uuid().v4(),
      associationId: associationId,
      driverId: driverUserId,
      driverName: driverName,
      operatorId: operatorId,
      operatorName: operatorName,
      clienteNombre: _clientCodeCtrl.text.trim().isEmpty
          ? null
          : 'Cliente ${_clientCodeCtrl.text.trim()}',
      pickupLatitude: 0,
      pickupLongitude: 0,
      pickupAddress: 'Recogida en calle',
      status: TripStatus.finalizado,
      source: TripSource.street,
      startTime: now,
      endTime: now,
      createdAt: now,
    );

    final messenger = ScaffoldMessenger.of(context);
    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(trip.uid)
          .set(trip.toFirestore());

      // Si el conductor estaba en la cola, sacarlo (ya tiene cliente).
      try {
        await StandQueueService.instance.leaveQueue(driverDocId);
      } catch (_) {}

      // Métricas: 1 contador "calle" por operadora, 1 por unidad.
      final dateKey =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      try {
        await FirebaseFirestore.instance
            .collection('operadora_metrics')
            .doc('${operatorId}_$dateKey')
            .set({
          'associationId': associationId,
          'operatorId': operatorId,
          'operatorName': operatorName,
          'date': dateKey,
          'streetAssigned': FieldValue.increment(1),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}

      if (!mounted) return;
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            vehicleNumber.isNotEmpty
                ? 'Carrera asignada a Unidad #$vehicleNumber'
                : 'Carrera asignada a $driverName',
          ),
          backgroundColor: AppTheme.successColor,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text('Error: $e'), backgroundColor: AppTheme.errorColor));
      setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return const SizedBox.shrink();
    final user = auth.user;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
                Icon(Icons.bolt, color: AppTheme.primaryColor, size: 28),
                const SizedBox(width: 8),
                const Text(
                  'Carrera rápida en la calle',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Toca el número de unidad para asignar.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 12),
            // Campo opcional para # cliente
            TextField(
              controller: _clientCodeCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '# cliente (opcional)',
                hintText: 'ej. 1059',
                border: OutlineInputBorder(),
                isDense: true,
                prefixIcon: Icon(Icons.tag, size: 20),
              ),
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            // Grid de unidades online
            Flexible(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _onlineDriversStream(user.associationId),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final docs = snap.data?.docs ?? [];
                  if (docs.isEmpty) {
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.orange.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline,
                              color: Colors.orange.shade800),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'No hay unidades en línea ahora.',
                              style: TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  // Ordenar por # de vehículo
                  final sorted = [...docs]..sort((a, b) {
                      final na =
                          int.tryParse(a.data()['vehicleNumber'] ?? '0') ?? 0;
                      final nb =
                          int.tryParse(b.data()['vehicleNumber'] ?? '0') ?? 0;
                      return na.compareTo(nb);
                    });
                  return GridView.builder(
                    shrinkWrap: true,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 1,
                    ),
                    itemCount: sorted.length,
                    itemBuilder: (_, i) {
                      final doc = sorted[i];
                      final d = doc.data();
                      final num_ = (d['vehicleNumber'] as String?) ?? '';
                      final userId = (d['userId'] as String?) ?? '';
                      final name = (d['driverName'] as String?) ?? '';
                      final status = (d['status'] as String?) ?? '';
                      final isFree = status == AppConstants.statusFree;
                      return _UnitChip(
                        number: num_,
                        statusColor: isFree
                            ? AppTheme.successColor
                            : Colors.orange.shade700,
                        enabled: !_submitting,
                        onTap: () => _assign(
                          associationId: user.associationId,
                          operatorId: user.uid,
                          operatorName:
                              '${user.name} ${user.lastname}'.trim(),
                          driverDocId: doc.id,
                          driverUserId: userId,
                          driverName: name,
                          vehicleNumber: num_,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnitChip extends StatelessWidget {
  final String number;
  final Color statusColor;
  final bool enabled;
  final VoidCallback onTap;
  const _UnitChip({
    required this.number,
    required this.statusColor,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled ? statusColor : Colors.grey,
      borderRadius: BorderRadius.circular(12),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: Container(
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.directions_car,
                  color: Colors.white, size: 18),
              const SizedBox(height: 4),
              Text(
                number.isEmpty ? '?' : '#$number',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Helper para abrir el modal desde cualquier pantalla.
Future<bool?> showQuickStreetAssignModal(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => Padding(
      padding: const EdgeInsets.only(top: 60),
      child: const QuickStreetAssignModal(),
    ),
  );
}
