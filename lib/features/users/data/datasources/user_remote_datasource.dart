import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../auth/data/models/user_model.dart';
import '../models/driver_model.dart';
import '../../../../core/constants/app_constants.dart';

class UserRemoteDatasource {
  final FirebaseFirestore _firestore;

  UserRemoteDatasource({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference get _usersRef =>
      _firestore.collection(AppConstants.usersCollection);

  CollectionReference get _driversRef =>
      _firestore.collection(AppConstants.driversCollection);

  // ========== USERS ==========

  Future<List<UserModel>> getAllUsers() async {
    final snapshot = await _usersRef.orderBy('name').get();
    return snapshot.docs.map((doc) => UserModel.fromFirestore(doc)).toList();
  }

  Future<List<UserModel>> getUsersByRole(String role) async {
    final snapshot = await _usersRef
        .where('role', isEqualTo: role)
        .orderBy('name')
        .get();
    return snapshot.docs.map((doc) => UserModel.fromFirestore(doc)).toList();
  }

  Future<void> toggleUserActive(String userId, bool isActive) async {
    await _usersRef.doc(userId).update({
      'isActive': isActive,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    });
  }

  Future<List<UserModel>> searchUsers(String query) async {
    final queryLower = query.toLowerCase();
    // Firestore no soporta búsqueda full-text, se obtienen todos y se filtran
    final snapshot = await _usersRef.get();
    return snapshot.docs
        .map((doc) => UserModel.fromFirestore(doc))
        .where((user) =>
            user.name.toLowerCase().contains(queryLower) ||
            user.lastname.toLowerCase().contains(queryLower) ||
            user.cedula.contains(query) ||
            user.email.toLowerCase().contains(queryLower))
        .toList();
  }

  // ========== DRIVERS ==========

  Future<List<DriverModel>> getAllDrivers() async {
    final snapshot = await _driversRef.get();
    return snapshot.docs.map((doc) => DriverModel.fromFirestore(doc)).toList();
  }

  Future<DriverModel?> getDriverByUserId(String userId) async {
    final snapshot = await _driversRef
        .where('userId', isEqualTo: userId)
        .limit(1)
        .get();
    if (snapshot.docs.isEmpty) return null;
    return DriverModel.fromFirestore(snapshot.docs.first);
  }

  Future<void> createDriver(DriverModel driver) async {
    await _driversRef.doc(driver.uid).set(driver.toFirestore());
  }

  Future<void> updateDriver(DriverModel driver) async {
    await _driversRef.doc(driver.uid).update(driver.toFirestore());
  }

  Future<List<DriverModel>> getDriverRanking({int limit = 20}) async {
    final snapshot = await _driversRef
        .where('isActive', isEqualTo: true)
        .orderBy('totalPoints', descending: true)
        .limit(limit)
        .get();
    return snapshot.docs.map((doc) => DriverModel.fromFirestore(doc)).toList();
  }
}
