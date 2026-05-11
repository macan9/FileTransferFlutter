import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:file_transfer_flutter/app/app.dart';
import 'package:file_transfer_flutter/core/bootstrap/app_bootstrap.dart';
import 'package:file_transfer_flutter/core/constants/app_constants.dart';
import 'package:file_transfer_flutter/core/services/desktop_tray_service.dart';
import 'package:file_transfer_flutter/core/services/window_state_service.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _writeStartupLog('main.start');
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    unawaited(
      _writeStartupLog(
        'flutter_error',
        fields: <String, Object?>{
          'exception': details.exceptionAsString(),
          'library': details.library,
          'context': details.context?.toDescription(),
        },
      ),
    );
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    unawaited(
      _writeStartupLog(
        'platform_error',
        fields: <String, Object?>{
          'error': error,
          'stackTrace': stackTrace,
        },
      ),
    );
    return false;
  };

  late final AppBootstrap bootstrap;
  try {
    bootstrap = await AppBootstrap.initialize();
  } catch (error, stackTrace) {
    await _writeStartupLog(
      'main.bootstrap_failed',
      fields: <String, Object?>{
        'error': error,
        'stackTrace': stackTrace,
      },
    );
    runApp(
      StartupFailureApp(
        error: error.toString(),
        details: '应用启动失败。请关闭其他已打开的调试版/发布版窗口后重试，'
            '并查看 startup.log。',
      ),
    );
    return;
  }
  await _writeStartupLog('main.bootstrap_ready');

  if (!_isDesktopPlatform) {
    await _writeStartupLog('main.non_desktop_runapp');
    runApp(
      ProviderScope(
        overrides: <Override>[
          appConfigRepositoryProvider.overrideWithValue(
            bootstrap.appConfigRepository,
          ),
          initialAppConfigProvider.overrideWithValue(bootstrap.initialConfig),
        ],
        child: const FileTransferApp(),
      ),
    );
    return;
  }

  await windowManager.ensureInitialized();
  await _writeStartupLog('main.window_manager_ready');

  const Size defaultWindowSize = Size(680, 780);
  const Size minimumWindowSize = Size(300, 350);

  final WindowStateService windowStateService =
      await WindowStateService.create();
  final WindowLaunchOptions launchOptions = windowStateService.getLaunchOptions(
    defaultSize: defaultWindowSize,
    minimumSize: minimumWindowSize,
  );

  final WindowOptions baseWindowOptions = launchOptions.toWindowOptions();
  final WindowOptions windowOptions = WindowOptions(
    size: baseWindowOptions.size,
    minimumSize: baseWindowOptions.minimumSize,
    center: baseWindowOptions.center,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await _writeStartupLog('window.waitUntilReadyToShow.begin');
    windowStateService.attach();
    await windowStateService.restoreAfterShow(launchOptions);
    await windowManager.setTitle(AppConstants.appName);
    await windowManager.show();
    await windowManager.focus();
    await _writeStartupLog('window.waitUntilReadyToShow.end');
  });

  await _writeStartupLog('main.runapp.before');
  runApp(
    ProviderScope(
      overrides: <Override>[
        appConfigRepositoryProvider.overrideWithValue(
          bootstrap.appConfigRepository,
        ),
        initialAppConfigProvider.overrideWithValue(bootstrap.initialConfig),
      ],
      child: const FileTransferApp(),
    ),
  );
  await _writeStartupLog('main.runapp.after');

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_writeStartupLog('main.first_frame'));
    unawaited(_initializeDesktopTraySafely());
  });
}

bool get _isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> _initializeDesktopTraySafely() async {
  try {
    await _writeStartupLog('tray.initialize.begin');
    await DesktopTrayService.initialize();
    await _writeStartupLog('tray.initialize.end');
  } catch (error, stackTrace) {
    await _writeStartupLog(
      'tray.initialize.error',
      fields: <String, Object?>{
        'error': error,
        'stackTrace': stackTrace,
      },
    );
    // Keep desktop-only initialization failures from blocking the UI.
  }
}

Future<void> _writeStartupLog(
  String event, {
  Map<String, Object?> fields = const <String, Object?>{},
}) async {
  try {
    final Directory baseDirectory = await _resolveStartupLogDirectory();
    final File file = File(
      '${baseDirectory.path}${Platform.pathSeparator}startup.log',
    );
    final StringBuffer buffer = StringBuffer()
      ..write(DateTime.now().toIso8601String())
      ..write(' event=')
      ..write(event);
    final List<String> keys = fields.keys.toList(growable: false)..sort();
    for (final String key in keys) {
      buffer
        ..write(' ')
        ..write(key)
        ..write('=')
        ..write(_normalizeStartupLogValue(fields[key]));
    }
    buffer.writeln();
    await file.writeAsString(
      buffer.toString(),
      mode: FileMode.append,
      encoding: utf8,
      flush: true,
    );
  } catch (_) {
    // Startup logging must never interrupt app launch.
  }
}

Future<Directory> _resolveStartupLogDirectory() async {
  if (Platform.isWindows) {
    final String? appData = Platform.environment['APPDATA'];
    if (appData != null && appData.trim().isNotEmpty) {
      final Directory directory = Directory(
        '$appData${Platform.pathSeparator}com.example${Platform.pathSeparator}${AppConstants.appName}${Platform.pathSeparator}logs',
      );
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      return directory;
    }
  }

  final Directory fallback = Directory(
    '${Directory.current.path}${Platform.pathSeparator}logs',
  );
  if (!await fallback.exists()) {
    await fallback.create(recursive: true);
  }
  return fallback;
}

String _normalizeStartupLogValue(Object? value) {
  if (value == null) {
    return '-';
  }
  return value
      .toString()
      .trim()
      .replaceAll('\\', '\\\\')
      .replaceAll('\r', r'\r')
      .replaceAll('\n', r'\n')
      .replaceAll(' ', '_');
}

class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({
    super.key,
    required this.error,
    required this.details,
  });

  final String error;
  final String details;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF7F8FB),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        '启动失败',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1F2937),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        details,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: Color(0xFF4B5563),
                        ),
                      ),
                      const SizedBox(height: 20),
                      SelectableText(
                        error,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: Color(0xFFB42318),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
