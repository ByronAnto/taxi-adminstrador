import 'package:flutter/material.dart';

/// Un tema curado (preset) que el admin de una asociación puede elegir.
///
/// El admin NO elige colores sueltos: escoge uno de estos presets
/// profesionales, garantizando que la paleta siempre se vea bien y que el
/// texto sobre `primary` sea legible (`onPrimary`).
class ThemePreset {
  final String id;
  final String name;
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color accent;

  const ThemePreset({
    required this.id,
    required this.name,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.accent,
  });
}

/// Presets curados disponibles. El primero es el default (Amarillo Clásico).
///
/// Todos validados para contraste de texto sobre `primary`:
/// - Amarillo claro → `onPrimary` negro.
/// - Resto (colores oscuros) → `onPrimary` blanco.
const List<ThemePreset> themePresets = <ThemePreset>[
  ThemePreset(
    id: 'amarillo_clasico',
    name: 'Amarillo Clásico',
    primary: Color(0xFFFFD600),
    onPrimary: Colors.black,
    secondary: Color(0xFF1A237E),
    accent: Color(0xFF00BFA5),
  ),
  ThemePreset(
    id: 'azul_corporativo',
    name: 'Azul Corporativo',
    primary: Color(0xFF1565C0),
    onPrimary: Colors.white,
    secondary: Color(0xFF0D47A1),
    accent: Color(0xFFFFB300),
  ),
  ThemePreset(
    id: 'verde_esmeralda',
    name: 'Verde Esmeralda',
    primary: Color(0xFF2E7D32),
    onPrimary: Colors.white,
    secondary: Color(0xFF1B5E20),
    accent: Color(0xFFFFC107),
  ),
  ThemePreset(
    id: 'rojo_taxi',
    name: 'Rojo Taxi',
    primary: Color(0xFFC62828),
    onPrimary: Colors.white,
    secondary: Color(0xFF1A237E),
    accent: Color(0xFFFFC107),
  ),
  ThemePreset(
    id: 'naranja_energia',
    name: 'Naranja Energía',
    primary: Color(0xFFEF6C00),
    onPrimary: Colors.white,
    secondary: Color(0xFF263238),
    accent: Color(0xFF00ACC1),
  ),
  ThemePreset(
    id: 'grafito_premium',
    name: 'Grafito Premium',
    primary: Color(0xFF263238),
    onPrimary: Colors.white,
    secondary: Color(0xFFFFC107),
    accent: Color(0xFF26A69A),
  ),
];

/// Preset por defecto (Amarillo Clásico).
const ThemePreset defaultPreset = ThemePreset(
  id: 'amarillo_clasico',
  name: 'Amarillo Clásico',
  primary: Color(0xFFFFD600),
  onPrimary: Colors.black,
  secondary: Color(0xFF1A237E),
  accent: Color(0xFF00BFA5),
);

/// Resuelve un preset por su `id`. Devuelve [defaultPreset] si el id es
/// null o desconocido.
ThemePreset presetById(String? id) {
  if (id == null) return defaultPreset;
  for (final p in themePresets) {
    if (p.id == id) return p;
  }
  return defaultPreset;
}
