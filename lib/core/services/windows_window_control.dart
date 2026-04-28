import 'dart:io';

import 'package:flutter/services.dart';

abstract final class WindowsWindowControl {
  static const MethodChannel _channel = MethodChannel(
    'file_transfer_flutter/window_control',
  );

  static Future<void> restore() async {
    if (!Platform.isWindows) {
      return;
    }
    await _channel.invokeMethod<void>('restore');
  }

  static Future<void> minimize() async {
    if (!Platform.isWindows) {
      return;
    }
    await _channel.invokeMethod<void>('minimize');
  }

  static Future<void> hide() async {
    if (!Platform.isWindows) {
      return;
    }
    await _channel.invokeMethod<void>('hide');
  }
}
