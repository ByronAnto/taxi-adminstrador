import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../bloc/auth_bloc.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/app_scaffold.dart';

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
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return AppScaffold(
      title: 'Crear Cuenta',
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
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Icono
                CircleAvatar(
                  radius: 40,
                  backgroundColor: colorScheme.primary,
                  child: Icon(
                    Icons.person_add,
                    size: 40,
                    color: colorScheme.secondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Registro de Conductor / Operadora',
                  textAlign: TextAlign.center,
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.secondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),

                // ============ SECCIÓN: ASOCIACIÓN ============
                _buildSectionHeader(context, 'Tu Asociación'),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Pídele a tu administrador el código de la asociación '
                  '(ej. JIPI, ROLD).',
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: AppSpacing.md),
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
                                  ? SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: colorScheme.onPrimary),
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
                  const SizedBox(height: AppSpacing.md),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.md),
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
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _validatedAssociation!['name'] ?? '',
                                style: textTheme.titleMedium,
                              ),
                              Text(
                                '${_validatedAssociation!['city'] ?? ''} · '
                                'código ${_validatedAssociation!['code'] ?? ''}',
                                style: textTheme.bodySmall
                                    ?.copyWith(color: AppTheme.textSecondary),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                'Tu cuenta quedará pendiente hasta que el '
                                'administrador la apruebe.',
                                style: textTheme.labelSmall?.copyWith(
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
                const SizedBox(height: AppSpacing.xl),

                // ============ SECCIÓN: DATOS PERSONALES ============
                _buildSectionHeader(context, 'Datos Personales'),
                const SizedBox(height: AppSpacing.md),

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
                const SizedBox(height: AppSpacing.lg),

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
                const SizedBox(height: AppSpacing.lg),

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
                const SizedBox(height: AppSpacing.lg),

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
                const SizedBox(height: AppSpacing.lg),

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
                const SizedBox(height: AppSpacing.lg),

                // Rol
                DropdownButtonFormField<String>(
                  initialValue: _selectedRole,
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
                        }
                      });
                    }
                  },
                ),
                const SizedBox(height: AppSpacing.xl),

                // Las secciones de Cooperativa, Vehículo y Fotos solo
                // aplican a conductores. Las operadoras no manejan
                // vehículo, así que se ocultan completamente.
                if (_selectedRole == AppConstants.roleDriver) ...[
                // ============ SECCIÓN: DATOS DE COOPERATIVA ============
                _buildSectionHeader(context, 'Datos de Cooperativa y Vehículo'),
                const SizedBox(height: AppSpacing.md),

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
                const SizedBox(height: AppSpacing.lg),

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
                const SizedBox(height: AppSpacing.lg),

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
                const SizedBox(height: AppSpacing.lg),

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
                const SizedBox(height: AppSpacing.xl),

                // Aviso: las fotos del vehículo y licencia se piden DESPUÉS
                // de crear la cuenta, en la pantalla "Completar registro".
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: AppTheme.infoColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppTheme.infoColor.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline,
                          color: AppTheme.infoColor, size: 20),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Después de crear tu cuenta te pediremos las fotos '
                          'del vehículo y de tu licencia.',
                          style: textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                ], // fin de la sección solo para conductores

                // ============ SECCIÓN: CONTRASEÑA ============
                _buildSectionHeader(context, 'Credenciales de Acceso'),
                const SizedBox(height: AppSpacing.md),

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
                const SizedBox(height: AppSpacing.lg),

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
                const SizedBox(height: AppSpacing.xxl),

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
                                  SizedBox(
                                    height: 22,
                                    width: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: colorScheme.onPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.md),
                                  Text(
                                    _isUploading ? 'Subiendo fotos...' : 'Creando cuenta...',
                                    style: textTheme.bodyMedium,
                                  ),
                                ],
                              )
                            : const Text('CREAR CUENTA'),
                      ),
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('¿Ya tienes cuenta? '),
                    TextButton(
                      onPressed: () => context.pop(),
                      child: Text(
                        'Iniciar sesión',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.secondary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.secondary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: colorScheme.secondary, width: 3),
        ),
      ),
      child: Text(
        title,
        style: textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
          color: colorScheme.secondary,
        ),
      ),
    );
  }
}
