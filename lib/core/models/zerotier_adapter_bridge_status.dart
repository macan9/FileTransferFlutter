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
    required this.isMountCandidate,
    required this.matchesExpectedIp,
    required this.hasExpectedRoute,
    required this.driverKind,
    required this.mediaStatus,
    required this.tapDeviceInstanceId,
    required this.tapNetCfgInstanceId,
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
  final bool isMountCandidate;
  final bool matchesExpectedIp;
  final bool hasExpectedRoute;
  final String driverKind;
  final String mediaStatus;
  final String tapDeviceInstanceId;
  final String tapNetCfgInstanceId;
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
        isMountCandidate,
        matchesExpectedIp,
        hasExpectedRoute,
        driverKind,
        mediaStatus,
        tapDeviceInstanceId,
        tapNetCfgInstanceId,
        ipv4Addresses,
      ];
}

class ZeroTierAdapterBridgeStatus extends Equatable {
  const ZeroTierAdapterBridgeStatus({
    required this.initialized,
    required this.hasVirtualAdapter,
    required this.hasMountCandidate,
    required this.hasExpectedNetworkIp,
    required this.hasExpectedRoute,
    required this.virtualAdapterNames,
    required this.matchedAdapterNames,
    required this.mountCandidateNames,
    required this.detectedIpv4Addresses,
    required this.expectedIpv4Addresses,
    required this.adapters,
    this.summary,
  });

  const ZeroTierAdapterBridgeStatus.unknown()
      : initialized = false,
        hasVirtualAdapter = false,
        hasMountCandidate = false,
        hasExpectedNetworkIp = false,
        hasExpectedRoute = false,
        virtualAdapterNames = const <String>[],
        matchedAdapterNames = const <String>[],
        mountCandidateNames = const <String>[],
        detectedIpv4Addresses = const <String>[],
        expectedIpv4Addresses = const <String>[],
        adapters = const <ZeroTierAdapterRecord>[],
        summary = null;

  final bool initialized;
  final bool hasVirtualAdapter;
  final bool hasMountCandidate;
  final bool hasExpectedNetworkIp;
  final bool hasExpectedRoute;
  final List<String> virtualAdapterNames;
  final List<String> matchedAdapterNames;
  final List<String> mountCandidateNames;
  final List<String> detectedIpv4Addresses;
  final List<String> expectedIpv4Addresses;
  final List<ZeroTierAdapterRecord> adapters;
  final String? summary;

  @override
  List<Object?> get props => <Object?>[
        initialized,
        hasVirtualAdapter,
        hasMountCandidate,
        hasExpectedNetworkIp,
        hasExpectedRoute,
        virtualAdapterNames,
        matchedAdapterNames,
        mountCandidateNames,
        detectedIpv4Addresses,
        expectedIpv4Addresses,
        adapters,
        summary,
      ];
}
