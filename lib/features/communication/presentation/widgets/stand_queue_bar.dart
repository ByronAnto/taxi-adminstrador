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
  final ScrollController _scrollCtrl = ScrollController();
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    _scrollCtrl.addListener(_updateScrollIndicators);
  }

  void _updateScrollIndicators() {
    if (!_scrollCtrl.hasClients) return;
    final p = _scrollCtrl.position;
    final left = p.pixels > 4;
    final right = p.pixels < p.maxScrollExtent - 4;
    if (left != _canScrollLeft || right != _canScrollRight) {
      setState(() {
        _canScrollLeft = left;
        _canScrollRight = right;
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scrollCtrl.removeListener(_updateScrollIndicators);
    _scrollCtrl.dispose();
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
                    child: InkWell(
                      onTap: queue.length > 4
                          ? () => _showFullQueueSheet(
                              context, queue, user, isOperator)
                          : null,
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Text(
                              isOperator
                                  ? 'Cola de la parada (${queue.length})'
                                  : 'En la parada (${queue.length})',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.amber.shade900,
                              ),
                            ),
                            if (queue.length > 4) ...[
                              const SizedBox(width: 4),
                              Icon(Icons.unfold_more,
                                  size: 14, color: Colors.amber.shade800),
                              Text(
                                'ver todas',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.amber.shade800,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ],
                          ],
                        ),
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
                    : NotificationListener<ScrollMetricsNotification>(
                        onNotification: (_) {
                          // Cuando cambia la longitud de la lista re-evalúa indicadores.
                          WidgetsBinding.instance.addPostFrameCallback(
                              (_) => _updateScrollIndicators());
                          return false;
                        },
                        child: Stack(
                          children: [
                            ListView.builder(
                              controller: _scrollCtrl,
                              scrollDirection: Axis.horizontal,
                              itemCount: queue.length,
                              itemBuilder: (_, i) {
                                final unit = queue[i];
                                final isMyUnit = unit.userId == user.uid;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4),
                                  child: _UnitQueueChip(
                                    order: i + 1,
                                    unit: unit,
                                    isMine: isMyUnit,
                                    isOperator: isOperator,
                                    onTap: isOperator
                                        ? () =>
                                            _assignToUnit(context, user, unit)
                                        : null,
                                    onLongPress: isOperator
                                        ? () => _showOperatorChipMenu(
                                            context, user, unit, i,
                                            queue.length)
                                        : null,
                                  ),
                                );
                              },
                            ),
                            if (_canScrollLeft)
                              Positioned(
                                left: 0,
                                top: 0,
                                bottom: 0,
                                child: IgnorePointer(
                                  child: Container(
                                    width: 18,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                        colors: [
                                          Colors.amber.shade50,
                                          Colors.amber.shade50
                                              .withValues(alpha: 0),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (_canScrollRight)
                              Positioned(
                                right: 0,
                                top: 0,
                                bottom: 0,
                                child: IgnorePointer(
                                  child: Container(
                                    width: 18,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.centerRight,
                                        end: Alignment.centerLeft,
                                        colors: [
                                          Colors.amber.shade50,
                                          Colors.amber.shade50
                                              .withValues(alpha: 0),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Bottom-sheet que muestra TODA la cola en grid (útil cuando hay muchas
  /// unidades y la barra horizontal queda muy larga). Tap en una unidad
  /// abre el mismo flujo de asignación rápida (operadora) o cierra (conductor).
  Future<void> _showFullQueueSheet(
    BuildContext context,
    List<QueuedUnit> queue,
    user,
    bool isOperator,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollCtrl) => Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
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
                    Icon(Icons.local_taxi, color: Colors.amber.shade800),
                    const SizedBox(width: 8),
                    Text(
                      'Cola completa (${queue.length})',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isOperator
                      ? 'Toca una unidad para asignarle un cliente.'
                      : 'Tu posición está marcada en azul.',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: GridView.builder(
                    controller: scrollCtrl,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 0.95,
                    ),
                    itemCount: queue.length,
                    itemBuilder: (_, i) {
                      final unit = queue[i];
                      final isMine = unit.userId == user.uid;
                      return _UnitQueueChip(
                        order: i + 1,
                        unit: unit,
                        isMine: isMine,
                        isOperator: isOperator,
                        onTap: isOperator
                            ? () {
                                Navigator.of(sheetCtx).pop();
                                _assignToUnit(context, user, unit);
                              }
                            : null,
                        onLongPress: isOperator
                            ? () {
                                Navigator.of(sheetCtx).pop();
                                _showOperatorChipMenu(
                                    context, user, unit, i, queue.length);
                              }
                            : null,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Modal para que la operadora agregue MANUALMENTE una unidad a la cola.
  /// Útil cuando el conductor está online pero no tap "Entrar a parada"
  /// en su propia app.
  /// Long-press en un chip por la operadora/admin: menú compacto con
  /// las acciones de reorder + sacar de cola.
  ///
  /// Caso típico: alguien se reportó por voz antes pero el otro alcanzó
  /// a registrarse en la app primero. La operadora corrige el orden
  /// subiendo al que tiene prioridad real.
  Future<void> _showOperatorChipMenu(
    BuildContext context,
    user,
    QueuedUnit unit,
    int index,
    int total,
  ) async {
    HapticFeedback.lightImpact();
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('#${unit.vehicleNumber}',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppTheme.primaryColor)),
              ),
              title: Text(unit.driverName.isEmpty
                  ? 'Conductor'
                  : unit.driverName),
              subtitle: Text(
                  'Posición ${index + 1} de $total · ${unit.waitingTimeLabel}'),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.arrow_upward, color: Colors.green),
              title: const Text('Subir uno'),
              subtitle: index == 0
                  ? const Text('Ya está al inicio',
                      style: TextStyle(fontSize: 11))
                  : Text(
                      'Pasa a la posición $index de $total',
                      style: const TextStyle(fontSize: 11),
                    ),
              enabled: index > 0,
              onTap: () async {
                Navigator.of(ctx).pop();
                await _doMove(unit, user.associationId, up: true);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.arrow_downward, color: Colors.orange),
              title: const Text('Bajar uno'),
              subtitle: index >= total - 1
                  ? const Text('Ya está al final',
                      style: TextStyle(fontSize: 11))
                  : Text(
                      'Pasa a la posición ${index + 2} de $total',
                      style: const TextStyle(fontSize: 11),
                    ),
              enabled: index < total - 1,
              onTap: () async {
                Navigator.of(ctx).pop();
                await _doMove(unit, user.associationId, up: false);
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.exit_to_app, color: Colors.red.shade700),
              title: Text('Sacar de la cola',
                  style: TextStyle(color: Colors.red.shade700)),
              onTap: () async {
                Navigator.of(ctx).pop();
                await StandQueueService.instance.leaveQueue(unit.driverDocId);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                          'Unidad #${unit.vehicleNumber} retirada de la cola'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _doMove(
      QueuedUnit unit, String aid, {required bool up}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (up) {
        await StandQueueService.instance
            .moveUp(unit.driverDocId, associationId: aid);
      } else {
        await StandQueueService.instance
            .moveDown(unit.driverDocId, associationId: aid);
      }
      HapticFeedback.mediumImpact();
      messenger.showSnackBar(
        SnackBar(
          content: Text(up
              ? 'Unidad #${unit.vehicleNumber} subió uno'
              : 'Unidad #${unit.vehicleNumber} bajó uno'),
          backgroundColor: AppTheme.successColor,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.orange.shade800,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

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
                    // Filtros defensivos:
                    //  - Que no esté ya en la cola.
                    //  - Que no sea un conductor archivado / eliminado:
                    //    si `deleteUser` aplicó la cascada, tendrá
                    //    `archivedAt`/`deletedAt`. Sin esto, un usuario
                    //    eliminado seguía apareciendo duplicado en la
                    //    lista junto al conductor real con la misma
                    //    unidad.
                    //  - Que `isActive` no sea explícitamente false.
                    //  - Que tenga vehicleNumber (excluye operadoras y
                    //    docs sin unidad).
                    final nowTs = DateTime.now();
                    final notInQueue = docs.where((d) {
                      final data = d.data();
                      // "En cola" solo si inQueueAt es RECIENTE (misma regla de
                      // 2h que watchQueue). Un inQueueAt viejo deja la unidad
                      // fuera de la lista visible pero antes bloqueaba el
                      // re-agregado → la unidad no podía volver a entrar.
                      final iq = data['inQueueAt'];
                      if (iq is Timestamp &&
                          nowTs.difference(iq.toDate()) <
                              const Duration(hours: 2)) {
                        return false;
                      }
                      if (data['archivedAt'] != null) return false;
                      if (data['deletedAt'] != null) return false;
                      if (data['isActive'] == false) return false;
                      final vn = (data['vehicleNumber'] as String?) ?? '';
                      if (vn.isEmpty) return false;
                      return true;
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
                              // La operadora ve la cola desde lejos
                              // (puede no estar físicamente en la parada),
                              // por eso bypassDistanceCheck = true.
                              await StandQueueService.instance.joinQueue(
                                docId,
                                bypassDistanceCheck: true,
                              );
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
      source: TripSource.standQueue,
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
  final VoidCallback? onLongPress;

  const _UnitQueueChip({
    required this.order,
    required this.unit,
    required this.isMine,
    required this.isOperator,
    this.onTap,
    this.onLongPress,
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
        onLongPress: onLongPress,
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

class _DriverQueueButton extends StatefulWidget {
  final List<QueuedUnit> queue;
  const _DriverQueueButton({required this.queue});

  @override
  State<_DriverQueueButton> createState() => _DriverQueueButtonState();
}

class _DriverQueueButtonState extends State<_DriverQueueButton> {
  /// True mientras una solicitud de joinQueue está en vuelo (GPS + Firestore).
  /// Mientras esté en true, el botón se deshabilita: evita el spam de
  /// snackbars cuando el usuario tapea repetidamente y el GPS demora 1-3s.
  bool _busy = false;

  Future<void> _handlePress(String myDriverId, String aid, bool iAmInQueue) async {
    if (_busy) return; // Click guard
    setState(() => _busy = true);
    HapticFeedback.lightImpact();
    final messenger = ScaffoldMessenger.of(context);
    // Limpiar snackbars previos para que no se apilen (importante cuando
    // el conductor da varios taps en rápida sucesión).
    messenger.clearSnackBars();
    try {
      if (iAmInQueue) {
        await StandQueueService.instance.leaveQueue(myDriverId);
        return;
      }
      await StandQueueService.instance.joinQueue(
        myDriverId,
        associationId: aid,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('🚖 Estás en la cola de la parada'),
          backgroundColor: AppTheme.successColor,
          duration: Duration(seconds: 2),
        ),
      );
    } on StandQueueOutOfRange catch (e) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      messenger.showSnackBar(
        SnackBar(
          content: Text(e.userMessage),
          backgroundColor: e.reason == StandQueueErrorReason.gpsUnavailable
              ? Colors.red
              : Colors.orange.shade800,
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    final aid = (auth is AuthAuthenticated) ? auth.user.associationId : null;
    final loc = DriverLocationService.instance;
    final myDriverId = loc.driverId;
    final iAmInQueue = myDriverId != null &&
        widget.queue.any((u) => u.driverDocId == myDriverId);

    final disabled = myDriverId == null || aid == null || _busy;

    return TextButton.icon(
      onPressed: disabled
          ? null
          : () => _handlePress(myDriverId, aid, iAmInQueue),
      icon: _busy
          ? const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              iAmInQueue ? Icons.exit_to_app : Icons.local_taxi,
              size: 16,
            ),
      label: Text(
        _busy
            ? 'Verificando…'
            : (iAmInQueue ? 'Salir' : 'Entrar a parada'),
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
