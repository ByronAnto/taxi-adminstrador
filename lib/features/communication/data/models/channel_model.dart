import 'package:cloud_firestore/cloud_firestore.dart';

/// Modelo de canal de comunicación para walkie-talkie
class ChannelModel {
  final String uid;
  final String name;
  final String description;
  final String type; // publico, privado
  final String createdBy;
  final List<String> memberIds;
  final bool isActive;
  final DateTime createdAt;

  // === PTT Lock (Zello-style) ===
  final String? currentSpeakerId;
  final String? currentSpeakerName;
  final DateTime? speakerLockedAt;

  const ChannelModel({
    required this.uid,
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
  });

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
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
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
    bool clearSpeaker = false,
  }) {
    return ChannelModel(
      uid: uid,
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
    );
  }
}

/// Modelo de mensaje (voz, texto)
class MessageModel {
  final String uid;
  final String channelId;
  final String senderId;
  final String senderName;
  final String type; // texto, voz
  final String? text;
  final String? audioBase64; // audio codificado en base64 para PTT cortos
  final int? durationSeconds; // para mensajes de voz
  final DateTime createdAt;

  const MessageModel({
    required this.uid,
    required this.channelId,
    required this.senderId,
    required this.senderName,
    required this.type,
    this.text,
    this.audioBase64,
    this.durationSeconds,
    required this.createdAt,
  });

  factory MessageModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return MessageModel(
      uid: doc.id,
      channelId: data['channelId'] ?? '',
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? '',
      type: data['type'] ?? 'texto',
      text: data['text'],
      audioBase64: data['audioBase64'],
      durationSeconds: data['durationSeconds'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'channelId': channelId,
      'senderId': senderId,
      'senderName': senderName,
      'type': type,
      'text': text,
      'audioBase64': audioBase64,
      'durationSeconds': durationSeconds,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}
