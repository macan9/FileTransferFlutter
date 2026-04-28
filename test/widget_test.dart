import 'package:file_transfer_flutter/app/app.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/cloud_file_list_response.dart';
import 'package:file_transfer_flutter/core/models/cloud_item.dart';
import 'package:file_transfer_flutter/core/models/file_storage_limits.dart';
import 'package:file_transfer_flutter/core/models/trash_item_operation_result.dart';
import 'package:file_transfer_flutter/core/services/file_repository.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app shows the four expected navigation tabs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          initialAppConfigProvider.overrideWithValue(_testConfig),
          fileRepositoryProvider.overrideWithValue(_FakeFileRepository()),
        ],
        child: const FileTransferApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('\u4e91\u6587\u4ef6'), findsOneWidget);
    expect(find.text('\u5b9e\u65f6\u4f20\u8f93'), findsOneWidget);
    expect(find.text('\u5185\u7f51\u7a7f\u900f'), findsOneWidget);
    expect(find.text('\u8bbe\u7f6e'), findsOneWidget);
  });
}

const AppConfig _testConfig = AppConfig(
  serverUrl: 'http://127.0.0.1:3000',
  deviceId: 'test-device',
  deviceName: 'Test Device',
  devicePlatform: 'windows',
  zeroTierNodeId: '',
  agentToken: '',
  downloadDirectory: 'C:/Downloads',
  autoOnline: false,
  minimizeToTrayOnClose: true,
);

class _FakeFileRepository implements FileRepository {
  @override
  Future<void> clearTrash() async {}

  @override
  Future<void> createFolder({
    required String path,
    String? name,
  }) async {}

  @override
  Future<void> deleteFile(int id) async {}

  @override
  Future<void> deleteFolder(String path) async {}

  @override
  Future<TrashItemOperationResult> deleteTrashFilePermanently(int id) async {
    return const TrashItemOperationResult(
      id: 0,
      type: CloudItemType.file,
      permanentlyDeleted: true,
    );
  }

  @override
  Future<String> downloadFile(
    CloudItem file, {
    TransferProgressCallback? onProgress,
  }) async {
    return 'test-download-path';
  }

  @override
  Future<CloudFileListResponse> fetchFiles({String path = ''}) async {
    return const CloudFileListResponse();
  }

  @override
  Future<CloudFileListResponse> fetchTrashFiles({String path = ''}) async {
    return const CloudFileListResponse();
  }

  @override
  Future<FileStorageLimits> fetchLimits() async {
    return const FileStorageLimits(
      singleFileLimitBytes: 200 * 1024 * 1024,
      totalUploadsLimitBytes: 10 * 1024 * 1024 * 1024,
      currentUsageBytes: 1024,
      remainingBytes: (10 * 1024 * 1024 * 1024) - 1024,
      transferRateLimitBytesPerSecond: 2 * 1024 * 1024,
    );
  }

  @override
  Future<List<String>> fetchRecentFiles() async {
    return <String>['demo.txt'];
  }

  @override
  Future<void> moveFile(int id, {required String targetPath}) async {}

  @override
  Future<void> moveFolder({
    required String sourcePath,
    required String targetPath,
    String? name,
  }) async {}

  @override
  Future<TrashItemOperationResult> restoreTrashItem(int id) async {
    return const TrashItemOperationResult(
      id: 0,
      type: CloudItemType.file,
      restored: true,
    );
  }

  @override
  Future<CloudItem> uploadFile({
    String path = '',
    TransferProgressCallback? onProgress,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<CloudItem> uploadFileFromPath(
    String filePath, {
    String path = '',
    TransferProgressCallback? onProgress,
  }) {
    throw UnimplementedError();
  }
}
