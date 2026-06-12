import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo de canal de comunicación para walkie-talkie
class ChannelModel {
  final String uid;

  /// Multi-tenant: slug de la asociación dueña del canal. Vacío en docs
  /// legacy migrados (las reglas asumen 'jipijapa' como fallback).
  final String associationId;

  final String name;
  final String description;
  final String type; // publico, privado
  final String createdBy;
  final List<String> memberIds;
  final bool isActive;
  final DateTime createdAt;

  /// Roles que entran a este canal por defecto cuando no tienen otro
  /// canal seleccionado. Ej. ['conductor'] hace que todos los conductores
  /// caigan acá al abrir Radio. Si vacío, no es default para nadie.
  /// Cualquier canal puede ser default; el último creado gana si hay 2.
  final List<String> defaultForRoles;

  // === PTT Lock (Zello-style) ===
  final String? currentSpeakerId;
  final String? currentSpeakerName;
  final DateTime? speakerLockedAt;

  const ChannelModel({
    required this.uid,
    this.associationId = '',
    required this.name,
    this.description = '',
    this.type = 'publico',
    required this.createdBy,
    this.memberIds = const [],
    this.isActive = true,
    required this.createdAt,
    this.currentSpeakerId,
    this.currentSpeakerName,
    this.speakerLockedAt,
    this.defaultForRoles = const [],
  });

  /// Devuelve una copia del canal con el lock del PTT SOBREESCRITO por los
  /// valores efímeros provenientes de RTDB (`/channelLocks`).
  ///
  /// A diferencia de [copyWith], aquí los tres campos del lock se ASIGNAN
  /// explícitamente (incluyendo `null`), porque el nodo RTDB es la fuente de
  /// verdad del lock cuando el flag está ON: si no hay speaker, deben quedar
  /// en null (estado "nadie habla"), y `speakerLockedAt` puede ser null
  /// momentáneamente mientras el ServerValue.timestamp se resuelve sin que
  /// se herede un valor viejo de Firestore.
  ChannelModel withLock({
    required String? currentSpeakerId,
    required String? currentSpeakerName,
    required DateTime? speakerLockedAt,
  }) {
    return ChannelModel(
      uid: uid,
      associationId: associationId,
      name: name,
      description: description,
      type: type,
      createdBy: createdBy,
      memberIds: memberIds,
      isActive: isActive,
      createdAt: createdAt,
      currentSpeakerId: currentSpeakerId,
      currentSpeakerName: currentSpeakerName,
      speakerLockedAt: speakerLockedAt,
      defaultForRoles: defaultForRoles,
    );
  }

  /// True si este canal es el default para [role] (admin/operadora/conductor).
  bool isDefaultForRole(String role) => defaultForRoles.contains(role);

  /// True si [userId] puede ver/usar este canal:
  /// - Canal público: todos los del tenant.
  /// - Canal privado: solo si está en memberIds (o el admin que lo creó).
  bool isAccessibleBy({
    required String userId,
    required String role,
  }) {
    if (type == 'publico') return true;
    if (createdBy == userId) return true;
    if (memberIds.contains(userId)) return true;
    return false;
  }

  /// Verifica si el canal está bloqueado por algún hablante
  bool get isLocked => currentSpeakerId != null && currentSpeakerId!.isNotEmpty;

  /// Verifica si el canal está bloqueado por un usuario específico
  bool isLockedBy(String userId) => currentSpeakerId == userId;

  /// Verifica si el bloqueo expiró (timeout de seguridad: 35 segundos)
  bool get isLockExpired {
    if (speakerLockedAt == null) return true;
    return DateTime.now().difference(speakerLockedAt!) > const Duration(seconds: 35);
  }

  factory ChannelModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ChannelModel(
      uid: doc.id,
      associationId: data['associationId'] ?? '',
      name: data['name'] ?? '',
      description: data['description'] ?? '',
      type: data['type'] ?? 'publico',
      createdBy: data['createdBy'] ?? '',
      memberIds: List<String>.from(data['memberIds'] ?? []),
      isActive: data['isActive'] ?? true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      currentSpeakerId: data['currentSpeakerId'],
      currentSpeakerName: data['currentSpeakerName'],
      speakerLockedAt: (data['speakerLockedAt'] as Timestamp?)?.toDate(),
      defaultForRoles:
          List<String>.from(data['defaultForRoles'] ?? const []),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'associationId': associationId,
      'name': name,
      'description': description,
      'type': type,
      'createdBy': createdBy,
      'memberIds': memberIds,
      'isActive': isActive,
      'createdAt': Timestamp.fromDate(createdAt),
      'currentSpeakerId': currentSpeakerId,
      'currentSpeakerName': currentSpeakerName,
      'speakerLockedAt': speakerLockedAt != null
          ? Timestamp.fromDate(speakerLockedAt!)
          : null,
      'defaultForRoles': defaultForRoles,
    };
  }

  ChannelModel copyWith({
    String? name,
    String? description,
    String? type,
    List<String>? memberIds,
    bool? isActive,
    String? currentSpeakerId,
    String? currentSpeakerName,
    DateTime? speakerLockedAt,
    List<String>? defaultForRoles,
    bool clearSpeaker = false,
  }) {
    return ChannelModel(
      uid: uid,
      associationId: associationId,
      name: name ?? this.name,
      description: description ?? this.description,
      type: type ?? this.type,
      createdBy: createdBy,
      memberIds: memberIds ?? this.memberIds,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
      currentSpeakerId: clearSpeaker ? null : (currentSpeakerId ?? this.currentSpeakerId),
      currentSpeakerName: clearSpeaker ? null : (currentSpeakerName ?? this.currentSpeakerName),
      speakerLockedAt: clearSpeaker ? null : (speakerLockedAt ?? this.speakerLockedAt),
      defaultForRoles: defaultForRoles ?? this.defaultForRoles,
    );
  }
}

/// Modelo de mensaje (voz, texto)
class MessageModel {
  final String uid;

  /// Multi-tenant: slug de la asociación. Las reglas Firestore lo exigen.
  final String associationId;

  final String channelId;
  final String senderId;
  final String senderName;

  /// Número de unidad/vehículo de quien envió (resuelto por el bot grabador
  /// desde `users/{uid}.numeroVehiculo`). Vacío/null en mensajes viejos o de
  /// usuarios sin unidad. Se muestra como "Unidad #N · Nombre".
  final String? senderVehiculo;

  final String type; // texto, voz
  final String? text;
  final String? audioBase64; // audio codificado en base64 para PTT cortos
  final int? durationSeconds; // para mensajes de voz

  /// URL del audio respaldado (.wav) servido por el bot grabador server-side
  /// (https://livekit.it-services.center/rec/...). Cuando está presente, el
  /// mensaje de voz se puede REPRODUCIR en el chat del canal. Los mensajes
  /// viejos (solo metadatos) tienen este campo en null.
  final String? audioUrl;

  final DateTime createdAt;

  const MessageModel({
    required this.uid,
    this.associationId = '',
    required this.channelId,
    required this.senderId,
    required this.senderName,
    this.senderVehiculo,
    required this.type,
    this.text,
    this.audioBase64,
    this.durationSeconds,
    this.audioUrl,
    required this.createdAt,
  });

  factory MessageModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return MessageModel(
      uid: doc.id,
      associationId: data['associationId'] ?? '',
      channelId: data['channelId'] ?? '',
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? '',
      senderVehiculo: data['senderVehiculo'] as String?,
      type: data['type'] ?? 'texto',
      text: data['text'],
      audioBase64: data['audioBase64'],
      durationSeconds: data['durationSeconds'],
      audioUrl: data['audioUrl'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'associationId': associationId,
      'channelId': channelId,
      'senderId': senderId,
      'senderName': senderName,
      'senderVehiculo': senderVehiculo,
      'type': type,
      'text': text,
      'audioBase64': audioBase64,
      'durationSeconds': durationSeconds,
      'audioUrl': audioUrl,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}
