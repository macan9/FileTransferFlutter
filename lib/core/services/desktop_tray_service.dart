import 'dart:async';
import 'dart:io';

import 'package:file_transfer_flutter/app/router/app_route_names.dart';
import 'package:file_transfer_flutter/app/router/app_router.dart';
import 'package:file_transfer_flutter/core/constants/app_constants.dart';
import 'package:file_transfer_flutter/core/services/windows_window_control.dart';
import 'package:hive/hive.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class DesktopTrayService with TrayListener {
  DesktopTrayService._();

  static const String _trayIconPath = 'assets/icon/tray_icon.ico';
  static const String _openIconPath = 'assets/tray_menu/open.png';
  static const String _networkIconPath = 'assets/tray_menu/network.png';
  static const String _privateIconPath = 'assets/tray_menu/private.png';
  static const String _transferIconPath = 'assets/tray_menu/transfer.png';
  static const String _settingsIconPath = 'assets/tray_menu/settings.png';
  static const String _exitIconPath = 'assets/tray_menu/exit.png';

  static DesktopTrayService? _instance;
  static bool _isQuitting = false;

  static Future<DesktopTrayService?> initialize() async {
    if (!Platform.isWindows) {
      return null;
    }

    if (_instance != null) {
      return _instance;
    }

    final DesktopTrayService service = DesktopTrayService._();
    await service._initialize();
    _instance = service;
    return service;
  }

  Future<void> _initialize() async {
    trayManager.addListener(this);

    await trayManager.setIcon(_trayIconPath);
    await trayManager.setToolTip(AppConstants.appName);
    await trayManager.setContextMenu(_buildMenu());
  }

  Menu _buildMenu() {
    return Menu(
      items: <MenuItem>[
        MenuItem(
          label: '\u6253\u5f00\u4e3b\u754c\u9762',
          icon: _openIconPath,
          onClick: (_) => unawaited(_showRoute(AppRouteNames.files)),
        ),
        MenuItem.separator(),
        MenuItem.checkbox(
          label: '\u9ed8\u8ba4\u7f51\u7edc',
          icon: _networkIconPath,
          checked: true,
          onClick: (_) => unawaited(_showRoute(AppRouteNames.networking)),
        ),
        MenuItem(
          label: '\u79c1\u6709\u7ec4\u7f51',
          icon: _privateIconPath,
          onClick: (_) => unawaited(_showRoute(AppRouteNames.networking)),
        ),
        MenuItem(
          label: '\u5b9e\u65f6\u4f20\u8f93',
          icon: _transferIconPath,
          onClick: (_) => unawaited(_showRoute(AppRouteNames.transfers)),
        ),
        MenuItem.separator(),
        MenuItem(
          label: '\u8bbe\u7f6e',
          icon: _settingsIconPath,
          onClick: (_) => unawaited(_showRoute(AppRouteNames.settings)),
        ),
        MenuItem(
          label: '\u9000\u51fa',
          icon: _exitIconPath,
          onClick: (_) => unawaited(_quit()),
        ),
      ],
    );
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_showRoute(AppRouteNames.files));
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  Future<void> _showRoute(String routeName) async {
    await showMainWindow();
    try {
      appRouter.goNamed(routeName);
    } catch (_) {
      // The tray can be clicked during startup before the router is attached.
    }
  }

  static Future<void> showMainWindow() async {
    await windowManager.setSkipTaskbar(false);
    await WindowsWindowControl.restore();
    await windowManager.focus();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await WindowsWindowControl.restore();
    await windowManager.focus();
  }

  static Future<void> hideToTray() async {
    await windowManager.setSkipTaskbar(true);
    await windowManager.hide();
  }

  static Future<void> quitApp() async {
    if (_isQuitting) {
      return;
    }
    _isQuitting = true;

    await WindowsWindowControl.hide();
    unawaited(Hive.close());
    unawaited(_finishQuit());
    await Future<void>.delayed(const Duration(milliseconds: 150));
    exit(0);
  }

  Future<void> _quit() async {
    await quitApp();
  }

  static Future<void> _finishQuit() async {
    try {
      await trayManager.destroy();
    } catch (_) {
      // Best effort cleanup before the process exits.
    }
  }
}
