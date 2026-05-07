import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/services/association_theme_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';

/// Pantalla del admin para editar el branding de su asociación
/// (`associations/{aid}.theme`): logoUrl, primaryColor, secondaryColor,
/// accentColor.
///
/// Al guardar, [AssociationThemeService.loadFor] vuelve a cargar y la app
/// se repinta automáticamente.
class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  Color _primary = const Color(0xFF1565C0);
  Color _secondary = const Color(0xFFFFC107);
  Color _accent = const Color(0xFF0D47A1);
  String? _logoUrl;
  bool _loading = true;
  bool _saving = false;
  bool _uploadingLogo = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String? get _aid {
    final auth = context.read<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return null;
    return auth.user.associationId;
  }

  Future<void> _load() async {
    final aid = _aid;
    if (aid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .get();
      final theme = doc.data()?['theme'] as Map<String, dynamic>?;
      _primary = _parseHex(theme?['primaryColor']) ?? _primary;
      _secondary = _parseHex(theme?['secondaryColor']) ?? _secondary;
      _accent = _parseHex(theme?['accentColor']) ?? _accent;
      _logoUrl = theme?['logoUrl'] as String?;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Color? _parseHex(dynamic value) {
    if (value is! String || !value.startsWith('#') || value.length != 7) {
      return null;
    }
    try {
      final v = int.parse(value.substring(1), radix: 16);
      return Color(0xff000000 | v);
    } catch (_) {
      return null;
    }
  }

  String _toHex(Color c) {
    return '#${(((c.r * 255.0).round() & 0xff) << 16 | ((c.g * 255.0).round() & 0xff) << 8 | ((c.b * 255.0).round() & 0xff)).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  Future<void> _pickColor(String label, Color current, ValueChanged<Color> onPicked) async {
    final palette = <Color>[
      const Color(0xFF1565C0), const Color(0xFFFFC107), const Color(0xFFE91E63),
      const Color(0xFF4CAF50), const Color(0xFFFF5722), const Color(0xFF9C27B0),
      const Color(0xFF00BCD4), const Color(0xFF795548), const Color(0xFF607D8B),
      const Color(0xFFF44336), const Color(0xFF3F51B5), const Color(0xFF009688),
      const Color(0xFFFFEB3B), const Color(0xFF8BC34A), const Color(0xFF673AB7),
      const Color(0xFF0D47A1),
    ];
    final picked = await showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Seleccionar $label'),
        content: SizedBox(
          width: 320,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: palette
                .map((c) => GestureDetector(
                      onTap: () => Navigator.pop(ctx, c),
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: c.toARGB32() == current.toARGB32()
                                ? Colors.black
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
        ],
      ),
    );
    if (picked != null) onPicked(picked);
  }

  Future<void> _pickLogo() async {
    final aid = _aid;
    if (aid == null) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 800,
    );
    if (picked == null) return;
    setState(() => _uploadingLogo = true);
    try {
      final ref =
          FirebaseStorage.instance.ref('association_logos/$aid.jpg');
      await ref.putFile(
        await _xFileToFile(picked),
        SettableMetadata(contentType: 'image/jpeg'),
      );
      final url = await ref.getDownloadURL();
      setState(() => _logoUrl = url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error subiendo logo: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingLogo = false);
    }
  }

  Future<dynamic> _xFileToFile(XFile x) async {
    return File(x.path);
  }

  Future<void> _save() async {
    final aid = _aid;
    if (aid == null) return;
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .update({
        'theme': {
          'primaryColor': _toHex(_primary),
          'secondaryColor': _toHex(_secondary),
          'accentColor': _toHex(_accent),
          'logoUrl': _logoUrl,
        },
        'updatedAt': FieldValue.serverTimestamp(),
      });
      // Recargar el theme service para que la app se repinte.
      await AssociationThemeService.instance.loadFor(aid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Branding guardado')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error: $e'),
              backgroundColor: AppTheme.errorColor),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Branding'),
        actions: [
          IconButton(
            tooltip: 'Guardar',
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Logo de la asociación',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: _uploadingLogo ? null : _pickLogo,
                    child: Container(
                      height: 140,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: _uploadingLogo
                          ? const Center(child: CircularProgressIndicator())
                          : (_logoUrl != null && _logoUrl!.isNotEmpty
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.network(_logoUrl!,
                                      fit: BoxFit.contain),
                                )
                              : Center(
                                  child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.add_photo_alternate,
                                          size: 40,
                                          color: Colors.grey.shade500),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Toca para subir logo',
                                        style: TextStyle(
                                            color: Colors.grey.shade600),
                                      ),
                                    ],
                                  ),
                                )),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text('Colores',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 12),
                  _colorRow('Primario', _primary,
                      (c) => setState(() => _primary = c)),
                  _colorRow('Secundario', _secondary,
                      (c) => setState(() => _secondary = c)),
                  _colorRow('Acento', _accent,
                      (c) => setState(() => _accent = c)),
                  const SizedBox(height: 24),
                  // Vista previa
                  const Text('Vista previa',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  Card(
                    color: _primary.withValues(alpha: 0.08),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('Primario',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(height: 8),
                          ElevatedButton(
                            onPressed: () {},
                            style: ElevatedButton.styleFrom(
                                backgroundColor: _secondary,
                                foregroundColor: Colors.black),
                            child: const Text('Botón secundario'),
                          ),
                          const SizedBox(height: 8),
                          Text('Texto en color acento',
                              style: TextStyle(
                                  color: _accent,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _colorRow(String label, Color color, ValueChanged<Color> onPicked) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.grey.shade400),
        ),
      ),
      title: Text(label),
      subtitle: Text(_toHex(color),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      trailing: TextButton(
        onPressed: () => _pickColor(label, color, onPicked),
        child: const Text('Cambiar'),
      ),
    );
  }
}
