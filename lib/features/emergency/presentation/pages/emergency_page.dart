import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/constants/app_constants.dart';
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

  void _activateSOS() {
    final authState = context.read<AuthBloc>().state;
    if (authState is! AuthAuthenticated) return;

    final user = authState.user;
    final emergency = EmergencyModel(
      uid: const Uuid().v4(),
      driverId: user.uid,
      driverName: '${user.name} ${user.lastname}',
      latitude: AppConstants.baseLatitude,
      longitude: AppConstants.baseLongitude,
      status: 'active',
      createdAt: DateTime.now(),
    );

    context.read<EmergencyBloc>().add(EmergencyCreateRequested(emergency));
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

                  // Quick actions
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      children: [
                        Expanded(
                          child: _buildQuickAction(
                            Icons.phone,
                            'Llamar\nCentral',
                            Colors.blue,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildQuickAction(
                            Icons.local_police,
                            'Llamar\nPolicía',
                            Colors.orange,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildQuickAction(
                            Icons.local_hospital,
                            'Llamar\nAmbulancia',
                            Colors.red,
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
                        _buildContact('Central de Radio', '02-234-5678'),
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

  Widget _buildQuickAction(IconData icon, String label, Color color) {
    return Container(
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
    );
  }

  Widget _buildContact(String name, String number) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
        ],
      ),
    );
  }
}
