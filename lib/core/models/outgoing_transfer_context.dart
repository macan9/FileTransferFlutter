import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';

class OutgoingTransferContext extends Equatable {
  const OutgoingTransferContext({
    required this.transferId,
    required this.sessionId,
    required this.senderDeviceId,
    required this.receiverDeviceId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.sourcePath,
    required this.chunkSize,
    required this.totalChunks,
    required this.status,
    required this.createdAt,
    this.startedAt,
    this.completedAt,
    this.errorMessage,
    this.sentChunks = 0,
    this.sentBytes = 0,
  });

  final String transferId;
  final String sessionId;
  final String senderDeviceId;
  final String receiverDeviceId;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final String sourcePath;
  final int chunkSize;
  final int totalChunks;
  final TransferRecordStatus status;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? errorMessage;
  final int sentChunks;
  final int sentBytes;

  double get progress {
    if (fileSize <= 0) {
      return 0;
    }
    return (sentBytes / fileSize).clamp(0, 1).toDouble();
  }

  bool get isComplete => status == TransferRecordStatus.sent;

  OutgoingTransferContext copyWith({
    String? transferId,
    String? sessionId,
    String? senderDeviceId,
    String? receiverDeviceId,
    String? fileName,
    int? fileSize,
    String? mimeType,
    String? sourcePath,
    int? chunkSize,
    int? totalChunks,
    TransferRecordStatus? status,
    DateTime? createdAt,
    DateTime? startedAt,
    bool clearStartedAt = false,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    int? sentChunks,
    int? sentBytes,
  }) {
    return OutgoingTransferContext(
      transferId: transferId ?? this.transferId,
      sessionId: sessionId ?? this.sessionId,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
      receiverDeviceId: receiverDeviceId ?? this.receiverDeviceId,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      sourcePath: sourcePath ?? this.sourcePath,
      chunkSize: chunkSize ?? this.chunkSize,
      totalChunks: totalChunks ?? this.totalChunks,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      startedAt: clearStartedAt ? null : startedAt ?? this.startedAt,
      completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
      errorMessage:
          clearErrorMessage ? null : errorMessage ?? this.errorMessage,
      sentChunks: sentChunks ?? this.sentChunks,
      sentBytes: sentBytes ?? this.sentBytes,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        transferId,
        sessionId,
        senderDeviceId,
        receiverDeviceId,
        fileName,
        fileSize,
        mimeType,
        sourcePath,
        chunkSize,
        totalChunks,
        status,
        createdAt,
        startedAt,
        completedAt,
        errorMessage,
        sentChunks,
        sentBytes,
      ];
}
