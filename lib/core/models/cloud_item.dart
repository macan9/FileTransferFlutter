import 'package:equatable/equatable.dart';

enum CloudItemType { file, folder }

class CloudItem extends Equatable {
  const CloudItem({
    required this.id,
    required this.type,
    required this.name,
    required this.createdAt,
    this.originalName = '',
    this.filename = '',
    this.mimeType = 'application/octet-stream',
    this.size = 0,
    this.url = '',
    this.deletedAt,
    this.path,
    this.parentPath,
    this.directoryPath,
    this.storagePath,
  });

  factory CloudItem.fromJson(Map<String, dynamic> json) {
    final CloudItemType type = (json['type'] as String?) == 'folder'
        ? CloudItemType.folder
        : CloudItemType.file;
    final String fallbackName = json['name'] as String? ?? '';

    return CloudItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      type: type,
      name: fallbackName,
      originalName: json['originalName'] as String? ?? fallbackName,
      filename: json['filename'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      size: (json['size'] as num?)?.toInt() ?? 0,
      url: json['url'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      deletedAt: DateTime.tryParse(json['deletedAt'] as String? ?? ''),
      path: json['path'] as String?,
      parentPath: json['parentPath'] as String?,
      directoryPath: json['directoryPath'] as String?,
      storagePath: json['storagePath'] as String?,
    );
  }

  final int id;
  final CloudItemType type;
  final String name;
  final String originalName;
  final String filename;
  final String mimeType;
  final int size;
  final String url;
  final DateTime createdAt;
  final DateTime? deletedAt;
  final String? path;
  final String? parentPath;
  final String? directoryPath;
  final String? storagePath;

  bool get isFile => type == CloudItemType.file;
  bool get isFolder => type == CloudItemType.folder;
  bool get isDeleted => deletedAt != null;
  String get displayName => isFolder ? name : originalName;
  String get fullPath => isFolder ? (path ?? '') : (directoryPath ?? '');

  @override
  List<Object?> get props => <Object?>[
        id,
        type,
        name,
        originalName,
        filename,
        mimeType,
        size,
        url,
        createdAt,
        deletedAt,
        path,
        parentPath,
        directoryPath,
        storagePath,
      ];
}
