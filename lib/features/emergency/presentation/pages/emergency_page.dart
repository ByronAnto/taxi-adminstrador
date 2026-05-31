import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/services/current_user_context.dart';
import '../../../../core/services/driver_location_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/emergency_model.dart';
import '../bloc/emergency_bloc.dart';

/// Página de emergencia con botón de pánico SOS
class EmergencyPage extends StatefulWidget {
  const EmergencyPage({super.key});

  @override
  State<EmergencyPage> createState() => _EmergencyPageState();
}

class _EmergencyPageState extends State<EmergencyPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  /// Teléfono de la "Central" (la asociación). Se carga del doc de la
  /// asociación; si no hay número, el botón/ contacto "Central" se oculta.
  String? _centralPhone;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Check for existing active emergency
    final authState = context.read<AuthBloc>().state;
    if (authState is AuthAuthenticated) {
      context
          .read<EmergencyBloc>()
          .add(EmergencyCheckActiveRequested(authState.user.uid));
    }

    _loadCentralPhone();
  }

  /// Lee el teléfono de la asociación (`associations/{aid}.phone`) para el
  /// botón "Llamar Central". Si no existe, [_centralPhone] queda null y el
  /// botón/contacto se oculta (no dejamos acciones muertas).
  Future<void> _loadCentralPhone() async {
    final aid = CurrentUserContext.instance.associationId;
    if (aid == null || aid.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .get();
      final phone = (doc.data()?['phone'] as String?)?.trim();
      if (mounted && phone != null && phone.isNotEmpty) {
        setState(() => _centralPhone = phone);
      }
    } catch (e) {
      debugPrint('🚨 [EmergencyPage] No se pudo cargar tel. central: $e');
    }
  }

  /// Lanza el marcador del teléfono con el número dado.
  Future<void> _dial(String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    try {
      await launchUrl(uri);
    } catch (e) {
      debugPrint('🚨 [EmergencyPage] No se pudo abrir marcador ($number): $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudo llamar al $number'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  bool _isAlertActive(EmergencyState state) {
    if (state is EmergencyLoaded && state.myActiveEmergency != null) {
      return true;
    }
    return false;
  }

  Future<void> _activateSOS() async {
    final authState = context.read<AuthBloc>().state;
    if (authState is! AuthAuthenticated) return;

    final user = authState.user;

    // Ubicación real del dispositivo. NUNCA bloqueamos el SOS por el GPS:
    // si no logramos un fix usamos (0,0) como "desconocida" (el modelo lo
    // trata igual que un doc sin coords) y la alerta se dispara de todos
    // modos. La central recibe el aviso aunque no haya posición.
    final coords = await _resolveSosCoordinates();

    if (!mounted) return;

    final emergency = EmergencyModel(
      uid: const Uuid().v4(),
      driverId: user.uid,
      driverName: '${user.name} ${user.lastname}',
      latitude: coords?.$1 ?? 0,
      longitude: coords?.$2 ?? 0,
      status: 'active',
      createdAt: DateTime.now(),
    );

    if (!context.mounted) return;
    context.read<EmergencyBloc>().add(EmergencyCreateRequested(emergency));
  }

  /// Obtiene la mejor ubicación disponible para la alerta:
  /// 1. La última posición conocida del [DriverLocationService] (ya activo
  ///    para conductores con GPS encendido — instantáneo).
  /// 2. Si no hay, un fix en vivo de [Geolocator] con timeout corto.
  /// Devuelve null si no se puede obtener ninguna (sin bloquear el SOS).
  Future<(double, double)?> _resolveSosCoordinates() async {
    final loc = DriverLocationService.instance;
    if (loc.lastLatitude != null && loc.lastLongitude != null) {
      return (loc.lastLatitude!, loc.lastLongitude!);
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return (pos.latitude, pos.longitude);
    } catch (e) {
      debugPrint('🚨 [EmergencyPage] No se pudo obtener GPS para SOS: $e');
      return null;
    }
  }

  void _cancelSOS(EmergencyModel active) {
    context.read<EmergencyBloc>().add(EmergencyCancelRequested(active.uid));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Emergencia'),
        backgroundColor: AppTheme.errorColor,
        foregroundColor: Colors.white,
      ),
      body: BlocConsumer<EmergencyBloc, EmergencyState>(
        listener: (context, state) {
          if (state is EmergencyActionSuccess) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: AppTheme.successColor,
              ),
            );
            // Refresh active check
            final authState = context.read<AuthBloc>().state;
            if (authState is AuthAuthenticated) {
              context
                  .read<EmergencyBloc>()
                  .add(EmergencyCheckActiveRequested(authState.user.uid));
            }
          }
          if (state is EmergencyError) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: AppTheme.errorColor,
              ),
            );
          }
        },
        builder: (context, state) {
          final alertActive = _isAlertActive(state);
          final activeEmergency = state is EmergencyLoaded
              ? state.myActiveEmergency
              : null;

          return Container(
            decoration: BoxDecoration(
              gradient: alertActive
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFFB71C1C), Color(0xFF1A1A2E)],
                    )
                  : const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF1A1A2E), Color(0xFF16213E)],
                    ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 24),

                  // Status indicator
                  if (alertActive)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 24),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: Colors.red.withValues(alpha: 0.5)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.warning, color: Colors.red, size: 28),
                          SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'ALERTA ACTIVA',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                Text(
                                  'Se ha enviado tu ubicación a la central',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                  const Spacer(),

                  // SOS Button
                  Center(
                    child: GestureDetector(
                      onLongPress: () {
                        if (alertActive && activeEmergency != null) {
                          _cancelSOS(activeEmergency);
                        } else {
                          _activateSOS();
                        }
                      },
                      child: AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, child) {
                          final scale =
                              alertActive ? _pulseAnimation.value : 1.0;
                          return Transform.scale(
                            scale: scale,
                            child: Container(
                              width: 180,
                              height: 180,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: alertActive
                                    ? Colors.red
                                    : AppTheme.errorColor,
                                boxShadow: [
                                  BoxShadow(
                                    color: (alertActive
                                            ? Colors.red
                                            : AppTheme.errorColor)
                                        .withValues(alpha: 0.4),
                                    blurRadius: alertActive ? 40 : 20,
                                    spreadRadius: alertActive ? 8 : 4,
                                  ),
                                ],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    alertActive
                                        ? Icons.close
                                        : Icons.sos,
                                    size: 56,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    alertActive ? 'CANCELAR' : 'SOS',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),
                  Text(
                    alertActive
                        ? 'Mantén presionado para CANCELAR'
                        : 'Mantén presionado para activar',
                    style: const TextStyle(color: Colors.white60, fontSize: 14),
                  ),

                  const Spacer(),

                  // Location sharing
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          alertActive
                              ? Icons.location_on
                              : Icons.location_off,
                          color: alertActive ? Colors.green : Colors.white38,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            alertActive
                                ? 'Compartiendo ubicación en tiempo real'
                                : 'Ubicación se compartirá al activar SOS',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Quick actions — números de emergencia de Ecuador (911).
                  // "Central" solo aparece si la asociación tiene teléfono.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      children: [
                        if (_centralPhone != null) ...[
                          Expanded(
                            child: _buildQuickAction(
                              Icons.phone,
                              'Llamar\nCentral',
                              Colors.blue,
                              () => _dial(_centralPhone!),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: _buildQuickAction(
                            Icons.local_police,
                            'Llamar\nPolicía',
                            Colors.orange,
                            () => _dial('911'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildQuickAction(
                            Icons.local_hospital,
                            'Llamar\nAmbulancia',
                            Colors.red,
                            () => _dial('911'),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Emergency contacts
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Contactos de Emergencia',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (_centralPhone != null)
                          _buildContact('Central de Radio', _centralPhone!),
                        _buildContact('ECU 911', '911'),
                        _buildContact('Policía Nacional', '101'),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildQuickAction(
      IconData icon, String label, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(color: color, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContact(String name, String number) {
    return InkWell(
      onTap: () => _dial(number),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.phone, color: Colors.white38, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(name,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ),
            Text(number,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
            const SizedBox(width: 6),
            const Icon(Icons.call, color: Colors.white38, size: 14),
          ],
        ),
      ),
    );
  }
}
