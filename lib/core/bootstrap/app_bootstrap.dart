import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/config/services/app_config_defaults_resolver.dart';
import 'package:file_transfer_flutter/core/config/services/app_config_repository.dart';
import 'package:hive_flutter/hive_flutter.dart';

class AppBootstrap {
  const AppBootstrap({
    required this.appConfigRepository,
    required this.initialConfig,
  });

  final AppConfigRepository appConfigRepository;
  final AppConfig initialConfig;

  static Future<AppBootstrap> initialize() async {
    await Hive.initFlutter();

    final Box<dynamic> configBox = await Hive.openBox<dynamic>(
      HiveAppConfigRepository.boxName,
    );

    final HiveAppConfigRepository appConfigRepository = HiveAppConfigRepository(
      box: configBox,
      defaultsResolver: AppConfigDefaultsResolver(),
    );

    final AppConfig initialConfig = await appConfigRepository.load();

    return AppBootstrap(
      appConfigRepository: appConfigRepository,
      initialConfig: initialConfig,
    );
  }
}
