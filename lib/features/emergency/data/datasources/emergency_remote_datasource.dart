import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../core/constants/app_constants.dart';
import '../models/emergency_model.dart';

class EmergencyRemoteDatasource {
  final FirebaseFirestore _firestore;

  EmergencyRemoteDatasource(this._firestore);

  CollectionReference get _emergencies =>
      _firestore.collection(AppConstants.emergenciesCollection);

  Stream<List<EmergencyModel>> watchActiveEmergencies() {
    return _emergencies
        .where('status', isEqualTo: 'active')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) =>
                EmergencyModel.fromMap(doc.data() as Map<String, dynamic>, doc.id))
            .toList());
  }

  Future<void> createEmergency(EmergencyModel emergency) async {
    await _emergencies.add(emergency.toMap());
  }

  Future<void> updateEmergencyLocation(
      String emergencyId, double latitude, double longitude) async {
    await _emergencies.doc(emergencyId).update({
      'latitude': latitude,
      'longitude': longitude,
    });
  }

  Future<void> resolveEmergency(
      String emergencyId, String resolvedBy, String? notes) async {
    await _emergencies.doc(emergencyId).update({
      'status': 'resolved',
      'resolvedBy': resolvedBy,
      'notes': notes,
      'resolvedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> cancelEmergency(String emergencyId) async {
    await _emergencies.doc(emergencyId).update({
      'status': 'cancelled',
      'resolvedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<List<EmergencyModel>> getEmergencyHistory({int limit = 50}) async {
    final snapshot = await _emergencies
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();

    return snapshot.docs
        .map((doc) =>
            EmergencyModel.fromMap(doc.data() as Map<String, dynamic>, doc.id))
        .toList();
  }

  Future<EmergencyModel?> getActiveEmergencyByDriver(String driverId) async {
    final snapshot = await _emergencies
        .where('driverId', isEqualTo: driverId)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .get();

    if (snapshot.docs.isEmpty) return null;
    final doc = snapshot.docs.first;
    return EmergencyModel.fromMap(doc.data() as Map<String, dynamic>, doc.id);
  }
}
