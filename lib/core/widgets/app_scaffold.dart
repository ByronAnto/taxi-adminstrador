import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// AppBar estándar del design system.
///
/// Hereda colores del theme (`primary`/`onPrimary` correctos según el
/// preset de la asociación) y trae un back-button integrado con la lógica
/// `context.canPop() ? context.pop() : context.go('/home')`, reemplazando
/// el patrón repetido en muchas pantallas.
///
/// No fuerza `backgroundColor`/`foregroundColor`: deja que el AppBarTheme
/// (y el preset por asociación) los resuelva, evitando los overrides de
/// contraste rotos.
class AppAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;

  /// Si false, no muestra el back-button (p. ej. pantallas raíz).
  final bool showBack;

  /// Ruta de fallback cuando no se puede hacer pop.
  final String fallbackRoute;

  final Widget? leading;
  final PreferredSizeWidget? bottom;
  final bool centerTitle;

  const AppAppBar({
    super.key,
    required this.title,
    this.actions,
    this.showBack = true,
    this.fallbackRoute = '/home',
    this.leading,
    this.bottom,
    this.centerTitle = true,
  });

  @override
  Size get preferredSize => Size.fromHeight(
      kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title),
      centerTitle: centerTitle,
      leading: leading ??
          (showBack
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => context.canPop()
                      ? context.pop()
                      : context.go(fallbackRoute),
                )
              : null),
      actions: actions,
      bottom: bottom,
    );
  }
}

/// Scaffold estándar que usa [AppAppBar]. Atajo para pantallas comunes.
class AppScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget>? actions;
  final bool showBack;
  final String fallbackRoute;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final PreferredSizeWidget? appBarBottom;

  const AppScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.showBack = true,
    this.fallbackRoute = '/home',
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.appBarBottom,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: title,
        actions: actions,
        showBack: showBack,
        fallbackRoute: fallbackRoute,
        bottom: appBarBottom,
      ),
      body: body,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
    );
  }
}
