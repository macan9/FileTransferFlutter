import 'package:equatable/equatable.dart';

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

  @override
  List<Object?> get props => <Object?>[
        id,
        fileName,
        progress,
        direction,
        status,
      ];
}
