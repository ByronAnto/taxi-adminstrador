import 'package:flutter/material.dart';

/// Escala de espaciado del design system (tokens 4/8/12/16/24/32).
///
/// Usar en lugar de números mágicos repetidos en `EdgeInsets`/`SizedBox`.
class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Tema principal de la aplicación Taxi Jipijapa.
///
/// Regla arquitectónica:
/// - Colores de MARCA (primary/secondary/accent) → se exponen vía
///   `Theme.of(context).colorScheme.primary/secondary/tertiary` en runtime
///   para que el preset por asociación se refleje. NO usar las consts de
///   marca de aquí para pintar UI.
/// - Colores SEMÁNTICOS (success/warning/error/info y estados del conductor)
///   → constantes en esta clase (no cambian por asociación).
class AppTheme {
  AppTheme._();

  // Colores principales (marca por defecto — Amarillo Clásico).
  static const Color primaryColor = Color(0xFFFFD600); // Amarillo taxi
  static const Color primaryDark = Color(0xFFC7A500);
  static const Color primaryLight = Color(0xFFFFF176);
  static const Color secondaryColor = Color(0xFF1A237E); // Azul oscuro
  static const Color accentColor = Color(0xFF00BFA5);

  // Colores semánticos (constantes — no cambian por asociación).
  static const Color errorColor = Color(0xFFD32F2F);
  static const Color successColor = Color(0xFF388E3C);
  static const Color warningColor = Color(0xFFF57C00);
  static const Color infoColor = Color(0xFF1976D2);

  static const Color backgroundColor = Color(0xFFF5F5F5);
  static const Color neutralBg = Color(0xFFF5F5F5);
  static const Color surfaceColor = Colors.white;
  static const Color onPrimaryColor = Colors.black;
  static const Color textPrimary = Color(0xFF212121);
  static const Color textSecondary = Color(0xFF757575);
  static const Color dividerColor = Color(0xFFBDBDBD);

  // Estado del conductor (semántico).
  static const Color statusFree = Color(0xFF4CAF50);
  static const Color statusBusy = Color(0xFFF44336);
  static const Color statusReturning = Color(0xFFFF9800);
  static const Color statusOffline = Color(0xFF9E9E9E);

  /// Paleta categórica cohesiva para tiles/categorías (home, caja, etc.).
  /// Reemplaza el uso ad-hoc de `Colors.deepPurple/teal/cyan…`.
  static const List<Color> categorical = <Color>[
    Color(0xFF3949AB), // indigo
    Color(0xFF00897B), // teal
    Color(0xFF8E24AA), // purple
    Color(0xFFF4511E), // deep orange
    Color(0xFF00ACC1), // cyan
    Color(0xFF43A047), // green
    Color(0xFFFB8C00), // orange
    Color(0xFFC0CA33), // lime
  ];

  /// Escala tipográfica Material 3 compartida por light/dark.
  /// Tamaños ≈ 28/22/18/16/15/14/12/11.
  static const TextTheme _textTheme = TextTheme(
    displaySmall: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
    headlineMedium: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
    titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
    bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
    bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
    labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
  );

  // Tema claro
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        primary: primaryColor,
        onPrimary: onPrimaryColor,
        secondary: secondaryColor,
        error: errorColor,
        surface: surfaceColor,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: backgroundColor,
      textTheme: _textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: primaryColor,
        foregroundColor: onPrimaryColor,
        elevation: 2,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: onPrimaryColor,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: onPrimaryColor,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: dividerColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: dividerColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryColor, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: errorColor),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: secondaryColor,
        unselectedItemColor: textSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryColor,
        foregroundColor: onPrimaryColor,
      ),
    );
  }

  // Tema oscuro
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        primary: primaryColor,
        onPrimary: onPrimaryColor,
        secondary: secondaryColor,
        error: errorColor,
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF121212),
      textTheme: _textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1E1E1E),
        foregroundColor: primaryColor,
        elevation: 2,
        centerTitle: true,
      ),
    );
  }
}
