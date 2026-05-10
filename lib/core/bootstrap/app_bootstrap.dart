import 'dart:io';

import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/config/services/app_config_defaults_resolver.dart';
import 'package:file_transfer_flutter/core/config/services/app_config_repository.dart';
import 'package:file_transfer_flutter/core/config/services/launch_environment_loader.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

class AppBootstrap {
  const AppBootstrap({
    required this.appConfigRepository,
    required this.initialConfig,
  });

  final AppConfigRepository appConfigRepository;
  final AppConfig initialConfig;

  static Future<AppBootstrap> initialize() async {
    final appSupportDirectory = await getApplicationSupportDirectory();
    final hiveDirectory =
        '${appSupportDirectory.path}${Platform.pathSeparator}hive';
    await Hive.initFlutter(hiveDirectory);
    const LaunchEnvironmentLoader launchEnvironmentLoader =
        LaunchEnvironmentLoader();
    final launchEnvironment = await launchEnvironmentLoader.load();

    final Box<dynamic> configBox = await Hive.openBox<dynamic>(
      HiveAppConfigRepository.boxName,
    );

    final HiveAppConfigRepository appConfigRepository = HiveAppConfigRepository(
      box: configBox,
      defaultsResolver: AppConfigDefaultsResolver(
        launchEnvironment: launchEnvironment,
      ),
      launchEnvironment: launchEnvironment,
    );

    final AppConfig initialConfig = await appConfigRepository.load();

    return AppBootstrap(
      appConfigRepository: appConfigRepository,
      initialConfig: initialConfig,
    );
  }
}
