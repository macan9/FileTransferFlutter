import 'package:equatable/equatable.dart';

class CloudFile extends Equatable {
  const CloudFile({
    required this.id,
    required this.originalName,
    required this.filename,
    required this.mimeType,
    required this.size,
    required this.url,
    required this.createdAt,
    this.deletedAt,
  });

  factory CloudFile.fromJson(Map<String, dynamic> json) {
    return CloudFile(
      id: json['id'] as int,
      originalName: json['originalName'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      size: (json['size'] as num?)?.toInt() ?? 0,
      url: json['url'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      deletedAt: DateTime.tryParse(json['deletedAt'] as String? ?? ''),
    );
  }

  final int id;
  final String originalName;
  final String filename;
  final String mimeType;
  final int size;
  final String url;
  final DateTime createdAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  @override
  List<Object?> get props => <Object?>[
        id,
        originalName,
        filename,
        mimeType,
        size,
        url,
        createdAt,
        deletedAt,
      ];
}
