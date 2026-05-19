import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../users/data/models/vehicle_change_request_model.dart';

class VehicleChangeRequestsPage extends StatelessWidget {
  const VehicleChangeRequestsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final authState = context.read<AuthBloc>().state;
    if (authState is! AuthAuthenticated) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final user = authState.user;

    return Scaffold(
      appBar: AppBar(title: const Text('Cambios de unidad pendientes')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('vehicleChangeRequests')
            .where('associationId', isEqualTo: user.associationId)
            .where('status', isEqualTo: 'pending')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.directions_car_outlined,
                      size: 64, color: Colors.grey),
                  SizedBox(height: 12),
                  Text('Sin solicitudes pendientes',
                      style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }
          final requests = docs
              .map((d) => VehicleChangeRequest.fromFirestore(d))
              .toList();
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: requests.length,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, i) =>
                _RequestCard(request: requests[i]),
          );
        },
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  final VehicleChangeRequest request;
  const _RequestCard({required this.request});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd/MM/yyyy HH:mm');
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: driver name + date
            Row(
              children: [
                const Icon(Icons.person, size: 18, color: AppTheme.primaryColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    request.driverName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                Text(
                  fmt.format(request.createdAt),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            const Divider(height: 16),

            // Comparativa: viejo vs nuevo
            Row(
              children: [
                Expanded(child: _VehicleColumn(
                  label: 'Actual',
                  plate: request.oldPlate,
                  vehicleNumber: request.oldVehicleNumber,
                  photoUrl: request.oldFotoVehiculo,
                )),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward, color: Colors.grey),
                ),
                Expanded(child: _VehicleColumn(
                  label: 'Nueva',
                  plate: request.newPlate,
                  vehicleNumber: request.newVehicleNumber,
                  photoUrl: request.newFotoVehiculo,
                  highlight: true,
                )),
              ],
            ),

            const SizedBox(height: 10),
            // Motivo
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.grey),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      request.reason,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            // Botones
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _reject(context),
                    icon: const Icon(Icons.close, color: Colors.red),
                    label: const Text('Rechazar',
                        style: TextStyle(color: Colors.red)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _approve(context),
                    icon: const Icon(Icons.check, color: Colors.white),
                    label: const Text('Aprobar',
                        style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _approve(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar aprobación'),
        content: Text(
          'Actualizar la unidad de ${request.driverName} a '
          '#${request.newVehicleNumber} placa ${request.newPlate}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Aprobar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    try {
      await FirebaseFunctions.instance
          .httpsCallable('approveVehicleChange')
          .call({'requestId': request.uid});
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Cambio aprobado correctamente.'),
          backgroundColor: Colors.green,
        ));
      }
    } on FirebaseFunctionsException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: ${e.message ?? e.code}'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  Future<void> _reject(BuildContext context) async {
    final reasonCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rechazar solicitud'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: reasonCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Motivo del rechazo',
              hintText: 'Indica el motivo para el conductor.',
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              if ((v ?? '').trim().length < 5) return 'Mínimo 5 caracteres';
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(ctx, true);
            },
            style:
                ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child:
                const Text('Rechazar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    try {
      await FirebaseFunctions.instance
          .httpsCallable('rejectVehicleChange')
          .call({
        'requestId': request.uid,
        'rejectReason': reasonCtrl.text.trim(),
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Solicitud rechazada.'),
          backgroundColor: Colors.orange,
        ));
      }
    } on FirebaseFunctionsException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: ${e.message ?? e.code}'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }
}

class _VehicleColumn extends StatelessWidget {
  final String label;
  final String plate;
  final String vehicleNumber;
  final String? photoUrl;
  final bool highlight;

  const _VehicleColumn({
    required this.label,
    required this.plate,
    required this.vehicleNumber,
    this.photoUrl,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: highlight ? Colors.green.shade700 : Colors.grey.shade600,
          ),
        ),
        const SizedBox(height: 4),
        if (photoUrl != null && photoUrl!.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: photoUrl!,
              height: 80,
              width: double.infinity,
              fit: BoxFit.cover,
              placeholder: (ctx, url) => Container(
                height: 80,
                color: Colors.grey.shade200,
                child: const Icon(Icons.image, color: Colors.grey),
              ),
              errorWidget: (ctx, url, err) => Container(
                height: 80,
                color: Colors.grey.shade200,
                child: const Icon(Icons.broken_image, color: Colors.grey),
              ),
            ),
          )
        else
          Container(
            height: 80,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: const Icon(Icons.no_photography, color: Colors.grey),
          ),
        const SizedBox(height: 6),
        Text(
          plate.isNotEmpty ? plate : '—',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        Text(
          vehicleNumber.isNotEmpty ? '#$vehicleNumber' : '—',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }
}
