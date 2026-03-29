import 'package:equatable/equatable.dart';

class AppConfig extends Equatable {
  const AppConfig({
    required this.serverUrl,
    required this.deviceId,
    required this.deviceName,
    required this.downloadDirectory,
    required this.autoOnline,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    return AppConfig(
      serverUrl: json['serverUrl']?.toString() ?? '',
      deviceId: json['deviceId']?.toString() ?? '',
      deviceName: json['deviceName']?.toString() ?? '',
      downloadDirectory: json['downloadDirectory']?.toString() ?? '',
      autoOnline: json['autoOnline'] as bool? ?? true,
    );
  }

  final String serverUrl;
  final String deviceId;
  final String deviceName;
  final String downloadDirectory;
  final bool autoOnline;

  Uri get serverUri => Uri.parse(serverUrl);

  AppConfig copyWith({
    String? serverUrl,
    String? deviceId,
    String? deviceName,
    String? downloadDirectory,
    bool? autoOnline,
  }) {
    return AppConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      autoOnline: autoOnline ?? this.autoOnline,
    );
  }

  AppConfig normalized() {
    return AppConfig(
      serverUrl: _normalizeServerUrl(serverUrl),
      deviceId: deviceId.trim(),
      deviceName: deviceName.trim(),
      downloadDirectory: downloadDirectory.trim(),
      autoOnline: autoOnline,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'serverUrl': serverUrl,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'downloadDirectory': downloadDirectory,
      'autoOnline': autoOnline,
    };
  }

  @override
  List<Object?> get props => <Object?>[
        serverUrl,
        deviceId,
        deviceName,
        downloadDirectory,
        autoOnline,
      ];

  static String _normalizeServerUrl(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }

    final Uri uri = Uri.parse(trimmed);
    final String normalizedPath = uri.path.endsWith('/') && uri.path.length > 1
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return uri.replace(path: normalizedPath).toString();
  }
}
