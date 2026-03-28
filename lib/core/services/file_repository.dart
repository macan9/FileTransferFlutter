import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:file_transfer_flutter/core/error/app_exception.dart';
import 'package:file_transfer_flutter/core/models/cloud_file.dart';
import 'package:file_transfer_flutter/core/models/file_storage_limits.dart';
import 'package:http/http.dart' as http;

typedef TransferProgressCallback = void Function(double progress);

abstract interface class FileRepository {
  Future<List<String>> fetchRecentFiles();
  Future<List<CloudFile>> fetchFiles();
  Future<List<CloudFile>> fetchTrashFiles();
  Future<FileStorageLimits> fetchLimits();
  Future<CloudFile> uploadFile({
    TransferProgressCallback? onProgress,
  });
  Future<CloudFile> uploadFileFromPath(
    String filePath, {
    TransferProgressCallback? onProgress,
  });
  Future<void> deleteFile(int id);
  Future<void> restoreTrashFile(int id);
  Future<void> deleteTrashFilePermanently(int id);
  Future<void> clearTrash();
  Future<String> downloadFile(
    CloudFile file, {
    TransferProgressCallback? onProgress,
  });
}

class HttpFileRepository implements FileRepository {
  HttpFileRepository({
    http.Client? client,
    Uri? baseUri,
  })  : _client = client ?? http.Client(),
        _baseUri = baseUri ?? Uri.parse('http://127.0.0.1:3000');

  final http.Client _client;
  final Uri _baseUri;

  @override
  Future<List<String>> fetchRecentFiles() async {
    final List<CloudFile> files = await fetchFiles();
    return files.take(4).map((CloudFile file) => file.originalName).toList();
  }

  @override
  Future<List<CloudFile>> fetchFiles() async {
    return _fetchFileList('/files', fallbackMessage: '加载文件列表失败');
  }

  @override
  Future<List<CloudFile>> fetchTrashFiles() async {
    return _fetchFileList('/files/trash', fallbackMessage: '加载回收站失败');
  }

  @override
  Future<FileStorageLimits> fetchLimits() async {
    final http.Response response =
        await _client.get(_buildUri('/files/limits'));
    _ensureSuccess(response, fallbackMessage: '加载存储空间信息失败');

    return FileStorageLimits.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
  }

  @override
  Future<CloudFile> uploadFile({
    TransferProgressCallback? onProgress,
  }) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      withData: false,
    );

    if (result == null || result.files.isEmpty) {
      throw const AppException('已取消上传');
    }

    final PlatformFile pickedFile = result.files.single;
    final String? filePath = pickedFile.path;
    if (filePath == null || filePath.isEmpty) {
      throw const AppException('未能读取所选文件路径');
    }

    return uploadFileFromPath(
      filePath,
      onProgress: onProgress,
    );
  }

  @override
  Future<CloudFile> uploadFileFromPath(
    String filePath, {
    TransferProgressCallback? onProgress,
  }) async {
    final File file = File(filePath);
    final int fileLength = await file.length();
    int sentBytes = 0;

    final Stream<List<int>> stream = file.openRead().transform(
      _ProgressStreamTransformer((int chunkLength) {
        sentBytes += chunkLength;
        onProgress?.call(
          fileLength == 0 ? 0 : math.min(sentBytes / fileLength, 1).toDouble(),
        );
      }),
    );

    final http.MultipartRequest request =
        http.MultipartRequest('POST', _buildUri('/files/upload'));
    request.files.add(
      http.MultipartFile(
        'file',
        http.ByteStream(stream),
        fileLength,
        filename: _extractFileName(filePath),
      ),
    );

    final http.StreamedResponse streamedResponse = await _client.send(request);
    final http.Response response =
        await http.Response.fromStream(streamedResponse);
    _ensureSuccess(response, fallbackMessage: '上传文件失败');
    onProgress?.call(1);

    return CloudFile.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> deleteFile(int id) async {
    final http.Response response =
        await _client.delete(_buildUri('/files/$id'));
    _ensureSuccess(response, fallbackMessage: '移入回收站失败');
  }

  @override
  Future<void> restoreTrashFile(int id) async {
    final http.Response response = await _client.post(
      _buildUri('/files/trash/$id/restore'),
    );
    _ensureSuccess(response, fallbackMessage: '恢复文件失败');
  }

  @override
  Future<void> deleteTrashFilePermanently(int id) async {
    final http.Response response =
        await _client.delete(_buildUri('/files/trash/$id'));
    _ensureSuccess(response, fallbackMessage: '彻底删除文件失败');
  }

  @override
  Future<void> clearTrash() async {
    final http.Response response =
        await _client.delete(_buildUri('/files/trash'));
    _ensureSuccess(response, fallbackMessage: '清空回收站失败');
  }

  @override
  Future<String> downloadFile(
    CloudFile file, {
    TransferProgressCallback? onProgress,
  }) async {
    final String? savePath = await FilePicker.platform.saveFile(
      dialogTitle: '保存文件',
      fileName: file.originalName,
    );

    if (savePath == null || savePath.isEmpty) {
      throw const AppException('已取消下载');
    }

    final http.StreamedResponse response = await _client.send(
      http.Request('GET', _buildUri('/files/${file.id}/download')),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final http.Response normalizedResponse =
          await http.Response.fromStream(response);
      _ensureSuccess(normalizedResponse, fallbackMessage: '下载文件失败');
    }

    final File targetFile = File(savePath);
    final IOSink sink = targetFile.openWrite();
    final int totalBytes = response.contentLength ?? file.size;
    int receivedBytes = 0;

    try {
      await for (final List<int> chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          onProgress?.call(
            math.min(receivedBytes / totalBytes, 1).toDouble(),
          );
        }
      }
    } finally {
      await sink.close();
    }

    onProgress?.call(1);
    return targetFile.path;
  }

  Future<List<CloudFile>> _fetchFileList(
    String path, {
    required String fallbackMessage,
  }) async {
    final http.Response response = await _client.get(_buildUri(path));
    _ensureSuccess(response, fallbackMessage: fallbackMessage);

    final List<dynamic> data =
        jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
    return data
        .map((dynamic item) => CloudFile.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Uri _buildUri(String path) {
    return _baseUri.replace(path: path);
  }

  String _extractFileName(String filePath) {
    final String normalized = filePath.replaceAll('\\', '/');
    final List<String> segments = normalized.split('/');
    return segments.isEmpty ? 'upload.bin' : segments.last;
  }

  void _ensureSuccess(
    http.Response response, {
    required String fallbackMessage,
  }) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    String message = fallbackMessage;
    if (response.bodyBytes.isNotEmpty) {
      try {
        final String decodedBody = utf8.decode(response.bodyBytes);
        final dynamic decoded = jsonDecode(decodedBody);
        if (decoded is Map<String, dynamic>) {
          message = decoded['message']?.toString() ??
              decoded['error']?.toString() ??
              fallbackMessage;
        } else if (decoded is String && decoded.isNotEmpty) {
          message = decoded;
        }
      } catch (_) {
        message = utf8.decode(response.bodyBytes, allowMalformed: true);
      }
    }

    throw AppException(_normalizeServerMessage(message, fallbackMessage));
  }

  String _normalizeServerMessage(String message, String fallbackMessage) {
    final String trimmed = message.trim();
    if (trimmed.isEmpty) {
      return fallbackMessage;
    }

    const Map<String, String> knownMessages = <String, String>{
      'Single file size cannot exceed 200MB': '单个文件大小不能超过 200MB',
      'File too large': '单个文件大小不能超过 200MB',
      'Expected maxSize to be': '单个文件大小不能超过 200MB',
      'Uploads directory cannot exceed 10GB total size': '服务器容量已满，请清理后再上传',
      'Failed to inspect uploads directory usage': '无法检查服务器存储空间，请稍后重试',
      'Invalid file name': '文件名无效，请重新选择文件',
      'Unexpected field': '上传参数无效，请重新选择文件',
      'File moved to trash.': '文件已移入回收站',
      'File restored from trash.': '文件已从回收站恢复',
      'File is in trash and cannot be downloaded.': '回收站中的文件不支持下载',
      'File not found': '文件不存在',
      'Trash file not found': '回收站文件不存在',
      'Trash cleared successfully': '回收站已清空',
    };

    for (final MapEntry<String, String> entry in knownMessages.entries) {
      if (trimmed.contains(entry.key)) {
        return entry.value;
      }
    }

    return trimmed;
  }
}

class _ProgressStreamTransformer
    extends StreamTransformerBase<List<int>, List<int>> {
  const _ProgressStreamTransformer(this.onChunk);

  final void Function(int chunkLength) onChunk;

  @override
  Stream<List<int>> bind(Stream<List<int>> stream) {
    return stream.map((List<int> chunk) {
      onChunk(chunk.length);
      return chunk;
    });
  }
}
