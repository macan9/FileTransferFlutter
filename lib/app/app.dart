import 'package:file_transfer_flutter/core/constants/app_constants.dart';
import 'package:file_transfer_flutter/app/router/app_router.dart';
import 'package:file_transfer_flutter/app/theme/app_theme.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FileTransferApp extends ConsumerStatefulWidget {
  const FileTransferApp({super.key});

  @override
  ConsumerState<FileTransferApp> createState() => _FileTransferAppState();
}

class _FileTransferAppState extends ConsumerState<FileTransferApp> {
  @override
  void reassemble() {
    super.reassemble();
    ref.read(appConfigProvider.notifier).reload();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      routerConfig: appRouter,
    );
  }
}
