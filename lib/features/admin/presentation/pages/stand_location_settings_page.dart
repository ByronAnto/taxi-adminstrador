import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../associations/data/models/association_model.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';

/// Configuración de la parada base de la cooperativa.
///
/// El admin elige en el mapa el punto exacto de la parada y un radio
/// (slider 50 m - 5 km) dentro del cual los conductores pueden entrar a
/// la cola. Si está vacío, la validación de distancia queda desactivada
/// (cualquier conductor puede entrar a la cola desde donde sea).
class StandLocationSettingsPage extends StatefulWidget {
  const StandLocationSettingsPage({super.key});

  @override
  State<StandLocationSettingsPage> createState() =>
      _StandLocationSettingsPageState();
}

class _StandLocationSettingsPageState extends State<StandLocationSettingsPage> {
  final Completer<GoogleMapController> _ctrl = Completer();
  static const _quito = LatLng(-0.1807, -78.4678);

  LatLng? _selected;
  double _radiusKm = 1.0;
  String _label = '';
  final _labelCtrl = TextEditingController();

  /// Rango configurable del radio: desde 50 m hasta 5 km.
  /// Las cooperativas urbanas pequeñas necesitan radios chicos (50-200 m)
  /// para que la cola solo cuente a quien está físicamente en la parada.
  /// Las suburbanas grandes usan 1-5 km.
  static const double _radiusMinKm = 0.05; // 50 m
  static const double _radiusMaxKm = 5.0; // 5 km
  static const int _radiusDivisions = 99; // pasos de 0.05 km = 50 m

  /// Formatea el radio: "350 m" si <1 km, "1.5 km" si ≥1 km.
  String _formatRadius(double km) {
    if (km < 1.0) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(1)} km';
  }

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AuthBloc>().state;
    if (state is! AuthAuthenticated) {
      setState(() => _loading = false);
      return;
    }
    final aid = state.user.associationId;
    final snap = await FirebaseFirestore.instance
        .collection('associations')
        .doc(aid)
        .get();
    final stand = StandLocation.fromMap(
        snap.data()?['standLocation'] as Map<String, dynamic>?);
    setState(() {
      if (stand.isConfigured) {
        _selected = LatLng(stand.lat!, stand.lng!);
      }
      _radiusKm = stand.radiusKm;
      _label = stand.label ?? '';
      _labelCtrl.text = _label;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _useMyLocation() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        final r = await Geolocator.requestPermission();
        if (r == LocationPermission.denied ||
            r == LocationPermission.deniedForever) {
          return;
        }
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      final point = LatLng(pos.latitude, pos.longitude);
      setState(() => _selected = point);
      final ctrl = await _ctrl.future;
      await ctrl.animateCamera(CameraUpdate.newLatLngZoom(point, 17));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No pudimos obtener tu ubicación: $e')),
      );
    }
  }

  Future<void> _save() async {
    final state = context.read<AuthBloc>().state;
    if (state is! AuthAuthenticated) return;
    final aid = state.user.associationId;

    setState(() => _saving = true);
    try {
      final newStand = StandLocation(
        lat: _selected?.latitude,
        lng: _selected?.longitude,
        radiusKm: _radiusKm,
        label: _labelCtrl.text.trim().isEmpty ? null : _labelCtrl.text.trim(),
      );
      await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .set({
        'standLocation': newStand.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_selected == null
              ? 'Parada eliminada. Los conductores pueden entrar desde cualquier lugar.'
              : 'Parada guardada. Radio: ${_formatRadius(_radiusKm)}.'),
          backgroundColor: AppTheme.successColor,
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al guardar: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitar parada'),
        content: const Text(
            'Si quitas la parada, los conductores podrán entrar a la cola desde cualquier lugar (sin validación de distancia). ¿Continuar?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: AppTheme.errorColor),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _selected = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final initial = _selected ?? _quito;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ubicación de la parada'),
        actions: [
          IconButton(
            tooltip: 'Mi ubicación',
            icon: const Icon(Icons.my_location),
            onPressed: _useMyLocation,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: initial,
                    zoom: 16,
                  ),
                  onMapCreated: (c) => _ctrl.complete(c),
                  onTap: (latlng) => setState(() => _selected = latlng),
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  markers: _selected != null
                      ? {
                          Marker(
                            markerId: const MarkerId('parada'),
                            position: _selected!,
                            infoWindow: InfoWindow(
                              title: _labelCtrl.text.trim().isNotEmpty
                                  ? _labelCtrl.text.trim()
                                  : 'Parada',
                              snippet: 'Radio: ${_formatRadius(_radiusKm)}',
                            ),
                          )
                        }
                      : {},
                  circles: _selected != null
                      ? {
                          Circle(
                            circleId: const CircleId('radio'),
                            center: _selected!,
                            radius: _radiusKm * 1000, // metros
                            strokeWidth: 2,
                            strokeColor: AppTheme.primaryColor,
                            fillColor: AppTheme.primaryColor
                                .withValues(alpha: 0.15),
                          )
                        }
                      : {},
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _selected == null
                          ? 'Toca el mapa para fijar la parada'
                          : 'Radio: ${_formatRadius(_radiusKm)} — los conductores pueden entrar a la cola dentro de esta zona',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 6,
                  offset: Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _labelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nombre de la parada (opcional)',
                    hintText: 'Ej. Parque central, Estación norte',
                    prefixIcon: Icon(Icons.label_outline),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.adjust, size: 18),
                    const SizedBox(width: 6),
                    Text('Radio permitido: ',
                        style:
                            const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      _formatRadius(_radiusKm),
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppTheme.primaryColor),
                    ),
                  ],
                ),
                Slider(
                  value: _radiusKm.clamp(_radiusMinKm, _radiusMaxKm),
                  min: _radiusMinKm,
                  max: _radiusMaxKm,
                  divisions: _radiusDivisions, // pasos de 50 m
                  label: _formatRadius(_radiusKm),
                  onChanged: (v) => setState(() => _radiusKm = v),
                ),
                Text(
                  _selected == null
                      ? 'Sin parada configurada → cualquier conductor puede entrar a la cola desde cualquier lugar.'
                      : 'Conductores fuera de este radio verán el mensaje "Estás a X km de la parada".',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade700,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (_selected != null)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _saving ? null : _clear,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Quitar'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.errorColor,
                            side: BorderSide(color: AppTheme.errorColor),
                          ),
                        ),
                      ),
                    if (_selected != null) const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.save),
                        label: Text(_saving ? 'Guardando…' : 'Guardar'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
