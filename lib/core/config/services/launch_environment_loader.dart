import 'dart:convert';

import 'package:file_transfer_flutter/core/config/app_network_config.dart';
import 'package:file_transfer_flutter/core/config/models/launch_environment.dart';
import 'package:flutter/services.dart';

class LaunchEnvironmentLoader {
  const LaunchEnvironmentLoader();

  Future<LaunchEnvironment> load() async {
    try {
      final String raw = await rootBundle.loadString(
        AppNetworkConfig.launchConfigAssetPath,
      );
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
