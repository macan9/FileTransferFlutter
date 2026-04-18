import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/error/app_exception.dart';
import 'package:file_transfer_flutter/core/models/cloud_file_list_response.dart';
import 'package:file_transfer_flutter/core/models/cloud_item.dart';
import 'package:file_transfer_flutter/core/models/file_storage_limits.dart';
import 'package:file_transfer_flutter/core/models/trash_item_operation_result.dart';
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
  late Future<CloudFileListResponse> _filesFuture;
  late Future<CloudFileListResponse> _trashFuture;
  late Future<FileStorageLimits> _limitsFuture;

  final ScrollController _pageScrollController = ScrollController();
  String _currentPath = '';
  String _currentTrashPath = '';
  bool _draggingUpload = false;
  bool _processingUploadQueue = false;
  bool _clearingTrash = false;

  final List<_UploadQueueItem> _uploadQueue = <_UploadQueueItem>[];
  final Set<int> _busyItemIds = <int>{};
  final Set<int> _busyTrashItemIds = <int>{};
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
  void dispose() {
    _pageScrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _filesFuture = _repository.fetchFiles(path: _currentPath);
    _trashFuture = _loadTrashFiles(_currentTrashPath);
    _limitsFuture = _repository.fetchLimits();
  }

  void _reloadFiles() {
    setState(() {
      _filesFuture = _repository.fetchFiles(path: _currentPath);
    });
  }

  void _reloadTrash() {
    setState(() {
      _trashFuture = _loadTrashFiles(_currentTrashPath);
    });
  }

  void _reloadLimits() {
    setState(() {
      _limitsFuture = _repository.fetchLimits();
    });
  }

  void _reloadPageData() {
    _reloadFiles();
    _reloadTrash();
    _reloadLimits();
  }

  Future<void> _refreshPage() async {
    _reloadPageData();
    try {
      await Future.wait(<Future<Object?>>[
        _filesFuture,
        _trashFuture,
        _limitsFuture,
      ]);
    } catch (_) {
      // Keep pull-to-refresh responsive when the backend is unavailable.
    }
  }

  Future<void> _navigateToPath(String path) async {
    final String normalizedPath = _normalizePath(path);
    setState(() {
      _currentPath = normalizedPath;
      _filesFuture = _repository.fetchFiles(path: normalizedPath);
    });
    try {
      await _filesFuture;
    } catch (_) {
      // Error handling stays inside the FutureBuilder.
    }
  }

  Future<void> _goToParent(String? parentPath) async {
    await _navigateToPath(parentPath ?? '');
  }

  Future<void> _navigateTrashToPath(String path) async {
    final String normalizedPath = _normalizePath(path);
    final double preservedOffset =
        _pageScrollController.hasClients ? _pageScrollController.offset : 0;
    setState(() {
      _currentTrashPath = normalizedPath;
      _trashFuture = _loadTrashFiles(normalizedPath);
    });
    try {
      await _trashFuture;
      _restorePageScrollOffset(preservedOffset);
    } catch (_) {
      // Error handling stays inside the FutureBuilder.
    }
  }

  Future<void> _goToTrashParent(String? parentPath) async {
    await _navigateTrashToPath(parentPath ?? '');
  }

  Future<CloudFileListResponse> _loadTrashFiles(
    String path,
  ) async {
    final String normalizedPath = _normalizePath(path);
    try {
      return await _repository.fetchTrashFiles(path: normalizedPath);
    } on AppException catch (error) {
      if (normalizedPath.isNotEmpty && _isTrashPathMissingError(error)) {
        final CloudFileListResponse rootResponse =
            await _repository.fetchTrashFiles();
        if (mounted) {
          setState(() {
            _currentTrashPath = '';
          });
        } else {
          _currentTrashPath = '';
        }
        return rootResponse;
      }
      rethrow;
    }
  }

  Future<void> _pickAndUploadFile() async {
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

    await _enqueueUploads(
      filePaths
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
          .toList(),
    );
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
            path: _currentPath,
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
        _showMessage(
          successCount == 1 ? '上传完成' : '已完成 $successCount 个文件上传',
        );
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

  Future<void> _downloadFile(CloudItem item) async {
    _setItemBusy(item.id, true);
    try {
      final String path = await _repository.downloadFile(
        item,
        onProgress: (double progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _downloadProgress[item.id] = progress;
          });
        },
      );
      if (!mounted) {
        return;
      }
      _showMessage('已下载到 $path');
    } on AppException catch (error) {
      if (!mounted) {
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
        _setItemBusy(item.id, false);
      }
    }
  }

  Future<void> _moveItemToTrash(CloudItem item) async {
    final bool confirmed = await _showConfirmationDialog(
          title: item.isFolder ? '删除文件夹' : '移入回收站',
          content: item.isFolder
              ? '确认将“${item.displayName}”及其内容移入回收站吗？'
              : '确认将“${item.displayName}”移入回收站吗？',
          confirmLabel: item.isFolder ? '删除文件夹' : '移入回收站',
        ) ??
        false;

    if (!confirmed) {
      return;
    }

    _setItemBusy(item.id, true);
    try {
      if (item.isFolder) {
        await _repository.deleteFolder(item.path ?? '');
      } else {
        await _repository.deleteFile(item.id);
      }
      _reloadPageData();
      if (!mounted) {
        return;
      }
      _showMessage(item.isFolder ? '文件夹已移入回收站' : '文件已移入回收站');
    } on AppException catch (error) {
      if (!mounted) {
        return;
      }
      _showAppException(error);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('删除失败: $error', isError: true);
    } finally {
      if (mounted) {
        _setItemBusy(item.id, false);
      }
    }
  }

  Future<void> _createFolder() async {
    final String? folderName = await _showTextInputDialog(
      title: '新建文件夹',
      label: '文件夹名称',
      hintText: '例如：images',
    );
    if (folderName == null) {
      return;
    }

    try {
      await _repository.createFolder(path: _currentPath, name: folderName);
      _reloadFiles();
      if (!mounted) {
        return;
      }
      _showMessage('文件夹已创建');
    } on AppException catch (error) {
      if (!mounted) {
        return;
      }
      _showAppException(error);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('新建文件夹失败: $error', isError: true);
    }
  }

  Future<void> _moveItem(
    CloudItem item, {
    required String targetPath,
    String? newName,
  }) async {
    final String normalizedTarget = _normalizePath(targetPath);
    if (item.isFolder) {
      final String sourcePath = item.path ?? '';
      if (normalizedTarget == sourcePath ||
          (sourcePath.isNotEmpty &&
              normalizedTarget.startsWith('$sourcePath/'))) {
        _showMessage('不能把文件夹移动到它自己或子目录中', isError: true);
        return;
      }
    } else {
      if (normalizedTarget == (item.directoryPath ?? '')) {
        _showMessage('文件已经在当前目录中');
        return;
      }
    }

    _setItemBusy(item.id, true);
    try {
      if (item.isFolder) {
        await _repository.moveFolder(
          sourcePath: item.path ?? '',
          targetPath: normalizedTarget,
          name: newName,
        );
      } else {
        await _repository.moveFile(item.id, targetPath: normalizedTarget);
      }
      _reloadFiles();
      if (!mounted) {
        return;
      }
      _showMessage(item.isFolder ? '文件夹已移动' : '文件已移动');
    } on AppException catch (error) {
      if (!mounted) {
        return;
      }
      _showAppException(error);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('移动失败: $error', isError: true);
    } finally {
      if (mounted) {
        _setItemBusy(item.id, false);
      }
    }
  }

  Future<void> _restoreTrashItem(CloudItem item) async {
    if (item.isFolder) {
      final bool confirmed = await _showConfirmationDialog(
            title: '恢复文件夹',
            content: '确认恢复该文件夹及其内部所有内容吗？',
            confirmLabel: '恢复整个文件夹',
          ) ??
          false;
      if (!confirmed) {
        return;
      }
    }

    _setTrashItemBusy(item.id, true);
    try {
      final TrashItemOperationResult result =
          await _repository.restoreTrashItem(item.id);
      _reloadPageData();
      if (!mounted) {
        return;
      }
      _showMessage(_buildRestoreTrashSuccessMessage(item, result));
    } on AppException catch (error) {
      if (!mounted) {
        return;
      }
      _showAppException(error);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('恢复失败: $error', isError: true);
    } finally {
      if (mounted) {
        _setTrashItemBusy(item.id, false);
      }
    }
  }

  Future<void> _deleteTrashItemPermanently(CloudItem item) async {
    final bool confirmed = await _showConfirmationDialog(
          title: '彻底删除',
          content: item.isFolder
              ? '确认彻底删除该文件夹及其内部所有内容吗？此操作不可撤销。'
              : '确认彻底删除“${item.displayName}”吗？此操作不可撤销。',
          confirmLabel: item.isFolder ? '彻底删除该文件夹及其内部所有内容' : '彻底删除',
          destructive: true,
        ) ??
        false;
    if (!confirmed) {
      return;
    }

    _setTrashItemBusy(item.id, true);
    try {
      final TrashItemOperationResult result =
          await _repository.deleteTrashFilePermanently(item.id);
      _reloadPageData();
      if (!mounted) {
        return;
      }
      _showMessage(_buildDeleteTrashSuccessMessage(item, result));
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
        _setTrashItemBusy(item.id, false);
      }
    }
  }

  Future<void> _clearTrash(CloudFileListResponse response) async {
    if (response.items.isEmpty || _clearingTrash) {
      return;
    }

    final bool confirmed = await _showConfirmationDialog(
          title: '清空回收站',
          content: '确认清空回收站吗？共 ${response.items.length} 个条目将被彻底删除，此操作不可撤销。',
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

  Future<String?> _showTextInputDialog({
    required String title,
    required String label,
    String? initialValue,
    String? hintText,
  }) async {
    final TextEditingController controller =
        TextEditingController(text: initialValue ?? '');
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: label,
              hintText: hintText,
            ),
            onSubmitted: (_) =>
                Navigator.of(context).pop(controller.text.trim()),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    controller.dispose();

    final String trimmed = result?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  void _setItemBusy(int itemId, bool isBusy) {
    setState(() {
      if (isBusy) {
        _busyItemIds.add(itemId);
      } else {
        _busyItemIds.remove(itemId);
        _downloadProgress.remove(itemId);
      }
    });
  }

  void _setTrashItemBusy(int itemId, bool isBusy) {
    setState(() {
      if (isBusy) {
        _busyTrashItemIds.add(itemId);
      } else {
        _busyTrashItemIds.remove(itemId);
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
    final ThemeData theme = Theme.of(context);
    final SnackBar snackBar = SnackBar(
      content: Text(message),
      backgroundColor: isError ? theme.colorScheme.error : null,
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      closeIconColor: isError ? theme.colorScheme.onError : null,
    );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(snackBar);
  }

  void _showAppException(AppException error) {
    _showMessage(error.message, isError: true);
  }

  bool _isTrashPathMissingError(AppException error) {
    final String message = error.message;
    return message.contains('Trash folder "') || message.contains('回收站文件夹不存在');
  }

  void _restorePageScrollOffset(double offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageScrollController.hasClients) {
        return;
      }
      final ScrollPosition position = _pageScrollController.position;
      final double target = offset.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((position.pixels - target).abs() < 1) {
        return;
      }
      _pageScrollController.jumpTo(target);
    });
  }

  String _buildRestoreTrashSuccessMessage(
    CloudItem item,
    TrashItemOperationResult result,
  ) {
    if (!item.isFolder) {
      return '文件已恢复';
    }

    return '已恢复文件夹，包含 ${result.restoredFolderCount} 个文件夹、${result.restoredFileCount} 个文件';
  }

  String _buildDeleteTrashSuccessMessage(
    CloudItem item,
    TrashItemOperationResult result,
  ) {
    if (!item.isFolder) {
      return '文件已彻底删除';
    }

    return '已彻底删除文件夹，包含 ${result.deletedFolderCount} 个文件夹、${result.deletedFileCount} 个文件';
  }

  String _extractFileName(String filePath) {
    final String normalized = filePath.replaceAll('\\', '/');
    final List<String> segments = normalized.split('/');
    return segments.isEmpty ? filePath : segments.last;
  }

  String _createUploadQueueId() {
    return '${DateTime.now().microsecondsSinceEpoch}-${_uploadQueue.length}';
  }

  String _normalizePath(String value) {
    String normalized = value.trim().replaceAll('\\', '/');
    while (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
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

  List<Widget> _buildCurrentDirectoryItems(List<CloudItem> items) {
    return items.map((CloudItem item) {
      final bool isBusy = _busyItemIds.contains(item.id);
      final Widget tile = item.isFolder
          ? _FolderTile(
              item: item,
              busy: isBusy,
              isDropTargetActive: false,
              onOpen: () => _navigateToPath(item.path ?? ''),
              onDelete: () => _moveItemToTrash(item),
            )
          : _FileTile(
              item: item,
              busy: isBusy,
              progress: _downloadProgress[item.id],
              onDownload: () => _downloadFile(item),
              onDelete: () => _moveItemToTrash(item),
            );

      return _MoveTarget(
        item: item,
        currentPath: _currentPath,
        onMoveHere: (CloudItem draggedItem) async {
          await _moveItem(
            draggedItem,
            targetPath: item.isFolder ? (item.path ?? '') : _currentPath,
          );
        },
        child: _DragSource(item: item, child: tile),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final AppConfig config = ref.watch(appConfigProvider);
    final Widget content = RefreshIndicator(
      onRefresh: _refreshPage,
      child: ListView(
        controller: _pageScrollController,
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          FutureBuilder<FileStorageLimits>(
            future: _limitsFuture,
            builder: (
              BuildContext context,
              AsyncSnapshot<FileStorageLimits> snapshot,
            ) {
              return _UploadHero(
                currentPath: _currentPath,
                uploadItems: _visibleUploadItems,
                dragging: _draggingUpload,
                dragEnabled: _dragEnabled,
                limits: snapshot.data,
                onUploadPressed: _pickAndUploadFile,
              );
            },
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '文件列表',
            subtitle: '点击文件夹进入，支持文件和文件夹长按拖拽移动。',
            titleAction: FilledButton.tonalIcon(
              onPressed: _createFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('新建文件夹'),
            ),
            child: FutureBuilder<CloudFileListResponse>(
              future: _filesFuture,
              builder: (
                BuildContext context,
                AsyncSnapshot<CloudFileListResponse> snapshot,
              ) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  );
                }

                if (snapshot.hasError) {
                  return _ErrorState(
                    message: '加载文件列表失败，请确认 ${config.serverUrl} 可访问。',
                    onRetry: _reloadFiles,
                  );
                }

                final CloudFileListResponse response =
                    snapshot.data ?? const CloudFileListResponse();
                final List<CloudItem> items = response.items;
                final bool isLoading =
                    snapshot.connectionState == ConnectionState.waiting;

                return Stack(
                  children: <Widget>[
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 160),
                      opacity: isLoading ? 0.82 : 1,
                      child: Column(
                        children: <Widget>[
                          _CurrentPathBar(
                            currentPath: response.path,
                            parentPath: response.parentPath,
                            onGoRoot: () => _navigateToPath(''),
                            onGoParent: response.parentPath == null
                                ? null
                                : () => _goToParent(response.parentPath),
                            onMoveHere: (CloudItem item) async {
                              await _moveItem(item, targetPath: response.path);
                            },
                          ),
                          const SizedBox(height: 12),
                          if (items.isEmpty)
                            const _EmptyState(
                              icon: Icons.cloud_outlined,
                              title: '当前目录为空',
                              description: '可以上传文件，或在这里新建文件夹。',
                            )
                          else
                            ..._buildCurrentDirectoryItems(items),
                        ],
                      ),
                    ),
                    if (isLoading)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: const LinearProgressIndicator(minHeight: 4),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '存储空间',
            subtitle: '查看当前已用空间与剩余空间。',
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
            subtitle: '支持浏览已删除文件夹；列表展示当前层级的顶层条目。',
            titleAction: FutureBuilder<CloudFileListResponse>(
              future: _trashFuture,
              builder: (
                BuildContext context,
                AsyncSnapshot<CloudFileListResponse> snapshot,
              ) {
                final CloudFileListResponse response =
                    snapshot.data ?? const CloudFileListResponse();
                return FilledButton.tonalIcon(
                  onPressed: response.items.isEmpty || _clearingTrash
                      ? null
                      : () => _clearTrash(response),
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
            child: FutureBuilder<CloudFileListResponse>(
              future: _trashFuture,
              builder: (
                BuildContext context,
                AsyncSnapshot<CloudFileListResponse> snapshot,
              ) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  );
                }

                if (snapshot.hasError) {
                  return _ErrorState(
                    message: '加载回收站失败，请确认 GET /files/trash 可用。',
                    onRetry: _reloadTrash,
                  );
                }

                final CloudFileListResponse response =
                    snapshot.data ?? const CloudFileListResponse();
                final bool isLoading =
                    snapshot.connectionState == ConnectionState.waiting;

                return Stack(
                  children: <Widget>[
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 160),
                      opacity: isLoading ? 0.82 : 1,
                      child: Column(
                        children: <Widget>[
                          _TrashPathBar(
                            currentPath: response.path,
                            parentPath: response.parentPath,
                            onGoRoot: () => _navigateTrashToPath(''),
                            onGoParent: response.parentPath == null
                                ? null
                                : () => _goToTrashParent(response.parentPath),
                          ),
                          const SizedBox(height: 12),
                          if (response.items.isEmpty)
                            _EmptyState(
                              icon: Icons.delete_sweep_outlined,
                              title:
                                  response.path.isEmpty ? '回收站为空' : '当前回收站目录为空',
                              description: response.path.isEmpty
                                  ? '删除的文件和文件夹会出现在这里。'
                                  : '这个已删除文件夹下当前层级没有直属内容。',
                            )
                          else
                            ...response.items.map((CloudItem item) {
                              return _TrashItemTile(
                                item: item,
                                busy: _busyTrashItemIds.contains(item.id),
                                onOpen: item.isFolder
                                    ? () =>
                                        _navigateTrashToPath(item.path ?? '')
                                    : null,
                                onRestore: () => _restoreTrashItem(item),
                                onDelete: () =>
                                    _deleteTrashItemPermanently(item),
                              );
                            }),
                        ],
                      ),
                    ),
                    if (isLoading)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: const LinearProgressIndicator(minHeight: 4),
                        ),
                      ),
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
                  _draggingUpload = true;
                });
              },
              onDragExited: (_) {
                setState(() {
                  _draggingUpload = false;
                });
              },
              onDragDone: (DropDoneDetails details) async {
                setState(() {
                  _draggingUpload = false;
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
          if (_draggingUpload && _dragEnabled)
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
                      Text('将文件拖到窗口内会上传到当前目录'),
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
    required this.currentPath,
    required this.uploadItems,
    required this.dragging,
    required this.dragEnabled,
    required this.limits,
    required this.onUploadPressed,
  });

  final String currentPath;
  final List<_UploadQueueItem> uploadItems;
  final bool dragging;
  final bool dragEnabled;
  final FileStorageLimits? limits;
  final VoidCallback onUploadPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hideSecondaryInfo = Platform.isAndroid || Platform.isIOS;
    final String singleFileLimit = limits == null
        ? '单文件上限'
        : '单文件上限 ${_formatFileSize(limits!.singleFileLimitBytes)}';
    final String transferRate = limits == null
        ? '当前限速'
        : '当前限速 ${_formatFileSize(limits!.transferRateLimitBytesPerSecond)}/s';
    final String totalCapacity = limits == null
        ? '总容量'
        : '总容量 ${_formatFileSize(limits!.totalUploadsLimitBytes)}';
    final String dragSupport =
        dragging ? '正在接收拖拽文件...' : (dragEnabled ? '支持拖拽上传' : '支持选择上传');

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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  '上传云文件',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: onUploadPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF0F6CBD),
                ),
                icon: const Icon(Icons.upload_file_rounded),
                label: const Text('选择文件'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            currentPath.isEmpty ? '当前目录：根目录' : '当前目录：/$currentPath',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.88),
            ),
          ),
          const SizedBox(height: 16),
          _UploadInfoRow(
            leftLabel: singleFileLimit,
            rightLabel: transferRate,
          ),
          if (!hideSecondaryInfo) ...<Widget>[
            const SizedBox(height: 12),
            _UploadInfoRow(
              leftLabel: totalCapacity,
              rightLabel: dragSupport,
            ),
          ],
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
    final String statusText = isUploading
        ? '上传中 ${(item.progress * 100).toStringAsFixed(0)}%'
        : isPending
            ? '排队等待上传'
            : isFailed
                ? (item.errorMessage?.isNotEmpty == true
                    ? item.errorMessage!
                    : '上传失败')
                : '上传完成';

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
        ],
      ),
    );
  }
}

class _UploadInfoChip extends StatelessWidget {
  const _UploadInfoChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _UploadInfoRow extends StatelessWidget {
  const _UploadInfoRow({
    required this.leftLabel,
    required this.rightLabel,
  });

  final String leftLabel;
  final String rightLabel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double itemWidth = math.min(
          (constraints.maxWidth - 12) / 2,
          176,
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
                width: itemWidth, child: _UploadInfoChip(label: leftLabel)),
            const SizedBox(width: 12),
            SizedBox(
              width: itemWidth,
              child: _UploadInfoChip(label: rightLabel),
            ),
          ],
        );
      },
    );
  }
}

class _CurrentPathBar extends StatelessWidget {
  const _CurrentPathBar({
    required this.currentPath,
    required this.parentPath,
    required this.onGoRoot,
    required this.onGoParent,
    required this.onMoveHere,
  });

  final String currentPath;
  final String? parentPath;
  final VoidCallback onGoRoot;
  final VoidCallback? onGoParent;
  final Future<void> Function(CloudItem item) onMoveHere;

  @override
  Widget build(BuildContext context) {
    return DragTarget<CloudItem>(
      onWillAcceptWithDetails: (DragTargetDetails<CloudItem> details) {
        final CloudItem data = details.data;
        if (data.isFolder && data.path == currentPath) {
          return false;
        }
        return true;
      },
      onAcceptWithDetails: (DragTargetDetails<CloudItem> details) async {
        await onMoveHere(details.data);
      },
      builder: (
        BuildContext context,
        List<CloudItem?> candidateData,
        List<dynamic> rejectedData,
      ) {
        final bool isActive = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isActive
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
                : Theme.of(context).colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isActive
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: onGoRoot,
                icon: const Icon(Icons.home_outlined),
                label: const Text('根目录'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  currentPath.isEmpty ? '/' : '/$currentPath',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: onGoParent,
                tooltip: '返回上一级',
                iconSize: 20,
                style: IconButton.styleFrom(
                  padding: const EdgeInsets.all(12),
                  minimumSize: const Size(44, 44),
                  shape: const CircleBorder(),
                  backgroundColor:
                      Theme.of(context).colorScheme.primary.withValues(
                            alpha: 0.10,
                          ),
                  foregroundColor: Theme.of(context).colorScheme.primary,
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.primary.withValues(
                          alpha: 0.18,
                        ),
                  ),
                ),
                icon:
                    const Icon(Icons.subdirectory_arrow_left_rounded, size: 20),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TrashPathBar extends StatelessWidget {
  const _TrashPathBar({
    required this.currentPath,
    required this.parentPath,
    required this.onGoRoot,
    required this.onGoParent,
  });

  final String currentPath;
  final String? parentPath;
  final VoidCallback onGoRoot;
  final VoidCallback? onGoParent;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          FilledButton.tonalIcon(
            onPressed: onGoRoot,
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text('回收站'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              currentPath.isEmpty ? '/' : '/$currentPath',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            onPressed: onGoParent,
            tooltip: '返回上一级',
            iconSize: 20,
            style: IconButton.styleFrom(
              padding: const EdgeInsets.all(12),
              minimumSize: const Size(44, 44),
              shape: const CircleBorder(),
            ),
            icon: const Icon(Icons.subdirectory_arrow_left_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

class _DragSource extends StatefulWidget {
  const _DragSource({
    required this.item,
    required this.child,
  });

  final CloudItem item;
  final Widget child;

  @override
  State<_DragSource> createState() => _DragSourceState();
}

class _DragSourceState extends State<_DragSource> {
  bool _pressing = false;
  bool _dragging = false;

  void _setPressing(bool value) {
    if (!mounted || _dragging || _pressing == value) {
      return;
    }
    setState(() {
      _pressing = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool showLift = _pressing && !_dragging;

    return LongPressDraggable<CloudItem>(
      data: widget.item,
      delay: const Duration(milliseconds: 800),
      onDragStarted: () {
        if (!mounted) {
          return;
        }
        setState(() {
          _dragging = true;
          _pressing = false;
        });
      },
      onDragEnd: (_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _dragging = false;
          _pressing = false;
        });
      },
      feedback: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 320,
            maxWidth: 420,
          ),
          child: Opacity(
            opacity: 0.94,
            child: widget.item.isFolder
                ? _FolderTile(
                    item: widget.item,
                    busy: false,
                    isDropTargetActive: false,
                    onOpen: () {},
                    onDelete: () {},
                    showActions: false,
                    compactMetaLayout: true,
                  )
                : _FileTile(
                    item: widget.item,
                    busy: false,
                    progress: null,
                    onDownload: () {},
                    onDelete: () {},
                    showActions: false,
                    compactMetaLayout: true,
                  ),
          ),
        ),
      ),
      childWhenDragging: _DraggingPlaceholder(item: widget.item),
      child: Listener(
        onPointerDown: (_) => _setPressing(true),
        onPointerUp: (_) => _setPressing(false),
        onPointerCancel: (_) => _setPressing(false),
        child: Stack(
          children: <Widget>[
            AnimatedScale(
              scale: showLift ? 0.985 : 1,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: showLift
                      ? <BoxShadow>[
                          BoxShadow(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.16),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : null,
                ),
                child: widget.child,
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 12,
              child: IgnorePointer(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0,
                      end: showLift ? 1 : 0,
                    ),
                    duration: Duration(
                      milliseconds: showLift ? 800 : 180,
                    ),
                    curve: showLift ? Curves.easeOutCubic : Curves.easeInCubic,
                    builder: (
                      BuildContext context,
                      double value,
                      Widget? child,
                    ) {
                      return Align(
                        alignment: Alignment.center,
                        child: FractionallySizedBox(
                          widthFactor: value,
                          child: child,
                        ),
                      );
                    },
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: <Color>[
                            Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.30),
                            Theme.of(context).colorScheme.primary,
                            Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.30),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DraggingPlaceholder extends StatelessWidget {
  const _DraggingPlaceholder({required this.item});

  final CloudItem item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.primary),
      ),
      child: Column(
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _FileIconBox(
                icon: item.isFolder
                    ? Icons.folder_open_rounded
                    : _fileIconForMimeType(item.mimeType),
                color: item.isFolder
                    ? const Color(0xFFC67F00)
                    : theme.colorScheme.primary,
                background: item.isFolder
                    ? const Color(0xFFFFF2CC)
                    : theme.colorScheme.primary.withValues(alpha: 0.10),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ItemTextBlock(
                  title: item.displayName,
                  subtitle: item.isFolder
                      ? (item.path?.isEmpty == true
                          ? '/'
                          : '/${item.path ?? ''}')
                      : '${_formatFileSize(item.size)}  ·  ${_formatMimeTypeLabel(item.mimeType, item.displayName)}',
                  meta: '拖拽中...',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: const LinearProgressIndicator(minHeight: 8),
          ),
        ],
      ),
    );
  }
}

class _MoveTarget extends StatelessWidget {
  const _MoveTarget({
    required this.item,
    required this.currentPath,
    required this.onMoveHere,
    required this.child,
  });

  final CloudItem item;
  final String currentPath;
  final Future<void> Function(CloudItem item) onMoveHere;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!item.isFolder) {
      return child;
    }

    return DragTarget<CloudItem>(
      onWillAcceptWithDetails: (DragTargetDetails<CloudItem> details) {
        final CloudItem dragged = details.data;
        final String targetPath = item.path ?? '';
        if (dragged.id == item.id) {
          return false;
        }
        if (!dragged.isFolder) {
          return dragged.directoryPath != targetPath;
        }
        final String sourcePath = dragged.path ?? '';
        return targetPath != sourcePath &&
            !targetPath.startsWith(sourcePath.isEmpty ? '/' : '$sourcePath/');
      },
      onAcceptWithDetails: (DragTargetDetails<CloudItem> details) async {
        await onMoveHere(details.data);
      },
      builder: (
        BuildContext context,
        List<CloudItem?> candidateData,
        List<dynamic> rejectedData,
      ) {
        final bool isActive = candidateData.isNotEmpty;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: isActive
                ? <BoxShadow>[
                    BoxShadow(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.18),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: child,
        );
      },
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.item,
    required this.busy,
    required this.isDropTargetActive,
    required this.onOpen,
    required this.onDelete,
    this.showActions = true,
    this.compactMetaLayout = false,
  });

  final CloudItem item;
  final bool busy;
  final bool isDropTargetActive;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final bool showActions;
  final bool compactMetaLayout;

  @override
  Widget build(BuildContext context) {
    return _BaseItemTile(
      icon: Icons.folder_open_rounded,
      iconColor: const Color(0xFFC67F00),
      iconBackground: const Color(0xFFFFF2CC),
      title: item.displayName,
      subtitle: item.path?.isEmpty == true ? '/' : '/${item.path ?? ''}',
      meta: _formatCloudTimestamp(label: '创建时间', time: item.createdAt),
      busy: busy,
      highlight: isDropTargetActive,
      compactMetaLayout: compactMetaLayout,
      onTap: onOpen,
      actions: showActions
          ? <Widget>[
              IconButton.filledTonal(
                tooltip: '打开文件夹',
                onPressed: onOpen,
                icon: const Icon(Icons.folder_open_rounded),
              ),
              IconButton.filledTonal(
                tooltip: '删除文件夹',
                onPressed: onDelete,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFFEE4E2),
                  foregroundColor: const Color(0xFFB42318),
                ),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ]
          : const <Widget>[],
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.item,
    required this.busy,
    required this.progress,
    required this.onDownload,
    required this.onDelete,
    this.showActions = true,
    this.compactMetaLayout = false,
  });

  final CloudItem item;
  final bool busy;
  final double? progress;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final bool showActions;
  final bool compactMetaLayout;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return _BaseItemTile(
      icon: _fileIconForMimeType(item.mimeType),
      iconColor: theme.colorScheme.primary,
      iconBackground: theme.colorScheme.primary.withValues(alpha: 0.10),
      title: item.displayName,
      subtitle:
          '${_formatFileSize(item.size)}  ·  ${_formatMimeTypeLabel(item.mimeType, item.displayName)}',
      meta: _formatCloudTimestamp(label: '上传时间', time: item.createdAt),
      busy: busy,
      progress: progress,
      compactMetaLayout: compactMetaLayout,
      actions: showActions
          ? <Widget>[
              IconButton.filledTonal(
                tooltip: '下载',
                onPressed: onDownload,
                icon: const Icon(Icons.download_rounded),
              ),
              IconButton.filledTonal(
                tooltip: '移入回收站',
                onPressed: onDelete,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFFFF4CC),
                  foregroundColor: const Color(0xFFB54708),
                ),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ]
          : const <Widget>[],
    );
  }
}

class _TrashItemTile extends StatelessWidget {
  const _TrashItemTile({
    required this.item,
    required this.busy,
    required this.onOpen,
    required this.onRestore,
    required this.onDelete,
  });

  final CloudItem item;
  final bool busy;
  final VoidCallback? onOpen;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final String subtitle = item.isFolder
        ? '文件夹  ·  /${item.path ?? ''}'
        : '${_formatFileSize(item.size)}  ·  ${_formatMimeTypeLabel(item.mimeType, item.displayName)}';

    return _BaseItemTile(
      icon: item.isFolder
          ? Icons.folder_delete_outlined
          : Icons.delete_sweep_outlined,
      iconColor: const Color(0xFFB54708),
      iconBackground: const Color(0xFFFFEDD5),
      title: item.displayName,
      subtitle: subtitle,
      meta: item.deletedAt == null
          ? '已移入回收站'
          : _formatCloudTimestamp(label: '删除时间', time: item.deletedAt),
      busy: busy,
      onTap: onOpen,
      backgroundColor: const Color(0xFFFFFBF5),
      borderColor: const Color(0xFFF2D3A5),
      actions: <Widget>[
        if (item.isFolder)
          IconButton.filledTonal(
            tooltip: '打开已删除文件夹',
            onPressed: onOpen,
            icon: const Icon(Icons.folder_open_rounded),
          ),
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
    );
  }
}

class _BaseItemTile extends StatelessWidget {
  const _BaseItemTile({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.title,
    required this.subtitle,
    required this.meta,
    required this.busy,
    required this.actions,
    this.progress,
    this.highlight = false,
    this.compactMetaLayout = false,
    this.onTap,
    this.backgroundColor,
    this.borderColor,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String title;
  final String subtitle;
  final String meta;
  final bool busy;
  final List<Widget> actions;
  final double? progress;
  final bool highlight;
  final bool compactMetaLayout;
  final VoidCallback? onTap;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: backgroundColor ?? theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: highlight
                  ? theme.colorScheme.primary
                  : (borderColor ?? theme.colorScheme.outlineVariant),
            ),
          ),
          child: compactMetaLayout
              ? _buildCompactContent(theme)
              : _buildDefaultContent(theme),
        ),
      ),
    );
  }

  Widget _buildDefaultContent(ThemeData theme) {
    return Column(
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            _FileIconBox(
              icon: icon,
              color: iconColor,
              background: iconBackground,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ItemTextBlock(
                title: title,
                subtitle: subtitle,
                meta: meta,
              ),
            ),
            const SizedBox(width: 12),
            if (busy)
              SizedBox(
                width: 78,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                    if (progress != null) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        '${(progress! * 100).toStringAsFixed(0)}%',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              )
            else if (actions.isNotEmpty)
              SizedBox(
                width: 152,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  runAlignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ),
          ],
        ),
        if (busy && progress != null) ...<Widget>[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: progress == 0 ? null : progress,
              minHeight: 8,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCompactContent(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _FileIconBox(
          icon: icon,
          color: iconColor,
          background: iconBackground,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ItemTextBlock(
            title: title,
            subtitle: subtitle,
            meta: meta,
          ),
        ),
      ],
    );
  }
}

class _ItemTextBlock extends StatelessWidget {
  const _ItemTextBlock({
    required this.title,
    required this.subtitle,
    required this.meta,
  });

  final String title;
  final String subtitle;
  final String meta;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (meta.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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
    const double strokeWidth = 18;
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
