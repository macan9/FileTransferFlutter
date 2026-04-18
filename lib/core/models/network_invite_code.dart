import 'package:equatable/equatable.dart';

class NetworkInviteCode extends Equatable {
  const NetworkInviteCode({
    required this.code,
    required this.status,
    this.managedNetworkId,
    this.createdByUserId,
    this.maxUses,
    this.useCount,
    this.expiresAt,
    this.revokedAt,
  });

  factory NetworkInviteCode.fromJson(Map<String, dynamic> json) {
    return NetworkInviteCode(
      code: json['code']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      managedNetworkId: json['managedNetworkId']?.toString(),
      createdByUserId: json['createdByUserId']?.toString(),
      maxUses: (json['maxUses'] as num?)?.toInt(),
      useCount: (json['useCount'] as num?)?.toInt(),
      expiresAt: _parseDateTime(json['expiresAt']),
      revokedAt: _parseDateTime(json['revokedAt']),
    );
  }

  final String code;
  final String status;
  final String? managedNetworkId;
  final String? createdByUserId;
  final int? maxUses;
  final int? useCount;
  final DateTime? expiresAt;
  final DateTime? revokedAt;

  @override
  List<Object?> get props => <Object?>[
        code,
        status,
        managedNetworkId,
        createdByUserId,
        maxUses,
        useCount,
        expiresAt,
        revokedAt,
      ];
}

DateTime? _parseDateTime(dynamic value) {
  if (value == null) {
    return null;
  }

  return DateTime.tryParse(value.toString());
}
