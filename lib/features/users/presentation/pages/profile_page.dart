import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/services/image_upload_service.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/data/models/user_model.dart';
import '../../../auth/domain/usecases/auth_usecases.dart';

/// Página de perfil de usuario con edición de datos
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _isEditing = false;
  bool _isSaving = false;

  // Controllers para edición
  late TextEditingController _nameCtrl;
  late TextEditingController _lastnameCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _placaCtrl;
  late TextEditingController _cooperativaCtrl;
  late TextEditingController _codigoCoopCtrl;
  late TextEditingController _numVehiculoCtrl;

  File? _newFotoVehiculo;
  File? _newFotoLicFrontal;
  File? _newFotoLicTrasera;

  final _imageService = ImageUploadService();

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _lastnameCtrl = TextEditingController();
    _phoneCtrl = TextEditingController();
    _placaCtrl = TextEditingController();
    _cooperativaCtrl = TextEditingController();
    _codigoCoopCtrl = TextEditingController();
    _numVehiculoCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _lastnameCtrl.dispose();
    _phoneCtrl.dispose();
    _placaCtrl.dispose();
    _cooperativaCtrl.dispose();
    _codigoCoopCtrl.dispose();
    _numVehiculoCtrl.dispose();
    super.dispose();
  }

  void _startEditing(UserModel user) {
    _nameCtrl.text = user.name;
    _lastnameCtrl.text = user.lastname;
    _phoneCtrl.text = user.phone;
    _placaCtrl.text = user.placa;
    _cooperativaCtrl.text = user.cooperativa;
    _codigoCoopCtrl.text = user.codigoCooperativa;
    _numVehiculoCtrl.text = user.numeroVehiculo;
    _newFotoVehiculo = null;
    _newFotoLicFrontal = null;
    _newFotoLicTrasera = null;
    setState(() => _isEditing = true);
  }

  Future<void> _pickImage(String tipo) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: AppTheme.primaryColor),
              title: const Text('Cámara'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: AppTheme.primaryColor),
              title: const Text('Galería'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final file = await _imageService.pickImage(source: source);
    if (file != null) {
      setState(() {
        switch (tipo) {
          case 'vehiculo':
            _newFotoVehiculo = file;
            break;
          case 'licencia_frontal':
            _newFotoLicFrontal = file;
            break;
          case 'licencia_trasera':
            _newFotoLicTrasera = file;
            break;
        }
      });
    }
  }

  Future<void> _saveProfile(UserModel user) async {
    setState(() => _isSaving = true);

    try {
      String? fotoVehiculoUrl = user.fotoVehiculo;
      String? fotoLicFrontalUrl = user.fotoLicenciaFrontal;
      String? fotoLicTraseraUrl = user.fotoLicenciaTrasera;

      if (_newFotoVehiculo != null) {
        fotoVehiculoUrl = await _imageService.uploadUserImage(
          file: _newFotoVehiculo!,
          uid: user.uid,
          tipo: 'vehiculo',
        );
      }
      if (_newFotoLicFrontal != null) {
        fotoLicFrontalUrl = await _imageService.uploadUserImage(
          file: _newFotoLicFrontal!,
          uid: user.uid,
          tipo: 'licencia_frontal',
        );
      }
      if (_newFotoLicTrasera != null) {
        fotoLicTraseraUrl = await _imageService.uploadUserImage(
          file: _newFotoLicTrasera!,
          uid: user.uid,
          tipo: 'licencia_trasera',
        );
      }

      final updatedUser = user.copyWith(
        name: _nameCtrl.text.trim(),
        lastname: _lastnameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        placa: _placaCtrl.text.trim().toUpperCase(),
        cooperativa: _cooperativaCtrl.text.trim(),
        codigoCooperativa: _codigoCoopCtrl.text.trim(),
        numeroVehiculo: _numVehiculoCtrl.text.trim(),
        fotoVehiculo: fotoVehiculoUrl,
        fotoLicenciaFrontal: fotoLicFrontalUrl,
        fotoLicenciaTrasera: fotoLicTraseraUrl,
      );

      if (!mounted) return;

      // Usar el UpdateProfileUseCase a través del bloc
      // Necesitamos acceder al repositorio directamente o agregar un evento
      // Usaremos un evento nuevo en el bloc
      context.read<AuthBloc>().add(AuthUpdateProfileRequested(user: updatedUser));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al guardar: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _isEditing = false;
        });
      }
    }
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'conductor':
        return 'Conductor';
      case 'operadora':
        return 'Operadora';
      case 'admin':
        return 'Administrador';
      default:
        return role;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi Perfil'),
        actions: [
          BlocBuilder<AuthBloc, AuthState>(
            builder: (context, state) {
              if (state is! AuthAuthenticated) return const SizedBox.shrink();
              final isSuper =
                  state.user.email == 'brealpeaymara@gmail.com';
              final isAdmin = state.user.role == AppConstants.roleAdmin;
              final isDriver =
                  state.user.role == AppConstants.roleDriver || isAdmin;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isDriver)
                    IconButton(
                      icon: const Icon(Icons.payments),
                      tooltip: 'Mis pagos',
                      onPressed: () => context.go('/my-payments'),
                    ),
                  if (isAdmin || isSuper)
                    IconButton(
                      icon: const Icon(Icons.tune),
                      tooltip: 'Config. cobros',
                      onPressed: () => context.go('/billing-config'),
                    ),
                  if (isAdmin || isSuper)
                    IconButton(
                      icon: const Icon(Icons.people),
                      tooltip: 'Gestionar socios',
                      onPressed: () => context.go('/members'),
                    ),
                  if (isSuper)
                    IconButton(
                      icon: const Icon(Icons.shield),
                      tooltip: 'Panel SaaS',
                      onPressed: () => context.go('/super'),
                    ),
                ],
              );
            },
          ),
          BlocBuilder<AuthBloc, AuthState>(
            builder: (context, state) {
              if (state is! AuthAuthenticated) return const SizedBox();
              if (_isEditing) {
                return Row(
                  children: [
                    TextButton(
                      onPressed: _isSaving
                          ? null
                          : () => setState(() => _isEditing = false),
                      child: const Text('Cancelar',
                          style: TextStyle(color: Colors.white70)),
                    ),
                    TextButton(
                      onPressed: _isSaving
                          ? null
                          : () => _saveProfile(state.user),
                      child: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Guardar',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                    ),
                  ],
                );
              }
              return IconButton(
                icon: const Icon(Icons.edit),
                tooltip: 'Editar perfil',
                onPressed: () => _startEditing(state.user),
              );
            },
          ),
        ],
      ),
      body: BlocConsumer<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is AuthUnauthenticated) {
            context.go('/login');
          } else if (state is AuthProfileUpdated) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Perfil actualizado correctamente'),
                backgroundColor: AppTheme.successColor,
              ),
            );
            // Re-check auth to reload user
            context.read<AuthBloc>().add(AuthCheckRequested());
          }
        },
        builder: (context, state) {
          if (state is! AuthAuthenticated) {
            return const Center(child: CircularProgressIndicator());
          }

          final user = state.user;
          final initials =
              '${user.name.isNotEmpty ? user.name[0] : ''}${user.lastname.isNotEmpty ? user.lastname[0] : ''}'
                  .toUpperCase();

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // Profile header
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppTheme.primaryColor, Color(0xFF1565C0)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 44,
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        child: Text(
                          initials,
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${user.name} ${user.lastname}',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          _roleLabel(user.role),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Datos Personales
                _isEditing
                    ? _buildEditablePersonalCard(user)
                    : _buildInfoCard(
                        context,
                        'Información Personal',
                        [
                          _InfoItem(Icons.person, 'Nombre', '${user.name} ${user.lastname}'),
                          _InfoItem(Icons.badge, 'Cédula', user.cedula),
                          _InfoItem(Icons.email, 'Email', user.email),
                          _InfoItem(Icons.phone, 'Teléfono', user.phone),
                        ],
                      ),

                const SizedBox(height: 12),

                // Datos de Cooperativa y Vehículo
                _isEditing
                    ? _buildEditableCooperativaCard(user)
                    : _buildInfoCard(
                        context,
                        'Cooperativa y Vehículo',
                        [
                          _InfoItem(Icons.business, 'Cooperativa',
                              user.cooperativa.isNotEmpty ? user.cooperativa : 'Sin registrar'),
                          _InfoItem(Icons.qr_code, 'Código Cooperativa',
                              user.codigoCooperativa.isNotEmpty ? user.codigoCooperativa : 'Sin registrar'),
                          _InfoItem(Icons.directions_car, 'Placa',
                              user.placa.isNotEmpty ? user.placa : 'Sin registrar'),
                          _InfoItem(Icons.tag, 'N° Vehículo Red',
                              user.numeroVehiculo.isNotEmpty ? user.numeroVehiculo : 'Sin registrar'),
                        ],
                      ),

                const SizedBox(height: 12),

                // Fotos
                _buildPhotosCard(user),

                const SizedBox(height: 12),

                _buildInfoCard(
                  context,
                  'Estado de Cuenta',
                  [
                    _InfoItem(
                      Icons.verified_user,
                      'Estado',
                      user.isActive ? 'Activo' : 'Inactivo',
                    ),
                    _InfoItem(Icons.security, 'Rol', _roleLabel(user.role)),
                  ],
                ),

                const SizedBox(height: 24),

                // Logout button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Cerrar Sesión'),
                          content: const Text(
                              '¿Estás seguro de que quieres cerrar sesión?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancelar'),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                Navigator.pop(ctx);
                                context
                                    .read<AuthBloc>()
                                    .add(AuthSignOutRequested());
                              },
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.errorColor),
                              child: const Text('Cerrar Sesión',
                                  style: TextStyle(color: Colors.white)),
                            ),
                          ],
                        ),
                      );
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('Cerrar Sesión'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.errorColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // App version
                Text(
                  '${AppConstants.appName} v${AppConstants.appVersion}',
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),

                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildEditablePersonalCard(UserModel user) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Información Personal',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Nombres',
                prefixIcon: Icon(Icons.person_outlined),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _lastnameCtrl,
              decoration: const InputDecoration(
                labelText: 'Apellidos',
                prefixIcon: Icon(Icons.person_outlined),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            // Cédula no editable
            _buildReadOnlyField(Icons.badge, 'Cédula', user.cedula),
            const SizedBox(height: 10),
            // Email no editable  
            _buildReadOnlyField(Icons.email, 'Email', user.email),
            const SizedBox(height: 10),
            TextFormField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Teléfono',
                prefixIcon: Icon(Icons.phone_outlined),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditableCooperativaCard(UserModel user) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Cooperativa y Vehículo',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _cooperativaCtrl,
              decoration: const InputDecoration(
                labelText: 'Cooperativa',
                prefixIcon: Icon(Icons.business_outlined),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _codigoCoopCtrl,
              decoration: const InputDecoration(
                labelText: 'Código de Cooperativa',
                prefixIcon: Icon(Icons.qr_code_outlined),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _placaCtrl,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Placa del Vehículo',
                prefixIcon: Icon(Icons.directions_car_outlined),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _numVehiculoCtrl,
              decoration: const InputDecoration(
                labelText: 'N° Vehículo en la asociación',
                prefixIcon: Icon(Icons.tag),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReadOnlyField(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey[500]),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              Text(value,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
        Icon(Icons.lock, size: 14, color: Colors.grey[400]),
      ],
    );
  }

  Widget _buildPhotosCard(UserModel user) {
    final hasAnyPhoto = user.fotoVehiculo != null ||
        user.fotoLicenciaFrontal != null ||
        user.fotoLicenciaTrasera != null ||
        _isEditing;

    if (!hasAnyPhoto) return const SizedBox();

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Fotografías',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 12),
            // Foto vehículo
            _buildPhotoRow(
              label: 'Vehículo',
              url: user.fotoVehiculo,
              newFile: _newFotoVehiculo,
              onEdit: _isEditing ? () => _pickImage('vehiculo') : null,
            ),
            const SizedBox(height: 8),
            _buildPhotoRow(
              label: 'Licencia Frontal',
              url: user.fotoLicenciaFrontal,
              newFile: _newFotoLicFrontal,
              onEdit: _isEditing ? () => _pickImage('licencia_frontal') : null,
            ),
            const SizedBox(height: 8),
            _buildPhotoRow(
              label: 'Licencia Trasera',
              url: user.fotoLicenciaTrasera,
              newFile: _newFotoLicTrasera,
              onEdit: _isEditing ? () => _pickImage('licencia_trasera') : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoRow({
    required String label,
    required String? url,
    required File? newFile,
    required VoidCallback? onEdit,
  }) {
    final hasImage = newFile != null || (url != null && url.isNotEmpty);

    return InkWell(
      onTap: onEdit ?? (hasImage ? () => _showFullPhoto(context, url, newFile) : null),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Colors.grey[50],
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Row(
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 48,
                height: 48,
                child: newFile != null
                    ? Image.file(newFile, fit: BoxFit.cover)
                    : (url != null && url.isNotEmpty)
                        ? CachedNetworkImage(
                            imageUrl: url,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(
                              color: Colors.grey[200],
                              child: const Icon(Icons.image, size: 20),
                            ),
                            errorWidget: (_, __, ___) => Container(
                              color: Colors.grey[200],
                              child: const Icon(Icons.broken_image, size: 20),
                            ),
                          )
                        : Container(
                            color: Colors.grey[200],
                            child: const Icon(Icons.no_photography,
                                size: 20, color: Colors.grey),
                          ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(
                    hasImage ? 'Foto cargada' : 'Sin foto',
                    style: TextStyle(
                      fontSize: 11,
                      color: hasImage ? AppTheme.successColor : Colors.grey[500],
                    ),
                  ),
                ],
              ),
            ),
            if (onEdit != null)
              Icon(Icons.edit, size: 18, color: AppTheme.primaryColor),
            if (hasImage && onEdit == null)
              Icon(Icons.zoom_in, size: 18, color: Colors.grey[500]),
          ],
        ),
      ),
    );
  }

  void _showFullPhoto(BuildContext context, String? url, File? file) {
    if (file == null && (url == null || url.isEmpty)) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: file != null
              ? Image.file(file, fit: BoxFit.contain)
              : CachedNetworkImage(
                  imageUrl: url!,
                  fit: BoxFit.contain,
                  placeholder: (_, __) =>
                      const Center(child: CircularProgressIndicator()),
                ),
        ),
      ),
    );
  }

  Widget _buildInfoCard(
      BuildContext context, String title, List<_InfoItem> items) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 12),
            ...items.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Icon(item.icon, size: 18, color: AppTheme.primaryColor),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.label,
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[500]),
                            ),
                            Text(
                              item.value,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}

class _InfoItem {
  final IconData icon;
  final String label;
  final String value;
  const _InfoItem(this.icon, this.label, this.value);
}
