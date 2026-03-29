import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';

class ConnectionRequest extends Equatable {
  const ConnectionRequest({
    required this.id,
    required this.requestId,
    required this.fromDeviceId,
    required this.toDeviceId,
    required this.status,
    required this.createdAt,
    this.message,
    this.respondedAt,
    this.expiredAt,
  });

  factory ConnectionRequest.fromJson(Map<String, dynamic> json) {
    return ConnectionRequest(
      id: json['id']?.toString() ?? '',
      requestId: json['requestId']?.toString() ?? '',
      fromDeviceId: json['fromDeviceId']?.toString() ?? '',
      toDeviceId: json['toDeviceId']?.toString() ?? '',
      status: ConnectionRequestStatus.fromValue(
        json['status']?.toString() ?? 'pending',
      ),
      message: json['message']?.toString(),
      createdAt: _parseRequiredDateTime(json['createdAt'], field: 'createdAt'),
      respondedAt: _parseDateTime(json['respondedAt']),
      expiredAt: _parseDateTime(json['expiredAt']),
    );
  }

  final String id;
  final String requestId;
  final String fromDeviceId;
  final String toDeviceId;
  final ConnectionRequestStatus status;
  final String? message;
  final DateTime createdAt;
  final DateTime? respondedAt;
  final DateTime? expiredAt;

  bool get isTerminal => status.isTerminal;
  bool get isPending => status == ConnectionRequestStatus.pending;

  ConnectionRequest copyWith({
    String? id,
    String? requestId,
    String? fromDeviceId,
    String? toDeviceId,
    ConnectionRequestStatus? status,
    String? message,
    bool clearMessage = false,
    DateTime? createdAt,
    DateTime? respondedAt,
    bool clearRespondedAt = false,
    DateTime? expiredAt,
    bool clearExpiredAt = false,
  }) {
    return ConnectionRequest(
      id: id ?? this.id,
      requestId: requestId ?? this.requestId,
      fromDeviceId: fromDeviceId ?? this.fromDeviceId,
      toDeviceId: toDeviceId ?? this.toDeviceId,
      status: status ?? this.status,
      message: clearMessage ? null : message ?? this.message,
      createdAt: createdAt ?? this.createdAt,
      respondedAt: clearRespondedAt ? null : respondedAt ?? this.respondedAt,
      expiredAt: clearExpiredAt ? null : expiredAt ?? this.expiredAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'requestId': requestId,
      'fromDeviceId': fromDeviceId,
      'toDeviceId': toDeviceId,
      'status': status.value,
      'message': message,
      'createdAt': createdAt.toIso8601String(),
      'respondedAt': respondedAt?.toIso8601String(),
      'expiredAt': expiredAt?.toIso8601String(),
    };
  }

  @override
  List<Object?> get props => <Object?>[
        id,
        requestId,
        fromDeviceId,
        toDeviceId,
        status,
        message,
        createdAt,
        respondedAt,
        expiredAt,
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
