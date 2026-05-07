import 'package:equatable/equatable.dart';

/// Clase base abstracta para Use Cases
abstract class UseCase<T, Params> {
  Future<T> call(Params params);
}

/// Para use cases que no requieren parámetros
class NoParams extends Equatable {
  @override
  List<Object?> get props => [];
}
