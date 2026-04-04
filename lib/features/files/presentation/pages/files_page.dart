import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/error/app_exception.dart';
import 'package:file_transfer_flutter/core/models/cloud_file.dart';
import 'package:file_transfer_flutter/core/models/file_storage_limits.dart';
import 'package:file_transfer_flutter/core/services/file_repository.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:file_transfer_flutter/shared/widgets/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

class FilesPage extends ConsumerStatefulWidget {
  const FilesPage({super.key});

  @override
  ConsumerState<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends ConsumerState<FilesPage> {
  late Future<List<CloudFile>> _filesFuture;
  late Future<List<CloudFile>> _trashFilesFuture;
  late Future<FileStorageLimits> _limitsFuture;

  bool _dragging = false;
  bool _processingUploadQueue = false;
  bool _clearingTrash = false;

  final List<_UploadQueueItem> _uploadQueue = <_UploadQueueItem>[];
  final Set<int> _busyFileIds = <int>{};
  final Set<int> _busyTrashFileIds = <int>{};
  final Map<int, double> _downloadProgress = <int, double>{};

  FileRepository get _repository => ref.read(fileRepositoryProvider);

  bool get _dragEnabled {
    final String bindingType = WidgetsBinding.instance.runtimeType.toString();
    final bool isWidgetTestBinding =
        bindingType.contains('TestWidgetsFlutterBinding') ||
            bindingType.contains('AutomatedTestWidgetsFlutterBinding') ||
            bindingType.contains('LiveTestWidgetsFlutterBinding');
    return Platform.isWindows && !isWidgetTestBinding;
  }

  @override
  void initState() {
    super.initState();
    _filesFuture = _repository.fetchFiles();
    _trashFilesFuture = _repository.fetchTrashFiles();
    _limitsFuture = _repository.fetchLimits();
  }

  void _reloadFiles() {
    setState(() {
      _filesFuture = _repository.fetchFiles();
    });
  }

  void _reloadTrashFiles() {
    setState(() {
      _trashFilesFuture = _repository.fetchTrashFiles();
    });
  }

  void _reloadLimits() {
    setState(() {
      _limitsFuture = _repository.fetchLimits();
    });
  }

  void _reloadPageData() {
    _reloadFiles();
    _reloadTrashFiles();
    _reloadLimits();
  }

  Future<void> _refreshPage() async {
    _reloadPageData();
    try {
      await Future.wait(<Future<Object?>>[
        _filesFuture,
        _trashFilesFuture,
        _limitsFuture,
      ]);
    } catch (_) {
      // Keep the refresh gesture responsive even when the local service is offline.
    }
  }

  Future<void> _uploadFile() async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        withData: false,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }

      final String? filePath = result.files.single.path;
      if (filePath == null || filePath.isEmpty) {
        throw const AppException('未能读取所选文件路径');
      }

      await _enqueueUploads(<_UploadQueueItem>[
        _UploadQueueItem(
          id: _createUploadQueueId(),
          filePath: filePath,
          displayName: _extractFileName(filePath),
          progress: 0,
          status: _UploadQueueStatus.pending,
          source: _UploadSource.picker,
        ),
      ]);
    } on AppException catch (error) {
      if (!mounted || error.message == '已取消上传') {
        return;
      }
      _showAppException(error);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('上传失败: $error', isError: true);
    }
  }

  Future<void> _uploadFilesFromPaths(List<String> filePaths) async {
    if (filePaths.isEmpty) {
      return;
    }

    final List<_UploadQueueItem> items = filePaths
        .map(
          (String filePath) => _UploadQueueItem(
            id: _createUploadQueueId(),
            filePath: filePath,
            displayName: _extractFileName(filePath),
            progress: 0,
            status: _UploadQueueStatus.pending,
            source: _UploadSource.dragDrop,
          ),
        )
        .toList();

    await _enqueueUploads(items);
  }

  Future<void> _enqueueUploads(List<_UploadQueueItem> items) async {
    if (items.isEmpty) {
      return;
    }

    setState(() {
      _uploadQueue.addAll(items);
    });

    if (_processingUploadQueue) {
      return;
    }

    _processingUploadQueue = true;
    int successCount = 0;

    try {
      while (true) {
        final _UploadQueueItem? nextItem =
            _uploadQueue.cast<_UploadQueueItem?>().firstWhere(
                  (_UploadQueueItem? item) =>
                      item?.status == _UploadQueueStatus.pending,
                  orElse: () => null,
                );

        if (nextItem == null) {
          break;
        }

        _updateUploadItem(
          nextItem.id,
          status: _UploadQueueStatus.uploading,
          progress: 0,
        );

        try {
          await _repository.uploadFileFromPath(
            nextItem.filePath,
            onProgress: (double progress) {
              if (!mounted) {
                return;
              }
              _updateUploadItem(nextItem.id, progress: progress);
            },
          );

          successCount += 1;
          _updateUploadItem(
            nextItem.id,
            status: _UploadQueueStatus.completed,
            progress: 1,
          );
          _reloadPageData();
        } on AppException catch (error) {
          _updateUploadItem(
            nextItem.id,
            status: _UploadQueueStatus.failed,
            errorMessage: error.message,
          );
          if (mounted) {
            _showAppException(error);
          }
        } catch (error) {
          _updateUploadItem(
            nextItem.id,
            status: _UploadQueueStatus.failed,
            errorMessage: '$error',
          );
          if (mounted) {
            _showMessage('上传失败: $error', isError: true);
          }
        }
      }

      if (mounted && successCount > 0) {
        _showMessage(successCount == 1 ? '上传完成' : '已完成 $successCount 个文件上传');
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploadQueue.removeWhere(
            (_UploadQueueItem item) =>
                item.status == _UploadQueueStatus.completed,
          );
        });
      }
      _processingUploadQueue = false;
    }
  }

  Future<void> _downloadFile(CloudFile file) async {
    _setFileBusy(file.id, true);

    try {
      final String path = await _repository.downloadFile(
        file,
        onProgress: (double progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _downloadProgress[file.id] = progress;
          });
        },
      );
      if (!mounted) {
        return;
      }
      _showMessage('已下载到 $path');
    } on AppException catch (error) {
      if (!mounted || error.message == '已取消下载') {
        return;
      }
      _showAppException(error);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('下载失败: $error', isError: true);
    } finally {
      if (mounted) {
        _setFileBusy(file.id, false);
      }
    }
  }

  Future<void> _moveFileToTrash(CloudFile file) async {
    final bool confirmed = await _showConfirmationDialog(
          title: '移入回收站',
          content: '确认将“${file.originalName}”移入回收站吗？移入后会从文件列表中隐藏，但不会立刻从磁盘删除。',
          confirmLabel: '移入回收站',
        ) ??
        false;

    if (!confirmed) {
      return;
    }

    _setFileBusy(file.id, true);

    try {
      await _repository.deleteFile(file.id);
      _reloadPageData();
      if (!mounted) {
        return;
      }
      _showMessage('文件已移入回收站');
    } on AppException catch (error) {
      if (!mounted) {
        return;
      }
      _showAppException(error);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('移入回收站失败: $error', isError: true);
    } finally {
      if (mounted) {
        _setFileBusy(file.id, false);
      }
    }
  }

  Future<void> _deleteTrashFilePermanently(CloudFile file) async {
    final bool confirmed = await _showConfirmationDialog(
          title: '彻底删除文件',
          content: '确认彻底删除“${file.originalName}”吗？这会同时删除回收站记录和磁盘文件，操作不可撤销。',
          confirmLabel: '彻底删除',
          destructive: true,
        ) ??
        false;

    if (!confirmed) {
      return;
    }

    _setTrashFileBusy(file.id, true);

    try {
      await _repository.deleteTrashFilePermanently(file.id);
      _reloadPageData();
      if (!mounted) {
        return;
      }
      _showMessage('文件已彻底删除');
    } on AppException catch (error) {
      if (!mounted) {
        return;
      }
      _showAppException(error);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('彻底删除失败: $error', isError: true);
    } finally {
      if (mounted) {
        _setTrashFileBusy(file.id, false);
      }
    }
  }

  Future<void> _restoreTrashFile(CloudFile file) async {
    _setTrashFileBusy(file.id, true);

    try {
      await _repository.restoreTrashFile(file.id);
      _reloadPageData();
      if (!mounted) {
        return;
      }
      _showMessage('文件已从回收站恢复');
    } on AppException catch (error) {
      if (!mounted) {
        return;
      }
      _showAppException(error);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('恢复文件失败: $error', isError: true);
    } finally {
      if (mounted) {
        _setTrashFileBusy(file.id, false);
      }
    }
  }

  Future<void> _clearTrash(List<CloudFile> trashFiles) async {
    if (trashFiles.isEmpty || _clearingTrash) {
      return;
    }

    final bool confirmed = await _showConfirmationDialog(
          title: '清空回收站',
          content: '确认清空回收站吗？共 ${trashFiles.length} 个文件将被彻底删除，此操作不可撤销。',
          confirmLabel: '清空回收站',
          destructive: true,
        ) ??
        false;

    if (!confirmed) {
      return;
    }

    setState(() {
      _clearingTrash = true;
    });

    try {
      await _repository.clearTrash();
      _reloadPageData();
      if (!mounted) {
        return;
      }
      _showMessage('回收站已清空');
    } on AppException catch (error) {
      if (!mounted) {
        return;
      }
      _showAppException(error);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('清空回收站失败: $error', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _clearingTrash = false;
        });
      }
    }
  }

  Future<bool?> _showConfirmationDialog({
    required String title,
    required String content,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB42318),
                      foregroundColor: Colors.white,
                    )
                  : null,
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
  }

  void _setFileBusy(int fileId, bool isBusy) {
    setState(() {
      if (isBusy) {
        _busyFileIds.add(fileId);
      } else {
        _busyFileIds.remove(fileId);
        _downloadProgress.remove(fileId);
      }
    });
  }

  void _setTrashFileBusy(int fileId, bool isBusy) {
    setState(() {
      if (isBusy) {
        _busyTrashFileIds.add(fileId);
      } else {
        _busyTrashFileIds.remove(fileId);
      }
    });
  }

  void _updateUploadItem(
    String id, {
    _UploadQueueStatus? status,
    double? progress,
    String? errorMessage,
  }) {
    if (!mounted) {
      return;
    }

    setState(() {
      final int index =
          _uploadQueue.indexWhere((_UploadQueueItem item) => item.id == id);
      if (index == -1) {
        return;
      }

      final _UploadQueueItem current = _uploadQueue[index];
      _uploadQueue[index] = current.copyWith(
        status: status ?? current.status,
        progress: progress ?? current.progress,
        errorMessage: errorMessage ?? current.errorMessage,
      );
    });
  }

  void _showMessage(String message, {bool isError = false}) {
    final Color? backgroundColor;
    final Color? foregroundColor;

    if (isError) {
      backgroundColor = Theme.of(context).colorScheme.error;
      foregroundColor = Theme.of(context).colorScheme.onError;
    } else {
      backgroundColor = null;
      foregroundColor = null;
    }

    final SnackBar snackBar = SnackBar(
      content: foregroundColor == null
          ? Text(message)
          : DefaultTextStyle(
              style: TextStyle(color: foregroundColor, fontSize: 14),
              child: Text(message),
            ),
      backgroundColor: backgroundColor,
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      closeIconColor: foregroundColor,
    );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(snackBar);
  }

  void _showWarningMessage(String message) {
    const Color warningBackground = Color(0xFFFDE68A);
    const Color warningForeground = Color(0xFF713F12);

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: DefaultTextStyle(
            style: const TextStyle(
              color: warningForeground,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            child: Text(message),
          ),
          backgroundColor: warningBackground,
          behavior: SnackBarBehavior.floating,
          showCloseIcon: true,
          closeIconColor: warningForeground,
        ),
      );
  }

  void _showAppException(AppException error) {
    if (_isWarningMessage(error.message)) {
      _showWarningMessage(error.message);
      return;
    }

    _showMessage(error.message, isError: true);
  }

  bool _isWarningMessage(String message) {
    const List<String> warningKeywords = <String>[
      '服务器容量已满',
      '存储空间',
      '单个文件大小不能超过',
      '上传限制',
      '容量已满',
      '200MB',
      '10GB',
    ];

    return warningKeywords.any(message.contains);
  }

  String _extractFileName(String filePath) {
    final String normalized = filePath.replaceAll('\\', '/');
    final List<String> segments = normalized.split('/');
    return segments.isEmpty ? filePath : segments.last;
  }

  String _createUploadQueueId() {
    return '${DateTime.now().microsecondsSinceEpoch}-${_uploadQueue.length}';
  }

  List<_UploadQueueItem> get _visibleUploadItems {
    return _uploadQueue
        .where(
          (_UploadQueueItem item) =>
              item.status == _UploadQueueStatus.pending ||
              item.status == _UploadQueueStatus.uploading ||
              item.status == _UploadQueueStatus.failed,
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final AppConfig config = ref.watch(appConfigProvider);
    final Widget content = RefreshIndicator(
      onRefresh: _refreshPage,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _UploadHero(
            uploadItems: _visibleUploadItems,
            dragging: _dragging,
            dragEnabled: _dragEnabled,
            onUploadPressed: _uploadFile,
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '文件列表',
            subtitle: '展示服务端当前可用文件，支持下载和移入回收站。',
            child: FutureBuilder<List<CloudFile>>(
              future: _filesFuture,
              builder: (
                BuildContext context,
                AsyncSnapshot<List<CloudFile>> snapshot,
              ) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  );
                }

                if (snapshot.hasError) {
                  return _ErrorState(
                    message:
                        '加载文件列表失败，请确认 ${config.serverUrl} 服务已启动，且手机可访问这台电脑。',
                    onRetry: _reloadFiles,
                  );
                }

                final List<CloudFile> files = snapshot.data ?? <CloudFile>[];
                if (files.isEmpty) {
                  return const _EmptyState(
                    icon: Icons.cloud_outlined,
                    title: '还没有云文件',
                    description: '点击上方上传区域选择文件，上传后会在这里展示。',
                  );
                }

                return Column(
                  children: files.map((CloudFile file) {
                    final bool isBusy = _busyFileIds.contains(file.id);
                    return _CloudFileTile(
                      file: file,
                      busy: isBusy,
                      progress: _downloadProgress[file.id],
                      onDownload: () => _downloadFile(file),
                      onDelete: () => _moveFileToTrash(file),
                    );
                  }).toList(),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '存储空间',
            subtitle: '查看当前已用空间、剩余空间、单文件上限和服务端 2MB/s 传输限速。',
            child: FutureBuilder<FileStorageLimits>(
              future: _limitsFuture,
              builder: (
                BuildContext context,
                AsyncSnapshot<FileStorageLimits> snapshot,
              ) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  );
                }

                if (snapshot.hasError || !snapshot.hasData) {
                  return _ErrorState(
                    message: '加载空间信息失败，请确认 GET /files/limits 可用。',
                    onRetry: _reloadLimits,
                  );
                }

                return _StorageLimitsPanel(limits: snapshot.data!);
              },
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '回收站',
            subtitle: '展示已移入回收站的文件，可恢复、单独彻底删除，也可一键清空。',
            titleAction: FutureBuilder<List<CloudFile>>(
              future: _trashFilesFuture,
              builder: (
                BuildContext context,
                AsyncSnapshot<List<CloudFile>> snapshot,
              ) {
                final List<CloudFile> files = snapshot.data ?? <CloudFile>[];
                return FilledButton.tonalIcon(
                  onPressed: files.isEmpty || _clearingTrash
                      ? null
                      : () => _clearTrash(files),
                  icon: _clearingTrash
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_forever_rounded),
                  label: Text(_clearingTrash ? '清空中...' : '清空回收站'),
                );
              },
            ),
            child: FutureBuilder<List<CloudFile>>(
              future: _trashFilesFuture,
              builder: (
                BuildContext context,
                AsyncSnapshot<List<CloudFile>> snapshot,
              ) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  );
                }

                if (snapshot.hasError) {
                  return _ErrorState(
                    message: '加载回收站失败，请确认 GET /files/trash 可用。',
                    onRetry: _reloadTrashFiles,
                  );
                }

                final List<CloudFile> files = snapshot.data ?? <CloudFile>[];
                if (files.isEmpty) {
                  return const _EmptyState(
                    icon: Icons.delete_sweep_outlined,
                    title: '回收站为空',
                    description: '从文件列表移入回收站的文件会显示在这里，服务端也会按配置自动清理。',
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    ...files.map((CloudFile file) {
                      return _TrashFileTile(
                        file: file,
                        busy: _busyTrashFileIds.contains(file.id),
                        onRestore: () => _restoreTrashFile(file),
                        onDelete: () => _deleteTrashFilePermanently(file),
                      );
                    }),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      body: Stack(
        children: <Widget>[
          if (_dragEnabled)
            DropTarget(
              onDragEntered: (_) {
                setState(() {
                  _dragging = true;
                });
              },
              onDragExited: (_) {
                setState(() {
                  _dragging = false;
                });
              },
              onDragDone: (DropDoneDetails details) async {
                setState(() {
                  _dragging = false;
                });

                final List<String> filePaths = details.files
                    .map((dynamic file) => file.path as String)
                    .where((String path) => path.isNotEmpty)
                    .toList();
                await _uploadFilesFromPaths(filePaths);
              },
              child: content,
            )
          else
            content,
          if (_dragging && _dragEnabled)
            IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(
                        alpha: 0.08,
                      ),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                ),
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 18,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 24,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.cloud_upload_rounded, size: 38),
                      SizedBox(height: 10),
                      Text(
                        '松开以上传文件',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text('支持直接把文件拖到当前窗口'),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

enum _UploadQueueStatus { pending, uploading, completed, failed }

enum _UploadSource { picker, dragDrop }

class _UploadQueueItem {
  const _UploadQueueItem({
    required this.id,
    required this.filePath,
    required this.displayName,
    required this.progress,
    required this.status,
    required this.source,
    this.errorMessage,
  });

  final String id;
  final String filePath;
  final String displayName;
  final double progress;
  final _UploadQueueStatus status;
  final _UploadSource source;
  final String? errorMessage;

  _UploadQueueItem copyWith({
    String? id,
    String? filePath,
    String? displayName,
    double? progress,
    _UploadQueueStatus? status,
    _UploadSource? source,
    String? errorMessage,
  }) {
    return _UploadQueueItem(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      displayName: displayName ?? this.displayName,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      source: source ?? this.source,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class _UploadHero extends StatelessWidget {
  const _UploadHero({
    required this.uploadItems,
    required this.dragging,
    required this.dragEnabled,
    required this.onUploadPressed,
  });

  final List<_UploadQueueItem> uploadItems;
  final bool dragging;
  final bool dragEnabled;
  final VoidCallback onUploadPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFF0F6CBD), Color(0xFF2B8EFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: const Color(0xFF0F6CBD).withValues(alpha: 0.20),
            blurRadius: 24,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  Icons.cloud_upload_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  '上传到云文件',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: <Widget>[
              _UploadInfoChip(
                label: dragging ? '正在接收拖拽文件...' : '单文件上限 200MB',
              ),
              const SizedBox(width: 12),
              const _UploadInfoChip(label: '总容量 10GB'),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        '请选择文件上传',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.92),
                          height: 1.0,
                        ),
                      ),
                    ),
                    if (dragEnabled)
                      Text(
                        '支持拖拽文件到当前窗口上传',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.82),
                          height: 1.5,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: onUploadPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF0F6CBD),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                ),
                icon: const Icon(Icons.add_rounded),
                label: const Text('选择文件'),
              ),
            ],
          ),
          if (uploadItems.isNotEmpty) ...<Widget>[
            const SizedBox(height: 18),
            ...uploadItems.map(
              (_UploadQueueItem item) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _UploadProgressTile(item: item),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _UploadProgressTile extends StatelessWidget {
  const _UploadProgressTile({required this.item});

  final _UploadQueueItem item;

  @override
  Widget build(BuildContext context) {
    final bool isUploading = item.status == _UploadQueueStatus.uploading;
    final bool isPending = item.status == _UploadQueueStatus.pending;
    final bool isFailed = item.status == _UploadQueueStatus.failed;
    final bool isCompleted = item.status == _UploadQueueStatus.completed;

    final Color accentColor = isFailed
        ? const Color(0xFFFCA5A5)
        : isCompleted
            ? const Color(0xFF86EFAC)
            : Colors.white.withValues(alpha: 0.22);

    final String statusText;
    if (isUploading) {
      statusText = '上传中 ${_formatProgress(item.progress)}';
    } else if (isPending) {
      statusText = '排队等待上传';
    } else if (isCompleted) {
      statusText = '上传完成';
    } else {
      statusText =
          item.errorMessage?.isNotEmpty == true ? item.errorMessage! : '上传失败';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  item.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                item.source == _UploadSource.dragDrop ? '拖拽' : '选择',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.88),
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: isPending ? 0 : item.progress,
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.18),
              valueColor: AlwaysStoppedAnimation<Color>(
                isFailed ? const Color(0xFFDC2626) : Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            statusText,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: isFailed ? const Color(0xFFFFE2E2) : Colors.white,
                  fontWeight: FontWeight.w500,
                ),
          ),
          if (isCompleted)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(
                width: 72,
                height: 4,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _formatProgress(double progress) {
    return '${(progress * 100).toStringAsFixed(0)}%';
  }
}

class _UploadInfoChip extends StatelessWidget {
  const _UploadInfoChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      width: 160,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _CloudFileTile extends StatelessWidget {
  const _CloudFileTile({
    required this.file,
    required this.busy,
    required this.progress,
    required this.onDownload,
    required this.onDelete,
  });

  final CloudFile file;
  final bool busy;
  final double? progress;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _FileIconBox(
                icon: _fileIconForMimeType(file.mimeType),
                color: theme.colorScheme.primary,
                background: theme.colorScheme.primary.withValues(alpha: 0.10),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      file.originalName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_formatFileSize(file.size)}  ·  ${_formatMimeTypeLabel(file.mimeType, file.originalName)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatCloudTimestamp(
                        label: '上传时间',
                        time: file.createdAt,
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (busy)
                SizedBox(
                  width: 78,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        progress == null
                            ? '处理中'
                            : '${(progress! * 100).toStringAsFixed(0)}%',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    IconButton.filledTonal(
                      tooltip: '下载',
                      onPressed: onDownload,
                      icon: const Icon(Icons.download_rounded),
                    ),
                    IconButton.filledTonal(
                      tooltip: '移入回收站',
                      onPressed: onDelete,
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFFFFE8D9),
                        foregroundColor: const Color(0xFFB54708),
                      ),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
            ],
          ),
          if (busy) ...<Widget>[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: progress == null || progress == 0 ? null : progress,
                minHeight: 8,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TrashFileTile extends StatelessWidget {
  const _TrashFileTile({
    required this.file,
    required this.busy,
    required this.onRestore,
    required this.onDelete,
  });

  final CloudFile file;
  final bool busy;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime? deletedAt = file.deletedAt;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBF5),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF2D3A5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _FileIconBox(
            icon: Icons.delete_sweep_outlined,
            color: Color(0xFFB54708),
            background: Color(0xFFFFEDD5),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  file.originalName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_formatFileSize(file.size)}  ·  ${_formatMimeTypeLabel(file.mimeType, file.originalName)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  deletedAt == null
                      ? '已移入回收站'
                      : _formatCloudTimestamp(label: '删除时间', time: deletedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                )
              : Wrap(
                  spacing: 8,
                  children: <Widget>[
                    IconButton.filledTonal(
                      tooltip: '恢复',
                      onPressed: onRestore,
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFFDFF7E2),
                        foregroundColor: const Color(0xFF166534),
                      ),
                      icon: const Icon(Icons.restore_rounded),
                    ),
                    IconButton.filled(
                      tooltip: '彻底删除',
                      onPressed: onDelete,
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFFB42318),
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.delete_forever_rounded),
                    ),
                  ],
                ),
        ],
      ),
    );
  }
}

class _FileIconBox extends StatelessWidget {
  const _FileIconBox({
    required this.icon,
    required this.color,
    required this.background,
  });

  final IconData icon;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: color),
    );
  }
}

class _StorageLimitsPanel extends StatelessWidget {
  const _StorageLimitsPanel({required this.limits});

  final FileStorageLimits limits;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 120,
              height: 120,
              child: CustomPaint(
                painter: _StoragePieChartPainter(
                  usedRatio: limits.usedRatio,
                  usedColor: const Color(0xFF0F6CBD),
                  remainingColor: const Color(0xFFDCEBFF),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        '${(limits.usedRatio * 100).toStringAsFixed(0)}%',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      Text(
                        '已使用',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                children: <Widget>[
                  _MetricChip(
                    label: '已用空间',
                    value: _formatFileSize(limits.currentUsageBytes),
                    color: const Color(0xFF0F6CBD),
                  ),
                  const SizedBox(height: 10),
                  _MetricChip(
                    label: '剩余空间',
                    value: _formatFileSize(limits.remainingBytes),
                    color: const Color(0xFF16A34A),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: <Widget>[
            Expanded(
              child: _StatTile(
                label: '总容量',
                value: _formatFileSize(limits.totalUploadsLimitBytes),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatTile(
                label: '单文件上限',
                value: _formatFileSize(limits.singleFileLimitBytes),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatTile(
                label: '当前限速',
                value:
                    '${_formatFileSize(limits.transferRateLimitBytesPerSecond)}/s',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: color,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _StoragePieChartPainter extends CustomPainter {
  const _StoragePieChartPainter({
    required this.usedRatio,
    required this.usedColor,
    required this.remainingColor,
  });

  final double usedRatio;
  final Color usedColor;
  final Color remainingColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double strokeWidth = 18;
    final double radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    final Paint basePaint = Paint()
      ..color = remainingColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final Paint usedPaint = Paint()
      ..color = usedColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, -math.pi / 2, math.pi * 2, false, basePaint);
    final double clampedRatio = usedRatio.clamp(0, 1).toDouble();
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * clampedRatio,
      false,
      usedPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _StoragePieChartPainter oldDelegate) {
    return oldDelegate.usedRatio != usedRatio ||
        oldDelegate.usedColor != usedColor ||
        oldDelegate.remainingColor != remainingColor;
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: <Widget>[
          Icon(icon, size: 36, color: theme.colorScheme.primary),
          const SizedBox(height: 14),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(message),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重新加载'),
        ),
      ],
    );
  }
}

IconData _fileIconForMimeType(String mimeType) {
  if (mimeType.startsWith('image/')) {
    return Icons.image_outlined;
  }
  if (mimeType.startsWith('video/')) {
    return Icons.movie_outlined;
  }
  if (mimeType.startsWith('audio/')) {
    return Icons.audiotrack_outlined;
  }
  if (mimeType.contains('pdf')) {
    return Icons.picture_as_pdf_outlined;
  }
  if (mimeType.contains('zip') || mimeType.contains('compressed')) {
    return Icons.archive_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

bool get _hideCloudFileTimeLabelsOnApp => Platform.isAndroid || Platform.isIOS;

String _formatCloudTimestamp({
  required String label,
  required DateTime? time,
}) {
  if (time == null) {
    return '';
  }

  final String formatted =
      DateFormat('yyyy-MM-dd HH:mm').format(time.toLocal());
  if (_hideCloudFileTimeLabelsOnApp) {
    return formatted;
  }
  return '$label $formatted';
}

String _formatMimeTypeLabel(String mimeType, String fileName) {
  final String normalizedMimeType = mimeType.trim().toLowerCase();
  if (normalizedMimeType.isEmpty ||
      normalizedMimeType == 'application/octet-stream') {
    final String extension = _fileExtension(fileName);
    return extension.isEmpty ? '未知文件' : '${extension.toUpperCase()} 文件';
  }
  if (normalizedMimeType.startsWith('image/')) {
    return '图片';
  }
  if (normalizedMimeType.startsWith('video/')) {
    return '视频';
  }
  if (normalizedMimeType.startsWith('audio/')) {
    return '音频';
  }
  if (normalizedMimeType == 'application/pdf') {
    return 'PDF 文档';
  }
  if (normalizedMimeType.contains('word')) {
    return 'Word 文档';
  }
  if (normalizedMimeType.contains('excel') ||
      normalizedMimeType.contains('spreadsheet')) {
    return 'Excel 表格';
  }
  if (normalizedMimeType.contains('powerpoint') ||
      normalizedMimeType.contains('presentation')) {
    return 'PPT 演示文稿';
  }
  if (normalizedMimeType.startsWith('text/')) {
    return '文本';
  }
  if (normalizedMimeType.contains('json')) {
    return 'JSON 文件';
  }
  if (normalizedMimeType.contains('zip') ||
      normalizedMimeType.contains('compressed') ||
      normalizedMimeType.contains('rar') ||
      normalizedMimeType.contains('7z')) {
    return '压缩包';
  }

  final int separatorIndex = normalizedMimeType.indexOf('/');
  if (separatorIndex >= 0 && separatorIndex < normalizedMimeType.length - 1) {
    return normalizedMimeType.substring(separatorIndex + 1).toUpperCase();
  }
  return normalizedMimeType.toUpperCase();
}

String _fileExtension(String fileName) {
  final int dotIndex = fileName.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex >= fileName.length - 1) {
    return '';
  }
  return fileName.substring(dotIndex + 1).trim();
}

String _formatFileSize(int bytes) {
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  int unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }

  final String display = value >= 100 || unitIndex == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$display ${units[unitIndex]}';
}
