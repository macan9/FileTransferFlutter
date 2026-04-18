import 'package:file_transfer_flutter/app/router/app_route_names.dart';
import 'package:file_transfer_flutter/features/files/presentation/pages/files_page.dart';
import 'package:file_transfer_flutter/features/settings/presentation/pages/settings_page.dart';
import 'package:file_transfer_flutter/features/transfers/presentation/pages/transfers_page.dart';
import 'package:file_transfer_flutter/shared/widgets/app_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/files',
  routes: <RouteBase>[
    _buildRootShellRoute(),
  ],
);

RouteBase _buildRootShellRoute() {
  return _buildPlatformShellRoute(
    builder: _buildAppShell,
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
  );
}

Widget _buildAppShell(
  BuildContext context,
  GoRouterState state,
  StatefulNavigationShell navigationShell,
) {
  return AppShell(navigationShell: navigationShell);
}

RouteBase _buildPlatformShellRoute({
  required StatefulShellRouteBuilder builder,
  required List<StatefulShellBranch> branches,
}) {
  if (kIsWeb) {
    return StatefulShellRoute.indexedStack(
      builder: builder,
      branches: branches,
    );
  }

  return StatefulShellRoute(
    builder: builder,
    navigatorContainerBuilder: (
      BuildContext context,
      StatefulNavigationShell navigationShell,
      List<Widget> children,
    ) {
      return AppShellBranchContainer(
        currentIndex: navigationShell.currentIndex,
        children: children,
      );
    },
    branches: branches,
  );
}
