import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/constants/app_constants.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class AppConfigDefaultsResolver {
  AppConfigDefaultsResolver({
    DeviceInfoPlugin? deviceInfoPlugin,
    Uuid? uuid,
  })  : _deviceInfoPlugin = deviceInfoPlugin ?? DeviceInfoPlugin(),
        _uuid = uuid ?? const Uuid();

  final DeviceInfoPlugin _deviceInfoPlugin;
  final Uuid _uuid;

  Future<AppConfig> resolve() async {
    final String deviceName = await _resolveDeviceName();
    final String downloadDirectory = await _resolveDownloadDirectory();

    return AppConfig(
      serverUrl: 'http://127.0.0.1:3000',
      deviceId: _uuid.v4(),
      deviceName: deviceName,
      downloadDirectory: downloadDirectory,
      autoOnline: true,
    );
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
    Directory? baseDirectory;

    try {
      baseDirectory = await getDownloadsDirectory();
    } catch (_) {
      baseDirectory = null;
    }

    baseDirectory ??= await getApplicationDocumentsDirectory();

    final Directory targetDirectory = Directory(
      p.join(baseDirectory.path, AppConstants.downloadFolderName),
    );
    if (!await targetDirectory.exists()) {
      await targetDirectory.create(recursive: true);
    }

    return targetDirectory.path;
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
