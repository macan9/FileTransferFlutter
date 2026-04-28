import 'package:equatable/equatable.dart';

class AppConfig extends Equatable {
  const AppConfig({
    required this.serverUrl,
    required this.deviceId,
    required this.deviceName,
    required this.devicePlatform,
    required this.zeroTierNodeId,
    required this.agentToken,
    required this.downloadDirectory,
    required this.autoOnline,
    required this.minimizeToTrayOnClose,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    return AppConfig(
      serverUrl: json['serverUrl']?.toString() ?? '',
      deviceId: json['deviceId']?.toString() ?? '',
      deviceName: json['deviceName']?.toString() ?? '',
      devicePlatform: json['devicePlatform']?.toString() ?? '',
      zeroTierNodeId: json['zeroTierNodeId']?.toString() ?? '',
      agentToken: json['agentToken']?.toString() ?? '',
      downloadDirectory: json['downloadDirectory']?.toString() ?? '',
      autoOnline: json['autoOnline'] as bool? ?? true,
      minimizeToTrayOnClose: json['minimizeToTrayOnClose'] as bool? ?? true,
    );
  }

  final String serverUrl;
  final String deviceId;
  final String deviceName;
  final String devicePlatform;
  final String zeroTierNodeId;
  final String agentToken;
  final String downloadDirectory;
  final bool autoOnline;
  final bool minimizeToTrayOnClose;

  Uri get serverUri => Uri.parse(serverUrl);

  AppConfig copyWith({
    String? serverUrl,
    String? deviceId,
    String? deviceName,
    String? devicePlatform,
    String? zeroTierNodeId,
    String? agentToken,
    String? downloadDirectory,
    bool? autoOnline,
    bool? minimizeToTrayOnClose,
  }) {
    return AppConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      devicePlatform: devicePlatform ?? this.devicePlatform,
      zeroTierNodeId: zeroTierNodeId ?? this.zeroTierNodeId,
      agentToken: agentToken ?? this.agentToken,
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      autoOnline: autoOnline ?? this.autoOnline,
      minimizeToTrayOnClose:
          minimizeToTrayOnClose ?? this.minimizeToTrayOnClose,
    );
  }

  AppConfig normalized() {
    return AppConfig(
      serverUrl: _normalizeServerUrl(serverUrl),
      deviceId: deviceId.trim(),
      deviceName: deviceName.trim(),
      devicePlatform: devicePlatform.trim(),
      zeroTierNodeId: zeroTierNodeId.trim(),
      agentToken: agentToken.trim(),
      downloadDirectory: downloadDirectory.trim(),
      autoOnline: autoOnline,
      minimizeToTrayOnClose: minimizeToTrayOnClose,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'serverUrl': serverUrl,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'devicePlatform': devicePlatform,
      'zeroTierNodeId': zeroTierNodeId,
      'agentToken': agentToken,
      'downloadDirectory': downloadDirectory,
      'autoOnline': autoOnline,
      'minimizeToTrayOnClose': minimizeToTrayOnClose,
    };
  }

  @override
  List<Object?> get props => <Object?>[
        serverUrl,
        deviceId,
        deviceName,
        devicePlatform,
        zeroTierNodeId,
        agentToken,
        downloadDirectory,
        autoOnline,
        minimizeToTrayOnClose,
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
