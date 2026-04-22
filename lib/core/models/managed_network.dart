import 'package:equatable/equatable.dart';

class ManagedNetwork extends Equatable {
  const ManagedNetwork({
    required this.id,
    required this.name,
    required this.type,
    required this.status,
    this.description,
    this.ownerUserId,
    this.ownerUser,
    this.zeroTierNetworkId,
    this.zeroTierNetworkName,
    this.defaultFirewallMode,
    this.memberships = const <ManagedNetworkMembership>[],
    this.inviteCodes = const <ManagedNetworkInviteCode>[],
  });

  factory ManagedNetwork.fromJson(Map<String, dynamic> json) {
    return ManagedNetwork(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      description: json['description']?.toString(),
      ownerUserId: json['ownerUserId']?.toString(),
      ownerUser: json['ownerUser'] is Map
          ? ManagedNetworkUser.fromJson(_mapOrEmpty(json['ownerUser']))
          : null,
      zeroTierNetworkId: json['zeroTierNetworkId']?.toString(),
      zeroTierNetworkName: json['zeroTierNetworkName']?.toString(),
      defaultFirewallMode: json['defaultFirewallMode']?.toString(),
      memberships: _mapList(json['memberships'])
          .map(ManagedNetworkMembership.fromJson)
          .toList(growable: false),
      inviteCodes: _mapList(json['inviteCodes'])
          .map(ManagedNetworkInviteCode.fromJson)
          .toList(growable: false),
    );
  }

  final String id;
  final String name;
  final String type;
  final String status;
  final String? description;
  final String? ownerUserId;
  final ManagedNetworkUser? ownerUser;
  final String? zeroTierNetworkId;
  final String? zeroTierNetworkName;
  final String? defaultFirewallMode;
  final List<ManagedNetworkMembership> memberships;
  final List<ManagedNetworkInviteCode> inviteCodes;

  bool get isDefault => type == 'default';
  bool get isPrivate => type == 'private';

  @override
  List<Object?> get props => <Object?>[
        id,
        name,
        type,
        status,
        description,
        ownerUserId,
        ownerUser,
        zeroTierNetworkId,
        zeroTierNetworkName,
        defaultFirewallMode,
        memberships,
        inviteCodes,
      ];
}

class ManagedNetworkUser extends Equatable {
  const ManagedNetworkUser({
    required this.id,
    required this.name,
    required this.email,
  });

  factory ManagedNetworkUser.fromJson(Map<String, dynamic> json) {
    return ManagedNetworkUser(
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

class ManagedNetworkMembership extends Equatable {
  const ManagedNetworkMembership({
    required this.id,
    required this.deviceId,
    required this.role,
    required this.status,
    required this.zeroTierNodeId,
    this.joinedByUserId,
    this.zeroTierAssignedIp,
    this.joinedAt,
    this.leftAt,
    this.device,
  });

  factory ManagedNetworkMembership.fromJson(Map<String, dynamic> json) {
    return ManagedNetworkMembership(
      id: json['id']?.toString() ?? '',
      deviceId: json['deviceId']?.toString() ?? '',
      joinedByUserId: json['joinedByUserId']?.toString(),
      role: json['role']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      zeroTierNodeId: json['zeroTierNodeId']?.toString() ?? '',
      zeroTierAssignedIp: json['zeroTierAssignedIp']?.toString(),
      joinedAt: _parseDateTime(json['joinedAt']),
      leftAt: _parseDateTime(json['leftAt']),
      device: json['device'] is Map
          ? ManagedNetworkDevice.fromJson(_mapOrEmpty(json['device']))
          : null,
    );
  }

  final String id;
  final String deviceId;
  final String? joinedByUserId;
  final String role;
  final String status;
  final String zeroTierNodeId;
  final String? zeroTierAssignedIp;
  final DateTime? joinedAt;
  final DateTime? leftAt;
  final ManagedNetworkDevice? device;

  @override
  List<Object?> get props => <Object?>[
        id,
        deviceId,
        joinedByUserId,
        role,
        status,
        zeroTierNodeId,
        zeroTierAssignedIp,
        joinedAt,
        leftAt,
        device,
      ];
}

class ManagedNetworkDevice extends Equatable {
  const ManagedNetworkDevice({
    required this.id,
    required this.deviceName,
    required this.platform,
    required this.status,
  });

  factory ManagedNetworkDevice.fromJson(Map<String, dynamic> json) {
    return ManagedNetworkDevice(
      id: json['id']?.toString() ?? '',
      deviceName: json['deviceName']?.toString() ?? '',
      platform: json['platform']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
    );
  }

  final String id;
  final String deviceName;
  final String platform;
  final String status;

  @override
  List<Object?> get props => <Object?>[id, deviceName, platform, status];
}

class ManagedNetworkInviteCode extends Equatable {
  const ManagedNetworkInviteCode({
    required this.id,
    required this.code,
    required this.status,
    required this.maxUses,
    required this.useCount,
    this.expiresAt,
    this.revokedAt,
    this.createdAt,
  });

  factory ManagedNetworkInviteCode.fromJson(Map<String, dynamic> json) {
    return ManagedNetworkInviteCode(
      id: json['id']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      maxUses: (json['maxUses'] as num?)?.toInt() ?? 0,
      useCount: (json['useCount'] as num?)?.toInt() ?? 0,
      expiresAt: _parseDateTime(json['expiresAt']),
      revokedAt: _parseDateTime(json['revokedAt']),
      createdAt: _parseDateTime(json['createdAt']),
    );
  }

  final String id;
  final String code;
  final String status;
  final int maxUses;
  final int useCount;
  final DateTime? expiresAt;
  final DateTime? revokedAt;
  final DateTime? createdAt;

  @override
  List<Object?> get props => <Object?>[
        id,
        code,
        status,
        maxUses,
        useCount,
        expiresAt,
        revokedAt,
        createdAt,
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
