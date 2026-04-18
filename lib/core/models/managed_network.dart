import 'package:equatable/equatable.dart';

class ManagedNetwork extends Equatable {
  const ManagedNetwork({
    required this.id,
    required this.name,
    required this.type,
    required this.status,
    this.description,
    this.ownerUserId,
    this.zeroTierNetworkId,
    this.zeroTierNetworkName,
    this.defaultFirewallMode,
  });

  factory ManagedNetwork.fromJson(Map<String, dynamic> json) {
    return ManagedNetwork(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      description: json['description']?.toString(),
      ownerUserId: json['ownerUserId']?.toString(),
      zeroTierNetworkId: json['zeroTierNetworkId']?.toString(),
      zeroTierNetworkName: json['zeroTierNetworkName']?.toString(),
      defaultFirewallMode: json['defaultFirewallMode']?.toString(),
    );
  }

  final String id;
  final String name;
  final String type;
  final String status;
  final String? description;
  final String? ownerUserId;
  final String? zeroTierNetworkId;
  final String? zeroTierNetworkName;
  final String? defaultFirewallMode;

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
        zeroTierNetworkId,
        zeroTierNetworkName,
        defaultFirewallMode,
      ];
}
