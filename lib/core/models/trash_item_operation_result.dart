import 'package:equatable/equatable.dart';

import 'package:file_transfer_flutter/core/models/cloud_item.dart';

class TrashItemOperationResult extends Equatable {
  const TrashItemOperationResult({
    required this.id,
    required this.type,
    this.restored = false,
    this.permanentlyDeleted = false,
    this.restoredFolderCount = 0,
    this.restoredFileCount = 0,
    this.deletedFolderCount = 0,
    this.deletedFileCount = 0,
    this.name,
    this.path,
    this.message,
  });

  factory TrashItemOperationResult.fromJson(Map<String, dynamic> json) {
    final CloudItemType type = (json['type'] as String?) == 'folder'
        ? CloudItemType.folder
        : CloudItemType.file;

    return TrashItemOperationResult(
      id: (json['id'] as num?)?.toInt() ?? 0,
      type: type,
      restored: json['restored'] as bool? ?? false,
      permanentlyDeleted: json['permanentlyDeleted'] as bool? ?? false,
      restoredFolderCount: (json['restoredFolderCount'] as num?)?.toInt() ?? 0,
      restoredFileCount: (json['restoredFileCount'] as num?)?.toInt() ?? 0,
      deletedFolderCount: (json['deletedFolderCount'] as num?)?.toInt() ?? 0,
      deletedFileCount: (json['deletedFileCount'] as num?)?.toInt() ?? 0,
      name: json['name'] as String?,
      path: json['path'] as String?,
      message: json['message'] as String?,
    );
  }

  final int id;
  final CloudItemType type;
  final bool restored;
  final bool permanentlyDeleted;
  final int restoredFolderCount;
  final int restoredFileCount;
  final int deletedFolderCount;
  final int deletedFileCount;
  final String? name;
  final String? path;
  final String? message;

  bool get isFolder => type == CloudItemType.folder;
  bool get isFile => type == CloudItemType.file;

  @override
  List<Object?> get props => <Object?>[
        id,
        type,
        restored,
        permanentlyDeleted,
        restoredFolderCount,
        restoredFileCount,
        deletedFolderCount,
        deletedFileCount,
        name,
        path,
        message,
      ];
}
