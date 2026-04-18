abstract final class AppNetworkConfig {
  static const String launchConfigFileName = 'app_env.json';
  static const String launchConfigAssetPath = launchConfigFileName;
  static const String fallbackDevServerUrl = 'http://localhost:3000';
  static const String fallbackProServerUrl = 'http://255';
  static const String defaultServerUrl = fallbackDevServerUrl;
  static const String exampleLanServerUrl = 'http://192.168.1.10:3000';
  static const Set<String> legacyLocalServerUrls = <String>{
    'http://127.0.0.1:3000',
    'http://localhost:3000',
    'http://0.0.0.0:3000',
  };

  static Uri get defaultServerUri => Uri.parse(defaultServerUrl);

  static String normalizeUrl(String value) {
    return _normalizeUrl(value);
  }

  static bool isLegacyLocalServerUrl(String value) {
    final String normalized = _normalizeUrl(value);
    return legacyLocalServerUrls.any(
      (String candidate) => _normalizeUrl(candidate) == normalized,
    );
  }

  static String _normalizeUrl(String value) {
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
