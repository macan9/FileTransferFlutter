import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart' as p2p;
import 'package:file_transfer_flutter/core/models/transfer_record.dart';

enum TransferDirection { upload, download, peerToPeer }

enum TransferStatus { pending, running, paused, completed, failed }

class TransferTask extends Equatable {
  const TransferTask({
    required this.id,
    required this.fileName,
    required this.progress,
    required this.direction,
    required this.status,
  });

  final String id;
  final String fileName;
  final double progress;
  final TransferDirection direction;
  final TransferStatus status;

  factory TransferTask.fromTransferRecord(
    TransferRecord record, {
    required String currentDeviceId,
  }) {
    final TransferDirection direction = record.isOutgoingFor(currentDeviceId)
        ? TransferDirection.upload
        : TransferDirection.download;

    return TransferTask(
      id: record.transferId,
      fileName: record.fileName,
      progress: _progressFromStatus(record.status),
      direction: direction,
      status: _statusFromRecord(record.status),
    );
  }

  @override
  List<Object?> get props => <Object?>[
        id,
        fileName,
        progress,
        direction,
        status,
      ];

  static double _progressFromStatus(p2p.TransferRecordStatus status) {
    return switch (status) {
      p2p.TransferRecordStatus.pending => 0,
      p2p.TransferRecordStatus.sending ||
      p2p.TransferRecordStatus.receiving =>
        0.5,
      p2p.TransferRecordStatus.received || p2p.TransferRecordStatus.sent => 1,
      p2p.TransferRecordStatus.failed ||
      p2p.TransferRecordStatus.cancelled =>
        0,
    };
  }

  static TransferStatus _statusFromRecord(p2p.TransferRecordStatus status) {
    return switch (status) {
      p2p.TransferRecordStatus.pending => TransferStatus.pending,
      p2p.TransferRecordStatus.sending ||
      p2p.TransferRecordStatus.receiving =>
        TransferStatus.running,
      p2p.TransferRecordStatus.received ||
      p2p.TransferRecordStatus.sent =>
        TransferStatus.completed,
      p2p.TransferRecordStatus.failed ||
      p2p.TransferRecordStatus.cancelled =>
        TransferStatus.failed,
    };
  }
}
