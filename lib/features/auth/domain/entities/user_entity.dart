import 'package:equatable/equatable.dart';

/// Entidad de usuario base
class UserEntity extends Equatable {
  final String uid;
  final String name;
  final String lastname;
  final String cedula;
  final String email;
  final String phone;
  final String role; // admin, conductor, operadora
  final String? photoUrl;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Campos de conductor/cooperativa
  final String placa;
  final String cooperativa;
  final String codigoCooperativa;
  final String numeroVehiculo; // Identificador en la red de Jipijapa
  final String? fotoVehiculo;
  final String? fotoLicenciaFrontal;
  final String? fotoLicenciaTrasera;

  const UserEntity({
    required this.uid,
    required this.name,
    required this.lastname,
    required this.cedula,
    required this.email,
    required this.phone,
    required this.role,
    this.photoUrl,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
    this.placa = '',
    this.cooperativa = '',
    this.codigoCooperativa = '',
    this.numeroVehiculo = '',
    this.fotoVehiculo,
    this.fotoLicenciaFrontal,
    this.fotoLicenciaTrasera,
  });

  @override
  List<Object?> get props => [uid, cedula, email];
}
