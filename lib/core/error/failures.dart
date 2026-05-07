import 'package:equatable/equatable.dart';

/// Clase base para errores del dominio
abstract class Failure extends Equatable {
  final String message;

  const Failure(this.message);

  @override
  List<Object> get props => [message];
}

/// Error de servidor (Firebase, API)
class ServerFailure extends Failure {
  const ServerFailure([super.message = 'Error del servidor']);
}

/// Error de conexión a internet
class NetworkFailure extends Failure {
  const NetworkFailure([super.message = 'Sin conexión a internet']);
}

/// Error de caché local
class CacheFailure extends Failure {
  const CacheFailure([super.message = 'Error de caché local']);
}

/// Error de autenticación
class AuthFailure extends Failure {
  const AuthFailure([super.message = 'Error de autenticación']);
}

/// Error de permisos
class PermissionFailure extends Failure {
  const PermissionFailure([super.message = 'Permiso denegado']);
}

/// Error de validación
class ValidationFailure extends Failure {
  const ValidationFailure([super.message = 'Error de validación']);
}

/// Error no encontrado
class NotFoundFailure extends Failure {
  const NotFoundFailure([super.message = 'Recurso no encontrado']);
}
