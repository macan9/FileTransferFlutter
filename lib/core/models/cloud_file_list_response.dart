import 'package:equatable/equatable.dart';

import 'package:file_transfer_flutter/core/models/cloud_item.dart';

class CloudFileListResponse extends Equatable {
  const CloudFileListResponse({
    this.path = '',
    this.parentPath,
    this.folders = const <CloudItem>[],
    this.files = const <CloudItem>[],
    this.items = const <CloudItem>[],
  });

  factory CloudFileListResponse.fromJson(Map<String, dynamic> json) {
    List<CloudItem> parseList(String key) {
      final List<dynamic> raw =
          json[key] as List<dynamic>? ?? const <dynamic>[];
      return raw
          .map((dynamic item) =>
              CloudItem.fromJson(item as Map<String, dynamic>))
          .toList();
    }

    final List<CloudItem> folders = parseList('folders');
    final List<CloudItem> files = parseList('files');
    final List<CloudItem> items = parseList('items');

    return CloudFileListResponse(
      path: json['path'] as String? ?? '',
      parentPath: json['parentPath'] as String?,
      folders: folders,
      files: files,
      items: items.isNotEmpty ? items : <CloudItem>[...folders, ...files],
    );
  }

  final String path;
  final String? parentPath;
  final List<CloudItem> folders;
  final List<CloudItem> files;
  final List<CloudItem> items;

  bool get isEmpty => items.isEmpty;

  @override
  List<Object?> get props => <Object?>[path, parentPath, folders, files, items];
}
