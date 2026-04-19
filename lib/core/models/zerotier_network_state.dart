import 'package:equatable/equatable.dart';

class ZeroTierNetworkState extends Equatable {
  const ZeroTierNetworkState({
    required this.networkId,
    required this.networkName,
    required this.status,
    required this.assignedAddresses,
    required this.isAuthorized,
    required this.isConnected,
  });

  final String networkId;
  final String networkName;
  final String status;
  final List<String> assignedAddresses;
  final bool isAuthorized;
  final bool isConnected;

  @override
  List<Object?> get props => <Object?>[
        networkId,
        networkName,
        status,
        assignedAddresses,
        isAuthorized,
        isConnected,
      ];
}
