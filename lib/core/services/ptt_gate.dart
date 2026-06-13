import 'package:flutter/foundation.dart';

/// Resultado de intentar arrancar una transmisión PTT.
enum PttStartStatus {
  /// Proceder con la transmisión. El caller DEBE llamar [PttGate.endOp] al
  /// terminar el arranque (éxito o error).
  allowed,

  /// Hay otra operación de PTT en vuelo (otro press/release procesándose).
  /// Ignorar este press — NO mostrar aviso (es ruido de dedo).
  inFlight,

  /// Rate-limit activo (castigo por spam). Mostrar aviso con [blockedSeconds].
  blocked,
}

class PttStartDecision {
  final PttStartStatus status;
  final int blockedSeconds;
  const PttStartDecision(this.status, [this.blockedSeconds = 0]);

  bool get allowed => status == PttStartStatus.allowed;
}

/// Portón ÚNICO y COMPARTIDO de control del PTT, usado por AMBOS botones (el
/// de la pantalla del walkie y el botón flotante del overlay). Centraliza:
///
///  1. **Guard en vuelo**: un press nuevo se ignora mientras el press/release
///     anterior sigue procesándose. El release NUNCA se bloquea (soltar
///     siempre libera el mic). Evita el mic "pegado" por clicks rápidos.
///
///  2. **Rate-limit estilo Zello**: [_emptyLimit] transmisiones "vacías"
///     (duración < [_emptyMax]) dentro de la ventana deslizante [_spamWindow]
///     bloquean el PTT por [_blockTime] con aviso. Una transmisión válida
///     (habló de verdad) limpia el contador.
///
/// Al vivir en un singleton, los DOS botones comparten el mismo estado: el
/// castigo y el guard valen sin importar por cuál botón se spamee (decisión
/// Byron 2026-06-12: "todas las mejoras del mic van a los dos botones").
class PttGate {
  PttGate._();
  static final PttGate instance = PttGate._();

  static const Duration _spamWindow = Duration(seconds: 8);
  static const Duration _emptyMax = Duration(seconds: 1);
  static const int _emptyLimit = 4;
  static const Duration _blockTime = Duration(seconds: 15);

  int _inFlight = 0;
  DateTime? _pressedAt;
  final List<DateTime> _emptyPresses = [];
  DateTime? _blockedUntil;

  /// Intenta arrancar una transmisión. Si devuelve [PttStartStatus.allowed],
  /// marca la operación como en-vuelo y registra el instante del press; el
  /// caller DEBE llamar [endOp] al terminar el arranque.
  PttStartDecision beginPress() {
    final until = _blockedUntil;
    if (until != null) {
      final now = DateTime.now();
      if (now.isBefore(until)) {
        return PttStartDecision(
            PttStartStatus.blocked, until.difference(now).inSeconds + 1);
      }
      _blockedUntil = null; // castigo cumplido
    }
    if (_inFlight > 0) return const PttStartDecision(PttStartStatus.inFlight);
    _inFlight++;
    _pressedAt = DateTime.now();
    return const PttStartDecision(PttStartStatus.allowed);
  }

  /// Arranca el RELEASE (soltar). Nunca se bloquea: soltar siempre libera el
  /// mic. Cuenta como operación en-vuelo para que un press inmediato no se
  /// encime con el muteo pendiente. Devuelve si la transmisión fue "vacía"
  /// (< [_emptyMax]) para alimentar el rate-limit en [registerUsage].
  bool beginRelease() {
    final pressedAt = _pressedAt;
    _pressedAt = null;
    _inFlight++;
    return pressedAt != null &&
        DateTime.now().difference(pressedAt) < _emptyMax;
  }

  /// Llamar SIEMPRE al terminar un beginPress/beginRelease (en el finally).
  void endOp() {
    if (_inFlight > 0) _inFlight--;
  }

  /// Contabiliza el uso tras el release para el rate-limit. Devuelve los
  /// segundos de castigo si se ACABA de activar el bloqueo (para que el caller
  /// muestre el aviso), o null si no hay castigo.
  int? registerUsage(bool wasEmpty) {
    if (!wasEmpty) {
      _emptyPresses.clear(); // habló de verdad → redención
      return null;
    }
    final now = DateTime.now();
    _emptyPresses.add(now);
    _emptyPresses.removeWhere((t) => now.difference(t) > _spamWindow);
    if (_emptyPresses.length >= _emptyLimit) {
      _emptyPresses.clear();
      _blockedUntil = now.add(_blockTime);
      debugPrint('🚫 PttGate: $_emptyLimit vacíos en ${_spamWindow.inSeconds}s '
          '→ bloqueado ${_blockTime.inSeconds}s');
      return _blockTime.inSeconds;
    }
    return null;
  }

  /// Segundos restantes de castigo si está bloqueado AHORA, o null.
  int? get blockedSecondsRemaining {
    final until = _blockedUntil;
    if (until == null) return null;
    final now = DateTime.now();
    if (now.isBefore(until)) return until.difference(now).inSeconds + 1;
    return null;
  }
}
