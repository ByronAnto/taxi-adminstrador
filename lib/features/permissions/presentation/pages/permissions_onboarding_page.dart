import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/theme/app_theme.dart';

/// Página de onboarding de permisos estilo inDriver.
///
/// Reemplaza el pedido "silencioso" en ráfaga (StartupPermissions.requestAll),
/// que fallaba por:
/// - colisión de permission_handler ("request already running") al disparar
///   varios pedidos casi simultáneos,
/// - MIUI/algunas ROMs bloquean diálogos que no nacen de un gesto del usuario,
/// - como efecto, el micrófono nunca llegaba a pedirse.
///
/// Aquí cada permiso se solicita de a UNO, disparado por el botón "Permitir"
/// (user-driven) → sin colisiones. Los estados se refrescan al volver de
/// ajustes (didChangeAppLifecycleState.resumed). "Continuar" se habilita solo
/// cuando los REQUERIDOS (micrófono + ubicación en uso + notificaciones) están
/// concedidos.
class PermissionsOnboardingPage extends StatefulWidget {
  const PermissionsOnboardingPage({super.key});

  @override
  State<PermissionsOnboardingPage> createState() =>
      _PermissionsOnboardingPageState();
}

/// Identificadores internos de cada permiso de la lista.
enum _PermId {
  microphone,
  location,
  notification,
  battery,
  overlay,
  bluetooth,
}

/// Estado en vivo de un permiso: concedido / pendiente / denegado permanente.
enum _PermState { granted, pending, permanentlyDenied }

class _PermissionsOnboardingPageState extends State<PermissionsOnboardingPage>
    with WidgetsBindingObserver {
  /// Estado actual de cada permiso. Se rellena en initState y se refresca
  /// al volver de ajustes.
  final Map<_PermId, _PermState> _states = {
    for (final id in _PermId.values) id: _PermState.pending,
  };

  /// Evita disparar dos solicitudes a la vez (defensa extra anti-colisión).
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al volver de Ajustes (o de cualquier pausa) refrescamos para reflejar
    // lo que el usuario haya cambiado fuera de la app.
    if (state == AppLifecycleState.resumed) {
      _refreshAll();
    }
  }

  // ───────────────────────── Lectura de estados ─────────────────────────

  Future<void> _refreshAll() async {
    final next = <_PermId, _PermState>{};
    for (final id in _PermId.values) {
      next[id] = await _readState(id);
    }
    if (!mounted) return;
    setState(() {
      _states
        ..clear()
        ..addAll(next);
    });
  }

  Future<_PermState> _readState(_PermId id) async {
    switch (id) {
      case _PermId.microphone:
        return _fromStatus(await Permission.microphone.status);
      case _PermId.location:
        // Para los requeridos basta "en uso"; el background (locationAlways)
        // se intenta tras conceder el en-uso, pero no bloquea el Continuar.
        return _fromStatus(await Permission.locationWhenInUse.status);
      case _PermId.notification:
        return _fromStatus(await Permission.notification.status);
      case _PermId.battery:
        final ignoring =
            await FlutterForegroundTask.isIgnoringBatteryOptimizations;
        return ignoring ? _PermState.granted : _PermState.pending;
      case _PermId.overlay:
        return _fromStatus(await Permission.systemAlertWindow.status);
      case _PermId.bluetooth:
        return _fromStatus(await Permission.bluetoothConnect.status);
    }
  }

  _PermState _fromStatus(PermissionStatus status) {
    if (status.isGranted || status.isLimited) return _PermState.granted;
    if (status.isPermanentlyDenied) return _PermState.permanentlyDenied;
    return _PermState.pending;
  }

  // ───────────────────────── Solicitud de permisos ─────────────────────────

  /// Solicita SOLO el permiso indicado (uno a la vez → sin colisión).
  Future<void> _request(_PermId id) async {
    if (_requesting) return;
    _requesting = true;
    try {
      // Si quedó denegado permanentemente, el botón abre ajustes.
      if (_states[id] == _PermState.permanentlyDenied) {
        await openAppSettings();
        return; // El refresh real ocurre en resumed.
      }

      switch (id) {
        case _PermId.microphone:
          await Permission.microphone.request();
          break;
        case _PermId.location:
          final loc = await Permission.locationWhenInUse.request();
          // Solo si concedió "en uso" pedimos el background (Android lo
          // exige en ese orden). No bloquea el Continuar si lo rechaza.
          if (loc.isGranted) {
            await Permission.locationAlways.request();
          }
          break;
        case _PermId.notification:
          await Permission.notification.request();
          break;
        case _PermId.battery:
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
          break;
        case _PermId.overlay:
          await Permission.systemAlertWindow.request();
          break;
        case _PermId.bluetooth:
          await Permission.bluetoothConnect.request();
          break;
      }

      // Releemos solo este permiso (rápido) y, por si Android cambió otro,
      // dejamos que el resumed haga el refresh completo.
      final newState = await _readState(id);
      if (!mounted) return;
      setState(() => _states[id] = newState);
    } catch (e) {
      // Una colisión puntual no debe romper la pantalla; el usuario reintenta.
      debugPrint('PermissionsOnboarding[$id]: $e');
    } finally {
      _requesting = false;
    }
  }

  // ───────────────────────── Gating de "Continuar" ─────────────────────────

  bool get _requiredGranted =>
      _states[_PermId.microphone] == _PermState.granted &&
      _states[_PermId.location] == _PermState.granted &&
      _states[_PermId.notification] == _PermState.granted;

  void _continue() {
    if (!_requiredGranted) return;
    context.go('/home');
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      _PermissionCard(
        icon: Icons.mic,
        title: 'Micrófono',
        subtitle: 'Para hablar por el radio.',
        required: true,
        state: _states[_PermId.microphone]!,
        onRequest: () => _request(_PermId.microphone),
      ),
      _PermissionCard(
        icon: Icons.location_on,
        title: 'Ubicación',
        subtitle:
            'Para que la operadora vea tu unidad (incluso en segundo plano).',
        required: true,
        state: _states[_PermId.location]!,
        onRequest: () => _request(_PermId.location),
      ),
      _PermissionCard(
        icon: Icons.notifications,
        title: 'Notificaciones',
        subtitle: 'Para avisos y el servicio en segundo plano.',
        required: true,
        state: _states[_PermId.notification]!,
        onRequest: () => _request(_PermId.notification),
      ),
      _PermissionCard(
        icon: Icons.battery_charging_full,
        title: 'Batería sin restricciones',
        subtitle: 'Para que el radio/ubicación no se corten.',
        required: false,
        state: _states[_PermId.battery]!,
        onRequest: () => _request(_PermId.battery),
      ),
      _PermissionCard(
        icon: Icons.picture_in_picture_alt,
        title: 'Mostrar sobre otras apps',
        subtitle: 'Para el botón flotante de hablar.',
        required: false,
        state: _states[_PermId.overlay]!,
        onRequest: () => _request(_PermId.overlay),
      ),
      _PermissionCard(
        icon: Icons.bluetooth,
        title: 'Bluetooth',
        subtitle: 'Para audífonos / manos libres.',
        required: false,
        state: _states[_PermId.bluetooth]!,
        onRequest: () => _request(_PermId.bluetooth),
      ),
    ];

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Encabezado
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppTheme.primaryColor,
                    AppTheme.primaryColor.withValues(alpha: 0.8),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.verified_user,
                      size: 40, color: AppTheme.onPrimaryColor),
                  const SizedBox(height: 12),
                  const Text(
                    'Permisos necesarios',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.onPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Para que el radio y la ubicación funcionen, concede los '
                    'permisos de abajo. Los marcados como requeridos son '
                    'indispensables.',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.onPrimaryColor.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
            // Lista de tarjetas
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: cards.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, i) => cards[i],
              ),
            ),
            // Pie con acciones
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final canContinue = _requiredGranted;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: canContinue ? _continue : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: AppTheme.onPrimaryColor,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  disabledBackgroundColor: Colors.grey.shade300,
                ),
                child: Text(
                  canContinue
                      ? 'Continuar'
                      : 'Concede los permisos requeridos',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => context.go('/home'),
              child: const Text(
                'Omitir por ahora',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tarjeta individual de permiso: ícono, título, "para qué", estado en vivo
/// y botón de acción ("Permitir" / "Abrir ajustes").
class _PermissionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool required;
  final _PermState state;
  final VoidCallback onRequest;

  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.required,
    required this.state,
    required this.onRequest,
  });

  @override
  Widget build(BuildContext context) {
    final granted = state == _PermState.granted;
    final permanentlyDenied = state == _PermState.permanentlyDenied;

    return Material(
      color: Colors.white,
      elevation: 1.5,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // Ícono
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: (granted ? AppTheme.successColor : AppTheme.secondaryColor)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                color: granted ? AppTheme.successColor : AppTheme.secondaryColor,
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
            // Texto + estado
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (required)
                        _Badge(
                          text: 'Requerido',
                          color: AppTheme.errorColor,
                        )
                      else
                        _Badge(
                          text: 'Opcional',
                          color: AppTheme.textSecondary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _statusRow(granted),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Botón de acción
            if (!granted)
              SizedBox(
                child: ElevatedButton(
                  onPressed: onRequest,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: AppTheme.onPrimaryColor,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: Text(
                    permanentlyDenied ? 'Abrir ajustes' : 'Permitir',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusRow(bool granted) {
    if (granted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.check_circle, size: 16, color: AppTheme.successColor),
          SizedBox(width: 4),
          Text(
            'Concedido',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppTheme.successColor,
            ),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.radio_button_unchecked,
            size: 16, color: Colors.grey.shade500),
        const SizedBox(width: 4),
        Text(
          'Pendiente',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }
}

/// Etiqueta pequeña "Requerido" / "Opcional".
class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}
