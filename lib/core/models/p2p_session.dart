import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';

class P2pSession extends Equatable {
  const P2pSession({
    required this.id,
    required this.sessionId,
    required this.deviceAId,
    required this.deviceBId,
    required this.status,
    required this.createdByDeviceId,
    required this.createdAt,
    this.connectionMode,
    this.connectedAt,
    this.closedAt,
    this.closeReason,
  });

  factory P2pSession.fromJson(Map<String, dynamic> json) {
    return P2pSession(
      id: json['id']?.toString() ?? '',
      sessionId: json['sessionId']?.toString() ?? '',
      deviceAId: json['deviceAId']?.toString() ?? '',
      deviceBId: json['deviceBId']?.toString() ?? '',
      status: P2pSessionStatus.fromValue(
        json['status']?.toString() ?? 'connecting',
      ),
      createdByDeviceId: json['createdByDeviceId']?.toString() ?? '',
      createdAt: _parseRequiredDateTime(json['createdAt'], field: 'createdAt'),
      connectionMode: P2pConnectionMode.tryParse(
        json['connectionMode']?.toString(),
      ),
      connectedAt: _parseDateTime(json['connectedAt']),
      closedAt: _parseDateTime(json['closedAt']),
      closeReason: json['closeReason']?.toString(),
    );
  }

  final String id;
  final String sessionId;
  final String deviceAId;
  final String deviceBId;
  final P2pSessionStatus status;
  final String createdByDeviceId;
  final DateTime createdAt;
  final P2pConnectionMode? connectionMode;
  final DateTime? connectedAt;
  final DateTime? closedAt;
  final String? closeReason;

  bool involves(String deviceId) {
    return deviceAId == deviceId || deviceBId == deviceId;
  }

  String peerDeviceIdOf(String deviceId) {
    if (deviceAId == deviceId) {
      return deviceBId;
    }
    if (deviceBId == deviceId) {
      return deviceAId;
    }

    throw ArgumentError.value(
      deviceId,
      'deviceId',
      'Device is not part of this session',
    );
  }

  P2pSession copyWith({
    String? id,
    String? sessionId,
    String? deviceAId,
    String? deviceBId,
    P2pSessionStatus? status,
    String? createdByDeviceId,
    DateTime? createdAt,
    P2pConnectionMode? connectionMode,
    bool clearConnectionMode = false,
    DateTime? connectedAt,
    bool clearConnectedAt = false,
    DateTime? closedAt,
    bool clearClosedAt = false,
    String? closeReason,
    bool clearCloseReason = false,
  }) {
    return P2pSession(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      deviceAId: deviceAId ?? this.deviceAId,
      deviceBId: deviceBId ?? this.deviceBId,
      status: status ?? this.status,
      createdByDeviceId: createdByDeviceId ?? this.createdByDeviceId,
      createdAt: createdAt ?? this.createdAt,
      connectionMode:
          clearConnectionMode ? null : connectionMode ?? this.connectionMode,
      connectedAt: clearConnectedAt ? null : connectedAt ?? this.connectedAt,
      closedAt: clearClosedAt ? null : closedAt ?? this.closedAt,
      closeReason: clearCloseReason ? null : closeReason ?? this.closeReason,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'sessionId': sessionId,
      'deviceAId': deviceAId,
      'deviceBId': deviceBId,
      'status': status.value,
      'createdByDeviceId': createdByDeviceId,
      'createdAt': createdAt.toIso8601String(),
      'connectionMode': connectionMode?.value,
      'connectedAt': connectedAt?.toIso8601String(),
      'closedAt': closedAt?.toIso8601String(),
      'closeReason': closeReason,
    };
  }

  @override
  List<Object?> get props => <Object?>[
        id,
        sessionId,
        deviceAId,
        deviceBId,
        status,
        createdByDeviceId,
        createdAt,
        connectionMode,
        connectedAt,
        closedAt,
        closeReason,
      ];
}

DateTime? _parseDateTime(dynamic value) {
  if (value == null) {
    return null;
  }

  return DateTime.tryParse(value.toString());
}

DateTime _parseRequiredDateTime(
  dynamic value, {
  required String field,
}) {
  final DateTime? parsed = _parseDateTime(value);
  if (parsed == null) {
    throw ArgumentError.value(value, field, 'Invalid date time');
  }

  return parsed;
}
