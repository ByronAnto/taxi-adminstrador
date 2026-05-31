import 'dart:io';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';

class RequestVehicleChangePage extends StatefulWidget {
  const RequestVehicleChangePage({super.key});

  @override
  State<RequestVehicleChangePage> createState() =>
      _RequestVehicleChangePageState();
}

class _RequestVehicleChangePageState extends State<RequestVehicleChangePage> {
  final _formKey = GlobalKey<FormState>();
  final _plate = TextEditingController();
  final _vehNumber = TextEditingController();
  final _reason = TextEditingController();
  File? _photo;
  bool _submitting = false;

  @override
  void dispose() {
    _plate.dispose();
    _vehNumber.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 75,
      maxWidth: 1280,
    );
    if (picked != null) setState(() => _photo = File(picked.path));
  }

  Future<String?> _uploadPhoto(String uid) async {
    if (_photo == null) return null;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ref = FirebaseStorage.instance
        .ref('users/$uid/vehicle_change_$ts.jpg');
    await ref.putFile(_photo!);
    return await ref.getDownloadURL();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return;
    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final photoUrl = await _uploadPhoto(auth.user.uid);
      await FirebaseFunctions.instance
          .httpsCallable('requestVehicleChange')
          .call({
        'newPlate': _plate.text.trim().toUpperCase(),
        'newVehicleNumber': _vehNumber.text.trim(),
        'newFotoVehiculo': photoUrl,
        'reason': _reason.text.trim(),
      });
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(const SnackBar(
        content: Text('Solicitud enviada. Espera la aprobación.'),
        backgroundColor: AppTheme.successColor,
      ));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Error: ${e.message ?? e.code}'),
        backgroundColor: AppTheme.errorColor,
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: AppTheme.errorColor,
      ));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return const SizedBox.shrink();
    final user = auth.user;

    return Scaffold(
      appBar: AppBar(title: const Text('Solicitar cambio de unidad')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                color: AppTheme.neutralBg,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Unidad actual',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: AppSpacing.xs),
                      Text('Placa: ${user.placa.isNotEmpty ? user.placa : "Sin registrar"}'),
                      Text('Número: ${user.numeroVehiculo.isNotEmpty ? "#${user.numeroVehiculo}" : "Sin registrar"}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Nueva unidad',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: _plate,
                decoration: const InputDecoration(labelText: 'Placa nueva'),
                textCapitalization: TextCapitalization.characters,
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Requerido' : null,
              ),
              TextFormField(
                controller: _vehNumber,
                decoration:
                    const InputDecoration(labelText: 'Número de unidad'),
                keyboardType: TextInputType.number,
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Requerido' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _reason,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Motivo del cambio',
                  hintText: 'Ej. Accidente, avería del motor, préstamo, etc.',
                ),
                validator: (v) {
                  if ((v ?? '').trim().length < 10) {
                    return 'Mínimo 10 caracteres';
                  }
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Foto del nuevo vehículo (opcional pero recomendada)',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: _pickPhoto,
                icon: const Icon(Icons.camera_alt),
                label: Text(_photo == null
                    ? 'Tomar foto'
                    : 'Foto cargada — Volver a tomar'),
              ),
              if (_photo != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Image.file(_photo!, height: 150, fit: BoxFit.cover),
              ],
              const SizedBox(height: AppSpacing.xl),
              ElevatedButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.onPrimary),
                      )
                    : const Text('Enviar solicitud'),
              ),
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.warningColor.withValues(alpha: 0.08),
                  border: Border.all(
                      color: AppTheme.warningColor.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Mientras se aprueba, seguís operando con tu unidad actual. '
                  'Máximo 2 cambios aprobados en los últimos 30 días.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
