import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class NetworkingDebugLog {
  NetworkingDebugLog._();

  static Future<void> _pending = Future<void>.value();
  static String? _cachedPath;

  static Future<void> write(
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    _pending = _pending.then((_) => _append(event, fields: fields));
    return _pending;
  }

  static Future<String> path() async {
    if (_cachedPath != null) {
      return _cachedPath!;
    }
    final Directory baseDirectory = await getApplicationSupportDirectory();
    final Directory logDirectory = Directory(
      '${baseDirectory.path}${Platform.pathSeparator}logs',
    );
    if (!await logDirectory.exists()) {
      await logDirectory.create(recursive: true);
    }
    _cachedPath =
        '${logDirectory.path}${Platform.pathSeparator}networking_ui.log';
    return _cachedPath!;
  }

  static Future<void> _append(
    String event, {
    required Map<String, Object?> fields,
  }) async {
    try {
      final String logPath = await path();
      final File file = File(logPath);
      final StringBuffer buffer = StringBuffer()
        ..write(DateTime.now().toIso8601String())
        ..write(' event=')
        ..write(_normalize(event));
      final List<String> keys = fields.keys.toList(growable: false)..sort();
      for (final String key in keys) {
        buffer
          ..write(' ')
          ..write(key)
          ..write('=')
          ..write(_normalize(fields[key]));
      }
      buffer.writeln();
      await file.writeAsString(
        buffer.toString(),
        mode: FileMode.append,
        encoding: utf8,
        flush: true,
      );
    } catch (_) {}
  }

  static String _normalize(Object? value) {
    if (value == null) {
      return '-';
    }
    final String text = value.toString().trim();
    if (text.isEmpty) {
      return '-';
    }
    return text
        .replaceAll('\\', '\\\\')
        .replaceAll('\r', r'\r')
        .replaceAll('\n', r'\n')
        .replaceAll(' ', '_');
  }
}
