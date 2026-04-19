import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/network_agent_command.dart';

class PairingSession extends Equatable {
  const PairingSession({
    required this.id,
    required this.status,
    required this.initiatorDevice,
    required this.targetDevice,
    required this.allowedPorts,
    required this.zeroTierBindings,
    required this.commands,
    this.createdByUser,
    this.createdAt,
    this.updatedAt,
    this.expiresAt,
    this.joinedAt,
    this.activatedAt,
    this.revokedAt,
    this.closedReason,
    this.zeroTierNetworkId,
    this.zeroTierNetworkName,
  });

  factory PairingSession.fromJson(Map<String, dynamic> json) {
    return PairingSession(
      id: json['id']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      initiatorDevice: PairingSessionDevice.fromJson(
        _mapOrEmpty(json['initiatorDevice']),
      ),
      targetDevice: PairingSessionDevice.fromJson(
        _mapOrEmpty(json['targetDevice']),
      ),
      allowedPorts: _mapList(json['allowedPorts'])
          .map(PairingSessionPortPolicy.fromJson)
          .toList(growable: false),
      zeroTierBindings: _mapList(json['zeroTierBindings'])
          .map(PairingSessionZeroTierBinding.fromJson)
          .toList(growable: false),
      commands: _mapList(json['commands'])
          .map(NetworkAgentCommand.fromJson)
          .toList(growable: false),
      createdByUser: json['createdByUser'] is Map
          ? PairingSessionUser.fromJson(_mapOrEmpty(json['createdByUser']))
          : null,
      createdAt: _parseDateTime(json['createdAt']),
      updatedAt: _parseDateTime(json['updatedAt']),
      expiresAt: _parseDateTime(json['expiresAt']),
      joinedAt: _parseDateTime(json['joinedAt']),
      activatedAt: _parseDateTime(json['activatedAt']),
      revokedAt: _parseDateTime(json['revokedAt']),
      closedReason: json['closedReason']?.toString(),
      zeroTierNetworkId: json['zeroTierNetworkId']?.toString(),
      zeroTierNetworkName: json['zeroTierNetworkName']?.toString(),
    );
  }

  final String id;
  final String status;
  final PairingSessionDevice initiatorDevice;
  final PairingSessionDevice targetDevice;
  final List<PairingSessionPortPolicy> allowedPorts;
  final List<PairingSessionZeroTierBinding> zeroTierBindings;
  final List<NetworkAgentCommand> commands;
  final PairingSessionUser? createdByUser;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? expiresAt;
  final DateTime? joinedAt;
  final DateTime? activatedAt;
  final DateTime? revokedAt;
  final String? closedReason;
  final String? zeroTierNetworkId;
  final String? zeroTierNetworkName;

  bool get isCancelled => status == 'cancelled';

  @override
  List<Object?> get props => <Object?>[
        id,
        status,
        initiatorDevice,
        targetDevice,
        allowedPorts,
        zeroTierBindings,
        commands,
        createdByUser,
        createdAt,
        updatedAt,
        expiresAt,
        joinedAt,
        activatedAt,
        revokedAt,
        closedReason,
        zeroTierNetworkId,
        zeroTierNetworkName,
      ];
}

class PairingSessionDevice extends Equatable {
  const PairingSessionDevice({
    required this.id,
    required this.deviceName,
    required this.platform,
    required this.zeroTierNodeId,
    required this.status,
  });

  factory PairingSessionDevice.fromJson(Map<String, dynamic> json) {
    return PairingSessionDevice(
      id: json['id']?.toString() ?? '',
      deviceName: json['deviceName']?.toString() ?? '',
      platform: json['platform']?.toString() ?? '',
      zeroTierNodeId: json['zeroTierNodeId']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
    );
  }

  final String id;
  final String deviceName;
  final String platform;
  final String zeroTierNodeId;
  final String status;

  @override
  List<Object?> get props => <Object?>[
        id,
        deviceName,
        platform,
        zeroTierNodeId,
        status,
      ];
}

class PairingSessionUser extends Equatable {
  const PairingSessionUser({
    required this.id,
    required this.name,
    required this.email,
  });

  factory PairingSessionUser.fromJson(Map<String, dynamic> json) {
    return PairingSessionUser(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
    );
  }

  final String id;
  final String name;
  final String email;

  @override
  List<Object?> get props => <Object?>[id, name, email];
}

class PairingSessionPortPolicy extends Equatable {
  const PairingSessionPortPolicy({
    required this.id,
    required this.protocol,
    required this.port,
    required this.direction,
  });

  factory PairingSessionPortPolicy.fromJson(Map<String, dynamic> json) {
    return PairingSessionPortPolicy(
      id: json['id']?.toString() ?? '',
      protocol: json['protocol']?.toString() ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      direction: json['direction']?.toString() ?? '',
    );
  }

  final String id;
  final String protocol;
  final int port;
  final String direction;

  @override
  List<Object?> get props => <Object?>[id, protocol, port, direction];
}

class PairingSessionZeroTierBinding extends Equatable {
  const PairingSessionZeroTierBinding({
    required this.deviceId,
    required this.zeroTierNodeId,
    required this.memberStatus,
    this.zeroTierAssignedIp,
    this.authorizedAt,
    this.deauthorizedAt,
  });

  factory PairingSessionZeroTierBinding.fromJson(Map<String, dynamic> json) {
    return PairingSessionZeroTierBinding(
      deviceId: json['deviceId']?.toString() ?? '',
      zeroTierNodeId: json['zeroTierNodeId']?.toString() ?? '',
      memberStatus: json['memberStatus']?.toString() ?? '',
      zeroTierAssignedIp: json['zeroTierAssignedIp']?.toString(),
      authorizedAt: _parseDateTime(json['authorizedAt']),
      deauthorizedAt: _parseDateTime(json['deauthorizedAt']),
    );
  }

  final String deviceId;
  final String zeroTierNodeId;
  final String memberStatus;
  final String? zeroTierAssignedIp;
  final DateTime? authorizedAt;
  final DateTime? deauthorizedAt;

  @override
  List<Object?> get props => <Object?>[
        deviceId,
        zeroTierNodeId,
        memberStatus,
        zeroTierAssignedIp,
        authorizedAt,
        deauthorizedAt,
      ];
}

Map<String, dynamic> _mapOrEmpty(dynamic value) {
  if (value is Map) {
    return value.map(
      (dynamic key, dynamic item) => MapEntry(key.toString(), item),
    );
  }
  return const <String, dynamic>{};
}

List<Map<String, dynamic>> _mapList(dynamic value) {
  if (value is! List) {
    return const <Map<String, dynamic>>[];
  }
  return value.whereType<Map>().map(_mapOrEmpty).toList(growable: false);
}

DateTime? _parseDateTime(dynamic value) {
  if (value == null) {
    return null;
  }

  return DateTime.tryParse(value.toString());
}
