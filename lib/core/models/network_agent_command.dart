import 'package:equatable/equatable.dart';

class NetworkAgentCommand extends Equatable {
  const NetworkAgentCommand({
    required this.id,
    required this.type,
    required this.status,
    required this.payload,
    this.deviceId,
    this.sessionId,
    this.errorMessage,
    this.createdAt,
    this.deliveredAt,
    this.acknowledgedAt,
  });

  factory NetworkAgentCommand.fromJson(Map<String, dynamic> json) {
    return NetworkAgentCommand(
      id: json['id']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      payload: (json['payload'] is Map)
          ? (json['payload'] as Map).map(
              (dynamic key, dynamic value) => MapEntry(key.toString(), value),
            )
          : const <String, dynamic>{},
      deviceId: json['deviceId']?.toString(),
      sessionId: json['sessionId']?.toString(),
      errorMessage: json['errorMessage']?.toString(),
      createdAt: _parseDateTime(json['createdAt']),
      deliveredAt: _parseDateTime(json['deliveredAt']),
      acknowledgedAt: _parseDateTime(json['acknowledgedAt']),
    );
  }

  final String id;
  final String type;
  final String status;
  final Map<String, dynamic> payload;
  final String? deviceId;
  final String? sessionId;
  final String? errorMessage;
  final DateTime? createdAt;
  final DateTime? deliveredAt;
  final DateTime? acknowledgedAt;

  bool get isCancelled => status == 'cancelled';
  bool get isSuperseded => status == 'superseded';
  bool get isExpired => status == 'expired';
  bool get isFinal =>
      status == 'acknowledged' ||
      status == 'failed' ||
      status == 'cancelled' ||
      isSuperseded ||
      isExpired;
  bool get isSkipped => isCancelled || isSuperseded || isExpired;

  @override
  List<Object?> get props => <Object?>[
        id,
        type,
        status,
        payload,
        deviceId,
        sessionId,
        errorMessage,
        createdAt,
        deliveredAt,
        acknowledgedAt,
      ];
}

DateTime? _parseDateTime(dynamic value) {
  if (value == null) {
    return null;
  }

  return DateTime.tryParse(value.toString());
}
