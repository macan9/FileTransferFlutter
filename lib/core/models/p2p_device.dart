import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';

class P2pDevice extends Equatable {
  const P2pDevice({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.status,
    this.socketId,
    this.lastHeartbeatAt,
    this.connectedAt,
    this.disconnectedAt,
  });

  factory P2pDevice.fromJson(Map<String, dynamic> json) {
    return P2pDevice(
      deviceId: json['deviceId']?.toString() ?? '',
      deviceName: json['deviceName']?.toString() ?? '',
      platform: json['platform']?.toString() ?? '',
      socketId: json['socketId']?.toString(),
      status:
          P2pDeviceStatus.fromValue(json['status']?.toString() ?? 'offline'),
      lastHeartbeatAt: _parseDateTime(json['lastHeartbeatAt']),
      connectedAt: _parseDateTime(json['connectedAt']),
      disconnectedAt: _parseDateTime(json['disconnectedAt']),
    );
  }

  final String deviceId;
  final String deviceName;
  final String platform;
  final String? socketId;
  final P2pDeviceStatus status;
  final DateTime? lastHeartbeatAt;
  final DateTime? connectedAt;
  final DateTime? disconnectedAt;

  bool get isOnline => status == P2pDeviceStatus.online;
  bool get isStale => status == P2pDeviceStatus.stale;
  bool get isOffline => status == P2pDeviceStatus.offline;

  P2pDevice copyWith({
    String? deviceId,
    String? deviceName,
    String? platform,
    String? socketId,
    bool clearSocketId = false,
    P2pDeviceStatus? status,
    DateTime? lastHeartbeatAt,
    bool clearLastHeartbeatAt = false,
    DateTime? connectedAt,
    bool clearConnectedAt = false,
    DateTime? disconnectedAt,
    bool clearDisconnectedAt = false,
  }) {
    return P2pDevice(
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      platform: platform ?? this.platform,
      socketId: clearSocketId ? null : socketId ?? this.socketId,
      status: status ?? this.status,
      lastHeartbeatAt:
          clearLastHeartbeatAt ? null : lastHeartbeatAt ?? this.lastHeartbeatAt,
      connectedAt: clearConnectedAt ? null : connectedAt ?? this.connectedAt,
      disconnectedAt:
          clearDisconnectedAt ? null : disconnectedAt ?? this.disconnectedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'deviceId': deviceId,
      'deviceName': deviceName,
      'platform': platform,
      'socketId': socketId,
      'status': status.value,
      'lastHeartbeatAt': lastHeartbeatAt?.toIso8601String(),
      'connectedAt': connectedAt?.toIso8601String(),
      'disconnectedAt': disconnectedAt?.toIso8601String(),
    };
  }

  @override
  List<Object?> get props => <Object?>[
        deviceId,
        deviceName,
        platform,
        socketId,
        status,
        lastHeartbeatAt,
        connectedAt,
        disconnectedAt,
      ];
}

DateTime? _parseDateTime(dynamic value) {
  if (value == null) {
    return null;
  }

  return DateTime.tryParse(value.toString());
}
