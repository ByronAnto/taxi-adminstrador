import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Cola de unidades cerca de la parada — para coordinar el despacho
/// "estilo cooperativa": las unidades circulan cerca de la parada para
/// evitar tráfico y se registran en orden de llegada. La operadora ve
/// la cola y asigna el cliente al primero (#24, #32, #33, ...).
///
/// Implementación: un campo `inQueueAt` (Timestamp) en cada doc de
/// `drivers/{driverId}`. Si null = no está en cola. El listado se obtiene
/// ordenando por `inQueueAt` ASC.
///
/// El conductor pulsa "Entrar a cola" cuando llega a la zona de la
/// parada. Auto-sale si pasa a status "con pasajero" o "desconectado",
/// o si pasa más de 2 horas (timeout de seguridad — limpieza en cliente).
class StandQueueService {
  StandQueueService._();
  static final StandQueueService instance = StandQueueService._();

  final _firestore = FirebaseFirestore.instance;

  /// Agrega el driver actual a la cola con timestamp del servidor.
  Future<void> joinQueue(String driverDocId) async {
    if (driverDocId.isEmpty) return;
    try {
      await _firestore.collection('drivers').doc(driverDocId).update({
        'inQueueAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('StandQueueService.joinQueue error: $e');
    }
  }

  /// Saca el driver de la cola.
  Future<void> leaveQueue(String driverDocId) async {
    if (driverDocId.isEmpty) return;
    try {
      await _firestore.collection('drivers').doc(driverDocId).update({
        'inQueueAt': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('StandQueueService.leaveQueue error: $e');
    }
  }

  /// Stream de la cola para una asociación, ordenada por orden de llegada.
  /// Solo incluye drivers con isActive=true e inQueueAt != null.
  Stream<List<QueuedUnit>> watchQueue(String associationId) {
    return _firestore
        .collection('drivers')
        .where('associationId', isEqualTo: associationId)
        .where('inQueueAt', isNull: false)
        .orderBy('inQueueAt')
        .snapshots()
        .map((snap) {
      final now = DateTime.now();
      // Filtro extra cliente: timeout 2h y status válido (no desconectado).
      return snap.docs
          .map((d) => QueuedUnit.fromFirestore(d))
          .where((u) {
            if (u.status == 'desconectado') return false;
            if (u.joinedAt == null) return false;
            return now.difference(u.joinedAt!) <
                const Duration(hours: 2);
          })
          .toList();
    });
  }
}

/// Item de la cola: una unidad esperando ser asignada.
class QueuedUnit {
  final String driverDocId;
  final String userId;
  final String vehicleNumber;
  final String driverName;
  final String status;
  final DateTime? joinedAt;

  const QueuedUnit({
    required this.driverDocId,
    required this.userId,
    required this.vehicleNumber,
    required this.driverName,
    required this.status,
    required this.joinedAt,
  });

  factory QueuedUnit.fromFirestore(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    return QueuedUnit(
      driverDocId: doc.id,
      userId: (d['userId'] as String?) ?? '',
      vehicleNumber: (d['vehicleNumber'] as String?) ?? '',
      driverName: (d['driverName'] as String?) ?? '',
      status: (d['status'] as String?) ?? '',
      joinedAt: (d['inQueueAt'] as Timestamp?)?.toDate(),
    );
  }

  String get waitingTimeLabel {
    if (joinedAt == null) return '—';
    final mins = DateTime.now().difference(joinedAt!).inMinutes;
    if (mins < 1) return 'ahora';
    if (mins < 60) return '${mins}m';
    return '${(mins / 60).floor()}h${mins % 60}m';
  }
}
