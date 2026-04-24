import 'package:file_transfer_flutter/core/models/zerotier_adapter_bridge_status.dart';
import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/zerotier_network_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_permission_state.dart';

class ZeroTierRuntimeStatus extends Equatable {
  const ZeroTierRuntimeStatus({
    required this.nodeId,
    required this.version,
    required this.serviceState,
    required this.permissionState,
    required this.isNodeRunning,
    required this.joinedNetworks,
    required this.adapterBridge,
    required this.updatedAt,
    this.lastError,
  });

  const ZeroTierRuntimeStatus.unavailable()
      : nodeId = '',
        version = null,
        serviceState = 'unavailable',
        permissionState = const ZeroTierPermissionState.unknown(),
        isNodeRunning = false,
        joinedNetworks = const <ZeroTierNetworkState>[],
        adapterBridge = const ZeroTierAdapterBridgeStatus.unknown(),
        updatedAt = null,
        lastError = null;

  final String nodeId;
  final String? version;
  final String serviceState;
  final ZeroTierPermissionState permissionState;
  final bool isNodeRunning;
  final List<ZeroTierNetworkState> joinedNetworks;
  final ZeroTierAdapterBridgeStatus adapterBridge;
  final String? lastError;
  final DateTime? updatedAt;

  bool get hasNodeId => nodeId.trim().isNotEmpty;
  bool get cliAvailable => serviceState != 'unavailable';
  bool get isEnvironmentReady => cliAvailable;
  bool get isNodeReady =>
      serviceState == 'running' && isNodeRunning && hasNodeId;
  bool get isNodeStarting =>
      serviceState == 'starting' ||
      (isNodeRunning && !isNodeReady && serviceState != 'offline');
  bool get isNodeOffline => serviceState == 'offline';
  bool get isNodeErrored => serviceState == 'error';

  ZeroTierRuntimeStatus copyWith({
    String? nodeId,
    String? version,
    bool clearVersion = false,
    String? serviceState,
    ZeroTierPermissionState? permissionState,
    bool? isNodeRunning,
    List<ZeroTierNetworkState>? joinedNetworks,
    ZeroTierAdapterBridgeStatus? adapterBridge,
    String? lastError,
    bool clearLastError = false,
    DateTime? updatedAt,
  }) {
    return ZeroTierRuntimeStatus(
      nodeId: nodeId ?? this.nodeId,
      version: clearVersion ? null : version ?? this.version,
      serviceState: serviceState ?? this.serviceState,
      permissionState: permissionState ?? this.permissionState,
      isNodeRunning: isNodeRunning ?? this.isNodeRunning,
      joinedNetworks: joinedNetworks ?? this.joinedNetworks,
      adapterBridge: adapterBridge ?? this.adapterBridge,
      lastError: clearLastError ? null : lastError ?? this.lastError,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        nodeId,
        version,
        serviceState,
        permissionState,
        isNodeRunning,
        joinedNetworks,
        adapterBridge,
        lastError,
        updatedAt,
      ];
}
