import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Vista de estado vacío reutilizable: icono + título + subtítulo opcional
/// + acción opcional. Usa `colorScheme`/`textTheme`/[AppSpacing].
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: AppSpacing.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(color: Colors.black54),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(color: Colors.black45),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Indicador de carga centrado con mensaje opcional.
class LoadingState extends StatelessWidget {
  final String? message;

  const LoadingState({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium
                  ?.copyWith(color: AppTheme.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// Vista de error reutilizable. Detecta el caso de índice Firestore
/// faltante (failed-precondition / requires an index) y muestra un mensaje
/// accionable, igual que el error-state original de `my_payments_page`.
class ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorState({super.key, required this.message, this.onRetry});

  /// Construye un [ErrorState] a partir de un error arbitrario (p. ej. el
  /// `snapshot.error` de un StreamBuilder).
  factory ErrorState.fromError(Object? error, {VoidCallback? onRetry}) {
    return ErrorState(message: error?.toString() ?? '', onRetry: onRetry);
  }

  bool get _isIndexError =>
      message.contains('failed-precondition') ||
      message.contains('requires an index');

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 64, color: AppTheme.errorColor),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Ocurrió un error',
              textAlign: TextAlign.center,
              style: textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _isIndexError
                  ? 'El administrador necesita desplegar el índice nuevo de '
                      'Firestore. Avísale para que ejecute '
                      '"firebase deploy --only firestore:indexes".'
                  : message.isEmpty
                      ? 'No se pudo completar la operación.'
                      : message,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall
                  ?.copyWith(color: Colors.grey.shade700),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppSpacing.xl),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
