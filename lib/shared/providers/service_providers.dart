import 'package:file_transfer_flutter/core/models/device_info.dart';
import 'package:file_transfer_flutter/core/models/transfer_task.dart';
import 'package:file_transfer_flutter/core/services/device_discovery_service.dart';
import 'package:file_transfer_flutter/core/services/file_repository.dart';
import 'package:file_transfer_flutter/core/services/transfer_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final fileRepositoryProvider = Provider<FileRepository>((Ref ref) {
  return HttpFileRepository();
});

final deviceDiscoveryServiceProvider = Provider<DeviceDiscoveryService>((Ref ref) {
  return const MockDeviceDiscoveryService();
});

final transferServiceProvider = Provider<TransferService>((Ref ref) {
  return const MockTransferService();
});

class MockDeviceDiscoveryService implements DeviceDiscoveryService {
  const MockDeviceDiscoveryService();

  @override
  Future<List<DeviceInfo>> discoverDevices() async {
    return const <DeviceInfo>[
      DeviceInfo(
        id: 'dev-01',
        name: 'Office MacBook',
        address: '192.168.1.12',
        isOnline: true,
      ),
      DeviceInfo(
        id: 'dev-02',
        name: 'Living Room PC',
        address: '192.168.1.19',
        isOnline: true,
      ),
      DeviceInfo(
        id: 'dev-03',
        name: 'Android Phone',
        address: '192.168.1.28',
        isOnline: false,
      ),
    ];
  }
}

class MockTransferService implements TransferService {
  const MockTransferService();

  @override
  Future<List<TransferTask>> fetchActiveTasks() async {
    return const <TransferTask>[
      TransferTask(
        id: 'task-01',
        fileName: 'design_export.fig',
        progress: 0.72,
        direction: TransferDirection.upload,
        status: TransferStatus.running,
      ),
      TransferTask(
        id: 'task-02',
        fileName: 'demo_build.apk',
        progress: 1,
        direction: TransferDirection.peerToPeer,
        status: TransferStatus.completed,
      ),
      TransferTask(
        id: 'task-03',
        fileName: 'raw_video.mov',
        progress: 0.16,
        direction: TransferDirection.download,
        status: TransferStatus.paused,
      ),
    ];
  }
}
