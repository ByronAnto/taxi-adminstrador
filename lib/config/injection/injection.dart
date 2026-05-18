import 'package:get_it/get_it.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

// Core Services (Agora audio is handled by AgoraService singleton)

// Auth
import '../../features/auth/data/datasources/auth_remote_datasource.dart';
import '../../features/auth/data/repositories/auth_repository_impl.dart';
import '../../features/auth/domain/repositories/auth_repository.dart';
import '../../features/auth/domain/usecases/auth_usecases.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';

// Trips
import '../../features/trips/data/datasources/trip_remote_datasource.dart';
import '../../features/trips/data/repositories/trip_repository_impl.dart';
import '../../features/trips/domain/repositories/trip_repository.dart';
import '../../features/trips/domain/usecases/trip_usecases.dart';
import '../../features/trips/presentation/bloc/trip_bloc.dart';

// Payments
import '../../features/payments/data/datasources/payment_remote_datasource.dart';
import '../../features/payments/data/repositories/payment_repository_impl.dart';
import '../../features/payments/domain/repositories/payment_repository.dart';
import '../../features/payments/domain/usecases/payment_usecases.dart';
import '../../features/payments/presentation/bloc/payment_bloc.dart';

// Chat
import '../../features/chat/data/datasources/chat_remote_datasource.dart';
import '../../features/chat/data/repositories/chat_repository_impl.dart';
import '../../features/chat/domain/repositories/chat_repository.dart';
import '../../features/chat/domain/usecases/chat_usecases.dart';
import '../../features/chat/presentation/bloc/chat_bloc.dart';

// Communication
import '../../features/communication/data/datasources/communication_remote_datasource.dart';
import '../../features/communication/data/repositories/communication_repository_impl.dart';
import '../../features/communication/domain/repositories/communication_repository.dart';
import '../../features/communication/domain/usecases/communication_usecases.dart';
import '../../features/communication/presentation/bloc/communication_bloc.dart';

// Map
import '../../features/map/data/datasources/map_remote_datasource.dart';
import '../../features/map/data/repositories/map_repository_impl.dart';
import '../../features/map/domain/repositories/map_repository.dart';
import '../../features/map/domain/usecases/map_usecases.dart';
import '../../features/map/presentation/bloc/map_bloc.dart';

// Users
import '../../features/users/data/datasources/user_remote_datasource.dart';
import '../../features/users/data/repositories/user_repository_impl.dart';
import '../../features/users/domain/repositories/user_repository.dart';
import '../../features/users/domain/usecases/user_usecases.dart';
import '../../features/users/presentation/bloc/user_management_bloc.dart';

// Emergency
import '../../features/emergency/data/datasources/emergency_remote_datasource.dart';
import '../../features/emergency/data/repositories/emergency_repository_impl.dart';
import '../../features/emergency/domain/repositories/emergency_repository.dart';
import '../../features/emergency/domain/usecases/emergency_usecases.dart';
import '../../features/emergency/presentation/bloc/emergency_bloc.dart';

// Reports
import '../../features/reports/data/datasources/reports_remote_datasource.dart';
import '../../features/reports/data/repositories/reports_repository_impl.dart';
import '../../features/reports/domain/repositories/reports_repository.dart';
import '../../features/reports/domain/usecases/reports_usecases.dart';
import '../../features/reports/presentation/bloc/reports_bloc.dart';

/// Service Locator para inyección de dependencias
final sl = GetIt.instance;

/// Inicializa todas las dependencias de la aplicación
Future<void> initDependencies() async {
  // Firebase instances
  sl.registerLazySingleton<FirebaseAuth>(() => FirebaseAuth.instance);
  sl.registerLazySingleton<FirebaseFirestore>(() => FirebaseFirestore.instance);

  // Core Services
  // Audio en tiempo real manejado por AgoraService.instance (singleton)

  // Features
  _initAuth();
  _initTrips();
  _initPayments();
  _initChat();
  _initCommunication();
  _initMap();
  _initUsers();
  _initEmergency();
  _initReports();
}

// ======================== AUTH ========================

void _initAuth() {
  // Datasource
  sl.registerLazySingleton<AuthRemoteDatasource>(
    () => AuthRemoteDatasource(
      auth: sl<FirebaseAuth>(),
      firestore: sl<FirebaseFirestore>(),
    ),
  );

  // Repository
  sl.registerLazySingleton<AuthRepository>(
    () => AuthRepositoryImpl(remoteDatasource: sl<AuthRemoteDatasource>()),
  );

  // Use Cases
  sl.registerLazySingleton(() => SignInUseCase(sl<AuthRepository>()));
  sl.registerLazySingleton(() => SignUpUseCase(sl<AuthRepository>()));
  sl.registerLazySingleton(() => SignOutUseCase(sl<AuthRepository>()));
  sl.registerLazySingleton(() => CheckAuthUseCase(sl<AuthRepository>()));
  sl.registerLazySingleton(() => ResetPasswordUseCase(sl<AuthRepository>()));
  sl.registerLazySingleton(() => UpdateProfileUseCase(sl<AuthRepository>()));
  sl.registerLazySingleton(() => ChangePasswordUseCase(sl<AuthRepository>()));

  // Bloc
  sl.registerFactory<AuthBloc>(
    () => AuthBloc(
      signInUseCase: sl<SignInUseCase>(),
      signUpUseCase: sl<SignUpUseCase>(),
      signOutUseCase: sl<SignOutUseCase>(),
      checkAuthUseCase: sl<CheckAuthUseCase>(),
      resetPasswordUseCase: sl<ResetPasswordUseCase>(),
      updateProfileUseCase: sl<UpdateProfileUseCase>(),
      changePasswordUseCase: sl<ChangePasswordUseCase>(),
    ),
  );
}

// ======================== TRIPS ========================

void _initTrips() {
  // Datasource
  sl.registerLazySingleton<TripRemoteDatasource>(
    () => TripRemoteDatasource(firestore: sl<FirebaseFirestore>()),
  );

  // Repository
  sl.registerLazySingleton<TripRepository>(
    () => TripRepositoryImpl(remoteDatasource: sl<TripRemoteDatasource>()),
  );

  // Use Cases
  sl.registerLazySingleton(() => WatchActiveTripsUseCase(sl<TripRepository>()));
  sl.registerLazySingleton(() => WatchDriverTripsUseCase(sl<TripRepository>()));
  sl.registerLazySingleton(() => GetTripsHistoryUseCase(sl<TripRepository>()));
  sl.registerLazySingleton(() => CreateTripUseCase(sl<TripRepository>()));
  sl.registerLazySingleton(() => CompleteTripUseCase(sl<TripRepository>()));
  sl.registerLazySingleton(() => CancelTripUseCase(sl<TripRepository>()));
  sl.registerLazySingleton(() => GetDriverTripStatsUseCase(sl<TripRepository>()));

  // Bloc
  sl.registerFactory<TripBloc>(
    () => TripBloc(
      watchActiveTrips: sl<WatchActiveTripsUseCase>(),
      watchDriverTrips: sl<WatchDriverTripsUseCase>(),
      getTripsHistory: sl<GetTripsHistoryUseCase>(),
      createTrip: sl<CreateTripUseCase>(),
      completeTrip: sl<CompleteTripUseCase>(),
      cancelTrip: sl<CancelTripUseCase>(),
      getDriverTripStats: sl<GetDriverTripStatsUseCase>(),
    ),
  );
}

// ======================== PAYMENTS ========================

void _initPayments() {
  // Datasource
  sl.registerLazySingleton<PaymentRemoteDatasource>(
    () => PaymentRemoteDatasource(firestore: sl<FirebaseFirestore>()),
  );

  // Repository
  sl.registerLazySingleton<PaymentRepository>(
    () => PaymentRepositoryImpl(sl<PaymentRemoteDatasource>()),
  );

  // Use Cases
  sl.registerLazySingleton(() => WatchPaymentsUseCase(sl<PaymentRepository>()));
  sl.registerLazySingleton(() => GetPaymentsByStatusUseCase(sl<PaymentRepository>()));
  sl.registerLazySingleton(() => CreatePaymentUseCase(sl<PaymentRepository>()));
  sl.registerLazySingleton(() => MarkPaymentPaidUseCase(sl<PaymentRepository>()));
  sl.registerLazySingleton(() => GetExpensesUseCase(sl<PaymentRepository>()));
  sl.registerLazySingleton(() => CreateExpenseUseCase(sl<PaymentRepository>()));
  sl.registerLazySingleton(() => DeleteExpenseUseCase(sl<PaymentRepository>()));
  sl.registerLazySingleton(() => GetFinancialSummaryUseCase(sl<PaymentRepository>()));

  // Bloc
  sl.registerFactory<PaymentBloc>(
    () => PaymentBloc(
      watchPayments: sl<WatchPaymentsUseCase>(),
      createPayment: sl<CreatePaymentUseCase>(),
      markPaymentPaid: sl<MarkPaymentPaidUseCase>(),
      getExpenses: sl<GetExpensesUseCase>(),
      createExpense: sl<CreateExpenseUseCase>(),
      deleteExpense: sl<DeleteExpenseUseCase>(),
      getFinancialSummary: sl<GetFinancialSummaryUseCase>(),
    ),
  );
}

// ======================== CHAT ========================

void _initChat() {
  // Datasource
  sl.registerLazySingleton<ChatRemoteDatasource>(
    () => ChatRemoteDatasource(firestore: sl<FirebaseFirestore>()),
  );

  // Repository
  sl.registerLazySingleton<ChatRepository>(
    () => ChatRepositoryImpl(sl<ChatRemoteDatasource>()),
  );

  // Use Cases
  sl.registerLazySingleton(() => WatchChatRoomsUseCase(sl<ChatRepository>()));
  sl.registerLazySingleton(() => GetOrCreateChatRoomUseCase(sl<ChatRepository>()));
  sl.registerLazySingleton(() => WatchMessagesUseCase(sl<ChatRepository>()));
  sl.registerLazySingleton(() => SendMessageUseCase(sl<ChatRepository>()));
  sl.registerLazySingleton(() => MarkMessagesReadUseCase(sl<ChatRepository>()));
  sl.registerLazySingleton(() => WatchUnreadCountUseCase(sl<ChatRepository>()));

  // Bloc
  sl.registerFactory<ChatBloc>(
    () => ChatBloc(
      watchChatRooms: sl<WatchChatRoomsUseCase>(),
      getOrCreateChatRoom: sl<GetOrCreateChatRoomUseCase>(),
      watchMessages: sl<WatchMessagesUseCase>(),
      sendMessage: sl<SendMessageUseCase>(),
      markMessagesRead: sl<MarkMessagesReadUseCase>(),
    ),
  );
}

// ======================== COMMUNICATION ========================

void _initCommunication() {
  // Datasource
  sl.registerLazySingleton<CommunicationRemoteDatasource>(
    () => CommunicationRemoteDatasource(firestore: sl<FirebaseFirestore>()),
  );

  // Repository
  sl.registerLazySingleton<CommunicationRepository>(
    () => CommunicationRepositoryImpl(sl<CommunicationRemoteDatasource>()),
  );

  // Use Cases
  sl.registerLazySingleton(() => WatchChannelsUseCase(sl<CommunicationRepository>()));
  sl.registerLazySingleton(() => CreateChannelUseCase(sl<CommunicationRepository>()));
  sl.registerLazySingleton(() => JoinChannelUseCase(sl<CommunicationRepository>()));
  sl.registerLazySingleton(() => LeaveChannelUseCase(sl<CommunicationRepository>()));
  sl.registerLazySingleton(() => WatchChannelMessagesUseCase(sl<CommunicationRepository>()));
  sl.registerLazySingleton(() => SendChannelMessageUseCase(sl<CommunicationRepository>()));
  sl.registerLazySingleton(() => WatchChannelUseCase(sl<CommunicationRepository>()));
  sl.registerLazySingleton(() => LockChannelUseCase(sl<CommunicationRepository>()));
  sl.registerLazySingleton(() => UnlockChannelUseCase(sl<CommunicationRepository>()));

  // Bloc
  sl.registerFactory<CommunicationBloc>(
    () => CommunicationBloc(
      watchChannels: sl<WatchChannelsUseCase>(),
      createChannel: sl<CreateChannelUseCase>(),
      joinChannel: sl<JoinChannelUseCase>(),
      leaveChannel: sl<LeaveChannelUseCase>(),
      watchChannelMessages: sl<WatchChannelMessagesUseCase>(),
      sendChannelMessage: sl<SendChannelMessageUseCase>(),
      watchChannel: sl<WatchChannelUseCase>(),
      lockChannel: sl<LockChannelUseCase>(),
      unlockChannel: sl<UnlockChannelUseCase>(),
    ),
  );
}

// ======================== MAP ========================

void _initMap() {
  // Datasource
  sl.registerLazySingleton<MapRemoteDatasource>(
    () => MapRemoteDatasource(firestore: sl<FirebaseFirestore>()),
  );

  // Repository
  sl.registerLazySingleton<MapRepository>(
    () => MapRepositoryImpl(sl<MapRemoteDatasource>()),
  );

  // Use Cases
  sl.registerLazySingleton(() => WatchActiveDriversUseCase(sl<MapRepository>()));
  sl.registerLazySingleton(() => UpdateDriverLocationUseCase(sl<MapRepository>()));
  sl.registerLazySingleton(() => UpdateDriverStatusUseCase(sl<MapRepository>()));
  sl.registerLazySingleton(() => GetNearbyDriversUseCase(sl<MapRepository>()));
  sl.registerLazySingleton(() => WatchTaxiStandsUseCase(sl<MapRepository>()));
  sl.registerLazySingleton(() => CreateTaxiStandUseCase(sl<MapRepository>()));
  sl.registerLazySingleton(() => UpdateTaxiStandUseCase(sl<MapRepository>()));
  sl.registerLazySingleton(() => DeleteTaxiStandUseCase(sl<MapRepository>()));

  // Bloc
  sl.registerFactory<MapBloc>(
    () => MapBloc(
      watchActiveDrivers: sl<WatchActiveDriversUseCase>(),
      updateDriverLocation: sl<UpdateDriverLocationUseCase>(),
      updateDriverStatus: sl<UpdateDriverStatusUseCase>(),
      getNearbyDrivers: sl<GetNearbyDriversUseCase>(),
      watchTaxiStands: sl<WatchTaxiStandsUseCase>(),
      createTaxiStand: sl<CreateTaxiStandUseCase>(),
      updateTaxiStandUseCase: sl<UpdateTaxiStandUseCase>(),
      deleteTaxiStandUseCase: sl<DeleteTaxiStandUseCase>(),
    ),
  );
}

// ======================== USERS ========================

void _initUsers() {
  // Datasource
  sl.registerLazySingleton<UserRemoteDatasource>(
    () => UserRemoteDatasource(firestore: sl<FirebaseFirestore>()),
  );

  // Repository
  sl.registerLazySingleton<UserRepository>(
    () => UserRepositoryImpl(sl<UserRemoteDatasource>()),
  );

  // Use Cases
  sl.registerLazySingleton(() => GetAllUsersUseCase(sl<UserRepository>()));
  sl.registerLazySingleton(() => GetUsersByRoleUseCase(sl<UserRepository>()));
  sl.registerLazySingleton(() => ToggleUserActiveUseCase(sl<UserRepository>()));
  sl.registerLazySingleton(() => GetDriverRankingUseCase(sl<UserRepository>()));
  sl.registerLazySingleton(() => SearchUsersUseCase(sl<UserRepository>()));
  sl.registerLazySingleton(() => CreateDriverUseCase(sl<UserRepository>()));
  sl.registerLazySingleton(() => UpdateDriverUseCase(sl<UserRepository>()));

  // Bloc
  sl.registerFactory<UserManagementBloc>(
    () => UserManagementBloc(
      getAllUsers: sl<GetAllUsersUseCase>(),
      getUsersByRole: sl<GetUsersByRoleUseCase>(),
      toggleUserActive: sl<ToggleUserActiveUseCase>(),
      getDriverRanking: sl<GetDriverRankingUseCase>(),
      searchUsers: sl<SearchUsersUseCase>(),
      createDriver: sl<CreateDriverUseCase>(),
      updateDriver: sl<UpdateDriverUseCase>(),
    ),
  );
}

// ======================== EMERGENCY ========================

void _initEmergency() {
  // Datasource
  sl.registerLazySingleton<EmergencyRemoteDatasource>(
    () => EmergencyRemoteDatasource(sl<FirebaseFirestore>()),
  );

  // Repository
  sl.registerLazySingleton<EmergencyRepository>(
    () => EmergencyRepositoryImpl(sl<EmergencyRemoteDatasource>()),
  );

  // Use Cases
  sl.registerLazySingleton(() => WatchActiveEmergenciesUseCase(sl<EmergencyRepository>()));
  sl.registerLazySingleton(() => CreateEmergencyUseCase(sl<EmergencyRepository>()));
  sl.registerLazySingleton(() => UpdateEmergencyLocationUseCase(sl<EmergencyRepository>()));
  sl.registerLazySingleton(() => ResolveEmergencyUseCase(sl<EmergencyRepository>()));
  sl.registerLazySingleton(() => CancelEmergencyUseCase(sl<EmergencyRepository>()));
  sl.registerLazySingleton(() => GetEmergencyHistoryUseCase(sl<EmergencyRepository>()));
  sl.registerLazySingleton(() => GetActiveEmergencyByDriverUseCase(sl<EmergencyRepository>()));

  // Bloc
  sl.registerFactory<EmergencyBloc>(
    () => EmergencyBloc(
      watchActiveEmergencies: sl<WatchActiveEmergenciesUseCase>(),
      createEmergency: sl<CreateEmergencyUseCase>(),
      updateEmergencyLocation: sl<UpdateEmergencyLocationUseCase>(),
      resolveEmergency: sl<ResolveEmergencyUseCase>(),
      cancelEmergency: sl<CancelEmergencyUseCase>(),
      getEmergencyHistory: sl<GetEmergencyHistoryUseCase>(),
      getActiveByDriver: sl<GetActiveEmergencyByDriverUseCase>(),
    ),
  );
}

// ======================== REPORTS ========================

void _initReports() {
  // Datasource
  sl.registerLazySingleton<ReportsRemoteDatasource>(
    () => ReportsRemoteDatasource(firestore: sl<FirebaseFirestore>()),
  );

  // Repository
  sl.registerLazySingleton<ReportsRepository>(
    () => ReportsRepositoryImpl(remoteDatasource: sl<ReportsRemoteDatasource>()),
  );

  // UseCases
  sl.registerLazySingleton(() => GetReportDataUseCase(sl<ReportsRepository>()));

  // Bloc
  sl.registerFactory<ReportsBloc>(
    () => ReportsBloc(getReportData: sl<GetReportDataUseCase>()),
  );
}
