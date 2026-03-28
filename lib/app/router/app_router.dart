import 'package:file_transfer_flutter/app/router/app_route_names.dart';
import 'package:file_transfer_flutter/features/files/presentation/pages/files_page.dart';
import 'package:file_transfer_flutter/features/settings/presentation/pages/settings_page.dart';
import 'package:file_transfer_flutter/features/transfers/presentation/pages/transfers_page.dart';
import 'package:file_transfer_flutter/shared/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/files',
  routes: <RouteBase>[
    StatefulShellRoute.indexedStack(
      builder: (
        BuildContext context,
        GoRouterState state,
        StatefulNavigationShell navigationShell,
      ) {
        return AppShell(navigationShell: navigationShell);
      },
      branches: <StatefulShellBranch>[
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/files',
              name: AppRouteNames.files,
              builder: (BuildContext context, GoRouterState state) {
                return const FilesPage();
              },
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/transfers',
              name: AppRouteNames.transfers,
              builder: (BuildContext context, GoRouterState state) {
                return const TransfersPage();
              },
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/settings',
              name: AppRouteNames.settings,
              builder: (BuildContext context, GoRouterState state) {
                return const SettingsPage();
              },
            ),
          ],
        ),
      ],
    ),
  ],
);
