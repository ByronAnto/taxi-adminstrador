import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/driver_location_service.dart';
import '../../../../core/services/stand_queue_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../trips/data/models/trip_model.dart';

/// Barra horizontal con la **cola de unidades cerca de la parada**.
///
/// - **Operadora/Admin**: ve los chips en orden de llegada
///   (#24 → #32 → #33 → ...). Tap en un chip = asignar cliente a esa
///   unidad (1 toque, idéntico al QuickStreet pero pre-seleccionado).
/// - **Conductor**: ve botón "Entrar a parada" / "Salir" según su estado
///   actual. Al entrar, su unidad se agrega al final de la cola.
///
/// Re-renderiza cada minuto para actualizar el "tiempo de espera".
class StandQueueBar extends StatefulWidget {
  const StandQueueBar({super.key});

  @override
  State<StandQueueBar> createState() => _StandQueueBarState();
}

class _StandQueueBarState extends State<StandQueueBar> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Re-render cada 30s para refrescar etiqueta de tiempo de espera.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return const SizedBox.shrink();
    final user = auth.user;
    final aid = user.associationId;

    return StreamBuilder<List<QueuedUnit>>(
      stream: StandQueueService.instance.watchQueue(aid),
      builder: (context, snap) {
        final queue = snap.data ?? const [];
        final isDriver = user.role == AppConstants.roleDriver;
        final isOperator = user.role == AppConstants.roleOperator ||
            user.role == AppConstants.roleAdmin;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: BoxDecoration(
            color: Colors.amber.shade50,
            border: Border(
              top: BorderSide(color: Colors.amber.shade200, width: 1),
              bottom: BorderSide(color: Colors.amber.shade200, width: 1),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.local_taxi,
                      size: 18, color: Colors.amber.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      isOperator
                          ? 'Cola de la parada (${queue.length})'
                          : 'En la parada (${queue.length})',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.amber.shade900,
                      ),
                    ),
                  ),
                  if (isDriver) _DriverQueueButton(queue: queue),
                  if (isOperator)
                    TextButton.icon(
                      onPressed: () => _showOperatorAddToQueue(context, aid),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Agregar',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w700)),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.primaryColor,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 56,
                child: queue.isEmpty
                    ? Center(
                        child: Text(
                          isDriver
                              ? 'Aún no hay unidades. Toca "Entrar a parada" cuando llegues.'
                              : 'Aún no hay unidades en la cola.',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                              fontStyle: FontStyle.italic),
                        ),
                      )
                    : ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: queue.length,
                        itemBuilder: (_, i) {
                          final unit = queue[i];
                          final isMyUnit = unit.userId == user.uid;
                          return Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            child: _UnitQueueChip(
                              order: i + 1,
                              unit: unit,
                              isMine: isMyUnit,
                              isOperator: isOperator,
                              onTap: isOperator
                                  ? () => _assignToUnit(context, user, unit)
                                  : null,
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Modal para que la operadora agregue MANUALMENTE una unidad a la cola.
  /// Útil cuando el conductor está online pero no tap "Entrar a parada"
  /// en su propia app.
  Future<void> _showOperatorAddToQueue(
      BuildContext context, String aid) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return Container(
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
                  Icon(Icons.local_taxi, color: AppTheme.primaryColor),
                  const SizedBox(width: 8),
                  const Text(
                    'Agregar unidad a la cola',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Toca el número de unidad para ponerla al final de la cola.',
                style:
                    TextStyle(fontSize: 13, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 280,
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection(AppConstants.driversCollection)
                      .where('associationId', isEqualTo: aid)
                      .where('status', whereNotIn: [
                    AppConstants.statusOffline
                  ]).snapshots(),
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(
                          child: CircularProgressIndicator());
                    }
                    final docs = snap.data?.docs ?? [];
                    if (docs.isEmpty) {
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline,
                                color: Colors.orange.shade800),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'No hay unidades online. Pídele al conductor que active su radio y entre.',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    // Filtrar las que ya están en cola (no las mostramos otra vez).
                    final notInQueue = docs.where((d) {
                      return d.data()['inQueueAt'] == null;
                    }).toList()
                      ..sort((a, b) {
                        final na = int.tryParse(
                                a.data()['vehicleNumber'] ?? '0') ??
                            0;
                        final nb = int.tryParse(
                                b.data()['vehicleNumber'] ?? '0') ??
                            0;
                        return na.compareTo(nb);
                      });
                    if (notInQueue.isEmpty) {
                      return const Center(
                        child: Text('Todas las unidades online ya están en la cola.'),
                      );
                    }
                    return GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 1,
                      ),
                      itemCount: notInQueue.length,
                      itemBuilder: (_, i) {
                        final d = notInQueue[i].data();
                        final num_ =
                            (d['vehicleNumber'] as String?) ?? '';
                        final docId = notInQueue[i].id;
                        return Material(
                          color: AppTheme.successColor,
                          borderRadius: BorderRadius.circular(12),
                          elevation: 2,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () async {
                              HapticFeedback.lightImpact();
                              await StandQueueService.instance
                                  .joinQueue(docId);
                              if (context.mounted) {
                                Navigator.of(context).pop();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                        'Unidad #$num_ agregada a la cola'),
                                    backgroundColor: AppTheme.successColor,
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              }
                            },
                            child: Container(
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.directions_car,
                                      color: Colors.white, size: 18),
                                  const SizedBox(height: 4),
                                  Text(
                                    num_.isEmpty ? '?' : '#$num_',
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
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _assignToUnit(
    BuildContext context,
    user,
    QueuedUnit unit,
  ) async {
    HapticFeedback.mediumImpact();
    // Confirmación rápida con un AlertDialog ligero.
    final messenger = ScaffoldMessenger.of(context);
    final clientCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Asignar a Unidad #${unit.vehicleNumber}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Conductor: ${unit.driverName}',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: clientCtrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '# cliente (opcional)',
                hintText: 'ej. 1059',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.check),
            label: const Text('Asignar'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final now = DateTime.now();
    final code = clientCtrl.text.trim();
    final trip = TripModel(
      uid: const Uuid().v4(),
      associationId: user.associationId,
      driverId: unit.userId,
      driverName: unit.driverName,
      operatorId: user.uid,
      operatorName: '${user.name} ${user.lastname}'.trim(),
      clienteNombre: code.isEmpty ? null : 'Cliente $code',
      pickupLatitude: 0,
      pickupLongitude: 0,
      pickupAddress: 'Parada (cola)',
      status: TripStatus.finalizado,
      source: TripSource.street,
      startTime: now,
      endTime: now,
      createdAt: now,
    );

    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(trip.uid)
          .set(trip.toFirestore());
      // Sacar al conductor de la cola
      await StandQueueService.instance.leaveQueue(unit.driverDocId);
      // Métrica de la operadora
      final dateKey =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await FirebaseFirestore.instance
          .collection('operadora_metrics')
          .doc('${user.uid}_$dateKey')
          .set({
        'associationId': user.associationId,
        'operatorId': user.uid,
        'operatorName': '${user.name} ${user.lastname}'.trim(),
        'date': dateKey,
        'streetAssigned': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      messenger.showSnackBar(
        SnackBar(
          content: Text(
              'Carrera asignada a Unidad #${unit.vehicleNumber}'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.errorColor));
    }
  }
}

class _UnitQueueChip extends StatelessWidget {
  final int order;
  final QueuedUnit unit;
  final bool isMine;
  final bool isOperator;
  final VoidCallback? onTap;

  const _UnitQueueChip({
    required this.order,
    required this.unit,
    required this.isMine,
    required this.isOperator,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = unit.status == AppConstants.statusFree
        ? AppTheme.successColor
        : Colors.orange.shade700;
    return Material(
      color: isMine ? AppTheme.primaryColor : color,
      borderRadius: BorderRadius.circular(10),
      elevation: isMine ? 4 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          width: 84,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('#$order',
                        style: const TextStyle(
                            fontSize: 9,
                            color: Colors.white,
                            fontWeight: FontWeight.w700)),
                  ),
                  Text(
                    unit.waitingTimeLabel,
                    style: const TextStyle(
                        fontSize: 9,
                        color: Colors.white70,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              Text(
                unit.vehicleNumber.isEmpty ? '?' : '#${unit.vehicleNumber}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DriverQueueButton extends StatelessWidget {
  final List<QueuedUnit> queue;
  const _DriverQueueButton({required this.queue});

  @override
  Widget build(BuildContext context) {
    final loc = DriverLocationService.instance;
    final myDriverId = loc.driverId;
    final iAmInQueue =
        myDriverId != null && queue.any((u) => u.driverDocId == myDriverId);

    return TextButton.icon(
      onPressed: myDriverId == null
          ? null
          : () async {
              HapticFeedback.lightImpact();
              if (iAmInQueue) {
                await StandQueueService.instance.leaveQueue(myDriverId);
              } else {
                await StandQueueService.instance.joinQueue(myDriverId);
              }
            },
      icon: Icon(
        iAmInQueue ? Icons.exit_to_app : Icons.local_taxi,
        size: 16,
      ),
      label: Text(
        iAmInQueue ? 'Salir' : 'Entrar a parada',
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
      style: TextButton.styleFrom(
        foregroundColor:
            iAmInQueue ? Colors.red.shade700 : AppTheme.primaryColor,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        minimumSize: const Size(0, 28),
      ),
    );
  }
}
