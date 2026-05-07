import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Carga el theme de la asociación (`associations/{aid}.theme`) al login y
/// expone los colores como un [ChangeNotifier] para que el [MaterialApp]
/// reconstruya cuando cambien.
///
/// El admin de la asociación puede editar logoUrl, primaryColor,
/// secondaryColor, accentColor y la app se actualiza automáticamente.
///
/// Si la asociación no tiene theme custom o los colores no son válidos,
/// usa los defaults de [AppTheme].
class AssociationThemeService extends ChangeNotifier {
  AssociationThemeService._();
  static final AssociationThemeService instance = AssociationThemeService._();

  Color? _primary;
  Color? _secondary;
  Color? _accent;
  String? _logoUrl;
  String? _associationName;
  String? _currentAid;

  Color? get primaryColor => _primary;
  Color? get secondaryColor => _secondary;
  Color? get accentColor => _accent;
  String? get logoUrl => _logoUrl;
  String? get associationName => _associationName;

  /// True si hay theme cargado (vs defaults).
  bool get hasCustomTheme =>
      _primary != null || _secondary != null || _accent != null;

  /// Carga theme para la asociación dada. Idempotente: no recarga si ya
  /// está en la misma `aid`.
  Future<void> loadFor(String aid) async {
    if (aid.isEmpty) {
      clear();
      return;
    }
    if (_currentAid == aid) return;
    _currentAid = aid;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .get();
      if (!doc.exists) {
        clear();
        return;
      }
      final data = doc.data()!;
      _associationName = (data['name'] as String?) ?? aid;
      final theme = data['theme'] as Map<String, dynamic>?;
      _primary = _parseHex(theme?['primaryColor'] as String?);
      _secondary = _parseHex(theme?['secondaryColor'] as String?);
      _accent = _parseHex(theme?['accentColor'] as String?);
      _logoUrl = theme?['logoUrl'] as String?;
      notifyListeners();
    } catch (e) {
      debugPrint('AssociationThemeService.loadFor error: $e');
    }
  }

  void clear() {
    _primary = null;
    _secondary = null;
    _accent = null;
    _logoUrl = null;
    _associationName = null;
    _currentAid = null;
    notifyListeners();
  }

  /// Construye un [ColorScheme] aplicando los colores de la asociación
  /// sobre el [base] dado. Si no hay theme custom, devuelve el base.
  ColorScheme applyTo(ColorScheme base) {
    if (!hasCustomTheme) return base;
    return base.copyWith(
      primary: _primary ?? base.primary,
      secondary: _secondary ?? base.secondary,
      tertiary: _accent ?? base.tertiary,
    );
  }

  /// Aplica el theme custom a un [ThemeData].
  ThemeData applyToThemeData(ThemeData base) {
    if (!hasCustomTheme) return base;
    return base.copyWith(
      colorScheme: applyTo(base.colorScheme),
      primaryColor: _primary ?? base.primaryColor,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: _primary ?? base.appBarTheme.backgroundColor,
      ),
    );
  }

  Color? _parseHex(String? hex) {
    if (hex == null || !hex.startsWith('#')) return null;
    if (hex.length != 7 && hex.length != 9) return null;
    try {
      final cleaned = hex.substring(1);
      final value = int.parse(cleaned, radix: 16);
      // 7 chars = #RRGGBB → agregar alpha 0xff.
      if (cleaned.length == 6) {
        return Color(0xff000000 | value);
      }
      // 9 chars = #AARRGGBB.
      return Color(value);
    } catch (_) {
      return null;
    }
  }
}
