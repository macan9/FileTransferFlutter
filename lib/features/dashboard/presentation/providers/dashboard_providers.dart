import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final recentFilesProvider = FutureProvider<List<String>>((Ref ref) async {
  return ref.watch(fileRepositoryProvider).fetchRecentFiles();
});

final dashboardDevicesProvider = FutureProvider((Ref ref) async {
  return ref.watch(deviceDiscoveryServiceProvider).discoverDevices();
});

final dashboardTransfersProvider = FutureProvider((Ref ref) async {
  return ref.watch(transferServiceProvider).fetchActiveTasks();
});
