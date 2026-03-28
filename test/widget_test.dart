import 'package:file_transfer_flutter/app/app.dart';
import 'package:file_transfer_flutter/core/models/cloud_file.dart';
import 'package:file_transfer_flutter/core/models/file_storage_limits.dart';
import 'package:file_transfer_flutter/core/services/file_repository.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app shows the three expected navigation tabs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          fileRepositoryProvider.overrideWithValue(_FakeFileRepository()),
        ],
        child: const FileTransferApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('\u4e91\u6587\u4ef6'), findsOneWidget);
    expect(find.text('\u5b9e\u65f6\u4f20\u8f93'), findsOneWidget);
    expect(find.text('\u8bbe\u7f6e'), findsOneWidget);
  });
}

class _FakeFileRepository implements FileRepository {
  @override
  Future<void> clearTrash() async {}

  @override
  Future<void> deleteFile(int id) async {}

  @override
  Future<void> deleteTrashFilePermanently(int id) async {}

  @override
  Future<void> restoreTrashFile(int id) async {}

  @override
  Future<String> downloadFile(
    CloudFile file, {
    TransferProgressCallback? onProgress,
  }) async {
    return 'test-download-path';
  }

  @override
  Future<List<CloudFile>> fetchFiles() async {
    return const <CloudFile>[];
  }

  @override
  Future<List<CloudFile>> fetchTrashFiles() async {
    return const <CloudFile>[];
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
  Future<CloudFile> uploadFile({TransferProgressCallback? onProgress}) {
    throw UnimplementedError();
  }

  @override
  Future<CloudFile> uploadFileFromPath(
    String filePath, {
    TransferProgressCallback? onProgress,
  }) {
    throw UnimplementedError();
  }
}
