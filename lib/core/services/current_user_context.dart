/// Contexto global del usuario autenticado.
///
/// Singleton ligero que mantiene el `associationId` y el `uid` del usuario
/// actual para que servicios y datasources puedan filtrar queries por
/// tenant sin tener que recibir el AuthBloc por dependency injection.
///
/// Lo settea AuthBloc cuando se entra a `AuthAuthenticated` y se limpia en
/// logout. Es complementario al JWT custom claim (que es la fuente de verdad
/// del lado del servidor para las reglas Firestore).
class CurrentUserContext {
  CurrentUserContext._();
  static final CurrentUserContext instance = CurrentUserContext._();

  String? _associationId;
  String? _uid;
  String? _role;

  String? get associationId => _associationId;
  String? get uid => _uid;
  String? get role => _role;

  void set({
    required String uid,
    required String associationId,
    required String role,
  }) {
    _uid = uid;
    _associationId = associationId;
    _role = role;
  }

  void clear() {
    _uid = null;
    _associationId = null;
    _role = null;
  }
}
