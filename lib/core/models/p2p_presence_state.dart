import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/p2p_device.dart';

enum SignalingPresenceStatus {
  offline,
  connecting,
  registering,
  online,
}

class P2pPresenceState extends Equatable {
  const P2pPresenceState({
    required this.status,
    required this.devices,
    this.currentDevice,
    this.socketId,
    this.lastError,
    this.heartbeatTimeoutMs,
    this.lastHeartbeatAt,
  });

  const P2pPresenceState.initial()
      : status = SignalingPresenceStatus.offline,
        devices = const <P2pDevice>[],
        currentDevice = null,
        socketId = null,
        lastError = null,
        heartbeatTimeoutMs = null,
        lastHeartbeatAt = null;

  final SignalingPresenceStatus status;
  final List<P2pDevice> devices;
  final P2pDevice? currentDevice;
  final String? socketId;
  final String? lastError;
  final int? heartbeatTimeoutMs;
  final DateTime? lastHeartbeatAt;

  bool get isOnline => status == SignalingPresenceStatus.online;
  bool get isBusy =>
      status == SignalingPresenceStatus.connecting ||
      status == SignalingPresenceStatus.registering;

  List<P2pDevice> devicesExcludingSelf(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) {
      return devices;
    }

    return devices
        .where((P2pDevice item) => item.deviceId != deviceId)
        .toList();
  }

  P2pPresenceState copyWith({
    SignalingPresenceStatus? status,
    List<P2pDevice>? devices,
    P2pDevice? currentDevice,
    bool clearCurrentDevice = false,
    String? socketId,
    bool clearSocketId = false,
    String? lastError,
    bool clearLastError = false,
    int? heartbeatTimeoutMs,
    bool clearHeartbeatTimeoutMs = false,
    DateTime? lastHeartbeatAt,
    bool clearLastHeartbeatAt = false,
  }) {
    return P2pPresenceState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      currentDevice:
          clearCurrentDevice ? null : currentDevice ?? this.currentDevice,
      socketId: clearSocketId ? null : socketId ?? this.socketId,
      lastError: clearLastError ? null : lastError ?? this.lastError,
      heartbeatTimeoutMs: clearHeartbeatTimeoutMs
          ? null
          : heartbeatTimeoutMs ?? this.heartbeatTimeoutMs,
      lastHeartbeatAt:
          clearLastHeartbeatAt ? null : lastHeartbeatAt ?? this.lastHeartbeatAt,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        status,
        devices,
        currentDevice,
        socketId,
        lastError,
        heartbeatTimeoutMs,
        lastHeartbeatAt,
      ];
}
