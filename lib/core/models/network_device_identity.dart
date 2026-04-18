import 'package:equatable/equatable.dart';

class NetworkDeviceIdentity extends Equatable {
  const NetworkDeviceIdentity({
    required this.id,
    required this.deviceName,
    required this.platform,
    required this.zeroTierNodeId,
    required this.status,
    required this.hasAgentToken,
    required this.agentTokenIssuedAt,
    required this.agentToken,
  });

  factory NetworkDeviceIdentity.fromJson(Map<String, dynamic> json) {
    return NetworkDeviceIdentity(
      id: json['id']?.toString() ?? '',
      deviceName: json['deviceName']?.toString() ?? '',
      platform: json['platform']?.toString() ?? '',
      zeroTierNodeId: json['zeroTierNodeId']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      hasAgentToken: json['hasAgentToken'] as bool? ?? false,
      agentTokenIssuedAt: _parseDateTime(json['agentTokenIssuedAt']),
      agentToken: json['agentToken']?.toString() ?? '',
    );
  }

  final String id;
  final String deviceName;
  final String platform;
  final String zeroTierNodeId;
  final String status;
  final bool hasAgentToken;
  final DateTime? agentTokenIssuedAt;
  final String agentToken;

  @override
  List<Object?> get props => <Object?>[
        id,
        deviceName,
        platform,
        zeroTierNodeId,
        status,
        hasAgentToken,
        agentTokenIssuedAt,
        agentToken,
      ];
}

DateTime? _parseDateTime(dynamic value) {
  if (value == null) {
    return null;
  }

  return DateTime.tryParse(value.toString());
}
