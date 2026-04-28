import 'dart:io';

import 'package:file_transfer_flutter/core/config/app_network_config.dart';
import 'package:file_transfer_flutter/core/config/models/launch_environment.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class AppConfigDefaultsResolver {
  AppConfigDefaultsResolver({
    DeviceInfoPlugin? deviceInfoPlugin,
    Uuid? uuid,
    LaunchEnvironment? launchEnvironment,
  })  : _deviceInfoPlugin = deviceInfoPlugin ?? DeviceInfoPlugin(),
        _launchEnvironment = launchEnvironment,
        _uuid = uuid ?? const Uuid();

  final DeviceInfoPlugin _deviceInfoPlugin;
  final LaunchEnvironment? _launchEnvironment;
  final Uuid _uuid;

  Future<AppConfig> resolve() async {
    final String deviceName = await _resolveDeviceName();
    final String devicePlatform = _resolvePlatform();
    final String downloadDirectory = await _resolveDownloadDirectory();

    return AppConfig(
      serverUrl: _launchEnvironment?.activeServerUrl ??
          AppNetworkConfig.defaultServerUrl,
      deviceId: _uuid.v4(),
      deviceName: deviceName,
      devicePlatform: devicePlatform,
      zeroTierNodeId: '',
      agentToken: '',
      downloadDirectory: downloadDirectory,
      autoOnline: true,
      minimizeToTrayOnClose: true,
    );
  }

  String _resolvePlatform() {
    if (Platform.isWindows) {
      return 'windows';
    }
    if (Platform.isMacOS) {
      return 'macos';
    }
    if (Platform.isLinux) {
      return 'linux';
    }
    if (Platform.isAndroid) {
      return 'android';
    }
    if (Platform.isIOS) {
      return 'ios';
    }
    return 'unknown';
  }

  Future<String> _resolveDeviceName() async {
    try {
      if (Platform.isWindows) {
        final WindowsDeviceInfo info = await _deviceInfoPlugin.windowsInfo;
        return _nonEmptyOrFallback(
          info.computerName,
          fallback: Platform.localHostname,
        );
      }

      if (Platform.isMacOS) {
        final MacOsDeviceInfo info = await _deviceInfoPlugin.macOsInfo;
        return _nonEmptyOrFallback(
          info.computerName,
          fallback: Platform.localHostname,
        );
      }

      if (Platform.isLinux) {
        final LinuxDeviceInfo info = await _deviceInfoPlugin.linuxInfo;
        return _nonEmptyOrFallback(
          info.prettyName,
          fallback: Platform.localHostname,
        );
      }

      if (Platform.isAndroid) {
        final AndroidDeviceInfo info = await _deviceInfoPlugin.androidInfo;
        return _nonEmptyOrFallback(
          info.model,
          fallback: '${info.brand} Android',
        );
      }

      if (Platform.isIOS) {
        final IosDeviceInfo info = await _deviceInfoPlugin.iosInfo;
        return _nonEmptyOrFallback(
          info.name,
          fallback: info.model,
        );
      }
    } catch (_) {
      // Fall back to hostname below.
    }

    return _nonEmptyOrFallback(Platform.localHostname, fallback: 'My Device');
  }

  Future<String> _resolveDownloadDirectory() async {
    if (Platform.isAndroid) {
      final Directory? androidDownloadDirectory =
          await _resolveAndroidDownloadDirectory();
      if (androidDownloadDirectory != null) {
        return androidDownloadDirectory.path;
      }
    }

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        final Directory? downloadsDirectory = await getDownloadsDirectory();
        if (downloadsDirectory != null) {
          return downloadsDirectory.path;
        }
      } catch (_) {
        // Fall through to platform-specific fallback below.
      }
    }

    if (Platform.isIOS) {
      return (await getApplicationDocumentsDirectory()).path;
    }

    return (await getApplicationDocumentsDirectory()).path;
  }

  Future<Directory?> _resolveAndroidDownloadDirectory() async {
    final List<String> candidates = <String>[
      '/storage/emulated/0/Download',
      '/sdcard/Download',
    ];

    for (final String candidate in candidates) {
      final Directory directory = Directory(candidate);
      if (await directory.exists()) {
        return directory;
      }
    }

    try {
      final Directory? downloadsDirectory = await getDownloadsDirectory();
      if (downloadsDirectory != null) {
        return downloadsDirectory;
      }
    } catch (_) {
      // Ignore and fall back to app documents directory.
    }

    return null;
  }

  String _nonEmptyOrFallback(String? value, {required String fallback}) {
    final String trimmed = value?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      return trimmed;
    }

    final String normalizedFallback = fallback.trim();
    return normalizedFallback.isEmpty ? 'My Device' : normalizedFallback;
  }
}
