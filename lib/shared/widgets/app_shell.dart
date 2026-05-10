import 'dart:async';
import 'dart:io';

import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/constants/app_constants.dart';
import 'package:file_transfer_flutter/core/services/desktop_tray_service.dart';
import 'package:file_transfer_flutter/features/networking/presentation/providers/networking_agent_provider.dart';
import 'package:file_transfer_flutter/shared/providers/p2p_presence_providers.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const List<_BottomNavItemData> _destinations = <_BottomNavItemData>[
    _BottomNavItemData(
      icon: Icons.folder_open_outlined,
      selectedIcon: Icons.folder_open,
      label: '云文件',
    ),
    _BottomNavItemData(
      icon: Icons.sync_alt_outlined,
      selectedIcon: Icons.sync_alt,
      label: '实时传输',
    ),
    _BottomNavItemData(
      icon: Icons.hub_outlined,
      selectedIcon: Icons.hub,
      label: '虚拟组网',
    ),
    _BottomNavItemData(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: '设置',
    ),
  ];

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(networkingAgentRuntimeProvider.notifier).activate();
      if (ref.read(appConfigProvider).autoOnline) {
        _applyAutoOnline(enabled: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AppConfig>(appConfigProvider, (
      AppConfig? previous,
      AppConfig next,
    ) {
      if (previous?.autoOnline == next.autoOnline) {
        return;
      }

      if (next.autoOnline) {
        _applyAutoOnline(enabled: true);
      } else {
        _applyAutoOnline(enabled: false);
      }
    });

    final bool isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final Widget content = Column(
      children: <Widget>[
        if (isDesktop) const _DesktopTitleBar(),
        Expanded(child: widget.navigationShell),
      ],
    );

    return Scaffold(
      body: SafeArea(
        top: !isDesktop,
        bottom: false,
        child: content,
      ),
      bottomNavigationBar: _BottomNavigationBar(
        selectedIndex: widget.navigationShell.currentIndex,
        destinations: AppShell._destinations,
        onSelected: (int index) {
          widget.navigationShell.goBranch(
            index,
            initialLocation: index == widget.navigationShell.currentIndex,
          );
        },
      ),
    );
  }

  void _applyAutoOnline({required bool enabled}) {
    final P2pPresenceController notifier =
        ref.read(p2pPresenceProvider.notifier);
    final Future<void> action =
        enabled ? notifier.goOnline() : notifier.goOffline();
    unawaited(action.catchError((Object error, StackTrace stackTrace) {
      // Presence errors are reflected in the presence state when possible.
    }));
  }
}

class _BottomNavItemData {
  const _BottomNavItemData({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _BottomNavigationBar extends StatelessWidget {
  const _BottomNavigationBar({
    required this.selectedIndex,
    required this.destinations,
    required this.onSelected,
  });

  final int selectedIndex;
  final List<_BottomNavItemData> destinations;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Row(
            children: List<Widget>.generate(destinations.length, (int index) {
              final _BottomNavItemData item = destinations[index];
              return Expanded(
                child: _BottomNavigationButton(
                  data: item,
                  selected: index == selectedIndex,
                  onTap: () => onSelected(index),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _BottomNavigationButton extends StatefulWidget {
  const _BottomNavigationButton({
    required this.data,
    required this.selected,
    required this.onTap,
  });

  final _BottomNavItemData data;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_BottomNavigationButton> createState() =>
      _BottomNavigationButtonState();
}

class _BottomNavigationButtonState extends State<_BottomNavigationButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool highlighted = widget.selected || _hovered;
    final Color foreground = widget.selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final Color background = widget.selected
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.9)
        : theme.colorScheme.primary.withValues(alpha: 0.08);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: highlighted ? background : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    widget.selected
                        ? widget.data.selectedIcon
                        : widget.data.icon,
                    color: foreground,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.data.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: foreground,
                      fontWeight:
                          widget.selected ? FontWeight.w800 : FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppShellBranchContainer extends StatefulWidget {
  const AppShellBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  State<AppShellBranchContainer> createState() =>
      _AppShellBranchContainerState();
}

class _AppShellBranchContainerState extends State<AppShellBranchContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _transitionDuration,
  );
  late final Animation<double> _animation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  int? _previousIndex;
  late int _activeIndex = widget.currentIndex;
  int _direction = 1;

  Duration get _transitionDuration {
    final bool isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return Duration(milliseconds: isDesktop ? 260 : 320);
  }

  @override
  void didUpdateWidget(covariant AppShellBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.currentIndex == widget.currentIndex) {
      return;
    }

    _previousIndex = oldWidget.currentIndex;
    _activeIndex = widget.currentIndex;
    _direction = widget.currentIndex > oldWidget.currentIndex ? 1 : -1;
    _controller
      ..duration = _transitionDuration
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isAnimating = _controller.isAnimating &&
        _previousIndex != null &&
        _previousIndex != _activeIndex;

    return ClipRect(
      child: AnimatedBuilder(
        animation: _animation,
        builder: (BuildContext context, Widget? child) {
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              for (int index = 0; index < widget.children.length; index++)
                _buildBranch(index, widget.children[index], isAnimating),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBranch(int index, Widget child, bool isAnimating) {
    final bool isCurrent = index == _activeIndex;
    final bool isPrevious = isAnimating && index == _previousIndex;
    final bool shouldShow = isCurrent || isPrevious;

    if (!shouldShow) {
      return Offstage(
        offstage: true,
        child: TickerMode(enabled: false, child: child),
      );
    }

    final Offset offset;
    if (isPrevious) {
      offset = Offset(-_direction * _animation.value, 0);
    } else if (isAnimating) {
      offset = Offset(_direction * (1 - _animation.value), 0);
    } else {
      offset = Offset.zero;
    }

    return IgnorePointer(
      ignoring: !isCurrent,
      child: TickerMode(
        enabled: isCurrent,
        child: FractionalTranslation(
          translation: offset,
          child: child,
        ),
      ),
    );
  }
}

class _DesktopTitleBar extends ConsumerWidget {
  const _DesktopTitleBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: DragToMoveArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.35,
                            ),
                          ),
                          borderRadius: BorderRadius.circular(10),
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.08,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Stack(
                          alignment: Alignment.center,
                          children: <Widget>[
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: theme.colorScheme.primary,
                                  width: 1.6,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            Positioned(
                              right: 6,
                              bottom: 6,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(2.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          AppConstants.appName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w400,
                            letterSpacing: 0.2,
                            color: const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _TitleBarButton(
              icon: Icons.remove_rounded,
              tooltip: '\u6700\u5c0f\u5316',
              onPressed: () async {
                await windowManager.minimize();
              },
            ),
            _TitleBarButton(
              icon: Icons.crop_square_rounded,
              tooltip: '\u6700\u5927\u5316',
              onPressed: () async {
                final bool isMaximized = await windowManager.isMaximized();
                if (isMaximized) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
            ),
            _TitleBarButton(
              icon: Icons.close_rounded,
              tooltip: '\u5173\u95ed',
              isClose: true,
              onPressed: () async {
                if (Platform.isWindows) {
                  final bool minimizeToTray =
                      ref.read(appConfigProvider).minimizeToTrayOnClose;
                  if (minimizeToTray) {
                    await DesktopTrayService.hideToTray();
                  } else {
                    await DesktopTrayService.quitApp();
                  }
                  return;
                }
                await windowManager.close();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TitleBarButton extends StatefulWidget {
  const _TitleBarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isClose = false,
  });

  final IconData icon;
  final String tooltip;
  final Future<void> Function() onPressed;
  final bool isClose;

  @override
  State<_TitleBarButton> createState() => _TitleBarButtonState();
}

class _TitleBarButtonState extends State<_TitleBarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color backgroundColor;
    final Color foregroundColor;

    if (_hovered && widget.isClose) {
      backgroundColor = const Color(0xFFE5484D);
      foregroundColor = Colors.white;
    } else if (_hovered) {
      backgroundColor = theme.colorScheme.surfaceContainerHighest;
      foregroundColor = theme.colorScheme.onSurface;
    } else {
      backgroundColor = Colors.transparent;
      foregroundColor = theme.colorScheme.onSurface;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: widget.tooltip,
        child: InkWell(
          onTap: () async {
            await widget.onPressed();
          },
          child: Container(
            width: 46,
            height: 60,
            color: backgroundColor,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 18,
              color: foregroundColor,
            ),
          ),
        ),
      ),
    );
  }
}
