import 'package:file_transfer_flutter/core/models/device_info.dart';
import 'package:file_transfer_flutter/shared/providers/p2p_presence_providers.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final recentFilesProvider = FutureProvider<List<String>>((Ref ref) async {
  return ref.watch(fileRepositoryProvider).fetchRecentFiles();
});

final dashboardDevicesProvider = Provider<List<DeviceInfo>>((Ref ref) {
  final presence = ref.watch(p2pPresenceProvider);
  return presence.devices
      .map((device) => DeviceInfo.fromP2pDevice(device))
      .toList();
});

final dashboardTransfersProvider = FutureProvider((Ref ref) async {
  return ref.watch(transferServiceProvider).fetchActiveTasks();
});
