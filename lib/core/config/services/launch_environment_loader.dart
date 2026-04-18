import 'dart:convert';
import 'dart:io';

import 'package:file_transfer_flutter/core/config/app_network_config.dart';
import 'package:file_transfer_flutter/core/config/models/launch_environment.dart';

class LaunchEnvironmentLoader {
  const LaunchEnvironmentLoader();

  Future<LaunchEnvironment> load() async {
    final File file = File(_resolveConfigPath());
    if (!await file.exists()) {
      return _fallbackEnvironment;
    }

    try {
      final String raw = await file.readAsString();
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return _fallbackEnvironment;
      }

      final LaunchEnvironment loaded = LaunchEnvironment.fromJson(decoded);
      return LaunchEnvironment(
        mode: loaded.mode,
        devServerUrl: _normalizeOrFallback(
          loaded.devServerUrl,
          AppNetworkConfig.fallbackDevServerUrl,
        ),
        proServerUrl: _normalizeOrFallback(
          loaded.proServerUrl,
          AppNetworkConfig.fallbackProServerUrl,
        ),
      );
    } catch (_) {
      return _fallbackEnvironment;
    }
  }

  String _resolveConfigPath() {
    return '${Directory.current.path}${Platform.pathSeparator}${AppNetworkConfig.launchConfigFileName}';
  }

  String _normalizeOrFallback(String value, String fallback) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return fallback;
    }
    return AppNetworkConfig.normalizeUrl(trimmed);
  }

  LaunchEnvironment get _fallbackEnvironment => LaunchEnvironment(
        mode: LaunchMode.dev,
        devServerUrl: AppNetworkConfig.fallbackDevServerUrl,
        proServerUrl: AppNetworkConfig.fallbackProServerUrl,
      );
}
