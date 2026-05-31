import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/services/radio_power_service.dart';
import '../../../../core/services/voice/voice_provider_factory.dart';
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
      // Red de seguridad: al volver del diálogo limpiamos el flag sí o sí, así
      // los botones nunca quedan muertos aunque un Future de request se haya
      // perdido (bug de permission_handler) y el `finally` no haya corrido.
      _requesting = false;
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

      // Cada request lleva un .timeout: permission_handler tiene un bug conocido
      // donde el Future del diálogo queda colgado si el diálogo se interrumpe
      // (cambio de app, ROM agresiva, etc.). Sin el timeout el `finally` nunca
      // corre → `_requesting` queda en true → todos los botones mueren ("se
      // cachea, toca reiniciar"). El onTimeout devuelve un valor por defecto
      // para que el await SIEMPRE termine; el estado real se relee igual en
      // resumed.
      const reqTimeout = Duration(seconds: 30);
      switch (id) {
        case _PermId.microphone:
          await Permission.microphone.request().timeout(
                reqTimeout,
                onTimeout: () => PermissionStatus.denied,
              );
          break;
        case _PermId.location:
          final loc = await Permission.locationWhenInUse.request().timeout(
                reqTimeout,
                onTimeout: () => PermissionStatus.denied,
              );
          // Solo si concedió "en uso" pedimos el background (Android lo
          // exige en ese orden). No bloquea el Continuar si lo rechaza.
          if (loc.isGranted) {
            await Permission.locationAlways.request().timeout(
                  reqTimeout,
                  onTimeout: () => PermissionStatus.denied,
                );
          }
          break;
        case _PermId.notification:
          await Permission.notification.request().timeout(
                reqTimeout,
                onTimeout: () => PermissionStatus.denied,
              );
          break;
        case _PermId.battery:
          // Devuelve bool → el valor por defecto en timeout es false.
          await FlutterForegroundTask.requestIgnoreBatteryOptimization()
              .timeout(reqTimeout, onTimeout: () => false);
          break;
        case _PermId.overlay:
          await Permission.systemAlertWindow.request().timeout(
                reqTimeout,
                onTimeout: () => PermissionStatus.denied,
              );
          break;
        case _PermId.bluetooth:
          await Permission.bluetoothConnect.request().timeout(
                reqTimeout,
                onTimeout: () => PermissionStatus.denied,
              );
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
    _goHome();
  }

  /// Navega a Home y, si el micrófono quedó concedido y el radio está
  /// encendido, re-inicializa el engine de voz para que tome el mic recién
  /// otorgado.
  ///
  /// MOTIVO: en instalación nueva los permisos se piden de cero. El radio se
  /// restaura al autenticarse (main.dart) y puede UNIRSE al canal ANTES de que
  /// el usuario conceda el micrófono acá → el provider queda "unido SIN mic"
  /// (`_joinedWithoutMic=true`). El recovery `ensureMicReady()` solo se
  /// disparaba en `AppLifecycleState.resumed`, que NO ocurre al volver del
  /// onboarding a Home por navegación in-app → el PTT quedaba muerto hasta
  /// cerrar/reabrir la app o togglear el radio. Disparándolo aquí, al COMPLETAR
  /// el onboarding, el engine queda mic-ready sin que el usuario tenga que
  /// reiniciar nada.
  ///
  /// `ensureMicReady()` es idempotente y conservador: es no-op rápido si el
  /// engine ya tiene mic (`_joinedWithoutMic=false`) o si el permiso aún no
  /// está concedido, y NO deja el mic capturando en reposo (re-publica el track
  /// muteado). Solo lo llamamos si el radio está ON; si está OFF, no hay engine
  /// que arreglar y el mic queda libre para otras apps.
  void _goHome() {
    if (_states[_PermId.microphone] == _PermState.granted &&
        RadioPowerService.instance.isOn) {
      // Fire-and-forget: no bloquea la navegación. El factory devuelve el
      // provider activo (Agora/LiveKit); en Agora ensureMicReady es no-op.
      VoiceProviderFactory.current.ensureMicReady().catchError((Object e) {
        debugPrint('PermissionsOnboarding: ensureMicReady falló: $e');
      });
    }
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

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.neutralBg,
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
                    colorScheme.primary,
                    colorScheme.primary.withValues(alpha: 0.8),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.verified_user,
                      size: 40, color: colorScheme.onPrimary),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Permisos necesarios',
                    style: textTheme.headlineMedium
                        ?.copyWith(color: colorScheme.onPrimary),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Para que el radio y la ubicación funcionen, concede los '
                    'permisos de abajo. Los marcados como requeridos son '
                    'indispensables.',
                    style: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onPrimary.withValues(alpha: 0.85),
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
    final colorScheme = Theme.of(context).colorScheme;
    final canContinue = _requiredGranted;
    // La batería es OPCIONAL para el gate (no bloquea), pero sin ella el Doze de
    // Android mata el GPS y el radio en segundo plano → el conductor desaparece
    // del mapa y deja de oír. Por eso, si los requeridos ya están pero la batería
    // NO, mostramos una advertencia fuerte y visible antes de dejar continuar.
    final batteryMissing =
        _states[_PermId.battery] != _PermState.granted;
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
            if (batteryMissing) _buildBatteryWarning(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: canContinue ? _continue : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
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
              onPressed: _goHome,
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

  /// Aviso fuerte (no bloqueante) cuando la batería sin restricciones no está
  /// concedida: sin ella, en segundo plano el conductor desaparece del mapa y
  /// deja de oír el radio. Ofrece un botón directo para concederla.
  Widget _buildBatteryWarning() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.warningColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.warningColor.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: AppTheme.warningColor, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Muy recomendado: batería sin restricciones',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Sin este permiso, el celular puede cortar tu ubicación y el '
                  'radio en segundo plano: desaparecerás del mapa de la operadora '
                  'y dejarás de escuchar.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () => _request(_PermId.battery),
                  child: Text(
                    'Conceder ahora',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.secondary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
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
    final colorScheme = Theme.of(context).colorScheme;
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
                color: (granted ? AppTheme.successColor : colorScheme.secondary)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                color: granted ? AppTheme.successColor : colorScheme.secondary,
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
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
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
