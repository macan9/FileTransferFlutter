import 'package:file_transfer_flutter/core/constants/app_constants.dart';
import 'package:file_transfer_flutter/app/router/app_router.dart';
import 'package:file_transfer_flutter/app/theme/app_theme.dart';
import 'package:flutter/material.dart';

class FileTransferApp extends StatelessWidget {
  const FileTransferApp({super.key});

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
