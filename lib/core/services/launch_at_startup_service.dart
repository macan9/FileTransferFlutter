import 'dart:io';

import 'package:file_transfer_flutter/core/constants/app_constants.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';

class LaunchAtStartupService {
  LaunchAtStartupService._();

  static bool _configured = false;

  static bool get isSupported => Platform.isWindows || Platform.isMacOS;

  static Future<void> ensureConfigured() async {
    if (_configured || !isSupported) {
      return;
    }

    if (Platform.isWindows) {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      launchAtStartup.setup(
        appName: AppConstants.appName,
        appPath: Platform.resolvedExecutable,
        packageName: packageInfo.packageName,
      );
    }

    _configured = true;
  }

  static Future<bool> isEnabled() async {
    await ensureConfigured();

    if (Platform.isWindows) {
      return launchAtStartup.isEnabled();
    }

    if (Platform.isMacOS) {
      final String? appBundlePath = _macOSAppBundlePath();
      if (appBundlePath == null) {
        return false;
      }
      final String escapedPath = _escapeAppleScriptString(appBundlePath);
      final ProcessResult result = await _runAppleScript(
        '''
tell application "System Events"
  set targetPath to POSIX file "$escapedPath" as alias
  repeat with loginItem in login items
    if path of loginItem is (POSIX path of targetPath) then return "true"
  end repeat
end tell
return "false"
''',
      );
      return result.exitCode == 0 && result.stdout.toString().trim() == 'true';
    }

    return false;
  }

  static Future<void> setEnabled(bool enabled) async {
    await ensureConfigured();

    if (Platform.isWindows) {
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
      return;
    }

    if (Platform.isMacOS) {
      final String? appBundlePath = _macOSAppBundlePath();
      if (appBundlePath == null) {
        throw StateError('Unable to locate macOS app bundle.');
      }
      final String escapedPath = _escapeAppleScriptString(appBundlePath);

      final String script = enabled
          ? '''
tell application "System Events"
  set targetPath to POSIX file "$escapedPath" as alias
  repeat with loginItem in login items
    if path of loginItem is (POSIX path of targetPath) then return
  end repeat
  make login item at end with properties {path:(POSIX path of targetPath), hidden:false}
end tell
'''
          : '''
tell application "System Events"
  set targetPath to POSIX file "$escapedPath" as alias
  repeat with loginItem in login items
    if path of loginItem is (POSIX path of targetPath) then delete loginItem
  end repeat
end tell
''';
      final ProcessResult result = await _runAppleScript(script);
      if (result.exitCode != 0) {
        final String message = result.stderr.toString().trim();
        throw StateError(message.isEmpty ? 'Failed to update Login Items.' : message);
      }
    }
  }

  static String? _macOSAppBundlePath() {
    final String executablePath = Platform.resolvedExecutable;
    final int appIndex = executablePath.indexOf('.app/');
    if (appIndex == -1) {
      return null;
    }
    return executablePath.substring(0, appIndex + 4);
  }

  static String _escapeAppleScriptString(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }

  static Future<ProcessResult> _runAppleScript(String script) {
    return Process.run(
      'osascript',
      <String>['-e', script],
      runInShell: false,
    );
  }
}
