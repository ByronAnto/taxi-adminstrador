import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../constants/app_constants.dart';
import '../services/driver_location_service.dart';
import '../theme/app_theme.dart';

/// Switch GENERAL "Activo / Inactivo" del conductor.
///
/// Es un wrapper visible sobre [DriverLocationService] que da al conductor
/// un control prominente en el AppBar para encender/apagar el envío de GPS y
/// la disponibilidad para recibir asignaciones.
///
/// **Diferencia con el toggle del walkie-talkie**:
/// - Este switch controla GPS + disponibilidad para mapas y asignaciones.
/// - El toggle del walkie-talkie controla únicamente Agora + foreground service
///   con `microphone`. Son independientes.
///
/// **Mapeo del estado**:
/// - `drivers/{driverId}.status == 'desconectado'` → switch en OFF (inactivo).
/// - cualquier otro estado (libre, con_pasajero, en_camino_base) → ON (activo).
///
/// Usamos el campo existente `drivers/{driverId}.status` en vez de crear un
/// `users/{uid}.isAvailable` nuevo. Razones: evitar migración, no duplicar
/// fuentes de verdad, no tocar custom claims.
class AvailabilityToggle extends StatefulWidget {
  const AvailabilityToggle({super.key});

  @override
  State<AvailabilityToggle> createState() => _AvailabilityToggleState();
}

class _AvailabilityToggleState extends State<AvailabilityToggle> {
  final _locationService = DriverLocationService.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _locationService.addListener(_onLocationChanged);
  }

  @override
  void dispose() {
    _locationService.removeListener(_onLocationChanged);
    super.dispose();
  }

  void _onLocationChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle(bool turnOn) async {
    if (_busy) return;
    setState(() => _busy = true);
    HapticFeedback.selectionClick();
    try {
      if (turnOn) {
        // Volver a "libre" al re-activar — el conductor luego puede pasar a
        // "con pasajero" desde el diálogo de cambio de estado.
        await _locationService.updateStatus(AppConstants.statusFree);
      } else {
        await _locationService.goOffline();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudo cambiar disponibilidad: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = _locationService.isOnline;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: _busy ? null : () => _toggle(!isOnline),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isOnline
                ? AppTheme.successColor.withValues(alpha: 0.15)
                : Colors.grey.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isOnline
                  ? AppTheme.successColor.withValues(alpha: 0.5)
                  : Colors.grey.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  isOnline ? Icons.circle : Icons.power_settings_new,
                  size: 12,
                  color: isOnline ? AppTheme.successColor : Colors.grey.shade700,
                ),
              const SizedBox(width: 6),
              Text(
                isOnline ? 'Activo' : 'Inactivo',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isOnline ? AppTheme.successColor : Colors.grey.shade800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
