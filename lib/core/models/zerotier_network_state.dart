import 'package:equatable/equatable.dart';

class ZeroTierNetworkState extends Equatable {
  const ZeroTierNetworkState({
    required this.networkId,
    required this.networkName,
    required this.status,
    required this.assignedAddresses,
    required this.isAuthorized,
    required this.isConnected,
    required this.localInterfaceReady,
    required this.matchedInterfaceName,
    required this.matchedInterfaceUp,
    required this.mountDriverKind,
    required this.mountCandidateNames,
    required this.routeExpected,
    required this.expectedRouteCount,
    required this.systemIpBound,
    required this.systemRouteBound,
    required this.tapMediaStatus,
    required this.tapDeviceInstanceId,
    required this.tapNetCfgInstanceId,
    required this.localMountState,
  });

  final String networkId;
  final String networkName;
  final String status;
  final List<String> assignedAddresses;
  final bool isAuthorized;
  final bool isConnected;
  final bool localInterfaceReady;
  final String matchedInterfaceName;
  final bool matchedInterfaceUp;
  final String mountDriverKind;
  final List<String> mountCandidateNames;
  final bool routeExpected;
  final int expectedRouteCount;
  final bool systemIpBound;
  final bool systemRouteBound;
  final String tapMediaStatus;
  final String tapDeviceInstanceId;
  final String tapNetCfgInstanceId;
  final String localMountState;

  @override
  List<Object?> get props => <Object?>[
        networkId,
        networkName,
        status,
        assignedAddresses,
        isAuthorized,
        isConnected,
        localInterfaceReady,
        matchedInterfaceName,
        matchedInterfaceUp,
        mountDriverKind,
        mountCandidateNames,
        routeExpected,
        expectedRouteCount,
        systemIpBound,
        systemRouteBound,
        tapMediaStatus,
        tapDeviceInstanceId,
        tapNetCfgInstanceId,
        localMountState,
      ];
}
