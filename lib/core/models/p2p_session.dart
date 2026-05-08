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
    this.preferredRelayNodeId,
    this.relayPolicy,
    this.relayDecisionReason,
    this.observedConnectionMode,
    this.observedRelayNodeId,
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
      preferredRelayNodeId: _trimmedOrNull(json['preferredRelayNodeId']),
      relayPolicy: RelayPolicy.tryParse(json['relayPolicy']?.toString()),
      relayDecisionReason: _trimmedOrNull(json['relayDecisionReason']),
      observedConnectionMode: P2pConnectionMode.tryParse(
        json['observedConnectionMode']?.toString(),
      ),
      observedRelayNodeId: _trimmedOrNull(json['observedRelayNodeId']),
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
  final String? preferredRelayNodeId;
  final RelayPolicy? relayPolicy;
  final String? relayDecisionReason;
  final P2pConnectionMode? observedConnectionMode;
  final String? observedRelayNodeId;
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
    String? preferredRelayNodeId,
    bool clearPreferredRelayNodeId = false,
    RelayPolicy? relayPolicy,
    bool clearRelayPolicy = false,
    String? relayDecisionReason,
    bool clearRelayDecisionReason = false,
    P2pConnectionMode? observedConnectionMode,
    bool clearObservedConnectionMode = false,
    String? observedRelayNodeId,
    bool clearObservedRelayNodeId = false,
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
      preferredRelayNodeId: clearPreferredRelayNodeId
          ? null
          : preferredRelayNodeId ?? this.preferredRelayNodeId,
      relayPolicy: clearRelayPolicy ? null : relayPolicy ?? this.relayPolicy,
      relayDecisionReason: clearRelayDecisionReason
          ? null
          : relayDecisionReason ?? this.relayDecisionReason,
      observedConnectionMode: clearObservedConnectionMode
          ? null
          : observedConnectionMode ?? this.observedConnectionMode,
      observedRelayNodeId: clearObservedRelayNodeId
          ? null
          : observedRelayNodeId ?? this.observedRelayNodeId,
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
      'preferredRelayNodeId': preferredRelayNodeId,
      'relayPolicy': relayPolicy?.value,
      'relayDecisionReason': relayDecisionReason,
      'observedConnectionMode': observedConnectionMode?.value,
      'observedRelayNodeId': observedRelayNodeId,
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
        preferredRelayNodeId,
        relayPolicy,
        relayDecisionReason,
        observedConnectionMode,
        observedRelayNodeId,
        connectedAt,
        closedAt,
        closeReason,
      ];
}

String? _trimmedOrNull(dynamic value) {
  final String text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
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
