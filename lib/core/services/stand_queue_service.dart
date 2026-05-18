import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../features/associations/data/models/association_model.dart';
import '../utils/geo_utils.dart';

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
  ///
  /// Si la asociación tiene una `standLocation` configurada, valida que
  /// el conductor esté DENTRO del radio permitido (default 1 km).
  /// Si está demasiado lejos, lanza [StandQueueOutOfRange] con la
  /// distancia y el radio para que la UI muestre el mensaje preciso.
  ///
  /// Si la asociación NO tiene parada configurada, deja entrar siempre
  /// (back-compat con cooperativas que aún no fijaron base).
  ///
  /// Si la operadora/admin lo agrega manualmente, pasa
  /// `bypassDistanceCheck = true` (la operadora ve la cola desde lejos).
  Future<void> joinQueue(
    String driverDocId, {
    String? associationId,
    bool bypassDistanceCheck = false,
  }) async {
    if (driverDocId.isEmpty) return;

    if (!bypassDistanceCheck && associationId != null) {
      await _validateDistanceOrThrow(associationId);
    }

    try {
      await _firestore.collection('drivers').doc(driverDocId).update({
        'inQueueAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('StandQueueService.joinQueue error: $e');
      rethrow;
    }
  }

  /// Lee la `standLocation` de la asociación y compara con el GPS actual.
  /// Si está fuera del radio, lanza [StandQueueOutOfRange].
  /// Si la asociación no tiene parada configurada, no valida nada.
  Future<void> _validateDistanceOrThrow(String associationId) async {
    final assocSnap =
        await _firestore.collection('associations').doc(associationId).get();
    final stand = StandLocation.fromMap(
        assocSnap.data()?['standLocation'] as Map<String, dynamic>?);
    if (!stand.isConfigured) return;

    Position pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } catch (e) {
      throw const StandQueueOutOfRange(
        distanceKm: -1,
        allowedKm: 0,
        reason: StandQueueErrorReason.gpsUnavailable,
      );
    }

    final km = haversineKm(
      lat1: pos.latitude,
      lng1: pos.longitude,
      lat2: stand.lat!,
      lng2: stand.lng!,
    );
    if (km > stand.radiusKm) {
      throw StandQueueOutOfRange(
        distanceKm: km,
        allowedKm: stand.radiusKm,
        reason: StandQueueErrorReason.tooFar,
      );
    }
  }

  /// Mueve un driver UNA posición arriba en la cola, intercambiando su
  /// `inQueueAt` con el inmediato anterior.
  ///
  /// Caso de uso: alguien se reportó por voz **antes** que otro pero el
  /// otro alcanzó a registrarse en la app primero. La operadora corrige
  /// el orden subiendo al que tiene prioridad real.
  ///
  /// Usa una transacción para que dos operadoras simultáneas no se
  /// pisen el reorder.
  Future<void> moveUp(
    String driverDocId, {
    required String associationId,
  }) async {
    if (driverDocId.isEmpty) return;
    await _swapWithNeighbor(driverDocId,
        associationId: associationId, direction: -1);
  }

  /// Mueve un driver UNA posición abajo (swap con el siguiente).
  Future<void> moveDown(
    String driverDocId, {
    required String associationId,
  }) async {
    if (driverDocId.isEmpty) return;
    await _swapWithNeighbor(driverDocId,
        associationId: associationId, direction: 1);
  }

  /// direction = -1 (subir, swap con el de menor inQueueAt anterior)
  /// direction = 1  (bajar, swap con el siguiente)
  Future<void> _swapWithNeighbor(
    String driverDocId, {
    required String associationId,
    required int direction,
  }) async {
    final col = _firestore.collection('drivers');
    final mySnap = await col.doc(driverDocId).get();
    final myAt = (mySnap.data()?['inQueueAt'] as Timestamp?)?.toDate();
    if (myAt == null) {
      throw Exception('Esta unidad ya no está en la cola.');
    }
    // Buscar el vecino: el que tiene inQueueAt más cercano del lado pedido.
    final query = direction < 0
        ? col
            .where('associationId', isEqualTo: associationId)
            .where('inQueueAt', isLessThan: Timestamp.fromDate(myAt))
            .orderBy('inQueueAt', descending: true)
            .limit(1)
        : col
            .where('associationId', isEqualTo: associationId)
            .where('inQueueAt', isGreaterThan: Timestamp.fromDate(myAt))
            .orderBy('inQueueAt')
            .limit(1);
    final neighborSnap = await query.get();
    if (neighborSnap.docs.isEmpty) {
      throw Exception(direction < 0
          ? 'Esta unidad ya está al inicio de la cola.'
          : 'Esta unidad ya está al final de la cola.');
    }
    final neighbor = neighborSnap.docs.first;
    final neighborAt =
        (neighbor.data()['inQueueAt'] as Timestamp?)?.toDate();
    if (neighborAt == null) return;

    // Swap atómico con batch.
    final batch = _firestore.batch();
    batch.update(col.doc(driverDocId), {
      'inQueueAt': Timestamp.fromDate(neighborAt),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    batch.update(neighbor.reference, {
      'inQueueAt': Timestamp.fromDate(myAt),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
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

enum StandQueueErrorReason { tooFar, gpsUnavailable }

/// Excepción lanzada cuando un conductor intenta entrar a la cola pero
/// está fuera del radio permitido por la asociación o el GPS no responde.
class StandQueueOutOfRange implements Exception {
  final double distanceKm;
  final double allowedKm;
  final StandQueueErrorReason reason;

  const StandQueueOutOfRange({
    required this.distanceKm,
    required this.allowedKm,
    required this.reason,
  });

  String get userMessage {
    if (reason == StandQueueErrorReason.gpsUnavailable) {
      return 'No pudimos obtener tu ubicación. Activa el GPS y vuelve a intentar.';
    }
    final dist = formatDistance(distanceKm);
    final allowed = formatDistance(allowedKm);
    return 'Estás a $dist de la parada. Acércate a menos de $allowed para entrar a la cola.';
  }
}
