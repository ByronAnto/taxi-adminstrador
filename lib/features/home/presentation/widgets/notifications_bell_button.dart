import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/data/models/user_model.dart';

/// Botón de campana en el AppBar.
///
/// Muestra badge con el número de notificaciones recibidas desde la
/// última vez que el usuario abrió la pantalla. Al tocar:
///   1. Escribe `users/{uid}.lastNotificationsViewedAt = now` (apaga el badge).
///   2. Navega a `/notifications` (lista completa).
class NotificationsBellButton extends StatelessWidget {
  const NotificationsBellButton({super.key, required this.user});

  final UserModel user;

  bool _matchesAudience(String audience) {
    if (audience == 'all') return true;
    if (audience == 'drivers' && user.role == AppConstants.roleDriver) {
      return true;
    }
    if (audience == 'operadoras' && user.role == AppConstants.roleOperator) {
      return true;
    }
    return false;
  }

  Stream<_BellState> _stateStream() {
    final db = FirebaseFirestore.instance;
    final userDoc = db.collection('users').doc(user.uid);
    final notifs = db
        .collection('notifications')
        .where('associationId', isEqualTo: user.associationId)
        .orderBy('createdAt', descending: true)
        .limit(50);

    return userDoc.snapshots().asyncExpand((u) {
      final lastViewedAt =
          (u.data() ?? const {})['lastNotificationsViewedAt'] as Timestamp?;
      return notifs.snapshots().map((q) {
        int unread = 0;
        for (final d in q.docs) {
          final data = d.data();
          final aud = (data['audience'] as String?) ?? 'all';
          if (!_matchesAudience(aud)) continue;
          final createdAt = data['createdAt'] as Timestamp?;
          if (createdAt == null) continue;
          if (lastViewedAt == null ||
              createdAt.compareTo(lastViewedAt) > 0) {
            unread++;
          }
        }
        return _BellState(unread: unread);
      });
    });
  }

  Future<void> _onTap(BuildContext context) async {
    // Marcar como vista ANTES de navegar — al volver, el badge ya estará
    // apagado. Si la escritura falla (sin red), el badge se queda igual
    // hasta la próxima visita.
    unawaited(FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set(
          {'lastNotificationsViewedAt': FieldValue.serverTimestamp()},
          SetOptions(merge: true),
        ));
    if (context.mounted) context.push('/notifications');
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<_BellState>(
      stream: _stateStream(),
      builder: (context, snap) {
        final unread = snap.data?.unread ?? 0;
        return Stack(
          alignment: Alignment.center,
          children: [
            IconButton(
              tooltip: 'Notificaciones',
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => _onTap(context),
            ),
            if (unread > 0)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 18,
                    minHeight: 18,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.errorColor,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Text(
                    unread > 99 ? '99+' : '$unread',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _BellState {
  const _BellState({required this.unread});
  final int unread;
}
