import 'dart:io';

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
  final AppBootstrap bootstrap = await AppBootstrap.initialize();

  if (!_isDesktopPlatform) {
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

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    windowStateService.attach();
    await windowStateService.restoreAfterShow(launchOptions);
    await windowManager.setTitle(AppConstants.appName);
  });

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

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await windowManager.show();
    await windowManager.focus();
  });

  await DesktopTrayService.initialize();
}

bool get _isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;
