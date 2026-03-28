import 'package:file_transfer_flutter/core/models/cloud_file.dart';
import 'package:file_transfer_flutter/core/models/file_storage_limits.dart';
import 'package:file_transfer_flutter/core/services/file_repository.dart';
import 'package:file_transfer_flutter/features/files/presentation/pages/files_page.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('files page renders active files and trash files', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          fileRepositoryProvider.overrideWithValue(_FakeFileRepository()),
        ],
        child: const MaterialApp(
          home: FilesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('文件列表'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('清空回收站'),
      300,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();

    expect(find.text('archived.zip'), findsOneWidget);
    expect(find.text('清空回收站'), findsOneWidget);
    expect(find.byTooltip('恢复'), findsOneWidget);
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
    return <CloudFile>[
      CloudFile(
        id: 1,
        originalName: 'report.pdf',
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        size: 1024,
        url: '/files/1/download',
        createdAt: DateTime.parse('2026-03-28T09:15:10.000Z'),
      ),
    ];
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
  Future<List<CloudFile>> fetchTrashFiles() async {
    return <CloudFile>[
      CloudFile(
        id: 2,
        originalName: 'archived.zip',
        filename: 'archived.zip',
        mimeType: 'application/zip',
        size: 2048,
        url: '/files/2/download',
        createdAt: DateTime.parse('2026-03-20T02:10:00.000Z'),
        deletedAt: DateTime.parse('2026-03-25T08:00:00.000Z'),
      ),
    ];
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
