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
    );
  }

  final String id;
  final String type;
  final String status;
  final Map<String, dynamic> payload;
  final String? deviceId;
  final String? sessionId;
  final String? errorMessage;

  @override
  List<Object?> get props => <Object?>[
        id,
        type,
        status,
        payload,
        deviceId,
        sessionId,
        errorMessage,
      ];
}
