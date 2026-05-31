import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/services/association_theme_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';

/// Pantalla del admin para editar el branding de su asociación
/// (`associations/{aid}.theme`): elige un TEMA CURADO (preset) + logo.
///
/// Ya no se eligen colores sueltos: el admin escoge un preset profesional
/// de una galería, garantizando combinaciones siempre legibles. Se guarda
/// `theme.presetId` (conservando `logoUrl`).
///
/// Al guardar, [AssociationThemeService.loadFor] vuelve a cargar y la app
/// se repinta automáticamente.
class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  String _selectedPresetId = defaultPreset.id;
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
    if (aid == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .get();
      final theme = doc.data()?['theme'] as Map<String, dynamic>?;
      final presetId = theme?['presetId'] as String?;
      if (presetId != null && presetId.isNotEmpty) {
        // Resolver para normalizar ids desconocidos al default.
        _selectedPresetId = presetById(presetId).id;
      }
      _logoUrl = theme?['logoUrl'] as String?;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
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
      // Path tiene que matchear `match /associations/{aid}/{allPaths=**}`
      // en storage.rules.
      final ref = FirebaseStorage.instance.ref('associations/$aid/logo.jpg');
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
          'presetId': _selectedPresetId,
          'logoUrl': _logoUrl,
        },
        'updatedAt': FieldValue.serverTimestamp(),
      });
      // Recargar el theme service para que la app se repinte. Como loadFor
      // es idempotente por aid, forzamos limpiando el aid actual.
      AssociationThemeService.instance.clear();
      await AssociationThemeService.instance.loadFor(aid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tema guardado')),
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
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tema y branding'),
        actions: [
          IconButton(
            tooltip: 'Guardar',
            icon: _saving
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.onPrimary),
                  )
                : const Icon(Icons.save),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Logo de la asociación', style: textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
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
                                      const SizedBox(height: AppSpacing.sm),
                                      Text(
                                        'Toca para subir logo',
                                        style: textTheme.bodyMedium?.copyWith(
                                            color: Colors.grey.shade600),
                                      ),
                                    ],
                                  ),
                                )),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text('Tema de la asociación', style: textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Elige un tema profesional. Los colores se aplican a toda '
                    'la app de tu asociación.',
                    style: textTheme.bodySmall
                        ?.copyWith(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: themePresets.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: AppSpacing.md,
                      crossAxisSpacing: AppSpacing.md,
                      childAspectRatio: 1.35,
                    ),
                    itemBuilder: (_, i) {
                      final preset = themePresets[i];
                      return _ThemeCard(
                        preset: preset,
                        selected: preset.id == _selectedPresetId,
                        onTap: () =>
                            setState(() => _selectedPresetId = preset.id),
                      );
                    },
                  ),
                ],
              ),
            ),
    );
  }
}

/// Tarjeta de la galería: nombre + swatches (primary/secondary/accent) y
/// estado seleccionado.
class _ThemeCard extends StatelessWidget {
  final ThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? preset.primary : Colors.grey.shade300,
            width: selected ? 3 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: preset.primary.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cabecera = muestra del color primary con texto onPrimary.
            Container(
              height: 46,
              decoration: BoxDecoration(
                color: preset.primary,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(11)),
              ),
              alignment: Alignment.center,
              child: Text(
                'Aa',
                style: textTheme.titleLarge?.copyWith(color: preset.onPrimary),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            preset.name,
                            style: textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (selected)
                          Icon(Icons.check_circle,
                              color: preset.primary, size: 20),
                      ],
                    ),
                    Row(
                      children: [
                        _swatch(preset.primary),
                        const SizedBox(width: AppSpacing.xs),
                        _swatch(preset.secondary),
                        const SizedBox(width: AppSpacing.xs),
                        _swatch(preset.accent),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _swatch(Color c) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black12),
      ),
    );
  }
}
