import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/config/models/launch_environment.dart';
import 'package:file_transfer_flutter/core/config/services/app_config_defaults_resolver.dart';
import 'package:file_transfer_flutter/core/config/services/launch_environment_loader.dart';
import 'package:hive/hive.dart';

abstract interface class AppConfigRepository {
  Future<AppConfig> load();
  Future<AppConfig> save(AppConfig config);
}

class HiveAppConfigRepository implements AppConfigRepository {
  HiveAppConfigRepository({
    required Box<dynamic> box,
    LaunchEnvironmentLoader? launchEnvironmentLoader,
  })  : _box = box,
        _launchEnvironmentLoader =
            launchEnvironmentLoader ?? const LaunchEnvironmentLoader(),
        super();

  static const String boxName = 'app_config';
  static const String configKey = 'current';

  final Box<dynamic> _box;
  final LaunchEnvironmentLoader _launchEnvironmentLoader;

  @override
  Future<AppConfig> load() async {
    final LaunchEnvironment effectiveEnvironment =
        await _launchEnvironmentLoader.load();
    final AppConfig defaults = await AppConfigDefaultsResolver(
      launchEnvironment: effectiveEnvironment,
    ).resolve();
    final dynamic raw = _box.get(configKey);
    final AppConfig mergedConfig = _mergePersistedConfig(raw, defaults);
    final AppConfig normalized = mergedConfig.normalized();

    if (!_jsonEquals(raw, normalized.toJson())) {
      await _box.put(configKey, normalized.toJson());
    }

    return normalized;
  }

  @override
  Future<AppConfig> save(AppConfig config) async {
    final LaunchEnvironment effectiveEnvironment =
        await _launchEnvironmentLoader.load();
    final AppConfig normalized = config
        .copyWith(
          serverUrl: effectiveEnvironment.activeServerUrl,
        )
        .normalized();
    await _box.put(configKey, normalized.toJson());
    return normalized;
  }

  AppConfig _mergePersistedConfig(dynamic raw, AppConfig defaults) {
    if (raw is! Map) {
      return defaults;
    }

    final Map<String, dynamic> json = raw.map(
      (dynamic key, dynamic value) => MapEntry(key.toString(), value),
    );

    final AppConfig persisted = AppConfig.fromJson(json);
    final bool serverChanged = _normalizeServerUrl(persisted.serverUrl) !=
        _normalizeServerUrl(defaults.serverUrl);
    return defaults.copyWith(
      // The root launch environment file is the source of truth for serverUrl.
      serverUrl: defaults.serverUrl,
      deviceId: serverChanged
          ? defaults.deviceId
          : _preferPersisted(persisted.deviceId, defaults.deviceId),
      deviceName: _preferPersisted(persisted.deviceName, defaults.deviceName),
      devicePlatform: _preferPersisted(
        persisted.devicePlatform,
        defaults.devicePlatform,
      ),
      zeroTierNodeId: serverChanged
          ? defaults.zeroTierNodeId
          : _preferPersisted(
              persisted.zeroTierNodeId,
              defaults.zeroTierNodeId,
            ),
      agentToken: serverChanged
          ? defaults.agentToken
          : _preferPersisted(
              persisted.agentToken,
              defaults.agentToken,
            ),
      downloadDirectory: _preferPersisted(
        persisted.downloadDirectory,
        defaults.downloadDirectory,
      ),
      autoOnline: json.containsKey('autoOnline')
          ? persisted.autoOnline
          : defaults.autoOnline,
      minimizeToTrayOnClose: json.containsKey('minimizeToTrayOnClose')
          ? persisted.minimizeToTrayOnClose
          : defaults.minimizeToTrayOnClose,
    );
  }

  String _preferPersisted(String persisted, String fallback) {
    final String trimmed = persisted.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  String _normalizeServerUrl(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final Uri uri = Uri.parse(trimmed);
    final String normalizedPath = uri.path.endsWith('/') && uri.path.length > 1
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return uri.replace(path: normalizedPath).toString();
  }

  bool _jsonEquals(dynamic raw, Map<String, dynamic> normalizedJson) {
    if (raw is! Map) {
      return false;
    }

    final Map<String, dynamic> persisted = raw.map(
      (dynamic key, dynamic value) => MapEntry(key.toString(), value),
    );

    if (persisted.length != normalizedJson.length) {
      return false;
    }

    for (final MapEntry<String, dynamic> entry in normalizedJson.entries) {
      if (persisted[entry.key] != entry.value) {
        return false;
      }
    }

    return true;
  }
}
