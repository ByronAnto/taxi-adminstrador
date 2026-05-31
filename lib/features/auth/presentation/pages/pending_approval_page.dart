import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_scaffold.dart';
import '../../../../core/widgets/state_views.dart';
import '../../data/models/user_model.dart';
import '../bloc/auth_bloc.dart';

/// Pantalla intermedia que se muestra al usuario logueado mientras
/// su cuenta está pendiente de aprobación.
///
/// Comportamiento:
/// - Si es **conductor** y faltan fotos → muestra form para subirlas.
/// - Si todas las fotos están listas (o no es conductor) → muestra
///   mensaje "Esperando aprobación".
/// - Si el admin lo aprueba (status pasa a `active`), AuthBloc emite
///   nuevo estado y GoRouter redirige al home automáticamente.
class PendingApprovalPage extends StatefulWidget {
  const PendingApprovalPage({super.key});

  @override
  State<PendingApprovalPage> createState() => _PendingApprovalPageState();
}

class _PendingApprovalPageState extends State<PendingApprovalPage> {
  final _picker = ImagePicker();

  File? _fotoVehiculo;
  File? _fotoLicenciaFrontal;
  File? _fotoLicenciaTrasera;

  bool _uploading = false;
  String? _uploadError;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    if (auth is! AuthAuthenticated) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return AppScaffold(
      title: 'Pendiente de aprobación',
      showBack: false,
      actions: [
        IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'Cerrar sesión',
          onPressed: () =>
              context.read<AuthBloc>().add(AuthSignOutRequested()),
        ),
      ],
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(auth.user.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorState.fromError(snapshot.error);
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LoadingState();
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const EmptyState(
              icon: Icons.person_off_outlined,
              title: 'Cuenta no encontrada',
              subtitle: 'No pudimos cargar tu cuenta. Cierra sesión e '
                  'intenta de nuevo.',
            );
          }
          final user = UserModel.fromFirestore(snapshot.data!);

          // Si el admin ya aprobó, dispara recheck para que GoRouter redirija.
          if (user.status == UserStatus.active) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                context.read<AuthBloc>().add(AuthCheckRequested());
              }
            });
          }

          return _buildBody(context, user);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, UserModel user) {
    if (user.status == UserStatus.rejected) {
      return _statusMessage(
        context,
        icon: Icons.cancel,
        color: AppTheme.errorColor,
        title: 'Cuenta rechazada',
        body:
            'Tu administrador rechazó esta solicitud. Si crees que es un '
            'error, contacta a la asociación.',
      );
    }
    if (user.status == UserStatus.suspended) {
      return _statusMessage(
        context,
        icon: Icons.block,
        color: AppTheme.warningColor,
        title: 'Cuenta suspendida',
        body:
            'Tu cuenta está suspendida temporalmente. Contacta al '
            'administrador para más información.',
      );
    }

    final isDriver = user.role == AppConstants.roleDriver;
    final missingPhotos = isDriver &&
        (user.fotoVehiculo == null ||
            user.fotoLicenciaFrontal == null ||
            user.fotoLicenciaTrasera == null);

    if (missingPhotos) {
      return _photosForm(context, user);
    }

    // Sin fotos faltantes → solo esperar
    return _statusMessage(
      context,
      icon: Icons.hourglass_top,
      color: AppTheme.warningColor,
      title: 'Esperando aprobación',
      body:
          'Tu cuenta y datos ya están registrados. El administrador de '
          'tu asociación los revisará pronto. Puedes cerrar la app — '
          'cuando te aprueben, tendrás acceso completo.',
    );
  }

  Widget _statusMessage(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String body,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 80, color: color),
            const SizedBox(height: AppSpacing.xl),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.headlineMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              body,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _photosForm(BuildContext context, UserModel user) {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: AppTheme.infoColor.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
            border:
                Border.all(color: AppTheme.infoColor.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.info_outline, color: AppTheme.infoColor),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Completa tu registro',
                      style: textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Toma una foto de tu vehículo y de tu licencia (lado '
                'frontal y trasero). Cuando termines, el administrador '
                'revisará tu solicitud.',
                style: textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        _photoTile(
          label: 'Foto del vehículo',
          icon: Icons.directions_car,
          file: _fotoVehiculo,
          existingUrl: user.fotoVehiculo,
          onTap: () => _pick('vehiculo'),
        ),
        const SizedBox(height: 12),
        _photoTile(
          label: 'Licencia - Lado frontal',
          icon: Icons.credit_card,
          file: _fotoLicenciaFrontal,
          existingUrl: user.fotoLicenciaFrontal,
          onTap: () => _pick('licencia_frontal'),
        ),
        const SizedBox(height: 12),
        _photoTile(
          label: 'Licencia - Lado trasero',
          icon: Icons.credit_card,
          file: _fotoLicenciaTrasera,
          existingUrl: user.fotoLicenciaTrasera,
          onTap: () => _pick('licencia_trasera'),
        ),
        const SizedBox(height: 24),
        if (_uploadError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Text(
              _uploadError!,
              style: const TextStyle(color: AppTheme.errorColor),
              textAlign: TextAlign.center,
            ),
          ),
        ElevatedButton(
          onPressed: _uploading ? null : () => _submitPhotos(user.uid),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: _uploading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary),
                )
              : const Text('SUBIR FOTOS Y CONTINUAR'),
        ),
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }

  Widget _photoTile({
    required String label,
    required IconData icon,
    required File? file,
    required String? existingUrl,
    required VoidCallback onTap,
  }) {
    final hasNew = file != null;
    final hasExisting = existingUrl != null && existingUrl.isNotEmpty;
    final hasAny = hasNew || hasExisting;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          border: Border.all(
            color: hasAny ? AppTheme.successColor : Colors.grey.shade400,
            width: hasAny ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 36,
                color: hasAny ? AppTheme.successColor : Colors.grey),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    hasNew
                        ? 'Foto seleccionada (toca para cambiar)'
                        : hasExisting
                            ? 'Foto ya subida (toca para cambiar)'
                            : 'Toca para tomar o seleccionar foto',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
            Icon(
              hasAny ? Icons.check_circle : Icons.camera_alt,
              color: hasAny ? AppTheme.successColor : Colors.grey,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(String tipo) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Cámara'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galería'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final picked = await _picker.pickImage(
      source: source,
      imageQuality: 70,
      maxWidth: 1280,
    );
    if (picked == null) return;
    setState(() {
      switch (tipo) {
        case 'vehiculo':
          _fotoVehiculo = File(picked.path);
          break;
        case 'licencia_frontal':
          _fotoLicenciaFrontal = File(picked.path);
          break;
        case 'licencia_trasera':
          _fotoLicenciaTrasera = File(picked.path);
          break;
      }
    });
  }

  Future<void> _submitPhotos(String uid) async {
    if (_fotoVehiculo == null &&
        _fotoLicenciaFrontal == null &&
        _fotoLicenciaTrasera == null) {
      setState(() => _uploadError = 'Toma al menos una foto.');
      return;
    }

    setState(() {
      _uploading = true;
      _uploadError = null;
    });

    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final updates = <String, dynamic>{};

      if (_fotoVehiculo != null) {
        final ref = FirebaseStorage.instance
            .ref('users/$uid/vehiculo_$ts.jpg');
        await ref.putFile(_fotoVehiculo!);
        updates['fotoVehiculo'] = await ref.getDownloadURL();
      }
      if (_fotoLicenciaFrontal != null) {
        final ref = FirebaseStorage.instance
            .ref('users/$uid/licencia_frontal_$ts.jpg');
        await ref.putFile(_fotoLicenciaFrontal!);
        updates['fotoLicenciaFrontal'] = await ref.getDownloadURL();
      }
      if (_fotoLicenciaTrasera != null) {
        final ref = FirebaseStorage.instance
            .ref('users/$uid/licencia_trasera_$ts.jpg');
        await ref.putFile(_fotoLicenciaTrasera!);
        updates['fotoLicenciaTrasera'] = await ref.getDownloadURL();
      }

      if (updates.isEmpty) return;

      await FirebaseFunctions.instance.httpsCallable('updateUser').call({
        'userUid': uid,
        'fields': updates,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fotos subidas. Esperando aprobación del admin.'),
          backgroundColor: AppTheme.successColor,
        ),
      );

      setState(() {
        _fotoVehiculo = null;
        _fotoLicenciaFrontal = null;
        _fotoLicenciaTrasera = null;
      });
    } on FirebaseFunctionsException catch (e) {
      setState(() => _uploadError = 'Error: ${e.message ?? e.code}');
    } catch (e) {
      setState(() => _uploadError = 'Error al subir: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }
}
