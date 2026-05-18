import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// Botón circular grande del Radio en el bottom nav, con animación de
/// ondas concéntricas (estilo "señal de radio") cuando hay actividad.
///
/// 3 anillos pulsantes con fases distintas → da el efecto de onda
/// continua emitida desde el botón. Cuando [active] es false, los
/// anillos se ocultan y queda solo el círculo del icono → no distrae.
///
/// Tamaño total ~76 dp (incluye los anillos cuando expanden), el círculo
/// del icono mide 56 dp.
class RadioWaveButton extends StatefulWidget {
  final bool selected;
  final bool active;
  final VoidCallback onTap;

  const RadioWaveButton({
    super.key,
    required this.selected,
    required this.active,
    required this.onTap,
  });

  @override
  State<RadioWaveButton> createState() => _RadioWaveButtonState();
}

class _RadioWaveButtonState extends State<RadioWaveButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _syncAnim();
  }

  @override
  void didUpdateWidget(covariant RadioWaveButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncAnim();
  }

  void _syncAnim() {
    if (widget.active) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fillColor = widget.selected
        ? AppTheme.primaryColor
        : AppTheme.primaryColor.withValues(alpha: 0.85);
    final iconColor = Colors.white;

    return SizedBox(
      width: 78,
      height: 78,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.active)
              AnimatedBuilder(
                animation: _ctrl,
                builder: (_, _) => CustomPaint(
                  size: const Size(78, 78),
                  painter: _RadioWavePainter(
                    progress: _ctrl.value,
                    color: AppTheme.primaryColor,
                  ),
                ),
              ),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fillColor,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primaryColor.withValues(alpha: 0.35),
                    blurRadius: 10,
                    spreadRadius: 1,
                    offset: const Offset(0, 2),
                  ),
                ],
                border: Border.all(color: Colors.white, width: 3),
              ),
              child: Icon(Icons.mic, color: iconColor, size: 28),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pinta 3 anillos concéntricos con fases distintas, pulsando hacia
/// afuera. Cada anillo arranca al 50% del radio del botón y crece hasta
/// 100% del SizedBox, con opacidad decayendo de 0.5 → 0.
class _RadioWavePainter extends CustomPainter {
  final double progress; // 0..1, tomado del AnimationController repeating
  final Color color;

  _RadioWavePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;
    const baseRadius = 28.0; // mismo que el radio del círculo principal
    const ringCount = 3;

    for (int i = 0; i < ringCount; i++) {
      // Cada anillo está desfasado para crear un patrón continuo.
      final phase = (progress + i / ringCount) % 1.0;
      final radius = baseRadius + (maxRadius - baseRadius) * phase;
      final opacity = (1.0 - phase) * 0.45;
      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RadioWavePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
