import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// Diálogo de diagnóstico SOLO para admin: activa/desactiva el envío de logs
/// al servidor de forma CENTRAL (escribe `app_config/remoteLogging`).
///
/// Modelo del flag:
///   { enabled: bool, onlyUser?: string (uid), until?: Timestamp }
///
/// Cuando está ON, TODOS los dispositivos (o solo `onlyUser`) empiezan a
/// subir sus logs. Cuando está OFF, los logs se quedan en el teléfono
/// (buffer local) y no se envían. Caso de uso: "cuando algo pasa, activar".
///
/// Decisión de seguridad: al activar se setea `until = now + 2h` para un
/// auto-apagado (evita dejar el envío encendido indefinidamente y consumir
/// datos/almacenamiento del servidor por olvido). Al desactivar se limpia.
class RemoteLoggingDialog extends StatefulWidget {
  const RemoteLoggingDialog({super.key});

  /// Helper para abrir el diálogo.
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const RemoteLoggingDialog(),
    );
  }

  @override
  State<RemoteLoggingDialog> createState() => _RemoteLoggingDialogState();
}

class _RemoteLoggingDialogState extends State<RemoteLoggingDialog> {
  /// Auto-apagado de seguridad al activar.
  static const Duration _autoOffAfter = Duration(hours: 2);

  static DocumentReference<Map<String, dynamic>> get _docRef =>
      FirebaseFirestore.instance.collection('app_config').doc('remoteLogging');

  bool _enabled = false;
  Timestamp? _until;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snap = await _docRef.get();
      final data = snap.data();
      if (mounted) {
        setState(() {
          _enabled = data?['enabled'] == true;
          _until = data?['until'] is Timestamp
              ? data!['until'] as Timestamp
              : null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _saving = true);
    try {
      if (value) {
        // Activar: enabled + auto-apagado en 2h. No tocamos `onlyUser`
        // (si quieres restringir a un solo uid se setea manualmente en
        // Firestore; aquí dejamos el modo "todos los dispositivos").
        final until = Timestamp.fromDate(DateTime.now().add(_autoOffAfter));
        await _docRef.set(<String, dynamic>{
          'enabled': true,
          'until': until,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        if (mounted) {
          setState(() {
            _enabled = true;
            _until = until;
          });
        }
      } else {
        await _docRef.set(<String, dynamic>{
          'enabled': false,
          'until': null,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        if (mounted) {
          setState(() {
            _enabled = false;
            _until = null;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo guardar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _untilLabel() {
    final u = _until;
    if (u == null) return '';
    final d = u.toDate();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.bug_report_outlined, color: AppTheme.primaryColor),
          SizedBox(width: 8),
          Expanded(child: Text('Logs remotos (diagnóstico)')),
        ],
      ),
      content: _loading
          ? const SizedBox(
              height: 64,
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enviar logs al servidor'),
                  subtitle: Text(
                    _enabled
                        ? 'ON: los dispositivos suben sus logs.'
                        : 'OFF: los logs se quedan en el teléfono.',
                  ),
                  value: _enabled,
                  onChanged: _saving ? null : _toggle,
                ),
                const SizedBox(height: 8),
                Text(
                  'Activa esto solo cuando estés diagnosticando un problema. '
                  'Mientras está OFF, cada teléfono guarda sus logs localmente '
                  'y no consume datos. Al activar se apaga solo en 2 horas '
                  'por seguridad.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_enabled && _until != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.timer_outlined, size: 16),
                      const SizedBox(width: 6),
                      Text('Se apagará automáticamente a las ${_untilLabel()}'),
                    ],
                  ),
                ],
                if (_saving) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}
