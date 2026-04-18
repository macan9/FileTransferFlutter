import 'package:equatable/equatable.dart';

class ZeroTierLocalStatus extends Equatable {
  const ZeroTierLocalStatus({
    required this.cliAvailable,
    required this.nodeId,
    this.version,
  });

  const ZeroTierLocalStatus.unavailable()
      : cliAvailable = false,
        nodeId = '',
        version = null;

  final bool cliAvailable;
  final String nodeId;
  final String? version;

  bool get hasNodeId => nodeId.trim().isNotEmpty;

  @override
  List<Object?> get props => <Object?>[cliAvailable, nodeId, version];
}
