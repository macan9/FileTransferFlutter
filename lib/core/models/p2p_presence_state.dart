import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/connection_request.dart';
import 'package:file_transfer_flutter/core/models/p2p_device.dart';
import 'package:file_transfer_flutter/core/models/p2p_session.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';

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
    required this.connectionRequests,
    required this.sessions,
    this.currentDevice,
    this.socketId,
    this.lastError,
    this.heartbeatTimeoutMs,
    this.lastHeartbeatAt,
  });

  const P2pPresenceState.initial()
      : status = SignalingPresenceStatus.offline,
        devices = const <P2pDevice>[],
        connectionRequests = const <ConnectionRequest>[],
        sessions = const <P2pSession>[],
        currentDevice = null,
        socketId = null,
        lastError = null,
        heartbeatTimeoutMs = null,
        lastHeartbeatAt = null;

  final SignalingPresenceStatus status;
  final List<P2pDevice> devices;
  final List<ConnectionRequest> connectionRequests;
  final List<P2pSession> sessions;
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
    final String normalizedDeviceId = _normalizeDeviceId(deviceId);
    if (normalizedDeviceId.isEmpty) {
      return devices;
    }

    return devices
        .where(
          (P2pDevice item) =>
              _normalizeDeviceId(item.deviceId) != normalizedDeviceId,
        )
        .toList();
  }

  List<ConnectionRequest> requestsForDevice(String deviceId) {
    return connectionRequests.where((ConnectionRequest item) {
      return item.fromDeviceId == deviceId || item.toDeviceId == deviceId;
    }).toList();
  }

  List<ConnectionRequest> incomingPendingRequests(String selfDeviceId) {
    return connectionRequests.where((ConnectionRequest item) {
      return item.toDeviceId == selfDeviceId &&
          item.status == ConnectionRequestStatus.pending;
    }).toList()
      ..sort(
        (ConnectionRequest a, ConnectionRequest b) =>
            b.createdAt.compareTo(a.createdAt),
      );
  }

  ConnectionRequest? outgoingPendingRequestTo({
    required String selfDeviceId,
    required String peerDeviceId,
  }) {
    return _firstWhereOrNull(
      connectionRequests,
      (ConnectionRequest item) =>
          item.fromDeviceId == selfDeviceId &&
          item.toDeviceId == peerDeviceId &&
          item.status == ConnectionRequestStatus.pending,
    );
  }

  ConnectionRequest? incomingPendingRequestFrom({
    required String selfDeviceId,
    required String peerDeviceId,
  }) {
    return _firstWhereOrNull(
      connectionRequests,
      (ConnectionRequest item) =>
          item.fromDeviceId == peerDeviceId &&
          item.toDeviceId == selfDeviceId &&
          item.status == ConnectionRequestStatus.pending,
    );
  }

  P2pSession? activeSessionWith({
    required String selfDeviceId,
    required String peerDeviceId,
  }) {
    return _firstWhereOrNull(
      sessions,
      (P2pSession item) =>
          item.involves(selfDeviceId) &&
          item.involves(peerDeviceId) &&
          item.status.isOpen,
    );
  }

  List<P2pSession> sessionsForDevice(String deviceId) {
    return sessions.where((P2pSession item) => item.involves(deviceId)).toList()
      ..sort(
          (P2pSession a, P2pSession b) => b.createdAt.compareTo(a.createdAt));
  }

  P2pPresenceState copyWith({
    SignalingPresenceStatus? status,
    List<P2pDevice>? devices,
    List<ConnectionRequest>? connectionRequests,
    List<P2pSession>? sessions,
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
      connectionRequests: connectionRequests ?? this.connectionRequests,
      sessions: sessions ?? this.sessions,
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
        connectionRequests,
        sessions,
        currentDevice,
        socketId,
        lastError,
        heartbeatTimeoutMs,
        lastHeartbeatAt,
      ];

  static T? _firstWhereOrNull<T>(
    List<T> items,
    bool Function(T item) predicate,
  ) {
    for (final T item in items) {
      if (predicate(item)) {
        return item;
      }
    }
    return null;
  }

  static String _normalizeDeviceId(String? deviceId) {
    return deviceId?.trim().toLowerCase() ?? '';
  }
}
