import 'package:equatable/equatable.dart';

enum ZeroTierRuntimeEventType {
  environmentReady,
  permissionRequired,
  nodeStarted,
  nodeOnline,
  nodeOffline,
  nodeStopped,
  networkJoining,
  networkLeaving,
  networkWaitingAuthorization,
  networkOnline,
  networkLeft,
  ipAssigned,
  error,
}

class ZeroTierRuntimeEvent extends Equatable {
  const ZeroTierRuntimeEvent({
    required this.type,
    required this.occurredAt,
    this.message,
    this.networkId,
    this.payload = const <String, Object?>{},
  });

  final ZeroTierRuntimeEventType type;
  final DateTime occurredAt;
  final String? message;
  final String? networkId;
  final Map<String, Object?> payload;

  @override
  List<Object?> get props => <Object?>[
        type,
        occurredAt,
        message,
        networkId,
        payload,
      ];
}
