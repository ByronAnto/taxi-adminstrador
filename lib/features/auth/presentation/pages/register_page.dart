import 'dart:io';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../bloc/auth_bloc.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/image_upload_service.dart';

/// Página de registro de nuevo usuario con campos completos de conductor
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _lastnameController = TextEditingController();
  final _cedulaController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _placaController = TextEditingController();
  final _cooperativaController = TextEditingController();
  final _codigoCooperativaController = TextEditingController();
  final _numeroVehiculoController = TextEditingController();
  final _associationCodeController = TextEditingController();

  String _selectedRole = AppConstants.roleDriver;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isUploading = false;

  /// Datos resueltos de la asociación tras llamar `validateAssociationCode`.
  /// Si es null, el usuario aún no validó su código y no se le permite registrarse.
  Map<String, dynamic>? _validatedAssociation;
  bool _validatingCode = false;

  // Fotos
  File? _fotoVehiculo;
  File? _fotoLicenciaFrontal;
  File? _fotoLicenciaTrasera;

  final _imageService = ImageUploadService();

  @override
  void dispose() {
    _nameController.dispose();
    _lastnameController.dispose();
    _cedulaController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _placaController.dispose();
    _cooperativaController.dispose();
    _codigoCooperativaController.dispose();
    _numeroVehiculoController.dispose();
    _associationCodeController.dispose();
    super.dispose();
  }

  /// Llama Cloud Function `validateAssociationCode` con el código que
  /// escribió el conductor. Si OK, guarda los datos de la asociación
  /// y los muestra para que confirme antes de seguir.
  Future<void> _verifyAssociationCode() async {
    final code = _associationCodeController.text.trim();
    if (code.length < 3) {
      _showError('Ingresa el código de tu asociación.');
      return;
    }

    setState(() {
      _validatingCode = true;
      _validatedAssociation = null;
    });

    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('validateAssociationCode')
          .call({'code': code});
      setState(() {
        _validatedAssociation = Map<String, dynamic>.from(result.data as Map);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Asociación encontrada: ${_validatedAssociation!['name']}'),
            backgroundColor: AppTheme.successColor,
          ),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      String message;
      switch (e.code) {
        case 'not-found':
          message = 'Código no encontrado. Verifica con tu administrador.';
          break;
        case 'failed-precondition':
          message = e.message ?? 'Esta asociación no está activa.';
          break;
        default:
          message = e.message ?? 'Error: ${e.code}';
      }
      _showError(message);
    } catch (e) {
      _showError('Error de conexión: $e');
    } finally {
      if (mounted) setState(() => _validatingCode = false);
    }
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
            _fotoVehiculo = file;
            break;
          case 'licencia_frontal':
            _fotoLicenciaFrontal = file;
            break;
          case 'licencia_trasera':
            _fotoLicenciaTrasera = file;
            break;
        }
      });
    }
  }

  Future<void> _submitForm() async {
    if (!_formKey.currentState!.validate()) return;

    final validated = _validatedAssociation;
    if (validated == null) {
      _showError('Verifica el código de tu asociación antes de continuar.');
      return;
    }

    setState(() => _isUploading = true);

    // El registro NO sube fotos. Las fotos se suben después del login,
    // en la pantalla "Completar registro" (cuando ya hay sesión Auth y
    // las reglas de Storage validan al usuario). Esto evita el error
    // 403 de Storage que ocurre al subir sin estar autenticado.
    try {
      if (!mounted) return;

      final cedula = _cedulaController.text.trim();

      context.read<AuthBloc>().add(
            AuthSignUpRequested(
              email: _emailController.text.trim(),
              password: _passwordController.text,
              name: _nameController.text.trim(),
              lastname: _lastnameController.text.trim(),
              cedula: cedula,
              phone: _phoneController.text.trim(),
              role: _selectedRole,
              associationId: validated['associationId'] as String,
              requiresApproval: true,
              placa: _placaController.text.trim().toUpperCase(),
              cooperativa: _cooperativaController.text.trim(),
              codigoCooperativa: _codigoCooperativaController.text.trim(),
              numeroVehiculo: _numeroVehiculoController.text.trim(),
              fotoVehiculo: null,
              fotoLicenciaFrontal: null,
              fotoLicenciaTrasera: null,
            ),
          );
    } catch (e) {
      if (mounted) {
        _showError('Error al crear cuenta: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.errorColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crear Cuenta'),
      ),
      body: BlocListener<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is AuthError) {
            setState(() => _isUploading = false);
            _showError(state.message);
          } else if (state is AuthAuthenticated) {
            context.go('/home');
          }
        },
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Icono
                const CircleAvatar(
                  radius: 40,
                  backgroundColor: AppTheme.primaryColor,
                  child: Icon(
                    Icons.person_add,
                    size: 40,
                    color: AppTheme.secondaryColor,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Registro de Conductor / Operadora',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryColor,
                  ),
                ),
                const SizedBox(height: 24),

                // ============ SECCIÓN: ASOCIACIÓN ============
                _buildSectionHeader('Tu Asociación'),
                const SizedBox(height: 8),
                const Text(
                  'Pídele a tu administrador el código de la asociación '
                  '(ej. JIPI, ROLD).',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _associationCodeController,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[a-zA-Z0-9]')),
                          LengthLimitingTextInputFormatter(10),
                        ],
                        enabled: _validatedAssociation == null &&
                            !_validatingCode &&
                            !_isUploading,
                        decoration: const InputDecoration(
                          labelText: 'Código *',
                          prefixIcon: Icon(Icons.qr_code_2),
                          hintText: 'JIPI',
                        ),
                        validator: (v) {
                          if (_validatedAssociation == null) {
                            return 'Verifica el código primero';
                          }
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 56,
                      child: _validatedAssociation == null
                          ? ElevatedButton(
                              onPressed:
                                  _validatingCode ? null : _verifyAssociationCode,
                              child: _validatingCode
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Text('Verificar'),
                            )
                          : OutlinedButton.icon(
                              onPressed: _isUploading
                                  ? null
                                  : () => setState(() {
                                        _validatedAssociation = null;
                                        _associationCodeController.clear();
                                      }),
                              icon: const Icon(Icons.close, size: 18),
                              label: const Text('Cambiar'),
                            ),
                    ),
                  ],
                ),
                if (_validatedAssociation != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.successColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppTheme.successColor.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle,
                            color: AppTheme.successColor),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _validatedAssociation!['name'] ?? '',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),
                              Text(
                                '${_validatedAssociation!['city'] ?? ''} · '
                                'código ${_validatedAssociation!['code'] ?? ''}',
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Tu cuenta quedará pendiente hasta que el '
                                'administrador la apruebe.',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                    color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),

                // ============ SECCIÓN: DATOS PERSONALES ============
                _buildSectionHeader('Datos Personales'),
                const SizedBox(height: 12),

                // Nombres completos
                TextFormField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Nombres *',
                    prefixIcon: Icon(Icons.person_outlined),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Ingresa tus nombres';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // Apellidos
                TextFormField(
                  controller: _lastnameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Apellidos *',
                    prefixIcon: Icon(Icons.person_outlined),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Ingresa tus apellidos';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // Cédula
                TextFormField(
                  controller: _cedulaController,
                  keyboardType: TextInputType.number,
                  maxLength: 10,
                  decoration: const InputDecoration(
                    labelText: 'Cédula de identidad *',
                    prefixIcon: Icon(Icons.badge_outlined),
                    counterText: '',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Ingresa tu cédula';
                    }
                    if (value.length != 10) {
                      return 'La cédula debe tener 10 dígitos';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // Email
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Correo electrónico *',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Ingresa tu correo electrónico';
                    }
                    if (!value.contains('@')) {
                      return 'Ingresa un correo válido';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // Teléfono
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  maxLength: 10,
                  decoration: const InputDecoration(
                    labelText: 'Teléfono *',
                    prefixIcon: Icon(Icons.phone_outlined),
                    counterText: '',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Ingresa tu teléfono';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // Rol
                DropdownButtonFormField<String>(
                  value: _selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'Tipo de cuenta *',
                    prefixIcon: Icon(Icons.work_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: AppConstants.roleDriver,
                      child: Text('Conductor'),
                    ),
                    DropdownMenuItem(
                      value: AppConstants.roleOperator,
                      child: Text('Operadora'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _selectedRole = value;
                        // Si cambia a operadora, limpiar campos de
                        // vehículo y fotos para evitar que datos
                        // residuales se envíen.
                        if (value != AppConstants.roleDriver) {
                          _cooperativaController.clear();
                          _codigoCooperativaController.clear();
                          _placaController.clear();
                          _numeroVehiculoController.clear();
                          _fotoVehiculo = null;
                          _fotoLicenciaFrontal = null;
                          _fotoLicenciaTrasera = null;
                        }
                      });
                    }
                  },
                ),
                const SizedBox(height: 24),

                // Las secciones de Cooperativa, Vehículo y Fotos solo
                // aplican a conductores. Las operadoras no manejan
                // vehículo, así que se ocultan completamente.
                if (_selectedRole == AppConstants.roleDriver) ...[
                // ============ SECCIÓN: DATOS DE COOPERATIVA ============
                _buildSectionHeader('Datos de Cooperativa y Vehículo'),
                const SizedBox(height: 12),

                // Cooperativa
                TextFormField(
                  controller: _cooperativaController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Cooperativa *',
                    prefixIcon: Icon(Icons.business_outlined),
                    hintText: 'Nombre de la cooperativa',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Ingresa el nombre de la cooperativa';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // Código de cooperativa
                TextFormField(
                  controller: _codigoCooperativaController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Código de Cooperativa *',
                    prefixIcon: Icon(Icons.qr_code_outlined),
                    hintText: 'Código asignado',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Ingresa el código de cooperativa';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // Placa
                TextFormField(
                  controller: _placaController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Placa del vehículo *',
                    prefixIcon: Icon(Icons.directions_car_outlined),
                    hintText: 'Ej: ABC-1234',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Ingresa la placa del vehículo';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // Número de vehículo en la red de Jipijapa
                TextFormField(
                  controller: _numeroVehiculoController,
                  keyboardType: TextInputType.text,
                  decoration: const InputDecoration(
                    labelText: 'N° Vehículo en la asociación *',
                    prefixIcon: Icon(Icons.tag),
                    hintText: 'Identificador del grupo',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Ingresa el número de vehículo';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 24),

                // Aviso: las fotos del vehículo y licencia se piden DESPUÉS
                // de crear la cuenta, en la pantalla "Completar registro".
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline,
                          color: Colors.blue.shade700, size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Después de crear tu cuenta te pediremos las fotos '
                          'del vehículo y de tu licencia.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                ], // fin de la sección solo para conductores

                // ============ SECCIÓN: CONTRASEÑA ============
                _buildSectionHeader('Credenciales de Acceso'),
                const SizedBox(height: 12),

                // Contraseña
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Contraseña *',
                    prefixIcon: const Icon(Icons.lock_outlined),
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Ingresa una contraseña';
                    }
                    if (value.length < 6) {
                      return 'La contraseña debe tener al menos 6 caracteres';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // Confirmar contraseña
                TextFormField(
                  controller: _confirmPasswordController,
                  obscureText: _obscureConfirmPassword,
                  decoration: InputDecoration(
                    labelText: 'Confirmar contraseña *',
                    prefixIcon: const Icon(Icons.lock_outlined),
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() {
                          _obscureConfirmPassword = !_obscureConfirmPassword;
                        });
                      },
                      icon: Icon(
                        _obscureConfirmPassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                    ),
                  ),
                  validator: (value) {
                    if (value != _passwordController.text) {
                      return 'Las contraseñas no coinciden';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 32),

                // ============ BOTÓN CREAR CUENTA ============
                BlocBuilder<AuthBloc, AuthState>(
                  builder: (context, state) {
                    final isLoading = state is AuthLoading || _isUploading;
                    final missingAssociation = _validatedAssociation == null;
                    return SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        onPressed: (isLoading || missingAssociation)
                            ? null
                            : _submitForm,
                        child: isLoading
                            ? Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(
                                    height: 22,
                                    width: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.black,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    _isUploading ? 'Subiendo fotos...' : 'Creando cuenta...',
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ],
                              )
                            : const Text('CREAR CUENTA'),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('¿Ya tienes cuenta? '),
                    TextButton(
                      onPressed: () => context.pop(),
                      child: const Text(
                        'Iniciar sesión',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: AppTheme.secondaryColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.primaryColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: AppTheme.primaryColor, width: 3),
        ),
      ),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: AppTheme.primaryColor,
        ),
      ),
    );
  }

  Widget _buildPhotoPicker({
    required String label,
    required IconData icon,
    required File? file,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: file != null ? 200 : 100,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: file != null ? AppTheme.successColor : Colors.grey[400]!,
            width: file != null ? 2 : 1,
          ),
          color: file != null ? null : Colors.grey[50],
        ),
        child: file != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Image.file(
                      file,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(
                        Icons.check_circle,
                        color: Colors.greenAccent,
                        size: 22,
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 6, horizontal: 12),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.only(
                          bottomLeft: Radius.circular(11),
                          bottomRight: Radius.circular(11),
                        ),
                      ),
                      child: Text(
                        '$label  ✓  Toca para cambiar',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 32, color: Colors.grey[500]),
                  const SizedBox(width: 12),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[700],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Toca para tomar o seleccionar foto',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Icon(Icons.add_a_photo, size: 24, color: AppTheme.primaryColor),
                ],
              ),
      ),
    );
  }
}
