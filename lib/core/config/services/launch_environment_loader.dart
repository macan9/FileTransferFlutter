import 'dart:convert';
import 'dart:io';

import 'package:file_transfer_flutter/core/config/app_network_config.dart';
import 'package:file_transfer_flutter/core/config/models/launch_environment.dart';
import 'package:flutter/services.dart';

class LaunchEnvironmentLoader {
  const LaunchEnvironmentLoader();

  Future<LaunchEnvironment> load() async {
    try {
      final String raw = await _loadRawConfig();
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

  Future<String> _loadRawConfig() async {
    final File diskConfig = File(AppNetworkConfig.launchConfigFileName);
    if (await diskConfig.exists()) {
      return diskConfig.readAsString();
    }
    return rootBundle.loadString(AppNetworkConfig.launchConfigAssetPath);
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
