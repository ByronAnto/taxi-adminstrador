import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/version_gate_service.dart';
import '../theme/app_theme.dart';

/// Pantalla a pantalla completa que bloquea cualquier interacción y
/// fuerza al usuario a actualizar antes de continuar.
///
/// Aparece cuando [VersionGateService.status] = `forceUpdate`. La
/// estrategia es **Play Store first**:
///
/// 1. **Auto-trigger en boot**: al mostrarse, llama a
///    `InAppUpdate.checkForUpdate()`. Si Play Core dice que hay una
///    versión nueva disponible, dispara `performImmediateUpdate()`
///    — el flujo oficial de Google: descarga + instala SIN salir de
///    la app. El usuario no tiene que hacer nada.
///
/// 2. **Fallback** si Play Core no responde (app instalada vía APK
///    sideload, dev build, internet caído): el botón "Actualizar
///    ahora" abre la URL de la Play Store en navegador externo.
///
/// El usuario no puede dismissear esta pantalla: `PopScope(canPop:
/// false)` impide back nativo y la única salida es actualizar o cerrar
/// la app desde el OS.
class ForceUpdateScreen extends StatefulWidget {
  const ForceUpdateScreen({super.key});

  @override
  State<ForceUpdateScreen> createState() => _ForceUpdateScreenState();
}

class _ForceUpdateScreenState extends State<ForceUpdateScreen> {
  bool _checking = false;
  String? _errorHint;

  @override
  void initState() {
    super.initState();
    // Disparar el flujo nativo de Google automáticamente al primer
    // frame. Si la app vino del Play Store, el usuario verá el sheet
    // de "Actualizar" sin tocar nada.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _tryImmediateUpdate());
  }

  Future<void> _tryImmediateUpdate() async {
    if (_checking) return;
    if (kIsWeb) {
      _fallbackToStore();
      return;
    }
    try {
      if (!Platform.isAndroid) {
        // iOS: no existe el equivalente del Play In-App Update.
        // Usamos el fallback de App Store URL.
        return;
      }
    } catch (_) {
      return;
    }

    setState(() => _checking = true);
    try {
      final info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability == UpdateAvailability.updateAvailable) {
        // Play Core sabe que hay una nueva versión publicada → flujo
        // nativo de Google, full-screen, bloqueante. Cuando la
        // descarga termina, Android reinicia la app sola.
        await InAppUpdate.performImmediateUpdate();
      } else {
        // Play Core dice que no hay update disponible aunque nuestro
        // VersionGateService SÍ exigió uno. Esto pasa cuando:
        //   - La app fue instalada por APK sideload (no Play Store).
        //   - La nueva versión todavía no está visible en el track del
        //     usuario (rollout gradual).
        // En esos casos solo queda el fallback al URL.
        if (mounted) {
          setState(() {
            _errorHint = info.updateAvailability ==
                    UpdateAvailability.developerTriggeredUpdateInProgress
                ? 'Actualización en curso, espera unos segundos…'
                : null;
          });
        }
      }
    } catch (e) {
      // Play Services no disponible, app no en Play Store, etc.
      // Silenciamos: el usuario tiene el botón manual de fallback.
      debugPrint('🔢 [ForceUpdate] In-app update no disponible: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _fallbackToStore() async {
    final url = VersionGateService.instance.storeUrl;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'No tenemos la URL de la tienda configurada. Contacta al administrador.'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final msg = VersionGateService.instance.message;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppTheme.primaryColor,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _checking
                        ? Icons.cloud_download_outlined
                        : Icons.system_update_alt,
                    color: Colors.white,
                    size: 56,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Actualización requerida',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Hay una nueva versión de la app que necesitas instalar para seguir usando el sistema.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.white,
                    height: 1.4,
                  ),
                ),
                if (msg != null && msg.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.lightbulb_outline,
                            color: Colors.amber, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            msg,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_errorHint != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _errorHint!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: _checking
                      ? null
                      : () async {
                          // Re-intentar el flujo Play Core; si vuelve
                          // a fallar (no Play Store) cae al URL.
                          await _tryImmediateUpdate();
                          if (!mounted) return;
                          if (VersionGateService.instance.status.value ==
                              VersionGateStatus.forceUpdate) {
                            await _fallbackToStore();
                          }
                        },
                  icon: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppTheme.primaryColor),
                        )
                      : const Icon(Icons.download),
                  label: Text(
                      _checking ? 'Verificando…' : 'Actualizar ahora'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppTheme.primaryColor,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _checking ? null : () => SystemNavigator.pop(),
                  icon: const Icon(Icons.close),
                  label: const Text('Cerrar app'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.4)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
