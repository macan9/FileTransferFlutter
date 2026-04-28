import 'dart:async';
import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

class WindowLaunchOptions {
  const WindowLaunchOptions({
    required this.defaultSize,
    required this.minimumSize,
    this.restoredBounds,
    this.startMaximized = false,
  });

  final Size defaultSize;
  final Size minimumSize;
  final Rect? restoredBounds;
  final bool startMaximized;

  WindowOptions toWindowOptions() {
    return WindowOptions(
      size: restoredBounds?.size ?? defaultSize,
      minimumSize: minimumSize,
      center: restoredBounds == null,
    );
  }
}

class WindowStateService with WindowListener {
  WindowStateService._(this._prefs);

  static const double _invalidMinimizedCoordinate = -10000;
  static const String _widthKey = 'window.width';
  static const String _heightKey = 'window.height';
  static const String _xKey = 'window.x';
  static const String _yKey = 'window.y';
  static const String _maximizedKey = 'window.maximized';

  final SharedPreferences _prefs;
  Timer? _saveTimer;

  static Future<WindowStateService> create() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return WindowStateService._(prefs);
  }

  WindowLaunchOptions getLaunchOptions({
    required Size defaultSize,
    required Size minimumSize,
  }) {
    final double? width = _prefs.getDouble(_widthKey);
    final double? height = _prefs.getDouble(_heightKey);
    final double? x = _prefs.getDouble(_xKey);
    final double? y = _prefs.getDouble(_yKey);
    final bool startMaximized = _prefs.getBool(_maximizedKey) ?? false;

    Rect? restoredBounds;
    if (width != null && height != null && x != null && y != null) {
      final Rect candidate = Rect.fromLTWH(x, y, width, height);
      if (_isRestorableBounds(candidate, minimumSize)) {
        restoredBounds = candidate;
      }
    }

    return WindowLaunchOptions(
      defaultSize: defaultSize,
      minimumSize: minimumSize,
      restoredBounds: restoredBounds,
      startMaximized: startMaximized,
    );
  }

  void attach() {
    windowManager.addListener(this);
  }

  Future<void> dispose() async {
    _saveTimer?.cancel();
    windowManager.removeListener(this);
    await saveNow();
  }

  Future<void> restoreAfterShow(WindowLaunchOptions options) async {
    if (options.restoredBounds != null) {
      await windowManager.setBounds(options.restoredBounds);
    }

    if (options.startMaximized) {
      await windowManager.maximize();
    }
  }

  @override
  void onWindowMoved() {
    _scheduleSave();
  }

  @override
  void onWindowResized() {
    _scheduleSave();
  }

  @override
  void onWindowMaximize() {
    _scheduleSave();
  }

  @override
  void onWindowUnmaximize() {
    _scheduleSave();
  }

  @override
  void onWindowClose() {
    unawaited(saveNow());
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(saveNow());
    });
  }

  Future<void> saveNow() async {
    final bool isMaximized = await windowManager.isMaximized();
    await _prefs.setBool(_maximizedKey, isMaximized);

    if (isMaximized || await windowManager.isMinimized()) {
      return;
    }

    final Rect bounds = await windowManager.getBounds();
    if (!_isRestorableBounds(bounds, const Size(1, 1))) {
      return;
    }

    await _prefs.setDouble(_widthKey, bounds.width);
    await _prefs.setDouble(_heightKey, bounds.height);
    await _prefs.setDouble(_xKey, bounds.left);
    await _prefs.setDouble(_yKey, bounds.top);
  }

  bool _isRestorableBounds(Rect bounds, Size minimumSize) {
    return bounds.width.isFinite &&
        bounds.height.isFinite &&
        bounds.left.isFinite &&
        bounds.top.isFinite &&
        bounds.width >= minimumSize.width &&
        bounds.height >= minimumSize.height &&
        bounds.left > _invalidMinimizedCoordinate &&
        bounds.top > _invalidMinimizedCoordinate;
  }
}
