import 'package:flutter/material.dart';
import 'package:taxi_jipijapa/core/services/connectivity_service.dart';

/// Widget que envuelve la app y muestra un banner persistente
/// cuando no hay conexión a internet.
///
/// Se coloca como wrapper del `MaterialApp.router` en main.dart.
class ConnectivityBanner extends StatefulWidget {
  final Widget child;

  const ConnectivityBanner({super.key, required this.child});

  @override
  State<ConnectivityBanner> createState() => _ConnectivityBannerState();
}

class _ConnectivityBannerState extends State<ConnectivityBanner>
    with SingleTickerProviderStateMixin {
  final ConnectivityService _service = ConnectivityService.instance;
  late AnimationController _animController;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    ));

    // Estado inicial
    if (!_service.isConnected) {
      _animController.value = 1.0; // mostrar inmediatamente
    }

    _service.addListener(_onConnectivityChanged);
  }

  void _onConnectivityChanged() {
    if (!mounted) return;
    if (_service.isConnected) {
      _animController.reverse();
    } else {
      _animController.forward();
    }
  }

  @override
  void dispose() {
    _service.removeListener(_onConnectivityChanged);
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          // App completa
          widget.child,

          // Banner sin conexión (encima de todo, debajo del status bar)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SlideTransition(
              position: _slideAnimation,
              child: _NoConnectionBanner(
                onRetry: () => _service.retry(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Banner visual que indica falta de conexión.
class _NoConnectionBanner extends StatelessWidget {
  final VoidCallback onRetry;

  const _NoConnectionBanner({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    // Usar MediaQuery si está disponible, sino un padding seguro
    final topPadding = MediaQuery.maybeOf(context)?.padding.top ?? 40.0;

    return Material(
      elevation: 4,
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFD32F2F), Color(0xFFB71C1C)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        padding: EdgeInsets.only(
          top: topPadding + 8,
          bottom: 12,
          left: 16,
          right: 8,
        ),
        child: Row(
          children: [
            const Icon(
              Icons.wifi_off_rounded,
              color: Colors.white,
              size: 24,
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Sin conexión a internet',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Verifique su conexión WiFi o datos móviles',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(
                Icons.refresh_rounded,
                color: Colors.white,
                size: 18,
              ),
              label: const Text(
                'Reintentar',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 36),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
