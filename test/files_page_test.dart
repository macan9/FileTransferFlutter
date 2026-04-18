import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/cloud_file_list_response.dart';
import 'package:file_transfer_flutter/core/models/cloud_item.dart';
import 'package:file_transfer_flutter/core/models/file_storage_limits.dart';
import 'package:file_transfer_flutter/core/models/trash_item_operation_result.dart';
import 'package:file_transfer_flutter/core/services/file_repository.dart';
import 'package:file_transfer_flutter/features/files/presentation/pages/files_page.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('files page renders folders, files and trash items', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          initialAppConfigProvider.overrideWithValue(_testConfig),
          fileRepositoryProvider.overrideWithValue(_FakeFileRepository()),
        ],
        child: const MaterialApp(home: FilesPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('文件列表'), findsOneWidget);
    expect(find.text('images'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -800));
    await tester.pumpAndSettle();

    expect(find.text('archived.zip', skipOffstage: false), findsOneWidget);
    expect(find.text('old-folder', skipOffstage: false), findsOneWidget);
    expect(find.text('清空回收站', skipOffstage: false), findsOneWidget);
    expect(find.byTooltip('恢复', skipOffstage: false), findsNWidgets(2));
  });
}

const AppConfig _testConfig = AppConfig(
  serverUrl: 'http://127.0.0.1:3000',
  deviceId: 'test-device',
  deviceName: 'Test Device',
  downloadDirectory: 'C:/Downloads',
  autoOnline: true,
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
    return CloudFileListResponse(
      path: path,
      parentPath: path.isEmpty ? null : '',
      items: <CloudItem>[
        CloudItem(
          id: 10,
          type: CloudItemType.folder,
          name: 'images',
          path: 'images',
          parentPath: '',
          createdAt: DateTime.parse('2026-03-27T09:15:10.000Z'),
        ),
        CloudItem(
          id: 1,
          type: CloudItemType.file,
          name: 'report.pdf',
          originalName: 'report.pdf',
          filename: 'report.pdf',
          mimeType: 'application/pdf',
          size: 1024,
          url: '/files/1/download',
          directoryPath: path,
          createdAt: DateTime.parse('2026-03-28T09:15:10.000Z'),
        ),
      ],
    );
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
    return <String>['report.pdf'];
  }

  @override
  Future<CloudFileListResponse> fetchTrashFiles({String path = ''}) async {
    if (path == 'old-folder') {
      return CloudFileListResponse(
        path: 'old-folder',
        parentPath: '',
        items: <CloudItem>[
          CloudItem(
            id: 4,
            type: CloudItemType.folder,
            name: 'child-folder',
            path: 'old-folder/child-folder',
            parentPath: 'old-folder',
            createdAt: DateTime.parse('2026-03-18T03:10:00.000Z'),
            deletedAt: DateTime.parse('2026-03-25T08:00:00.000Z'),
          ),
          CloudItem(
            id: 5,
            type: CloudItemType.file,
            name: 'nested.txt',
            originalName: 'nested.txt',
            filename: 'nested.txt',
            mimeType: 'text/plain',
            size: 512,
            url: '/files/5/download',
            directoryPath: 'old-folder',
            createdAt: DateTime.parse('2026-03-20T04:10:00.000Z'),
            deletedAt: DateTime.parse('2026-03-25T08:00:00.000Z'),
          ),
        ],
      );
    }

    return CloudFileListResponse(
      path: '',
      parentPath: null,
      items: <CloudItem>[
        CloudItem(
          id: 2,
          type: CloudItemType.file,
          name: 'archived.zip',
          originalName: 'archived.zip',
          filename: 'archived.zip',
          mimeType: 'application/zip',
          size: 2048,
          url: '/files/2/download',
          directoryPath: 'archive',
          createdAt: DateTime.parse('2026-03-20T02:10:00.000Z'),
          deletedAt: DateTime.parse('2026-03-25T08:00:00.000Z'),
        ),
        CloudItem(
          id: 3,
          type: CloudItemType.folder,
          name: 'old-folder',
          path: 'old-folder',
          parentPath: '',
          createdAt: DateTime.parse('2026-03-18T02:10:00.000Z'),
          deletedAt: DateTime.parse('2026-03-25T08:00:00.000Z'),
        ),
      ],
    );
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
