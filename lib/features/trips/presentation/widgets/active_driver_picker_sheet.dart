import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../../../core/constants/app_constants.dart';

/// Resultado de seleccionar un conductor activo en [ActiveDriverPickerSheet].
///
/// Lleva tanto el id del documento de `drivers/` como el `userId` (auth uid
/// del conductor, que es lo que se guarda en `trips.driverId`) y los datos
/// denormalizados que las pantallas suelen necesitar (nombre, # de unidad).
class ActiveDriverPick {
  /// Id del documento en la colección `drivers/`.
  final String driverDocId;

  /// Auth uid del conductor (lo que va en `trips.driverId`).
  final String userId;

  /// Nombre completo denormalizado del conductor.
  final String driverName;

  /// Número de unidad Jipijapa (puede venir vacío).
  final String vehicleNumber;

  const ActiveDriverPick({
    required this.driverDocId,
    required this.userId,
    required this.driverName,
    required this.vehicleNumber,
  });
}

/// Hoja reutilizable para que la operadora/admin elija un CONDUCTOR ACTIVO
/// de la asociación.
///
/// Definición de "activo" (idéntica a la usada en el mapa de la operadora,
/// ver `MapRemoteDatasource.watchActiveDriverLocations` y en
/// `AssignTripModal`): `isActive == true` y `status != desconectado`. El
/// filtro de status se hace client-side para no requerir un índice compuesto
/// adicional con `isActive`.
///
/// Centraliza el stream/filtro para que NO se duplique entre la asignación
/// inicial (solicitudes web) y la reasignación de una carrera existente.
/// Devuelve un [ActiveDriverPick] vía `Navigator.pop`, o `null` si se cancela.
class ActiveDriverPickerSheet extends StatelessWidget {
  /// Asociación (tenant) cuyos conductores se listan.
  final String associationId;

  /// Título mostrado en la cabecera de la hoja.
  final String title;

  /// uid del conductor que actualmente tiene la carrera. Si se pasa, se
  /// excluye de la lista (no tiene sentido reasignar al mismo conductor).
  final String? excludeUserId;

  const ActiveDriverPickerSheet({
    super.key,
    required this.associationId,
    this.title = 'Selecciona un conductor activo',
    this.excludeUserId,
  });

  /// Stream de conductores activos del tenant.
  Stream<QuerySnapshot<Map<String, dynamic>>> _activeDriversStream() {
    return FirebaseFirestore.instance
        .collection(AppConstants.driversCollection)
        .where('associationId', isEqualTo: associationId)
        .where('isActive', isEqualTo: true)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _activeDriversStream(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const LinearProgressIndicator();
              }
              // Solo conductores activos en el mapa (status != desconectado)
              // y, si aplica, distintos del conductor actual.
              final docs = (snap.data?.docs ?? [])
                  .where((d) =>
                      (d.data()['status'] as String?) !=
                      AppConstants.statusOffline)
                  .where((d) =>
                      excludeUserId == null ||
                      (d.data()['userId'] as String?) != excludeUserId)
                  .toList();
              if (docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No hay conductores activos en este momento.'),
                );
              }
              return ListView.builder(
                shrinkWrap: true,
                itemCount: docs.length,
                itemBuilder: (_, i) {
                  final d = docs[i].data();
                  final name = (d['driverName'] as String?) ?? 'Conductor';
                  final num_ = (d['vehicleNumber'] as String?) ?? '';
                  final status = (d['status'] as String?) ?? '';
                  final userId = (d['userId'] as String?) ?? '';
                  return ListTile(
                    leading: const Icon(Icons.directions_car),
                    title: Text(num_.isNotEmpty ? '#$num_ · $name' : name),
                    subtitle: Text(status),
                    onTap: () {
                      Navigator.of(context).pop(
                        ActiveDriverPick(
                          driverDocId: docs[i].id,
                          userId: userId,
                          driverName: name,
                          vehicleNumber: num_,
                        ),
                      );
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

/// Abre [ActiveDriverPickerSheet] como modal bottom sheet y devuelve la
/// selección (o `null` si se cancela).
Future<ActiveDriverPick?> showActiveDriverPicker(
  BuildContext context, {
  required String associationId,
  String title = 'Selecciona un conductor activo',
  String? excludeUserId,
}) {
  return showModalBottomSheet<ActiveDriverPick>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ActiveDriverPickerSheet(
      associationId: associationId,
      title: title,
      excludeUserId: excludeUserId,
    ),
  );
}
