import 'package:file_transfer_flutter/core/constants/app_constants.dart';
import 'package:file_transfer_flutter/app/router/app_router.dart';
import 'package:file_transfer_flutter/app/theme/app_theme.dart';
import 'package:file_transfer_flutter/features/networking/presentation/providers/networking_agent_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FileTransferApp extends ConsumerWidget {
  const FileTransferApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(networkingAgentRuntimeProvider);

    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      routerConfig: appRouter,
    );
  }
}
