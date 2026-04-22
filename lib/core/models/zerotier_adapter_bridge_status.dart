import 'package:equatable/equatable.dart';

class ZeroTierAdapterRecord extends Equatable {
  const ZeroTierAdapterRecord({
    required this.adapterName,
    required this.friendlyName,
    required this.description,
    required this.ifIndex,
    required this.luid,
    required this.operStatus,
    required this.isUp,
    required this.isVirtual,
    required this.matchesExpectedIp,
    required this.ipv4Addresses,
  });

  final String adapterName;
  final String friendlyName;
  final String description;
  final int ifIndex;
  final int luid;
  final String operStatus;
  final bool isUp;
  final bool isVirtual;
  final bool matchesExpectedIp;
  final List<String> ipv4Addresses;

  String get displayName {
    if (friendlyName.trim().isNotEmpty) {
      return friendlyName;
    }
    if (description.trim().isNotEmpty) {
      return description;
    }
    if (adapterName.trim().isNotEmpty) {
      return adapterName;
    }
    return 'Unnamed adapter';
  }

  @override
  List<Object?> get props => <Object?>[
        adapterName,
        friendlyName,
        description,
        ifIndex,
        luid,
        operStatus,
        isUp,
        isVirtual,
        matchesExpectedIp,
        ipv4Addresses,
      ];
}

class ZeroTierAdapterBridgeStatus extends Equatable {
  const ZeroTierAdapterBridgeStatus({
    required this.initialized,
    required this.hasVirtualAdapter,
    required this.hasExpectedNetworkIp,
    required this.virtualAdapterNames,
    required this.detectedIpv4Addresses,
    required this.expectedIpv4Addresses,
    required this.adapters,
    this.summary,
  });

  const ZeroTierAdapterBridgeStatus.unknown()
      : initialized = false,
        hasVirtualAdapter = false,
        hasExpectedNetworkIp = false,
        virtualAdapterNames = const <String>[],
        detectedIpv4Addresses = const <String>[],
        expectedIpv4Addresses = const <String>[],
        adapters = const <ZeroTierAdapterRecord>[],
        summary = null;

  final bool initialized;
  final bool hasVirtualAdapter;
  final bool hasExpectedNetworkIp;
  final List<String> virtualAdapterNames;
  final List<String> detectedIpv4Addresses;
  final List<String> expectedIpv4Addresses;
  final List<ZeroTierAdapterRecord> adapters;
  final String? summary;

  @override
  List<Object?> get props => <Object?>[
        initialized,
        hasVirtualAdapter,
        hasExpectedNetworkIp,
        virtualAdapterNames,
        detectedIpv4Addresses,
        expectedIpv4Addresses,
        adapters,
        summary,
      ];
}
