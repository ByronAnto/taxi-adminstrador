import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

/// Servicio para subir imágenes a Firebase Storage
class ImageUploadService {
  static final ImageUploadService _instance = ImageUploadService._internal();
  factory ImageUploadService() => _instance;
  ImageUploadService._internal();

  final FirebaseStorage _storage = FirebaseStorage.instance;
  final ImagePicker _picker = ImagePicker();

  /// Seleccionar imagen desde cámara o galería
  Future<File?> pickImage({
    required ImageSource source,
    int imageQuality = 70,
    double maxWidth = 1024,
  }) async {
    final XFile? pickedFile = await _picker.pickImage(
      source: source,
      imageQuality: imageQuality,
      maxWidth: maxWidth,
    );
    if (pickedFile != null) {
      return File(pickedFile.path);
    }
    return null;
  }

  /// Subir imagen a Firebase Storage y retornar URL
  Future<String> uploadImage({
    required File file,
    required String path, // ej: 'users/uid/vehiculo.jpg'
  }) async {
    final ref = _storage.ref().child(path);
    final uploadTask = await ref.putFile(
      file,
      SettableMetadata(contentType: 'image/jpeg'),
    );
    return await uploadTask.ref.getDownloadURL();
  }

  /// Subir imagen de perfil de usuario
  Future<String> uploadUserImage({
    required File file,
    required String uid,
    required String tipo, // vehiculo, licencia_frontal, licencia_trasera
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final path = 'users/$uid/${tipo}_$timestamp.jpg';
    return await uploadImage(file: file, path: path);
  }

  /// Mostrar diálogo para elegir cámara o galería
  /// Retorna el File seleccionado o null
  Future<File?> pickImageWithSource({required ImageSource source}) async {
    return await pickImage(source: source);
  }
}
