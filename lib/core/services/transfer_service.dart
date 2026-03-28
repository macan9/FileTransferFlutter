import 'package:file_transfer_flutter/core/models/transfer_task.dart';

abstract interface class TransferService {
  Future<List<TransferTask>> fetchActiveTasks();
}
