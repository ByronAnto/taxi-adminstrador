import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../theme/theme_presets.dart';

/// Carga el theme de la asociación (`associations/{aid}.theme`) al login y
/// expone los colores como un [ChangeNotifier] para que el [MaterialApp]
/// reconstruya cuando cambien.
///
/// Modelo nuevo: el admin elige un PRESET curado y se guarda
/// `theme.presetId`. La app resuelve el preset con [presetById] y aplica
/// `primary/secondary/accent` + `onPrimary` en runtime.
///
/// Backward-compat: si NO hay `presetId` pero existen los campos viejos
/// `primaryColor/secondaryColor/accentColor`, se siguen aplicando para no
/// romper asociaciones ya configuradas.
///
/// Si la asociación no tiene theme custom, usa los defaults de [AppTheme].
class AssociationThemeService extends ChangeNotifier {
  AssociationThemeService._();
  static final AssociationThemeService instance = AssociationThemeService._();

  // Preset elegido (modelo nuevo).
  ThemePreset? _preset;

  // Colores legacy (modelo viejo, solo si no hay preset).
  Color? _primary;
  Color? _secondary;
  Color? _accent;

  String? _logoUrl;
  String? _associationName;
  String? _currentAid;

  /// Color primario efectivo (preset o legacy).
  Color? get primaryColor => _preset?.primary ?? _primary;

  /// Color secundario efectivo.
  Color? get secondaryColor => _preset?.secondary ?? _secondary;

  /// Color de acento efectivo.
  Color? get accentColor => _preset?.accent ?? _accent;

  /// `onPrimary` del preset elegido (null en modo legacy).
  Color? get onPrimaryColor => _preset?.onPrimary;

  /// Id del preset elegido (null en modo legacy o sin theme).
  String? get presetId => _preset?.id;

  String? get logoUrl => _logoUrl;
  String? get associationName => _associationName;

  /// True si hay theme cargado (preset o legacy) vs defaults.
  bool get hasCustomTheme =>
      _preset != null ||
      _primary != null ||
      _secondary != null ||
      _accent != null;

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
      _logoUrl = theme?['logoUrl'] as String?;

      final presetId = theme?['presetId'] as String?;
      if (presetId != null && presetId.isNotEmpty) {
        // Modelo nuevo: resolver preset curado.
        _preset = presetById(presetId);
        _primary = null;
        _secondary = null;
        _accent = null;
      } else {
        // Backward-compat: aplicar colores sueltos viejos si existen.
        _preset = null;
        _primary = _parseHex(theme?['primaryColor'] as String?);
        _secondary = _parseHex(theme?['secondaryColor'] as String?);
        _accent = _parseHex(theme?['accentColor'] as String?);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('AssociationThemeService.loadFor error: $e');
    }
  }

  void clear() {
    _preset = null;
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
      primary: primaryColor ?? base.primary,
      // Solo el preset trae onPrimary legible; en legacy mantenemos el base.
      onPrimary: onPrimaryColor ?? base.onPrimary,
      secondary: secondaryColor ?? base.secondary,
      tertiary: accentColor ?? base.tertiary,
    );
  }

  /// Aplica el theme custom a un [ThemeData], incluyendo `onPrimary` del
  /// preset para que AppBar/botones tengan texto legible.
  ThemeData applyToThemeData(ThemeData base) {
    if (!hasCustomTheme) return base;
    final scheme = applyTo(base.colorScheme);
    return base.copyWith(
      colorScheme: scheme,
      primaryColor: scheme.primary,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        titleTextStyle: base.appBarTheme.titleTextStyle
            ?.copyWith(color: scheme.onPrimary),
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
