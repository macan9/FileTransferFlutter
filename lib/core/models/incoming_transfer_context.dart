import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';

class IncomingTransferContext extends Equatable {
  const IncomingTransferContext({
    required this.transferId,
    required this.sessionId,
    required this.senderDeviceId,
    required this.receiverDeviceId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.chunkSize,
    required this.totalChunks,
    required this.status,
    required this.createdAt,
    required this.downloadDirectory,
    this.savePath,
    this.startedAt,
    this.completedAt,
    this.errorMessage,
    this.receivedChunks = 0,
    this.receivedBytes = 0,
  });

  final String transferId;
  final String sessionId;
  final String senderDeviceId;
  final String receiverDeviceId;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final int chunkSize;
  final int totalChunks;
  final TransferRecordStatus status;
  final DateTime createdAt;
  final String downloadDirectory;
  final String? savePath;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? errorMessage;
  final int receivedChunks;
  final int receivedBytes;

  double get progress {
    if (fileSize <= 0) {
      return 0;
    }
    return (receivedBytes / fileSize).clamp(0, 1).toDouble();
  }

  bool get isComplete =>
      status == TransferRecordStatus.received ||
      status == TransferRecordStatus.sent;

  bool get hasAllChunks => totalChunks > 0 && receivedChunks >= totalChunks;

  IncomingTransferContext copyWith({
    String? transferId,
    String? sessionId,
    String? senderDeviceId,
    String? receiverDeviceId,
    String? fileName,
    int? fileSize,
    String? mimeType,
    int? chunkSize,
    int? totalChunks,
    TransferRecordStatus? status,
    DateTime? createdAt,
    String? downloadDirectory,
    String? savePath,
    bool clearSavePath = false,
    DateTime? startedAt,
    bool clearStartedAt = false,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    int? receivedChunks,
    int? receivedBytes,
  }) {
    return IncomingTransferContext(
      transferId: transferId ?? this.transferId,
      sessionId: sessionId ?? this.sessionId,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
      receiverDeviceId: receiverDeviceId ?? this.receiverDeviceId,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      chunkSize: chunkSize ?? this.chunkSize,
      totalChunks: totalChunks ?? this.totalChunks,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      savePath: clearSavePath ? null : savePath ?? this.savePath,
      startedAt: clearStartedAt ? null : startedAt ?? this.startedAt,
      completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
      errorMessage:
          clearErrorMessage ? null : errorMessage ?? this.errorMessage,
      receivedChunks: receivedChunks ?? this.receivedChunks,
      receivedBytes: receivedBytes ?? this.receivedBytes,
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
        chunkSize,
        totalChunks,
        status,
        createdAt,
        downloadDirectory,
        savePath,
        startedAt,
        completedAt,
        errorMessage,
        receivedChunks,
        receivedBytes,
      ];
}
