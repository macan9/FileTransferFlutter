import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';

class TransferRecord extends Equatable {
  const TransferRecord({
    required this.id,
    required this.transferId,
    required this.sessionId,
    required this.senderDeviceId,
    required this.receiverDeviceId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.direction,
    required this.status,
    required this.createdAt,
    this.errorMessage,
    this.startedAt,
    this.completedAt,
    this.hiddenAt,
    this.deletedAt,
  });

  factory TransferRecord.fromJson(Map<String, dynamic> json) {
    final String senderDeviceId = json['senderDeviceId']?.toString() ?? '';
    final String receiverDeviceId = json['receiverDeviceId']?.toString() ?? '';

    return TransferRecord(
      id: json['id']?.toString() ?? '',
      transferId: json['transferId']?.toString() ?? '',
      sessionId: json['sessionId']?.toString() ?? '',
      senderDeviceId: senderDeviceId,
      receiverDeviceId: receiverDeviceId,
      fileName: json['fileName']?.toString() ?? '',
      fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
      mimeType: json['mimeType']?.toString() ?? '',
      direction: json['direction'] == null
          ? TransferDirection(
              senderDeviceId: senderDeviceId,
              receiverDeviceId: receiverDeviceId,
            )
          : TransferDirection.fromValue(json['direction']?.toString() ?? ''),
      status: TransferRecordStatus.fromValue(
        json['status']?.toString() ?? 'pending',
      ),
      errorMessage: json['errorMessage']?.toString(),
      createdAt: _parseRequiredDateTime(json['createdAt'], field: 'createdAt'),
      startedAt: _parseDateTime(json['startedAt']),
      completedAt: _parseDateTime(json['completedAt']),
      hiddenAt: _parseDateTime(json['hiddenAt']),
      deletedAt: _parseDateTime(json['deletedAt']),
    );
  }

  final String id;
  final String transferId;
  final String sessionId;
  final String senderDeviceId;
  final String receiverDeviceId;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final TransferDirection direction;
  final TransferRecordStatus status;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? hiddenAt;
  final DateTime? deletedAt;

  bool get isHidden => hiddenAt != null;
  bool get isDeleted => deletedAt != null;

  bool isOutgoingFor(String deviceId) => direction.isOutgoingFor(deviceId);
  bool isIncomingFor(String deviceId) => direction.isIncomingFor(deviceId);

  TransferRecord copyWith({
    String? id,
    String? transferId,
    String? sessionId,
    String? senderDeviceId,
    String? receiverDeviceId,
    String? fileName,
    int? fileSize,
    String? mimeType,
    TransferDirection? direction,
    TransferRecordStatus? status,
    String? errorMessage,
    bool clearErrorMessage = false,
    DateTime? createdAt,
    DateTime? startedAt,
    bool clearStartedAt = false,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    DateTime? hiddenAt,
    bool clearHiddenAt = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return TransferRecord(
      id: id ?? this.id,
      transferId: transferId ?? this.transferId,
      sessionId: sessionId ?? this.sessionId,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
      receiverDeviceId: receiverDeviceId ?? this.receiverDeviceId,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      direction: direction ?? this.direction,
      status: status ?? this.status,
      errorMessage:
          clearErrorMessage ? null : errorMessage ?? this.errorMessage,
      createdAt: createdAt ?? this.createdAt,
      startedAt: clearStartedAt ? null : startedAt ?? this.startedAt,
      completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
      hiddenAt: clearHiddenAt ? null : hiddenAt ?? this.hiddenAt,
      deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'transferId': transferId,
      'sessionId': sessionId,
      'senderDeviceId': senderDeviceId,
      'receiverDeviceId': receiverDeviceId,
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'direction': direction.value,
      'status': status.value,
      'errorMessage': errorMessage,
      'createdAt': createdAt.toIso8601String(),
      'startedAt': startedAt?.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'hiddenAt': hiddenAt?.toIso8601String(),
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  @override
  List<Object?> get props => <Object?>[
        id,
        transferId,
        sessionId,
        senderDeviceId,
        receiverDeviceId,
        fileName,
        fileSize,
        mimeType,
        direction,
        status,
        errorMessage,
        createdAt,
        startedAt,
        completedAt,
        hiddenAt,
        deletedAt,
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
