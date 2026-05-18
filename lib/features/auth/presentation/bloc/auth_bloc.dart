import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../domain/usecases/auth_usecases.dart';
import '../../data/models/user_model.dart';
import '../../../../core/services/session_teardown_service.dart';
import '../../../../core/usecases/usecase.dart';

// ============ EVENTS ============

abstract class AuthEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class AuthCheckRequested extends AuthEvent {}

class AuthSignInRequested extends AuthEvent {
  final String email;
  final String password;

  AuthSignInRequested({required this.email, required this.password});

  @override
  List<Object?> get props => [email, password];
}

class AuthSignUpRequested extends AuthEvent {
  final String email;
  final String password;
  final String name;
  final String lastname;
  final String cedula;
  final String phone;
  final String role;
  final String associationId;
  final bool requiresApproval;
  final String placa;
  final String cooperativa;
  final String codigoCooperativa;
  final String numeroVehiculo;
  final String? fotoVehiculo;
  final String? fotoLicenciaFrontal;
  final String? fotoLicenciaTrasera;

  AuthSignUpRequested({
    required this.email,
    required this.password,
    required this.name,
    required this.lastname,
    required this.cedula,
    required this.phone,
    required this.role,
    required this.associationId,
    this.requiresApproval = true,
    this.placa = '',
    this.cooperativa = '',
    this.codigoCooperativa = '',
    this.numeroVehiculo = '',
    this.fotoVehiculo,
    this.fotoLicenciaFrontal,
    this.fotoLicenciaTrasera,
  });

  @override
  List<Object?> get props => [email, password, name, lastname, cedula, phone, role, associationId, requiresApproval, placa, cooperativa, codigoCooperativa, numeroVehiculo];
}

class AuthSignOutRequested extends AuthEvent {}

class AuthResetPasswordRequested extends AuthEvent {
  final String email;

  AuthResetPasswordRequested({required this.email});

  @override
  List<Object?> get props => [email];
}

class AuthUpdateProfileRequested extends AuthEvent {
  final UserModel user;

  AuthUpdateProfileRequested({required this.user});

  @override
  List<Object?> get props => [user];
}

class AuthChangePasswordRequested extends AuthEvent {
  final String currentPassword;
  final String newPassword;

  AuthChangePasswordRequested({
    required this.currentPassword,
    required this.newPassword,
  });

  @override
  List<Object?> get props => [currentPassword, newPassword];
}

// ============ STATES ============

abstract class AuthState extends Equatable {
  @override
  List<Object?> get props => [];
}

class AuthInitial extends AuthState {}

class AuthLoading extends AuthState {}

class AuthAuthenticated extends AuthState {
  final UserModel user;

  AuthAuthenticated({required this.user});

  @override
  List<Object?> get props => [user];
}

class AuthUnauthenticated extends AuthState {}

class AuthError extends AuthState {
  final String message;

  AuthError({required this.message});

  @override
  List<Object?> get props => [message];
}

class AuthPasswordResetSent extends AuthState {}

class AuthProfileUpdated extends AuthState {}

class AuthPasswordChanged extends AuthState {}

class AuthPasswordChangeFailure extends AuthState {
  final String message;
  AuthPasswordChangeFailure(this.message);
  @override
  List<Object?> get props => [message];
}

// ============ BLOC ============

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final SignInUseCase signInUseCase;
  final SignUpUseCase signUpUseCase;
  final SignOutUseCase signOutUseCase;
  final CheckAuthUseCase checkAuthUseCase;
  final ResetPasswordUseCase resetPasswordUseCase;
  final UpdateProfileUseCase updateProfileUseCase;
  final ChangePasswordUseCase changePasswordUseCase;

  AuthBloc({
    required this.signInUseCase,
    required this.signUpUseCase,
    required this.signOutUseCase,
    required this.checkAuthUseCase,
    required this.resetPasswordUseCase,
    required this.updateProfileUseCase,
    required this.changePasswordUseCase,
  }) : super(AuthInitial()) {
    on<AuthCheckRequested>(_onCheckRequested);
    on<AuthSignInRequested>(_onSignInRequested);
    on<AuthSignUpRequested>(_onSignUpRequested);
    on<AuthSignOutRequested>(_onSignOutRequested);
    on<AuthResetPasswordRequested>(_onResetPasswordRequested);
    on<AuthUpdateProfileRequested>(_onUpdateProfileRequested);
    on<AuthChangePasswordRequested>(_onChangePasswordRequested);
  }

  Future<void> _onCheckRequested(
    AuthCheckRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthLoading());
    try {
      final user = await checkAuthUseCase(NoParams());
      if (user != null) {
        if (user.isActive) {
          emit(AuthAuthenticated(user: user));
        } else {
          await _cleanSignOut();
          emit(AuthError(message: 'Tu cuenta ha sido desactivada. Contacta al administrador.'));
        }
      } else {
        emit(AuthUnauthenticated());
      }
    } catch (e) {
      emit(AuthUnauthenticated());
    }
  }

  Future<void> _onSignInRequested(
    AuthSignInRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthLoading());
    try {
      final user = await signInUseCase(
        SignInParams(email: event.email, password: event.password),
      );
      if (!user.isActive) {
        await _cleanSignOut();
        emit(AuthError(message: 'Tu cuenta ha sido desactivada. Contacta al administrador.'));
        return;
      }
      emit(AuthAuthenticated(user: user));
    } catch (e) {
      String message = 'Error al iniciar sesión';
      if (e.toString().contains('user-not-found')) {
        message = 'No existe una cuenta con ese correo';
      } else if (e.toString().contains('wrong-password')) {
        message = 'Contraseña incorrecta';
      } else if (e.toString().contains('invalid-email')) {
        message = 'Correo electrónico inválido';
      } else if (e.toString().contains('too-many-requests')) {
        message = 'Demasiados intentos. Intenta más tarde';
      }
      emit(AuthError(message: message));
    }
  }

  Future<void> _onSignUpRequested(
    AuthSignUpRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthLoading());
    try {
      final user = await signUpUseCase(SignUpParams(
        email: event.email,
        password: event.password,
        name: event.name,
        lastname: event.lastname,
        cedula: event.cedula,
        phone: event.phone,
        role: event.role,
        associationId: event.associationId,
        requiresApproval: event.requiresApproval,
        placa: event.placa,
        cooperativa: event.cooperativa,
        codigoCooperativa: event.codigoCooperativa,
        numeroVehiculo: event.numeroVehiculo,
        fotoVehiculo: event.fotoVehiculo,
        fotoLicenciaFrontal: event.fotoLicenciaFrontal,
        fotoLicenciaTrasera: event.fotoLicenciaTrasera,
      ));
      emit(AuthAuthenticated(user: user));
    } catch (e) {
      String message = 'Error al registrar usuario';
      if (e.toString().contains('email-already-in-use')) {
        message = 'Ya existe una cuenta con ese correo';
      } else if (e.toString().contains('cédula')) {
        message = e.toString();
      }
      emit(AuthError(message: message));
    }
  }

  Future<void> _onSignOutRequested(
    AuthSignOutRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthLoading());
    await _cleanSignOut();
    emit(AuthUnauthenticated());
  }

  /// Cierra la sesión limpia: ejecuta el teardown coordinado (apaga
  /// Agora, GPS, FGS, marca driver offline + isActive=false, retira FCM
  /// token) ANTES del signOut. Sin esto, el conductor seguía visible
  /// en el mapa de la operadora con su última posición y dentro del
  /// canal de Agora consumiendo billing.
  Future<void> _cleanSignOut() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    await SessionTeardownService.disposeAll(uid: uid);
    await signOutUseCase(NoParams());
  }

  Future<void> _onResetPasswordRequested(
    AuthResetPasswordRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthLoading());
    try {
      await resetPasswordUseCase(event.email);
      emit(AuthPasswordResetSent());
    } catch (e) {
      emit(AuthError(message: 'Error al enviar correo de recuperación'));
    }
  }

  Future<void> _onUpdateProfileRequested(
    AuthUpdateProfileRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthLoading());
    try {
      await updateProfileUseCase(event.user);
      emit(AuthProfileUpdated());
    } catch (e) {
      emit(AuthError(message: 'Error al actualizar perfil: $e'));
    }
  }

  Future<void> _onChangePasswordRequested(
    AuthChangePasswordRequested event,
    Emitter<AuthState> emit,
  ) async {
    // Guardamos el usuario actual para restaurar su estado tras el cambio.
    final currentState = state;
    final currentUser =
        currentState is AuthAuthenticated ? currentState.user : null;
    try {
      await changePasswordUseCase(ChangePasswordParams(
        currentPassword: event.currentPassword,
        newPassword: event.newPassword,
      ));
      emit(AuthPasswordChanged());
    } catch (e) {
      String msg = 'No pudimos cambiar tu contraseña.';
      final s = e.toString();
      if (s.contains('wrong-password') || s.contains('invalid-credential')) {
        msg = 'La contraseña actual es incorrecta.';
      } else if (s.contains('weak-password')) {
        msg = 'La contraseña nueva es demasiado débil (mínimo 6 caracteres).';
      } else if (s.contains('requires-recent-login')) {
        msg = 'Por seguridad, vuelve a iniciar sesión y reintenta.';
      } else if (s.contains('too-many-requests')) {
        msg = 'Demasiados intentos. Intenta más tarde.';
      }
      emit(AuthPasswordChangeFailure(msg));
    } finally {
      // Restaurar AuthAuthenticated para que la UI no se quede en estado raro.
      if (currentUser != null) {
        emit(AuthAuthenticated(user: currentUser));
      }
    }
  }
}
