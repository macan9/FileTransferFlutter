import 'dart:async';

import 'package:file_transfer_flutter/app/router/app_route_names.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/managed_network.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/private_network_creation_result.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/models/zerotier_adapter_bridge_status.dart';
import 'package:file_transfer_flutter/core/models/zerotier_network_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_event.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_status.dart';
import 'package:file_transfer_flutter/features/networking/presentation/providers/networking_agent_provider.dart';
import 'package:file_transfer_flutter/features/networking/presentation/providers/networking_providers.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:file_transfer_flutter/shared/widgets/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class NetworkingPage extends ConsumerStatefulWidget {
  const NetworkingPage({super.key});

  @override
  ConsumerState<NetworkingPage> createState() => _NetworkingPageState();
}

enum NetworkingSection { agent, runtime, alignment, localNetworks }

class NetworkingSectionPage extends ConsumerWidget {
  const NetworkingSectionPage({
    super.key,
    required this.section,
  });

  final NetworkingSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppConfig config = ref.watch(appConfigProvider);
    final AsyncValue<NetworkingDashboardState> networkingAsync =
        ref.watch(networkingProvider);
    final NetworkingDashboardState dashboard =
        networkingAsync.valueOrNull ?? const NetworkingDashboardState.initial();
    final NetworkingAgentRuntimeState agentState =
        ref.watch(networkingAgentRuntimeProvider);
    final ZeroTierRuntimeStatus runtimeStatus = agentState.runtimeStatus;
    final bool isRegistered = config.agentToken.trim().isNotEmpty &&
        config.zeroTierNodeId.trim().isNotEmpty &&
        config.deviceId.trim().isNotEmpty;

    final String title;
    final Widget child;
    switch (section) {
      case NetworkingSection.agent:
        title = 'Agent 实况';
        child = _HeroStatusCard(
          runtimeStatus: runtimeStatus,
          agentState: agentState,
          config: config,
          isRegistered: isRegistered,
          recentEvents: agentState.recentRuntimeEvents,
          lastError: agentState.lastError,
          onRefresh: () async {
            await ref
                .read(networkingAgentRuntimeProvider.notifier)
                .refreshNow();
            await ref.read(networkingProvider.notifier).refresh();
          },
          onCopyToken: config.agentToken.trim().isEmpty
              ? null
              : () async {
                  await Clipboard.setData(
                    ClipboardData(text: config.agentToken),
                  );
                  if (!context.mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制 Agent Token')),
                  );
                },
        );
      case NetworkingSection.runtime:
        title = '运行时事件';
        child = _RuntimeInsightCard(
          runtimeStatus: runtimeStatus,
          recentEvents: agentState.recentRuntimeEvents,
          lastError: agentState.lastError,
          onRefresh: () async {
            await ref
                .read(networkingAgentRuntimeProvider.notifier)
                .refreshNow();
          },
        );
      case NetworkingSection.alignment:
        title = '架构联动';
        child = _NetworkingAlignmentCard(
          defaultNetwork: dashboard.defaultNetwork,
          managedNetworks: dashboard.managedNetworks,
          deviceIdentity: dashboard.deviceIdentity,
          runtimeStatus: runtimeStatus,
        );
      case NetworkingSection.localNetworks:
        title = '本地网络';
        child = _LocalNetworksCard(
          currentDeviceId: config.deviceId,
          runtimeStatus: runtimeStatus,
          managedNetworks: dashboard.managedNetworks,
        );
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(networkingAgentRuntimeProvider.notifier).refreshNow();
          await ref.read(networkingProvider.notifier).refresh();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[child],
        ),
      ),
    );
  }
}

enum _PrivateNetworkingFlowState {
  idle,
  serverOrchestrating,
  localOrchestrating,
  success,
  closing,
}

enum _DefaultNetworkingUiState {
  idle,
  serverOrchestrating,
  localOrchestrating,
  awaitingAuthorization,
  success,
  closing,
}

class _NetworkingPageState extends ConsumerState<NetworkingPage> {
  late final TextEditingController _networkCodeController;
  ManagedNetwork? _createdPrivateNetwork;
  String? _generatedNetworkCode;
  String? _lastJoinedPrivateCode;
  _PrivateNetworkingFlowState _hostFlowState = _PrivateNetworkingFlowState.idle;
  _PrivateNetworkingFlowState _joinFlowState = _PrivateNetworkingFlowState.idle;
  _DefaultNetworkingUiState _defaultFlowState = _DefaultNetworkingUiState.idle;
  bool _hasDefaultNetworkingIntent = false;
  bool _isDefaultJoinTransitioning = false;
  bool _isDefaultLeaveTransitioning = false;
  DateTime? _defaultJoinTransitionStartedAt;
  int _selectedPrimaryTab = 0;
  int _selectedPrivateTab = 0;

  @override
  void initState() {
    super.initState();
    _networkCodeController = TextEditingController();
  }

  @override
  void dispose() {
    _networkCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<NetworkingAgentRuntimeState>(
      networkingAgentRuntimeProvider,
      (NetworkingAgentRuntimeState? previous,
          NetworkingAgentRuntimeState next) {
        final ZeroTierRuntimeEventType? nextEventType =
            next.lastRuntimeEvent?.type;
        final bool joinProgressObserved = next.hasActiveJoinSession ||
            next.activeNetworkActionType == 'join' ||
            nextEventType == ZeroTierRuntimeEventType.networkJoining ||
            nextEventType ==
                ZeroTierRuntimeEventType.networkWaitingAuthorization ||
            nextEventType == ZeroTierRuntimeEventType.ipAssigned ||
            nextEventType == ZeroTierRuntimeEventType.networkOnline ||
            nextEventType == ZeroTierRuntimeEventType.error;
        final bool leaveProgressObserved = next.hasActiveLeaveSession ||
            next.activeNetworkActionType == 'leave' ||
            nextEventType == ZeroTierRuntimeEventType.networkLeft ||
            nextEventType == ZeroTierRuntimeEventType.error;
        if (joinProgressObserved && _isDefaultJoinTransitioning && mounted) {
          setState(() {
            _isDefaultJoinTransitioning = false;
          });
        }
        if (leaveProgressObserved && _isDefaultLeaveTransitioning && mounted) {
          setState(() {
            _isDefaultLeaveTransitioning = false;
          });
        }
        final AppConfig currentConfig = ref.read(appConfigProvider);
        final NetworkingDashboardState currentDashboard =
            ref.read(networkingProvider).valueOrNull ??
                const NetworkingDashboardState.initial();
        final ManagedNetwork? currentDefaultNetwork =
            currentDashboard.defaultNetwork;
        ZeroTierNetworkState? currentDefaultLocalState;
        final String currentDefaultNetworkId =
            currentDefaultNetwork?.zeroTierNetworkId?.trim().toLowerCase() ??
                '';
        if (currentDefaultNetworkId.isNotEmpty) {
          for (final ZeroTierNetworkState state
              in next.runtimeStatus.joinedNetworks) {
            if (state.networkId.trim().toLowerCase() ==
                currentDefaultNetworkId) {
              currentDefaultLocalState = state;
              break;
            }
          }
        }
        final String? currentDefaultManagedStatus = _currentMembershipStatus(
          currentDefaultNetwork,
          currentConfig.deviceId,
        );
        final bool currentDefaultAccepted =
            _isAcceptedMembershipStatus(currentDefaultManagedStatus);
        final bool currentDefaultOnline = currentDefaultNetwork != null &&
            _isManagedNetworkOnline(
              network: currentDefaultNetwork,
              currentDeviceId: currentConfig.deviceId,
              runtimeStatus: next.runtimeStatus,
            );
        if (_hasDefaultNetworkingIntent &&
            _defaultFlowState != _DefaultNetworkingUiState.closing &&
            mounted) {
          if (currentDefaultOnline) {
            setState(() {
              _defaultFlowState = _DefaultNetworkingUiState.success;
            });
          } else if (_isAuthorizationPendingLocalNetwork(
              currentDefaultLocalState)) {
            setState(() {
              _defaultFlowState =
                  _DefaultNetworkingUiState.awaitingAuthorization;
            });
          } else if ((joinProgressObserved || currentDefaultAccepted) &&
              _defaultFlowState ==
                  _DefaultNetworkingUiState.serverOrchestrating) {
            setState(() {
              _defaultFlowState = _DefaultNetworkingUiState.localOrchestrating;
            });
          }
        } else if (!_hasDefaultNetworkingIntent &&
            _defaultFlowState == _DefaultNetworkingUiState.success &&
            !currentDefaultOnline &&
            mounted) {
          setState(() {
            _defaultFlowState = _DefaultNetworkingUiState.idle;
          });
        }
        final List<ManagedNetwork> currentPrivateNetworks = currentDashboard
            .managedNetworks
            .where((ManagedNetwork network) => network.isPrivate)
            .toList(growable: false);
        final ManagedNetwork? hostedNetwork = _findManagedNetworkById(
              currentPrivateNetworks,
              _createdPrivateNetwork?.id,
            ) ??
            _createdPrivateNetwork;
        final bool hostedPrivateOnline = hostedNetwork != null &&
            _isManagedNetworkOnline(
              network: hostedNetwork,
              currentDeviceId: currentConfig.deviceId,
              runtimeStatus: next.runtimeStatus,
            );
        final ManagedNetwork? joinedNetwork = _findManagedNetworkByInviteCode(
          currentPrivateNetworks,
          _lastJoinedPrivateCode,
        );
        final bool joinedPrivateOnline = joinedNetwork != null &&
            _isManagedNetworkOnline(
              network: joinedNetwork,
              currentDeviceId: currentConfig.deviceId,
              runtimeStatus: next.runtimeStatus,
            );
        final ZeroTierRuntimeEventType? eventType = next.lastRuntimeEvent?.type;
        if (_joinFlowState == _PrivateNetworkingFlowState.serverOrchestrating &&
            (eventType == ZeroTierRuntimeEventType.networkJoining ||
                eventType ==
                    ZeroTierRuntimeEventType.networkWaitingAuthorization ||
                eventType == ZeroTierRuntimeEventType.ipAssigned)) {
          setState(() {
            _joinFlowState = _PrivateNetworkingFlowState.localOrchestrating;
          });
        }
        if (joinedPrivateOnline &&
            _joinFlowState != _PrivateNetworkingFlowState.success &&
            mounted) {
          setState(() {
            _joinFlowState = _PrivateNetworkingFlowState.success;
          });
        }
        if (!joinedPrivateOnline &&
            _joinFlowState == _PrivateNetworkingFlowState.success &&
            (_lastJoinedPrivateCode?.trim().isEmpty ?? true) &&
            mounted) {
          setState(() {
            _joinFlowState = _PrivateNetworkingFlowState.idle;
          });
        }
        if (_hostFlowState == _PrivateNetworkingFlowState.localOrchestrating &&
            hostedPrivateOnline &&
            mounted) {
          setState(() {
            _hostFlowState = _PrivateNetworkingFlowState.success;
          });
        }
        final ZeroTierRuntimeEvent? nextEvent = next.lastRuntimeEvent;
        if (nextEvent != null && nextEvent != previous?.lastRuntimeEvent) {
          _showPageMessage(_eventMessage(nextEvent));
        }
        final String? nextError = next.lastError;
        if (nextError != null &&
            nextError.trim().isNotEmpty &&
            nextError != previous?.lastError) {
          _showPageMessage(nextError);
        }
      },
    );

    final AppConfig config = ref.watch(appConfigProvider);
    final AsyncValue<NetworkingDashboardState> networkingAsync =
        ref.watch(networkingProvider);
    final NetworkingDashboardState dashboard =
        networkingAsync.valueOrNull ?? const NetworkingDashboardState.initial();
    final NetworkingAgentRuntimeState agentState =
        ref.watch(networkingAgentRuntimeProvider);
    final ZeroTierRuntimeStatus runtimeStatus = agentState.runtimeStatus;
    final bool isLocalReady = agentState.isLocalReady;
    final bool isPrivateNetworkingBusy =
        dashboard.activeAction == 'create-private-network' ||
            dashboard.activeAction == 'join-by-invite-code';
    final bool hasPrivateFlowContext =
        _hostFlowState != _PrivateNetworkingFlowState.idle ||
            _joinFlowState != _PrivateNetworkingFlowState.idle;
    final bool defaultLockedByPrivate =
        hasPrivateFlowContext || isPrivateNetworkingBusy;
    final bool privateLockedByDefault = _isDefaultNetworkLocked(
      defaultNetwork: dashboard.defaultNetwork,
      currentDeviceId: config.deviceId,
      runtimeStatus: runtimeStatus,
      agentState: agentState,
    );

    return Column(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x120F172A),
                blurRadius: 14,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Align(
            alignment: Alignment.center,
            child: FractionallySizedBox(
              widthFactor: 5 / 6,
              child: _PrimaryTabSelector(
                selectedIndex: _selectedPrimaryTab,
                labels: const <String>['默认网络', '私有组网'],
                dense: true,
                onSelected: (int index) {
                  setState(() {
                    _selectedPrimaryTab = index;
                  });
                },
              ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refreshAll,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: <Widget>[
                _TopStatusPills(
                  runtimeStatus: runtimeStatus,
                  agentState: agentState,
                ),
                const SizedBox(height: 14),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: _selectedPrimaryTab == 0
                      ? _OneClickNetworkingTab(
                          key: const ValueKey<String>('default-networking'),
                          actionOrbKey:
                              const Key('networking-default-action-orb'),
                          defaultNetwork: dashboard.defaultNetwork,
                          currentDeviceId: config.deviceId,
                          agentState: agentState,
                          isBusy: dashboard.isSubmitting,
                          activeAction: dashboard.activeAction,
                          isLocalReady: isLocalReady,
                          runtimeStatus: runtimeStatus,
                          isExternallyLocked: defaultLockedByPrivate,
                          externalLockMessage: '当前已有私有组网任务进行中',
                          hasSessionJoinIntent: _hasDefaultNetworkingIntent,
                          isLocallyJoining: _isDefaultJoinTransitioning,
                          isLocallyLeaving: _isDefaultLeaveTransitioning,
                          uiFlowState: _defaultFlowState,
                          defaultJoinTransitionStartedAt:
                              _defaultJoinTransitionStartedAt,
                          onJoin: _joinDefaultNetwork,
                          onLeave: () =>
                              _leaveDefaultNetwork(dashboard.defaultNetwork),
                          onCopyIp: (String ip) => _copyToClipboard(
                            ip,
                            successMessage: '已复制虚拟 IP',
                          ),
                        )
                      : _PrivateNetworkingTab(
                          key: const ValueKey<String>('private-networking'),
                          joinOrbKey: const Key('networking-private-join-orb'),
                          hostOrbKey: const Key('networking-private-host-orb'),
                          codeController: _networkCodeController,
                          createdNetwork: _createdPrivateNetwork,
                          generatedCode: _generatedNetworkCode,
                          lastJoinedCode: _lastJoinedPrivateCode,
                          hostFlowState: _hostFlowState,
                          joinFlowState: _joinFlowState,
                          currentDeviceId: config.deviceId,
                          agentState: agentState,
                          isBusy: dashboard.isSubmitting,
                          activeAction: dashboard.activeAction,
                          isLocalReady: isLocalReady,
                          managedNetworks: dashboard.managedNetworks,
                          runtimeStatus: runtimeStatus,
                          selectedMode: _selectedPrivateTab,
                          isExternallyLocked: privateLockedByDefault,
                          externalLockMessage: '当前已有默认网络编排任务进行中',
                          onModeChanged: (int index) {
                            setState(() {
                              _selectedPrivateTab = index;
                            });
                          },
                          onJoinPressed: _joinByInviteCode,
                          onHostPressed: _createPrivateNetwork,
                          onLeavePressed: _leaveManagedNetwork,
                          onCopyValue: (String value, String message) =>
                              _copyToClipboard(
                            value,
                            successMessage: message,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        _SecondarySectionBar(
          onTapAgent: () => context.pushNamed(AppRouteNames.networkingAgent),
          onTapRuntime: () =>
              context.pushNamed(AppRouteNames.networkingRuntime),
          onTapAlignment: () =>
              context.pushNamed(AppRouteNames.networkingAlignment),
          onTapLocal: () => context.pushNamed(AppRouteNames.networkingLocal),
        ),
      ],
    );
  }

  Future<void> _refreshAll() async {
    await ref.read(networkingAgentRuntimeProvider.notifier).refreshNow();
    await ref.read(networkingProvider.notifier).refresh();
  }

  Future<void> _joinDefaultNetwork() async {
    final AppConfig readyConfig = ref.read(appConfigProvider);
    if (!_ensureRegistered(readyConfig)) {
      return;
    }

    try {
      if (mounted) {
        setState(() {
          _hasDefaultNetworkingIntent = true;
          _isDefaultJoinTransitioning = true;
          _isDefaultLeaveTransitioning = false;
          _defaultFlowState = _DefaultNetworkingUiState.serverOrchestrating;
          _defaultJoinTransitionStartedAt = DateTime.now();
        });
      }
      await ref
          .read(networkingProvider.notifier)
          .joinDefaultNetwork(deviceId: readyConfig.deviceId);
      if (!mounted) {
        return;
      }
      unawaited(ref.read(networkingAgentRuntimeProvider.notifier).refreshNow());
      unawaited(ref.read(networkingProvider.notifier).refresh());
      _showPageMessage('默认网络入网请求已提交，等待本机 Agent 执行 join。');
    } on RealtimeError catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isDefaultJoinTransitioning = false;
        _defaultFlowState = _DefaultNetworkingUiState.idle;
        _defaultJoinTransitionStartedAt = null;
      });
      _showPageMessage(error.message);
    }
  }

  Future<void> _leaveDefaultNetwork(
    ManagedNetwork? defaultNetwork,
  ) async {
    final String networkId = defaultNetwork?.zeroTierNetworkId?.trim() ?? '';
    if (networkId.isEmpty) {
      _showPageMessage('当前默认网络缺少 ZeroTier Network ID，无法取消组网。');
      return;
    }

    try {
      final AppConfig readyConfig = ref.read(appConfigProvider);
      if (!_ensureRegistered(readyConfig)) {
        return;
      }
      if (mounted) {
        setState(() {
          _isDefaultLeaveTransitioning = true;
          _isDefaultJoinTransitioning = false;
          _defaultFlowState = _DefaultNetworkingUiState.closing;
          _defaultJoinTransitionStartedAt = null;
        });
      }

      await ref.read(networkingProvider.notifier).leaveDefaultNetwork(
            deviceId: readyConfig.deviceId,
          );
      unawaited(ref.read(networkingAgentRuntimeProvider.notifier).refreshNow());
      await ref.read(networkingProvider.notifier).refresh();
      if (!mounted) {
        return;
      }
      setState(() {
        _hasDefaultNetworkingIntent = false;
        _isDefaultLeaveTransitioning = false;
        _defaultFlowState = _DefaultNetworkingUiState.idle;
        _defaultJoinTransitionStartedAt = null;
      });
      _showPageMessage('已取消默认网络组网。');
    } on RealtimeError catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isDefaultLeaveTransitioning = false;
        if (_hasDefaultNetworkingIntent) {
          _defaultFlowState = _DefaultNetworkingUiState.success;
        } else {
          _defaultFlowState = _DefaultNetworkingUiState.idle;
        }
        _defaultJoinTransitionStartedAt = null;
      });
      _showPageMessage(error.message);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showPageMessage('$error');
    }
  }

  Future<void> _joinByInviteCode() async {
    final AppConfig readyConfig = ref.read(appConfigProvider);
    if (!_ensureRegistered(readyConfig)) {
      return;
    }

    final String code = _networkCodeController.text.trim();
    if (code.isEmpty) {
      _showPageMessage('请先输入邀请码。');
      return;
    }
    if (code.length != 8) {
      _showPageMessage('请输入 8 位验证码。');
      return;
    }

    try {
      if (mounted) {
        setState(() {
          _hostFlowState = _PrivateNetworkingFlowState.idle;
          _lastJoinedPrivateCode = code;
          _joinFlowState = _PrivateNetworkingFlowState.serverOrchestrating;
          _selectedPrivateTab = 1;
        });
      }
      await ref.read(networkingProvider.notifier).joinByInviteCode(
            code: code,
            deviceId: readyConfig.deviceId,
          );
      if (mounted &&
          _joinFlowState == _PrivateNetworkingFlowState.serverOrchestrating) {
        setState(() {
          _joinFlowState = _PrivateNetworkingFlowState.localOrchestrating;
        });
      }
      unawaited(ref.read(networkingAgentRuntimeProvider.notifier).refreshNow());
      unawaited(ref.read(networkingProvider.notifier).refresh());
      if (!mounted) {
        return;
      }
      _showPageMessage('邀请码组网请求已提交，等待本机 Agent 执行 join。');
    } on RealtimeError catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _joinFlowState = _PrivateNetworkingFlowState.idle;
      });
      _showPageMessage(error.message);
    }
  }

  Future<void> _leaveManagedNetwork(ManagedNetwork? network) async {
    final String networkId = network?.id.trim() ?? '';
    if (networkId.isEmpty) {
      _showPageMessage('私有网络信息不完整，无法取消组网。');
      return;
    }

    final AppConfig readyConfig = ref.read(appConfigProvider);
    if (!_ensureRegistered(readyConfig)) {
      return;
    }

    final _PrivateNetworkingFlowState previousHostFlowState = _hostFlowState;
    final _PrivateNetworkingFlowState previousJoinFlowState = _joinFlowState;

    try {
      if (mounted) {
        setState(() {
          if (_selectedPrivateTab == 0) {
            _hostFlowState = _PrivateNetworkingFlowState.closing;
          } else {
            _joinFlowState = _PrivateNetworkingFlowState.closing;
          }
        });
      }
      await ref.read(networkingProvider.notifier).leaveManagedNetwork(
            networkId: networkId,
            deviceId: readyConfig.deviceId,
          );
      unawaited(ref.read(networkingAgentRuntimeProvider.notifier).refreshNow());
      await ref.read(networkingProvider.notifier).refresh();
      if (!mounted) {
        return;
      }
      setState(() {
        _createdPrivateNetwork = null;
        _generatedNetworkCode = null;
        _lastJoinedPrivateCode = null;
        _hostFlowState = _PrivateNetworkingFlowState.idle;
        _joinFlowState = _PrivateNetworkingFlowState.idle;
      });
      _showPageMessage('私有网络已断开。');
    } on RealtimeError catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _hostFlowState = previousHostFlowState;
        _joinFlowState = previousJoinFlowState;
      });
      _showPageMessage(error.message);
    }
  }

  Future<void> _createPrivateNetwork() async {
    final AppConfig readyConfig = ref.read(appConfigProvider);
    if (!_ensureRegistered(readyConfig)) {
      return;
    }

    final String name = _buildDefaultPrivateNetworkName(readyConfig);

    try {
      if (mounted) {
        setState(() {
          _selectedPrivateTab = 0;
          _hostFlowState = _PrivateNetworkingFlowState.serverOrchestrating;
          _joinFlowState = _PrivateNetworkingFlowState.idle;
          _lastJoinedPrivateCode = null;
        });
      }
      final PrivateNetworkCreationResult result =
          await ref.read(networkingServiceProvider).createPrivateNetwork(
                ownerDeviceId: readyConfig.deviceId,
                name: name,
              );
      if (!mounted) {
        return;
      }
      setState(() {
        _createdPrivateNetwork = result.network;
        _generatedNetworkCode = result.inviteCode.code;
        _lastJoinedPrivateCode = null;
        _hostFlowState = _PrivateNetworkingFlowState.localOrchestrating;
        _selectedPrivateTab = 0;
      });
      unawaited(ref.read(networkingAgentRuntimeProvider.notifier).refreshNow());
      unawaited(ref.read(networkingProvider.notifier).refresh());
      if (!mounted) {
        return;
      }
      _showPageMessage('私有网络已创建，邀请码 ${result.inviteCode.code} 已生成。');
    } on RealtimeError catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _hostFlowState = _PrivateNetworkingFlowState.idle;
      });
      _showPageMessage(error.message);
    }
  }

  bool _ensureRegistered(AppConfig config) {
    if (config.deviceId.trim().isEmpty ||
        config.zeroTierNodeId.trim().isEmpty ||
        config.agentToken.trim().isEmpty) {
      _showPageMessage('设备尚未完成自动注册，请先等待 ZeroTier 初始化和 bootstrap 完成。');
      return false;
    }
    return true;
  }

  Future<void> _copyToClipboard(
    String value, {
    required String successMessage,
  }) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    _showPageMessage(successMessage);
  }

  String _eventMessage(ZeroTierRuntimeEvent event) {
    final String networkSuffix =
        event.networkId == null ? '' : ' (${event.networkId})';
    final String defaultMessage = switch (event.type) {
      ZeroTierRuntimeEventType.environmentReady => 'Windows ZeroTier 环境已准备完成。',
      ZeroTierRuntimeEventType.permissionRequired => 'ZeroTier 需要额外权限或手动设置。',
      ZeroTierRuntimeEventType.nodeStarted => 'ZeroTier 节点已启动。',
      ZeroTierRuntimeEventType.nodeOnline => 'ZeroTier 节点已恢复在线。',
      ZeroTierRuntimeEventType.nodeOffline => 'ZeroTier 节点当前离线。',
      ZeroTierRuntimeEventType.nodeStopped => 'ZeroTier 节点已停止。',
      ZeroTierRuntimeEventType.networkJoining =>
        '正在加入 ZeroTier 网络$networkSuffix。',
      ZeroTierRuntimeEventType.networkWaitingAuthorization =>
        '网络$networkSuffix 仍在等待授权。',
      ZeroTierRuntimeEventType.networkOnline => '网络$networkSuffix 已在线。',
      ZeroTierRuntimeEventType.networkLeft => '已离开网络$networkSuffix。',
      ZeroTierRuntimeEventType.ipAssigned => '网络$networkSuffix 已分配托管地址。',
      ZeroTierRuntimeEventType.error => 'ZeroTier 运行时返回错误。',
    };
    return event.message?.trim().isNotEmpty == true
        ? event.message!
        : defaultMessage;
  }

  void _showPageMessage(String message) {
    if (!mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

class _HeroStatusCard extends StatelessWidget {
  const _HeroStatusCard({
    required this.runtimeStatus,
    required this.agentState,
    required this.config,
    required this.isRegistered,
    required this.recentEvents,
    required this.lastError,
    required this.onRefresh,
    required this.onCopyToken,
  });

  final ZeroTierRuntimeStatus runtimeStatus;
  final NetworkingAgentRuntimeState agentState;
  final AppConfig config;
  final bool isRegistered;
  final List<ZeroTierRuntimeEvent> recentEvents;
  final String? lastError;
  final Future<void> Function() onRefresh;
  final VoidCallback? onCopyToken;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final _RuntimeSignal signal = _resolveRuntimeSignal(
      runtimeStatus: runtimeStatus,
      recentEvents: recentEvents,
      lastError: lastError,
    );
    return SectionCard(
      title: 'ZeroTier Agent 实况',
      subtitle: '页面直接消费统一 ZeroTierFacade 与 provider 状态流，展示本机节点、网络与事件回流。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _RuntimeSignalBanner(signal: signal),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _InfoPill(label: '运行时', value: _serviceStateLabel(runtimeStatus)),
              _InfoPill(
                  label: 'libzt 节点', value: _nodeStateLabel(runtimeStatus)),
              _InfoPill(
                label: '注册状态',
                value: isRegistered ? '已注册' : '未注册',
              ),
              _InfoPill(
                label: '防火墙',
                value: runtimeStatus.permissionState.isFirewallSupported
                    ? '支持'
                    : '未知',
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: <Color>[Color(0xFFFFF3E7), Color(0xFFFFDFC3)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Wrap(
              runSpacing: 16,
              spacing: 24,
              children: <Widget>[
                _MetricBlock(
                  label: '节点 ID',
                  value: runtimeStatus.nodeId.isEmpty
                      ? '等待初始化'
                      : runtimeStatus.nodeId,
                ),
                _MetricBlock(
                  label: '运行时版本',
                  value: runtimeStatus.version ?? '等待回报',
                ),
                _MetricBlock(
                  label: '本地网络数',
                  value: '${runtimeStatus.joinedNetworks.length}',
                ),
                _MetricBlock(
                  label: '最近心跳',
                  value: _timeOrDash(agentState.lastHeartbeatAt),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _LabeledBlock(
            label: '设备 ID',
            value: config.deviceId.trim().isEmpty
                ? '等待 bootstrap'
                : config.deviceId,
          ),
          const SizedBox(height: 12),
          _LabeledBlock(
            label: 'Agent Token',
            value:
                config.agentToken.trim().isEmpty ? '尚未下发' : config.agentToken,
            action: onCopyToken == null
                ? null
                : IconButton(
                    tooltip: '复制 Agent Token',
                    onPressed: onCopyToken,
                    icon: const Icon(Icons.copy_rounded),
                  ),
          ),
          const SizedBox(height: 12),
          _LabeledBlock(
            label: '权限摘要',
            value: runtimeStatus.permissionState.summary ??
                'Windows libzt 运行时已接入。',
          ),
          const SizedBox(height: 12),
          _LabeledBlock(
            label: '最近命令',
            value: agentState.lastCommandSummary ?? '暂无',
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: () => onRefresh(),
              icon: const Icon(Icons.sync_rounded),
              label: Text(
                agentState.isBootstrapping || agentState.isPolling
                    ? '同步中...'
                    : '立即同步',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RuntimeInsightCard extends StatelessWidget {
  const _RuntimeInsightCard({
    required this.runtimeStatus,
    required this.recentEvents,
    required this.lastError,
    required this.onRefresh,
  });

  final ZeroTierRuntimeStatus runtimeStatus;
  final List<ZeroTierRuntimeEvent> recentEvents;
  final String? lastError;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final _RuntimeSignal signal = _resolveRuntimeSignal(
      runtimeStatus: runtimeStatus,
      recentEvents: recentEvents,
      lastError: lastError,
    );
    return SectionCard(
      title: '运行时事件回流',
      subtitle: '以下事件来自 Windows 原生 EventChannel，反映 libzt 节点生命周期与网络状态变化。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _InfoPill(label: '运行时', value: _serviceStateLabel(runtimeStatus)),
              _InfoPill(
                  label: 'libzt 节点', value: _nodeStateLabel(runtimeStatus)),
              _InfoPill(
                label: '最近更新',
                value: _timeOrDash(runtimeStatus.updatedAt),
              ),
              _InfoPill(
                label: '最近错误',
                value: runtimeStatus.lastError ?? '无',
              ),
              _InfoPill(label: '当前信号', value: signal.label),
            ],
          ),
          const SizedBox(height: 16),
          _AdapterBridgeCard(adapterBridge: runtimeStatus.adapterBridge),
          const SizedBox(height: 16),
          if (recentEvents.isEmpty)
            _EmptyStateBox(
              message: '当前还没有收到运行时事件。可以先点击“立即同步”，或发起一次入网联调。',
            )
          else
            Column(
              children: recentEvents
                  .map(
                    (ZeroTierRuntimeEvent event) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _RuntimeEventTile(event: event),
                    ),
                  )
                  .toList(),
            ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => onRefresh(),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('刷新运行时状态'),
          ),
        ],
      ),
    );
  }
}

class _AdapterBridgeCard extends StatelessWidget {
  const _AdapterBridgeCard({
    required this.adapterBridge,
  });

  final ZeroTierAdapterBridgeStatus adapterBridge;

  @override
  Widget build(BuildContext context) {
    final List<ZeroTierAdapterRecord> highlightedAdapters =
        adapterBridge.adapters
            .where(
              (ZeroTierAdapterRecord item) =>
                  item.isVirtual ||
                  item.matchesExpectedIp ||
                  item.isMountCandidate ||
                  item.hasExpectedRoute,
            )
            .toList(growable: false);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _InfoPill(
                label: '适配器探测',
                value: adapterBridge.initialized ? '就绪' : '等待中',
              ),
              _InfoPill(
                label: '虚拟适配器',
                value: adapterBridge.hasVirtualAdapter ? '已发现' : '缺失',
              ),
              _InfoPill(
                label: '挂载候选',
                value: adapterBridge.hasMountCandidate ? '已发现' : '缺失',
              ),
              _InfoPill(
                label: '目标 IP',
                value: adapterBridge.hasExpectedNetworkIp ? '已绑定' : '未绑定',
              ),
              _InfoPill(
                label: '目标路由',
                value: adapterBridge.hasExpectedRoute ? '已绑定' : '未绑定',
              ),
            ],
          ),
          if (adapterBridge.mountCandidateNames.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _LabeledBlock(
              label: '挂载候选列表',
              value: adapterBridge.mountCandidateNames.join(', '),
            ),
          ],
          if (adapterBridge.matchedAdapterNames.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _LabeledBlock(
              label: '匹配适配器',
              value: adapterBridge.matchedAdapterNames.join(', '),
            ),
          ],
          const SizedBox(height: 12),
          _LabeledBlock(
            label: '适配器摘要',
            value: adapterBridge.summary ?? '暂无适配器诊断信息。',
          ),
          if (highlightedAdapters.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            ...highlightedAdapters.map(
              (ZeroTierAdapterRecord adapter) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _LabeledBlock(
                  label: adapter.displayName,
                  value: 'status=${adapter.operStatus} up=${adapter.isUp} '
                      'virtual=${adapter.isVirtual} '
                      'mountCandidate=${adapter.isMountCandidate} '
                      'expectedIp=${adapter.matchesExpectedIp} '
                      'expectedRoute=${adapter.hasExpectedRoute} '
                      'driver=${adapter.driverKind} '
                      'media=${adapter.mediaStatus} '
                      'ifIndex=${adapter.ifIndex} '
                      'tapDevId=${adapter.tapDeviceInstanceId.isEmpty ? "-" : adapter.tapDeviceInstanceId} '
                      'tapCfgId=${adapter.tapNetCfgInstanceId.isEmpty ? "-" : adapter.tapNetCfgInstanceId} '
                      'ipv4=${adapter.ipv4Addresses.isEmpty ? "-" : adapter.ipv4Addresses.join(", ")}',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NetworkingAlignmentCard extends StatelessWidget {
  const _NetworkingAlignmentCard({
    required this.defaultNetwork,
    required this.managedNetworks,
    required this.deviceIdentity,
    required this.runtimeStatus,
  });

  final ManagedNetwork? defaultNetwork;
  final List<ManagedNetwork> managedNetworks;
  final NetworkDeviceIdentity? deviceIdentity;
  final ZeroTierRuntimeStatus runtimeStatus;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '架构联动状态',
      subtitle: '这里同时展示服务端编排层和本地 ZeroTier 运行时，方便校准状态映射是否一致。',
      child: Column(
        children: <Widget>[
          _CapabilityItem(
            tone: runtimeStatus.cliAvailable
                ? _CapabilityTone.ready
                : _CapabilityTone.warning,
            label: runtimeStatus.cliAvailable
                ? 'Windows libzt 运行时可用，节点 ID 与网络状态会通过统一接口回流。'
                : '当前 ZeroTier 运行时仍不可用，本机无法执行真实入网动作。',
          ),
          const SizedBox(height: 10),
          _CapabilityItem(
            tone: deviceIdentity == null
                ? _CapabilityTone.warning
                : _CapabilityTone.ready,
            label: deviceIdentity == null
                ? '设备还未完成服务端 bootstrap，Agent Token 与设备 ID 尚未就绪。'
                : '设备身份已建立：${deviceIdentity!.id} / ${deviceIdentity!.zeroTierNodeId}',
          ),
          const SizedBox(height: 10),
          _CapabilityItem(
            tone: defaultNetwork == null
                ? _CapabilityTone.warning
                : _CapabilityTone.info,
            label: defaultNetwork == null
                ? '默认网络信息尚未从服务端加载完成。'
                : '默认网络已加载：${defaultNetwork!.name} (${defaultNetwork!.status})',
          ),
          const SizedBox(height: 10),
          _CapabilityItem(
            tone: _CapabilityTone.info,
            label:
                '服务端编排网络 ${managedNetworks.length} 个，本地已知 ZeroTier 网络 ${runtimeStatus.joinedNetworks.length} 个。',
          ),
        ],
      ),
    );
  }
}

class _LocalNetworksCard extends StatelessWidget {
  const _LocalNetworksCard({
    required this.currentDeviceId,
    required this.runtimeStatus,
    required this.managedNetworks,
  });

  final String currentDeviceId;
  final ZeroTierRuntimeStatus runtimeStatus;
  final List<ManagedNetwork> managedNetworks;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '本地 ZeroTier 网络',
      subtitle: 'join/list/detail 已切到真实网络状态。这里优先展示本机运行时返回的网络与地址。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (runtimeStatus.joinedNetworks.isEmpty)
            const _EmptyStateBox(
              message: '本机还没有检测到已加入的 ZeroTier 网络。',
            )
          else
            Column(
              children: runtimeStatus.joinedNetworks
                  .map(
                    (ZeroTierNetworkState network) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _LocalNetworkCard(
                        currentDeviceId: currentDeviceId,
                        network: network,
                        managedNetwork:
                            _matchManagedNetwork(network, managedNetworks),
                      ),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }

  ManagedNetwork? _matchManagedNetwork(
    ZeroTierNetworkState network,
    List<ManagedNetwork> managedNetworks,
  ) {
    for (final ManagedNetwork managed in managedNetworks) {
      if (managed.zeroTierNetworkId?.trim().toLowerCase() ==
          network.networkId.trim().toLowerCase()) {
        return managed;
      }
    }
    return null;
  }
}

class _OneClickNetworkingTab extends StatelessWidget {
  const _OneClickNetworkingTab({
    super.key,
    required this.actionOrbKey,
    required this.defaultNetwork,
    required this.currentDeviceId,
    required this.agentState,
    required this.isBusy,
    required this.activeAction,
    required this.isLocalReady,
    required this.runtimeStatus,
    required this.isExternallyLocked,
    required this.externalLockMessage,
    required this.hasSessionJoinIntent,
    required this.isLocallyJoining,
    required this.isLocallyLeaving,
    required this.uiFlowState,
    required this.defaultJoinTransitionStartedAt,
    required this.onJoin,
    required this.onLeave,
    required this.onCopyIp,
  });

  final Key actionOrbKey;
  final ManagedNetwork? defaultNetwork;
  final String currentDeviceId;
  final NetworkingAgentRuntimeState agentState;
  final bool isBusy;
  final String? activeAction;
  final bool isLocalReady;
  final ZeroTierRuntimeStatus runtimeStatus;
  final bool isExternallyLocked;
  final String externalLockMessage;
  final bool hasSessionJoinIntent;
  final bool isLocallyJoining;
  final bool isLocallyLeaving;
  final _DefaultNetworkingUiState uiFlowState;
  final DateTime? defaultJoinTransitionStartedAt;
  final VoidCallback onJoin;
  final VoidCallback onLeave;
  final ValueChanged<String> onCopyIp;

  @override
  Widget build(BuildContext context) {
    final ZeroTierNetworkState? rawLocalState = defaultNetwork == null
        ? null
        : _findLocal(runtimeStatus, defaultNetwork!);
    final String transitionNetworkId =
        agentState.transitioningNetworkId?.trim().toLowerCase() ?? '';
    final String defaultNetworkId =
        defaultNetwork?.zeroTierNetworkId?.trim().toLowerCase() ?? '';
    final String? currentMembershipStatus =
        _currentMembershipStatus(defaultNetwork, currentDeviceId);
    final bool hasServiceAssignedIp =
        _hasCurrentServiceAssignedIp(defaultNetwork, currentDeviceId);
    final bool isMembershipRevoked =
        currentMembershipStatus?.trim().toLowerCase() == 'revoked';
    final ZeroTierNetworkState? localState =
        isMembershipRevoked && _isEffectivelyLeftLocalNetwork(rawLocalState)
            ? null
            : rawLocalState;
    final bool isMembershipAccepted =
        _isAcceptedMembershipStatus(currentMembershipStatus);
    final bool isSubmittingJoin = activeAction == 'join-default-network';
    final bool isSubmittingLeave = activeAction == 'leave-default-network';
    final bool hasActiveJoinSession = agentState.hasActiveJoinSession &&
        (agentState.activeNetworkActionNetworkId?.trim().toLowerCase() ?? '') ==
            defaultNetworkId;
    final bool hasActiveLeaveSession = agentState.hasActiveLeaveSession &&
        (agentState.activeNetworkActionNetworkId?.trim().toLowerCase() ?? '') ==
            defaultNetworkId;
    final bool isLocalAuthorizationPending =
        _isAuthorizationPendingLocalNetwork(localState);
    final bool isTransitionLocked = (agentState.isNetworkActionLocked ||
            isSubmittingLeave ||
            hasActiveLeaveSession ||
            isLocallyLeaving) &&
        (transitionNetworkId.isEmpty ||
            transitionNetworkId == defaultNetworkId);
    final bool hasLocalMapping = localState != null &&
        !isLocalAuthorizationPending &&
        _isLocalNetworkMounted(localState, hasServiceAssignedIp);
    final bool isClosing =
        isTransitionLocked || (isMembershipRevoked && localState != null);
    final bool isGrouped = !isMembershipRevoked &&
        hasLocalMapping &&
        (hasSessionJoinIntent ||
            isMembershipAccepted ||
            currentMembershipStatus?.trim().isNotEmpty == true);
    final bool shouldHoldJoinOrchestration = hasSessionJoinIntent &&
        defaultJoinTransitionStartedAt != null &&
        DateTime.now()
                .difference(defaultJoinTransitionStartedAt!)
                .inMilliseconds <
            900;
    final bool isOptimisticallyJoining = hasSessionJoinIntent &&
        (isBusy || isLocallyJoining) &&
        !isGrouped &&
        !isSubmittingLeave &&
        !hasActiveLeaveSession &&
        !isLocallyLeaving &&
        !isSubmittingJoin &&
        !hasActiveJoinSession;
    final bool effectiveGrouped = isGrouped && !shouldHoldJoinOrchestration;
    final bool isAwaitingAuthorization =
        !isClosing && isLocalAuthorizationPending;
    final bool effectiveSubmittingJoin = isSubmittingJoin ||
        isOptimisticallyJoining ||
        shouldHoldJoinOrchestration;
    final _DefaultNetworkFlowState resolvedFlowState =
        _resolveDefaultNetworkFlowState(
      isLocalReady: isLocalReady,
      isLocalInitializing: agentState.isLocalInitializing,
      isClosing: isClosing,
      isGrouped: effectiveGrouped,
      isAwaitingAuthorization: isAwaitingAuthorization,
      isSubmittingJoin: effectiveSubmittingJoin,
      hasActiveJoinSession: hasActiveJoinSession,
      isBootstrapping: agentState.isBootstrapping,
      localState: localState,
      managedStatus: currentMembershipStatus,
      hasServiceAssignedIp: hasServiceAssignedIp,
      hasMembershipAccepted: isMembershipAccepted,
      hasLastError: agentState.lastError?.trim().isNotEmpty == true,
    );
    final _DefaultNetworkFlowState flowState = switch (uiFlowState) {
      _DefaultNetworkingUiState.idle => resolvedFlowState,
      _DefaultNetworkingUiState.serverOrchestrating =>
        _DefaultNetworkFlowState.orchestrating,
      _DefaultNetworkingUiState.localOrchestrating =>
        _DefaultNetworkFlowState.awaitingLocalConfig,
      _DefaultNetworkingUiState.awaitingAuthorization =>
        _DefaultNetworkFlowState.awaitingAuthorization,
      _DefaultNetworkingUiState.success => _DefaultNetworkFlowState.online,
      _DefaultNetworkingUiState.closing => _DefaultNetworkFlowState.closing,
    };
    final _DefaultNetworkFlowPresentation flowPresentation =
        _describeDefaultNetworkFlowState(
      flowState,
      transitionLabel: agentState.networkTransitionLabel,
      hasServiceAssignedIp: hasServiceAssignedIp,
    );
    final bool isDisabled = isExternallyLocked ||
        flowPresentation.isDisabled ||
        agentState.isLocalInitializing ||
        !isLocalReady;
    final bool isConnected = flowState == _DefaultNetworkFlowState.online &&
        localState != null &&
        localState.assignedAddresses.isNotEmpty;
    return SectionCard(
      title: '默认网络编排',
      titleAction: _StatusChip(
        label: isConnected ? '网络已连接' : '网络未连接',
        color: isConnected ? const Color(0xFF2563EB) : const Color(0xFF64748B),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _NetworkingActionOrb(
            key: actionOrbKey,
            label: flowPresentation.label,
            icon: flowPresentation.icon,
            subtitle: flowPresentation.subtitle,
            tone: flowPresentation.tone,
            spinning: flowPresentation.isInProgress,
            onTap: isDisabled
                ? null
                : flowPresentation.usesLeaveAction
                    ? onLeave
                    : onJoin,
          ),
          const SizedBox(height: 16),
          _VirtualIpPanel(
            addresses: localState?.assignedAddresses ?? const <String>[],
            onCopy: onCopyIp,
          ),
          if (isExternallyLocked) ...<Widget>[
            const SizedBox(height: 16),
            _InlineHint(message: externalLockMessage),
          ],
        ],
      ),
    );
  }

  ZeroTierNetworkState? _findLocal(
    ZeroTierRuntimeStatus runtimeStatus,
    ManagedNetwork network,
  ) {
    final String targetId =
        network.zeroTierNetworkId?.trim().toLowerCase() ?? '';
    if (targetId.isEmpty) {
      return null;
    }
    for (final ZeroTierNetworkState state in runtimeStatus.joinedNetworks) {
      if (state.networkId.trim().toLowerCase() == targetId) {
        return state;
      }
    }
    return null;
  }
}

class _PrivateNetworkingTab extends StatelessWidget {
  const _PrivateNetworkingTab({
    super.key,
    required this.joinOrbKey,
    required this.hostOrbKey,
    required this.codeController,
    required this.createdNetwork,
    required this.generatedCode,
    required this.currentDeviceId,
    required this.hostFlowState,
    required this.joinFlowState,
    required this.agentState,
    required this.isBusy,
    required this.activeAction,
    required this.isLocalReady,
    required this.managedNetworks,
    required this.runtimeStatus,
    required this.selectedMode,
    required this.isExternallyLocked,
    required this.externalLockMessage,
    required this.lastJoinedCode,
    required this.onModeChanged,
    required this.onJoinPressed,
    required this.onHostPressed,
    required this.onLeavePressed,
    required this.onCopyValue,
  });

  final Key joinOrbKey;
  final Key hostOrbKey;
  final TextEditingController codeController;
  final ManagedNetwork? createdNetwork;
  final String? generatedCode;
  final String currentDeviceId;
  final _PrivateNetworkingFlowState hostFlowState;
  final _PrivateNetworkingFlowState joinFlowState;
  final NetworkingAgentRuntimeState agentState;
  final bool isBusy;
  final String? activeAction;
  final bool isLocalReady;
  final List<ManagedNetwork> managedNetworks;
  final ZeroTierRuntimeStatus runtimeStatus;
  final int selectedMode;
  final bool isExternallyLocked;
  final String externalLockMessage;
  final String? lastJoinedCode;
  final ValueChanged<int> onModeChanged;
  final VoidCallback onJoinPressed;
  final VoidCallback onHostPressed;
  final ValueChanged<ManagedNetwork?> onLeavePressed;
  final void Function(String value, String message) onCopyValue;

  @override
  Widget build(BuildContext context) {
    final bool isDisabled =
        isExternallyLocked || agentState.isLocalInitializing || !isLocalReady;
    final List<ManagedNetwork> privateNetworks = managedNetworks
        .where((ManagedNetwork network) => network.isPrivate)
        .toList(growable: false);
    final bool isHostMode = selectedMode == 0;
    final List<ManagedNetwork> hostNetworks = privateNetworks
        .where(
          (ManagedNetwork network) =>
              _isHostManagedNetwork(network, currentDeviceId),
        )
        .toList(growable: false);
    final List<ManagedNetwork> joinNetworks = privateNetworks
        .where(
          (ManagedNetwork network) =>
              !_isHostManagedNetwork(network, currentDeviceId),
        )
        .toList(growable: false);
    final ManagedNetwork? hostNetworkById = _findManagedNetworkById(
      privateNetworks,
      createdNetwork?.id,
    );
    final ManagedNetwork? joinNetworkByCode =
        _findManagedNetworkByInviteCode(joinNetworks, lastJoinedCode);
    final ManagedNetwork? onlineHostNetwork =
        hostNetworks.cast<ManagedNetwork?>().firstWhere(
              (ManagedNetwork? network) =>
                  network != null &&
                  _isManagedNetworkOnline(
                    network: network,
                    currentDeviceId: currentDeviceId,
                    runtimeStatus: runtimeStatus,
                  ),
              orElse: () => null,
            );
    final ManagedNetwork? onlineJoinNetwork =
        joinNetworks.cast<ManagedNetwork?>().firstWhere(
              (ManagedNetwork? network) =>
                  network != null &&
                  _isManagedNetworkOnline(
                    network: network,
                    currentDeviceId: currentDeviceId,
                    runtimeStatus: runtimeStatus,
                  ),
              orElse: () => null,
            );
    final ManagedNetwork? displayNetwork = isHostMode
        ? (hostNetworkById ??
            createdNetwork ??
            (generatedCode?.trim().isNotEmpty == true
                ? onlineHostNetwork
                : null))
        : (joinNetworkByCode ?? onlineJoinNetwork);
    final ZeroTierNetworkState? localState = displayNetwork == null
        ? null
        : _findLocal(runtimeStatus, displayNetwork);
    final _PrivateNetworkingFlowState activeFlowState =
        isHostMode ? hostFlowState : joinFlowState;
    final bool hostCodeReady = generatedCode?.trim().isNotEmpty == true;
    final bool hostCreationReady =
        hostFlowState == _PrivateNetworkingFlowState.success;
    final bool hasOnlinePrivateNetwork =
        activeFlowState == _PrivateNetworkingFlowState.success;
    final ManagedNetwork? activeNetwork =
        isHostMode ? displayNetwork : (joinNetworkByCode ?? onlineJoinNetwork);
    final String? inviteCode =
        isHostMode ? (hostCodeReady ? generatedCode : null) : null;
    final String? copyableInviteCode =
        hostCreationReady && inviteCode != null ? inviteCode : null;
    final List<String> addresses =
        localState?.assignedAddresses ?? const <String>[];
    final bool isClosing =
        activeFlowState == _PrivateNetworkingFlowState.closing;
    final bool isServerOrchestrating =
        activeFlowState == _PrivateNetworkingFlowState.serverOrchestrating;
    final bool isLocalOrchestrating =
        activeFlowState == _PrivateNetworkingFlowState.localOrchestrating;
    final bool isPrivateOrchestrating =
        isServerOrchestrating || isLocalOrchestrating || isClosing;
    final bool isModeSwitchLocked =
        activeFlowState != _PrivateNetworkingFlowState.idle;

    final String orbLabel;
    final String orbSubtitle;
    final IconData orbIcon;
    final _NetworkingOrbTone orbTone;
    final bool orbSpinning;

    if (!isLocalReady) {
      orbLabel = '环境未就绪';
      orbSubtitle = '请等待本地环境初始化';
      orbIcon = Icons.hourglass_top_rounded;
      orbTone = _NetworkingOrbTone.disabled;
      orbSpinning = true;
    } else if (hasOnlinePrivateNetwork) {
      orbLabel = '组网成功';
      orbSubtitle = '点击可取消';
      orbIcon = Icons.check_circle_rounded;
      orbTone = _NetworkingOrbTone.success;
      orbSpinning = false;
    } else if (isClosing) {
      orbLabel = '网络回收中';
      orbSubtitle = '正在回收当前网络链路';
      orbIcon = Icons.sync_rounded;
      orbTone = _NetworkingOrbTone.active;
      orbSpinning = true;
    } else if (isServerOrchestrating) {
      orbLabel = '网络编排';
      orbSubtitle = '请求服务器网络编排中';
      orbIcon = Icons.sync_rounded;
      orbTone = _NetworkingOrbTone.active;
      orbSpinning = true;
    } else if (isLocalOrchestrating) {
      orbLabel = '网络编排';
      orbSubtitle = '本地网络编排中';
      orbIcon = Icons.sync_rounded;
      orbTone = _NetworkingOrbTone.active;
      orbSpinning = true;
    } else {
      orbLabel = isHostMode ? '主持网络' : '加入网络';
      orbSubtitle = isHostMode ? '本地环境已就绪\n开始创建私有网络' : '本地环境已就绪\n输入验证码加入网络';
      orbIcon = isHostMode ? Icons.wifi_tethering_rounded : Icons.login_rounded;
      orbTone = _NetworkingOrbTone.idle;
      orbSpinning = false;
    }

    return SectionCard(
      title: '',
      header: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double modeTabsWidth =
              constraints.maxWidth < 300 ? constraints.maxWidth : 280;
          final Widget modeTabs = _PrimaryTabSelector(
            selectedIndex: selectedMode,
            labels: const <String>['主持网络', '加入网络'],
            compact: true,
            isLocked: isModeSwitchLocked,
            onSelected: onModeChanged,
          );
          final Widget statusChip = _StatusChip(
            label: hasOnlinePrivateNetwork ? '网络已连接' : '网络未连接',
            color: hasOnlinePrivateNetwork
                ? const Color(0xFF2563EB)
                : const Color(0xFF64748B),
          );

          if (constraints.maxWidth < 420) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: modeTabsWidth,
                  child: modeTabs,
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: statusChip,
                ),
              ],
            );
          }

          return Row(
            children: <Widget>[
              SizedBox(
                width: modeTabsWidth,
                child: modeTabs,
              ),
              const SizedBox(width: 12),
              const Spacer(),
              statusChip,
            ],
          );
        },
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Align(
            alignment: Alignment.center,
            child: FractionallySizedBox(
              widthFactor: 2 / 3,
              child: isHostMode
                  ? _InviteCodeDisplayBox(
                      code: copyableInviteCode,
                      onCopy: copyableInviteCode != null
                          ? () => onCopyValue(copyableInviteCode, '已复制验证码')
                          : null,
                    )
                  : _InviteCodeInputBox(
                      controller: codeController,
                      enabled:
                          !isBusy && !isDisabled && !isPrivateOrchestrating,
                    ),
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: _NetworkingActionOrb(
              key: isHostMode ? hostOrbKey : joinOrbKey,
              label: orbLabel,
              icon: orbIcon,
              subtitle: orbSubtitle,
              diameter: 220,
              tone: orbTone,
              spinning: orbSpinning,
              onTap: (isDisabled || isPrivateOrchestrating) &&
                      !hasOnlinePrivateNetwork
                  ? null
                  : hasOnlinePrivateNetwork
                      ? () => onLeavePressed(activeNetwork)
                      : (isHostMode ? onHostPressed : onJoinPressed),
            ),
          ),
          if (isHostMode &&
              hostCodeReady &&
              !hostCreationReady &&
              addresses.isEmpty) ...<Widget>[
            const SizedBox(height: 12),
            const _InlineHint(
              message: '验证码已生成，本地虚拟 IP 仍在同步，卡片会在地址就绪后自动出现。',
            ),
          ],
          const SizedBox(height: 16),
          _VirtualIpPanel(
            addresses: addresses,
            onCopy: (String value) => onCopyValue(value, '已复制虚拟 IP'),
          ),
          if (isExternallyLocked) ...<Widget>[
            const SizedBox(height: 16),
            _InlineHint(message: externalLockMessage),
          ],
        ],
      ),
    );
  }

  ZeroTierNetworkState? _findLocal(
    ZeroTierRuntimeStatus runtimeStatus,
    ManagedNetwork network,
  ) {
    final String targetId =
        network.zeroTierNetworkId?.trim().toLowerCase() ?? '';
    if (targetId.isEmpty) {
      return null;
    }
    for (final ZeroTierNetworkState state in runtimeStatus.joinedNetworks) {
      if (state.networkId.trim().toLowerCase() == targetId) {
        return state;
      }
    }
    return null;
  }
}

class _LocalNetworkCard extends StatelessWidget {
  const _LocalNetworkCard({
    required this.currentDeviceId,
    required this.network,
    required this.managedNetwork,
  });

  final String currentDeviceId;
  final ZeroTierNetworkState network;
  final ManagedNetwork? managedNetwork;

  @override
  Widget build(BuildContext context) {
    final Color accentColor = network.localInterfaceReady
        ? const Color(0xFF15803D)
        : const Color(0xFFB45309);
    final _NetworkVisualState visualState = _resolveNetworkVisualState(
      localState: network,
      managedStatus: _currentMembershipStatus(
        managedNetwork,
        currentDeviceId,
      ),
      hasServiceAssignedIp: _hasCurrentServiceAssignedIp(
        managedNetwork,
        currentDeviceId,
      ),
      hasJoinIntentEvidence: false,
      isBusy: false,
      lastError: null,
      runtimeServiceState: 'running',
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accentColor.withValues(alpha: 0.22)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: accentColor.withValues(alpha: 0.06),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  network.networkName.isEmpty
                      ? network.networkId
                      : network.networkName,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
              _StatusChip(
                label: visualState.label,
                color: visualState.foreground,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _InfoPill(label: '网络 ID', value: network.networkId),
              _InfoPill(
                label: '已授权',
                value: network.isAuthorized ? '是' : '否',
              ),
              _InfoPill(
                label: '已连接',
                value: network.isConnected ? '是' : '否',
              ),
              _InfoPill(
                label: '本地挂载',
                value: network.localMountState,
              ),
              if (network.matchedInterfaceName.trim().isNotEmpty)
                _InfoPill(
                  label: '接口',
                  value: network.matchedInterfaceName,
                ),
              if (managedNetwork != null)
                _InfoPill(label: '服务端网络', value: managedNetwork!.name),
            ],
          ),
          const SizedBox(height: 12),
          if (network.assignedAddresses.isEmpty)
            const Text('暂无可展示的虚拟 IP。')
          else ...<Widget>[
            _NetworkSegmentPanel(addresses: network.assignedAddresses),
            const SizedBox(height: 12),
            _AddressWrap(addresses: network.assignedAddresses),
          ],
        ],
      ),
    );
  }
}

class _RuntimeEventTile extends StatelessWidget {
  const _RuntimeEventTile({
    required this.event,
  });

  final ZeroTierRuntimeEvent event;

  @override
  Widget build(BuildContext context) {
    final _RuntimeEventStyle style = _runtimeEventStyle(event.type);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(style.icon, color: style.foreground, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _runtimeEventTitle(event.type),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: style.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  event.message?.trim().isNotEmpty == true
                      ? event.message!
                      : _runtimeEventFallbackMessage(event.type),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: style.foreground,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_timeOrDash(event.occurredAt)}${event.networkId == null ? '' : ' · ${event.networkId}'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: style.foreground.withValues(alpha: 0.82),
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RuntimeSignalBanner extends StatelessWidget {
  const _RuntimeSignalBanner({
    required this.signal,
  });

  final _RuntimeSignal signal;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: signal.background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(signal.icon, color: signal.foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  signal.label,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: signal.foreground,
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  signal.message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: signal.foreground,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricBlock extends StatelessWidget {
  const _MetricBlock({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF9A3412),
                ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF7C2D12),
                ),
          ),
        ],
      ),
    );
  }
}

class _LabeledBlock extends StatelessWidget {
  const _LabeledBlock({
    required this.label,
    required this.value,
    this.action,
  });

  final String label;
  final String value;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            children: <Widget>[
              Expanded(child: SelectableText(value)),
              if (action != null) action!,
            ],
          ),
        ),
      ],
    );
  }
}

class _InlineHint extends StatelessWidget {
  const _InlineHint({
    required this.message,
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E8),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _PrimaryTabSelector extends StatelessWidget {
  const _PrimaryTabSelector({
    required this.selectedIndex,
    required this.labels,
    required this.onSelected,
    this.compact = false,
    this.dense = false,
    this.isLocked = false,
  });

  final int selectedIndex;
  final List<String> labels;
  final ValueChanged<int> onSelected;
  final bool compact;
  final bool dense;
  final bool isLocked;

  @override
  Widget build(BuildContext context) {
    final bool isCompact = compact;
    final bool isDense = dense && !isCompact;
    final Color selectedBackground =
        isCompact ? const Color(0xFFE0F2FE) : const Color(0xFFFFE9D6);
    final Color selectedForeground =
        isCompact ? const Color(0xFF0F766E) : const Color(0xFFB45309);
    return Container(
      padding: EdgeInsets.all(isCompact ? 4 : (isDense ? 4 : 5)),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius:
            BorderRadius.circular(isCompact ? 16 : (isDense ? 16 : 18)),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool usesSlidingIndicator =
              labels.isNotEmpty && constraints.hasBoundedWidth;
          final int safeSelectedIndex = labels.isEmpty
              ? 0
              : selectedIndex.clamp(0, labels.length - 1).toInt();
          final Widget tabs = Row(
            mainAxisSize: MainAxisSize.max,
            children: List<Widget>.generate(labels.length, (int index) {
              final bool selected = index == safeSelectedIndex;
              final Widget item = AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.symmetric(
                  horizontal: isCompact ? 14 : (isDense ? 16 : 18),
                  vertical: isCompact ? 9 : (isDense ? 8 : 11),
                ),
                decoration: BoxDecoration(
                  color: selected && !usesSlidingIndicator
                      ? selectedBackground
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(
                      isCompact ? 12 : (isDense ? 12 : 14)),
                ),
                child: Center(
                  child: Opacity(
                    opacity: isLocked && !selected ? 0.45 : 1,
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      style: (isCompact
                                  ? Theme.of(context).textTheme.titleSmall
                                  : isDense
                                      ? Theme.of(context).textTheme.titleSmall
                                      : Theme.of(context).textTheme.titleMedium)
                              ?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: selected
                                ? selectedForeground
                                : const Color(0xFF6B7280),
                          ) ??
                          const TextStyle(),
                      child: Text(
                        labels[index],
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              );
              final Widget tappable = InkWell(
                borderRadius:
                    BorderRadius.circular(isCompact ? 12 : (isDense ? 12 : 14)),
                onTap: isLocked ? null : () => onSelected(index),
                child: item,
              );
              return Expanded(
                child: tappable,
              );
            }),
          );

          if (!usesSlidingIndicator) {
            return tabs;
          }

          final double indicatorWidth = constraints.maxWidth / labels.length;
          return Stack(
            children: <Widget>[
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: indicatorWidth * safeSelectedIndex,
                top: 0,
                bottom: 0,
                width: indicatorWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: selectedBackground,
                    borderRadius: BorderRadius.circular(
                        isCompact ? 12 : (isDense ? 12 : 14)),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x120F172A),
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                ),
              ),
              tabs,
            ],
          );
        },
      ),
    );
  }
}

class _TopStatusPills extends StatelessWidget {
  const _TopStatusPills({
    required this.runtimeStatus,
    required this.agentState,
  });

  final ZeroTierRuntimeStatus runtimeStatus;
  final NetworkingAgentRuntimeState agentState;

  @override
  Widget build(BuildContext context) {
    final List<Widget> pills = <Widget>[
      _SummaryPill(
        label: '服务器状态',
        value: agentState.isServerReachable ? '就绪' : '未就绪',
        isReady: agentState.isServerReachable,
      ),
      _SummaryPill(
        label: '本地网络轮巡',
        value: _serviceStateLabel(runtimeStatus),
        isReady: runtimeStatus.serviceState == 'running',
      ),
      _SummaryPill(
        label: '本地节点',
        value: _compactNodeStateLabel(runtimeStatus),
        isReady: _isNodeOperational(runtimeStatus),
      ),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= 520) {
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: constraints.maxWidth >= 760 ? 28 : 16,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Align(
                    alignment: const Alignment(-0.72, 0),
                    child: pills[0],
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.center,
                    child: pills[1],
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: const Alignment(0.72, 0),
                    child: pills[2],
                  ),
                ),
              ],
            ),
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: pills,
        );
      },
    );
  }
}

class _SummaryPill extends StatelessWidget {
  const _SummaryPill(
      {required this.label, required this.value, required this.isReady});
  final String label;
  final String value;
  final bool isReady;
  @override
  Widget build(BuildContext context) {
    final Color background =
        isReady ? const Color(0xFFEAF8EF) : const Color(0xFFEAF2FF);
    final Color border =
        isReady ? const Color(0xFF86EFAC) : const Color(0xFFBFDBFE);
    final Color foreground =
        isReady ? const Color(0xFF15803D) : const Color(0xFF1D4ED8);
    return Container(
      constraints: const BoxConstraints(minWidth: 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: border)),
      child: Text('$label: $value',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              )),
    );
  }
}

class _InviteCodeInputBox extends StatelessWidget {
  const _InviteCodeInputBox({
    required this.controller,
    required this.enabled,
  });

  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (
        BuildContext context,
        TextEditingValue value,
        Widget? child,
      ) {
        return _InviteCodeShell(
          child: TextField(
            controller: controller,
            enabled: enabled,
            textInputAction: TextInputAction.done,
            maxLength: 8,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
              TextInputFormatter.withFunction(
                (TextEditingValue oldValue, TextEditingValue newValue) {
                  return newValue.copyWith(
                    text: newValue.text.toUpperCase(),
                    selection: newValue.selection,
                  );
                },
              ),
            ],
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  letterSpacing: 2.4,
                  fontWeight: FontWeight.w800,
                ),
            decoration: InputDecoration(
              counterText: '',
              hintText: '请输入 8 位验证码',
              hintStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: const Color(0xFF94A3B8),
                  ),
              prefixIcon: const Icon(
                Icons.shield_outlined,
                color: Color(0xFF0F766E),
                size: 20,
              ),
              prefixIconConstraints: const BoxConstraints.tightFor(
                width: 46,
                height: 54,
              ),
              suffixIcon: Center(
                widthFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    '${value.text.trim().length}/8',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: const Color(0xFF64748B),
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ),
              suffixIconConstraints: const BoxConstraints.tightFor(
                width: 46,
                height: 54,
              ),
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 18,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _InviteCodeDisplayBox extends StatelessWidget {
  const _InviteCodeDisplayBox({
    required this.code,
    required this.onCopy,
  });

  final String? code;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final String displayCode =
        code?.trim().isNotEmpty == true ? code!.trim() : '--------';
    final bool canCopy = onCopy != null;
    return _InviteCodeShell(
      child: Row(
        children: <Widget>[
          const SizedBox(width: 14),
          const Icon(
            Icons.key_rounded,
            color: Color(0xFF0F766E),
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              displayCode,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: canCopy
                        ? const Color(0xFF0F766E)
                        : const Color(0xFF94A3B8),
                    letterSpacing: 2.8,
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
          IconButton(
            tooltip: '复制验证码',
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded),
            color: const Color(0xFF0F766E),
            disabledColor: const Color(0xFFCBD5E1),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(
              width: 42,
              height: 42,
            ),
          ),
        ],
      ),
    );
  }
}

class _InviteCodeShell extends StatelessWidget {
  const _InviteCodeShell({
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFCBD5E1)),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x0F0F172A),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: child,
        ),
      ),
    );
  }
}

class _SecondarySectionBar extends StatelessWidget {
  const _SecondarySectionBar(
      {required this.onTapAgent,
      required this.onTapRuntime,
      required this.onTapAlignment,
      required this.onTapLocal});
  final VoidCallback onTapAgent;
  final VoidCallback onTapRuntime;
  final VoidCallback onTapAlignment;
  final VoidCallback onTapLocal;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
          color: Colors.white,
          border: Border(
              top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant))),
      child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            _SectionLinkButton(label: 'Agent 实况', onTap: onTapAgent),
            _SectionLinkButton(label: '运行时事件', onTap: onTapRuntime),
            _SectionLinkButton(label: '架构联动', onTap: onTapAlignment),
            _SectionLinkButton(label: '本地网络', onTap: onTapLocal),
          ]),
    );
  }
}

class _SectionLinkButton extends StatelessWidget {
  const _SectionLinkButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return TextButton(onPressed: onTap, child: Text(label));
  }
}

class _EmptyStateBox extends StatelessWidget {
  const _EmptyStateBox({
    required this.message,
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
      ),
    );
  }
}

enum _CapabilityTone { ready, warning, info }

class _CapabilityItem extends StatelessWidget {
  const _CapabilityItem({
    required this.label,
    required this.tone,
  });

  final String label;
  final _CapabilityTone tone;

  @override
  Widget build(BuildContext context) {
    final ({Color background, Color foreground, IconData icon}) style =
        switch (tone) {
      _CapabilityTone.ready => (
          background: const Color(0xFFEAF8EF),
          foreground: const Color(0xFF15803D),
          icon: Icons.check_circle_rounded,
        ),
      _CapabilityTone.warning => (
          background: const Color(0xFFFFF4E8),
          foreground: const Color(0xFFB45309),
          icon: Icons.error_rounded,
        ),
      _CapabilityTone.info => (
          background: const Color(0xFFEAF2FF),
          foreground: const Color(0xFF1D4ED8),
          icon: Icons.info_rounded,
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(style.icon, color: style.foreground, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: style.foreground,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddressWrap extends StatelessWidget {
  const _AddressWrap({
    required this.addresses,
  });

  final List<String> addresses;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: addresses
          .map(
            (String address) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF2FF),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                address,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: const Color(0xFF1D4ED8),
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _VirtualIpPanel extends StatelessWidget {
  const _VirtualIpPanel({
    required this.addresses,
    required this.onCopy,
  });

  final List<String> addresses;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    final List<String> ipv4Addresses = addresses
        .where((String address) => address.trim().contains('.'))
        .toList(growable: false);
    final List<String> ipv6Addresses = addresses
        .where((String address) => address.trim().contains(':'))
        .toList(growable: false);
    final bool hasVirtualIp =
        ipv4Addresses.isNotEmpty || ipv6Addresses.isNotEmpty;
    final Color panelBackground =
        hasVirtualIp ? const Color(0xFFEAF8EF) : const Color(0xFFF8FAFC);
    final Color panelBorder =
        hasVirtualIp ? const Color(0xFF86EFAC) : const Color(0xFFCBD5E1);
    final Color panelForeground =
        hasVirtualIp ? const Color(0xFF166534) : const Color(0xFF475569);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: panelBackground,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            hasVirtualIp ? '已分配虚拟 IP' : '虚拟 IP 未就绪',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: panelForeground,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 12),
          if (ipv4Addresses.isEmpty && ipv6Addresses.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                '当前暂无虚拟 IP',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: panelForeground,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          if (ipv4Addresses.isNotEmpty)
            _VirtualIpGroup(
              title: 'IPv4 虚拟地址',
              addresses: ipv4Addresses,
              onCopy: onCopy,
            ),
          if (ipv6Addresses.isNotEmpty) ...<Widget>[
            if (ipv4Addresses.isNotEmpty) const SizedBox(height: 12),
            _VirtualIpGroup(
              title: 'IPv6 虚拟地址',
              addresses: ipv6Addresses,
              onCopy: onCopy,
            ),
          ],
        ],
      ),
    );
  }
}

class _VirtualIpGroup extends StatelessWidget {
  const _VirtualIpGroup({
    required this.title,
    required this.addresses,
    required this.onCopy,
  });

  final String title;
  final List<String> addresses;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: const Color(0xFF166534),
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 8),
        ...addresses.map(
          (String address) => Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: SelectableText(
                      address,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF166534),
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制虚拟 IP',
                    onPressed: () => onCopy(address),
                    icon: const Icon(Icons.copy_rounded),
                    color: const Color(0xFF166534),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _NetworkSegmentPanel extends StatelessWidget {
  const _NetworkSegmentPanel({
    required this.addresses,
  });

  final List<String> addresses;

  @override
  Widget build(BuildContext context) {
    final List<String> segments = _derivedSegmentsFromAddresses(addresses);
    if (segments.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF2FF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '共享网段',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF1D4ED8),
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: segments
                .map(
                  (String segment) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      segment,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: const Color(0xFF1D4ED8),
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

enum _NetworkingOrbTone { idle, active, success, disabled }

enum _DefaultNetworkFlowState {
  initializing,
  idle,
  orchestrating,
  awaitingLocalNetwork,
  awaitingLocalConfig,
  awaitingAuthorization,
  online,
  closing,
  retryableError,
}

class _DefaultNetworkFlowPresentation {
  const _DefaultNetworkFlowPresentation({
    required this.label,
    required this.subtitle,
    required this.hint,
    required this.icon,
    required this.tone,
    required this.isInProgress,
    required this.isDisabled,
    required this.usesLeaveAction,
  });

  final String label;
  final String subtitle;
  final String hint;
  final IconData icon;
  final _NetworkingOrbTone tone;
  final bool isInProgress;
  final bool isDisabled;
  final bool usesLeaveAction;
}

class _NetworkingActionOrb extends StatefulWidget {
  const _NetworkingActionOrb({
    super.key,
    required this.label,
    required this.icon,
    required this.subtitle,
    required this.onTap,
    this.diameter = 240,
    this.tone = _NetworkingOrbTone.idle,
    this.spinning = false,
  });

  final String label;
  final IconData icon;
  final String subtitle;
  final VoidCallback? onTap;
  final double diameter;
  final _NetworkingOrbTone tone;
  final bool spinning;

  @override
  State<_NetworkingActionOrb> createState() => _NetworkingActionOrbState();
}

class _NetworkingActionOrbState extends State<_NetworkingActionOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _syncRotation();
  }

  @override
  void didUpdateWidget(covariant _NetworkingActionOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spinning != widget.spinning) {
      _syncRotation();
    }
  }

  void _syncRotation() {
    if (widget.spinning) {
      _rotationController.repeat();
    } else {
      _rotationController.stop();
      _rotationController.value = 0;
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = widget.onTap != null;
    final bool isHovered = enabled && _isHovered;
    final ({List<Color> colors, Color shadow}) palette = switch (widget.tone) {
      _NetworkingOrbTone.idle => (
          colors: const <Color>[Color(0xFFFFC36B), Color(0xFFF97316)],
          shadow: const Color(0x40F97316),
        ),
      _NetworkingOrbTone.active => (
          colors: const <Color>[Color(0xFF6FB6FF), Color(0xFF2563EB)],
          shadow: const Color(0x402563EB),
        ),
      _NetworkingOrbTone.success => (
          colors: const <Color>[Color(0xFF6EE7B7), Color(0xFF16A34A)],
          shadow: const Color(0x4016A34A),
        ),
      _NetworkingOrbTone.disabled => (
          colors: const <Color>[Color(0xFFD1D5DB), Color(0xFF9CA3AF)],
          shadow: const Color(0x309CA3AF),
        ),
    };

    return Center(
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) {
          if (!enabled) {
            return;
          }
          setState(() {
            _isHovered = true;
          });
        },
        onExit: (_) {
          if (!_isHovered) {
            return;
          }
          setState(() {
            _isHovered = false;
          });
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: Opacity(
            opacity: enabled ? 1 : 0.82,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              scale: isHovered ? 1.025 : 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: widget.diameter,
                height: widget.diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: palette.colors,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: palette.shadow,
                      blurRadius: isHovered ? 34 : 28,
                      offset: Offset(0, isHovered ? 18 : 16),
                    ),
                    if (isHovered)
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.35),
                        blurRadius: 18,
                        spreadRadius: -4,
                      ),
                    const BoxShadow(
                      color: Color(0x80FFFFFF),
                      blurRadius: 18,
                      offset: Offset(-8, -8),
                      spreadRadius: -10,
                    ),
                  ],
                ),
                child: Container(
                  margin: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(
                        alpha: isHovered ? 0.46 : 0.30,
                      ),
                      width: isHovered ? 2 : 1.6,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      RotationTransition(
                        turns: _rotationController,
                        child: Icon(
                          widget.icon,
                          size: widget.diameter * 0.18,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: widget.diameter * 0.06),
                      Text(
                        widget.label,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: widget.diameter * 0.05),
                      Text(
                        widget.subtitle,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.92),
                          height: 1.45,
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

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('$label: $value'),
    );
  }
}

class _RuntimeSignal {
  const _RuntimeSignal({
    required this.label,
    required this.message,
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final String label;
  final String message;
  final IconData icon;
  final Color background;
  final Color foreground;
}

class _NetworkVisualState {
  const _NetworkVisualState({
    required this.label,
    required this.message,
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final String label;
  final String message;
  final IconData icon;
  final Color background;
  final Color foreground;
}

class _RuntimeEventStyle {
  const _RuntimeEventStyle({
    required this.background,
    required this.foreground,
    required this.icon,
  });

  final Color background;
  final Color foreground;
  final IconData icon;
}

String _timeOrDash(DateTime? time) {
  if (time == null) {
    return '-';
  }
  final DateTime local = time.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}:'
      '${local.second.toString().padLeft(2, '0')}';
}

String _buildDefaultPrivateNetworkName(AppConfig config) {
  final String baseName =
      config.deviceName.trim().isNotEmpty ? config.deviceName.trim() : '当前设备';
  final DateTime now = DateTime.now();
  final String stamp = '${now.year.toString().padLeft(4, '0')}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}-'
      '${now.hour.toString().padLeft(2, '0')}'
      '${now.minute.toString().padLeft(2, '0')}'
      '${now.second.toString().padLeft(2, '0')}';
  return '$baseName-私有网络-$stamp';
}

bool _networkContainsInviteCode(ManagedNetwork? network, String? code) {
  final String targetCode = code?.trim() ?? '';
  if (network == null || targetCode.isEmpty) {
    return false;
  }
  return network.inviteCodes.any(
    (ManagedNetworkInviteCode item) => item.code.trim() == targetCode,
  );
}

ManagedNetwork? _findManagedNetworkByInviteCode(
  List<ManagedNetwork> networks,
  String? code,
) {
  return networks.cast<ManagedNetwork?>().firstWhere(
        (ManagedNetwork? network) => _networkContainsInviteCode(network, code),
        orElse: () => null,
      );
}

ManagedNetwork? _findManagedNetworkById(
  List<ManagedNetwork> networks,
  String? networkId,
) {
  final String targetId = networkId?.trim() ?? '';
  if (targetId.isEmpty) {
    return null;
  }
  return networks.cast<ManagedNetwork?>().firstWhere(
        (ManagedNetwork? network) => network?.id.trim() == targetId,
        orElse: () => null,
      );
}

ManagedNetworkMembership? _findCurrentMembership(
  ManagedNetwork? network,
  String currentDeviceId,
) {
  final String targetDeviceId = currentDeviceId.trim();
  if (network == null || targetDeviceId.isEmpty) {
    return null;
  }
  for (final ManagedNetworkMembership membership in network.memberships) {
    if (membership.deviceId.trim() == targetDeviceId) {
      return membership;
    }
  }
  return null;
}

bool _isHostManagedNetwork(ManagedNetwork network, String currentDeviceId) {
  final ManagedNetworkMembership? membership =
      _findCurrentMembership(network, currentDeviceId);
  if (membership == null) {
    return false;
  }
  final String role = membership.role.trim().toLowerCase();
  return role == 'owner' || role == 'host' || role == 'admin';
}

bool _isManagedNetworkOnline(
    {required ManagedNetwork network,
    required String currentDeviceId,
    required ZeroTierRuntimeStatus runtimeStatus}) {
  final String targetNetworkId =
      network.zeroTierNetworkId?.trim().toLowerCase() ?? '';
  final bool accepted = _isAcceptedMembershipStatus(
      _currentMembershipStatus(network, currentDeviceId));
  if (targetNetworkId.isEmpty || !accepted) {
    return false;
  }
  for (final ZeroTierNetworkState state in runtimeStatus.joinedNetworks) {
    if (state.networkId.trim().toLowerCase() != targetNetworkId) {
      continue;
    }
    if (_isLocalNetworkMounted(
        state, _hasCurrentServiceAssignedIp(network, currentDeviceId))) {
      return true;
    }
  }
  return false;
}

bool _isDefaultNetworkLocked(
    {required ManagedNetwork? defaultNetwork,
    required String currentDeviceId,
    required ZeroTierRuntimeStatus runtimeStatus,
    required NetworkingAgentRuntimeState agentState}) {
  if (agentState.activeNetworkActionType?.trim().isNotEmpty == true ||
      agentState.isNetworkTransitioning) {
    return true;
  }
  if (defaultNetwork == null) {
    return false;
  }
  return _isManagedNetworkOnline(
      network: defaultNetwork,
      currentDeviceId: currentDeviceId,
      runtimeStatus: runtimeStatus);
}

List<String> _derivedSegmentsFromAddresses(List<String> addresses) {
  final Set<String> segments = <String>{};
  for (final String address in addresses) {
    final String? segment = _deriveSegmentFromAddress(address);
    if (segment != null && segment.isNotEmpty) {
      segments.add(segment);
    }
  }
  return segments.toList(growable: false);
}

String? _deriveSegmentFromAddress(String rawAddress) {
  final String address = rawAddress.trim();
  if (address.isEmpty) {
    return null;
  }

  final List<String> cidrParts = address.split('/');
  final String host = cidrParts.first.trim();
  final int? prefixLength =
      cidrParts.length > 1 ? int.tryParse(cidrParts[1].trim()) : null;

  if (host.contains('.')) {
    final List<String> octets = host.split('.');
    if (octets.length != 4) {
      return prefixLength == null ? null : '$host/$prefixLength';
    }
    final List<int> values = octets.map(int.tryParse).nonNulls.toList();
    if (values.length != 4) {
      return prefixLength == null ? null : '$host/$prefixLength';
    }
    final int normalizedPrefix =
        prefixLength == null ? 24 : prefixLength.clamp(0, 32);
    final int mask = normalizedPrefix == 0
        ? 0
        : (0xffffffff << (32 - normalizedPrefix)) & 0xffffffff;
    final int ip =
        (values[0] << 24) | (values[1] << 16) | (values[2] << 8) | values[3];
    final int network = ip & mask;
    return '${(network >> 24) & 0xff}.'
        '${(network >> 16) & 0xff}.'
        '${(network >> 8) & 0xff}.'
        '${network & 0xff}/$normalizedPrefix';
  }

  if (host.contains(':')) {
    return prefixLength == null ? host : '$host/$prefixLength';
  }

  return null;
}

bool _isNodeOperational(ZeroTierRuntimeStatus status) {
  return status.isEnvironmentReady &&
      status.serviceState == 'running' &&
      status.isNodeReady &&
      !status.isNodeOffline;
}

String _serviceStateLabel(ZeroTierRuntimeStatus status) {
  switch (status.serviceState) {
    case 'running':
      return '运行中';
    case 'offline':
      return '离线';
    case 'starting':
      return '启动中';
    case 'prepared':
      return '已就绪';
    case 'error':
      return '异常';
    case 'unavailable':
      return '不可用';
    default:
      return status.serviceState;
  }
}

String _nodeStateLabel(ZeroTierRuntimeStatus status) {
  if (!status.isEnvironmentReady) {
    return '未初始化';
  }
  if (_isNodeOperational(status)) {
    return '已就绪';
  }
  if (status.isNodeOffline) {
    return '离线';
  }
  if (status.isNodeStarting) {
    return '启动中';
  }
  if (status.isNodeErrored) {
    return '异常';
  }
  if (status.serviceState == 'prepared') {
    return '未启动';
  }
  return status.serviceState;
}

String _compactNodeStateLabel(ZeroTierRuntimeStatus status) {
  if (_isNodeOperational(status)) {
    return '就绪';
  }
  if (status.isNodeOffline) {
    return '掉线';
  }
  return '启动中';
}

_RuntimeSignal _resolveRuntimeSignal({
  required ZeroTierRuntimeStatus runtimeStatus,
  required List<ZeroTierRuntimeEvent> recentEvents,
  required String? lastError,
}) {
  final bool hasActiveJoinedNetwork = runtimeStatus.joinedNetworks.any(
    (ZeroTierNetworkState network) =>
        network.localInterfaceReady ||
        network.isConnected ||
        network.assignedAddresses.isNotEmpty,
  );
  final ZeroTierRuntimeEvent? highlightedEvent =
      recentEvents.cast<ZeroTierRuntimeEvent?>().firstWhere(
            (ZeroTierRuntimeEvent? event) =>
                event != null &&
                (event.type == ZeroTierRuntimeEventType.error ||
                    event.type == ZeroTierRuntimeEventType.nodeOffline ||
                    event.type ==
                        ZeroTierRuntimeEventType.networkWaitingAuthorization ||
                    event.type == ZeroTierRuntimeEventType.networkOnline ||
                    event.type == ZeroTierRuntimeEventType.networkLeft),
            orElse: () => null,
          );

  if (lastError?.trim().isNotEmpty == true) {
    return _RuntimeSignal(
      label: '运行异常',
      message: lastError!,
      icon: Icons.error_outline_rounded,
      background: const Color(0xFFFFE9E9),
      foreground: const Color(0xFFB91C1C),
    );
  }

  if (_isNodeOperational(runtimeStatus) && hasActiveJoinedNetwork) {
    return const _RuntimeSignal(
      label: '网络在线',
      message: '当前本机已检测到可用的 ZeroTier 本地网络映射，runtime 与 libzt 节点都已进入可用状态。',
      icon: Icons.check_circle_rounded,
      background: Color(0xFFEAF8EF),
      foreground: Color(0xFF15803D),
    );
  }

  if (highlightedEvent != null) {
    switch (highlightedEvent.type) {
      case ZeroTierRuntimeEventType.networkWaitingAuthorization:
        return _RuntimeSignal(
          label: '等待网络授权',
          message: highlightedEvent.message?.trim().isNotEmpty == true
              ? highlightedEvent.message!
              : 'ZeroTier 已发起入网请求，当前仍在等待控制面或网络侧授权。',
          icon: Icons.schedule_rounded,
          background: const Color(0xFFFFF4E8),
          foreground: const Color(0xFFB45309),
        );
      case ZeroTierRuntimeEventType.nodeOffline:
        return _RuntimeSignal(
          label: '节点当前离线',
          message: highlightedEvent.message?.trim().isNotEmpty == true
              ? highlightedEvent.message!
              : 'libzt 节点当前失去在线连接，这更像是节点在线性抖动，不等同于进程重启。',
          icon: Icons.wifi_off_rounded,
          background: const Color(0xFFFFF4E8),
          foreground: const Color(0xFFB45309),
        );
      case ZeroTierRuntimeEventType.networkOnline:
        return _RuntimeSignal(
          label: '网络已在线',
          message: highlightedEvent.message?.trim().isNotEmpty == true
              ? highlightedEvent.message!
              : 'ZeroTier 网络已经进入在线状态，可以继续观察地址分配与互通性。',
          icon: Icons.check_circle_rounded,
          background: const Color(0xFFEAF8EF),
          foreground: const Color(0xFF15803D),
        );
      case ZeroTierRuntimeEventType.networkLeft:
        return _RuntimeSignal(
          label: '已离开网络',
          message: highlightedEvent.message?.trim().isNotEmpty == true
              ? highlightedEvent.message!
              : '本机已经完成离网，当前可以继续观察本地链路是否稳定。',
          icon: Icons.logout_rounded,
          background: const Color(0xFFEAF2FF),
          foreground: const Color(0xFF1D4ED8),
        );
      case ZeroTierRuntimeEventType.error:
        return _RuntimeSignal(
          label: '运行异常',
          message: highlightedEvent.message?.trim().isNotEmpty == true
              ? highlightedEvent.message!
              : 'ZeroTier 运行时返回了错误，请结合最近事件与本地状态排查。',
          icon: Icons.error_outline_rounded,
          background: const Color(0xFFFFE9E9),
          foreground: const Color(0xFFB91C1C),
        );
      case ZeroTierRuntimeEventType.environmentReady:
      case ZeroTierRuntimeEventType.permissionRequired:
      case ZeroTierRuntimeEventType.nodeStarted:
      case ZeroTierRuntimeEventType.nodeOnline:
      case ZeroTierRuntimeEventType.nodeStopped:
      case ZeroTierRuntimeEventType.networkJoining:
      case ZeroTierRuntimeEventType.ipAssigned:
        break;
    }
  }

  switch (runtimeStatus.serviceState) {
    case 'running':
      if (_isNodeOperational(runtimeStatus)) {
        return const _RuntimeSignal(
          label: 'runtime ready',
          message: 'libzt 节点已经 ready，UI 现在把这作为 runtime 真正可用的判定条件。',
          icon: Icons.verified_rounded,
          background: Color(0xFFEAF8EF),
          foreground: Color(0xFF15803D),
        );
      }
      return const _RuntimeSignal(
        label: '节点未就绪',
        message: '宿主 runtime 已进入 running，但 libzt 节点还没有完成 ready，UI 仍按未就绪处理。',
        icon: Icons.hourglass_top_rounded,
        background: Color(0xFFFFF4E8),
        foreground: Color(0xFFB45309),
      );
    case 'offline':
      return const _RuntimeSignal(
        label: '节点离线',
        message: 'libzt 节点当前不在线，虽然本地 runtime 还在，但 UI 不会把它显示成 ready。',
        icon: Icons.wifi_off_rounded,
        background: Color(0xFFFFF4E8),
        foreground: Color(0xFFB45309),
      );
    case 'starting':
      return const _RuntimeSignal(
        label: '节点启动中',
        message: '宿主 runtime 已发起启动，但只有等 libzt 节点真正 ready 后，UI 才会进入 ready 显示。',
        icon: Icons.autorenew_rounded,
        background: Color(0xFFEAF2FF),
        foreground: Color(0xFF1D4ED8),
      );
    case 'prepared':
      return const _RuntimeSignal(
        label: '环境已就绪',
        message: '当前只说明宿主环境可用，还不代表 libzt 节点已经 ready。',
        icon: Icons.construction_rounded,
        background: Color(0xFFFFF4E8),
        foreground: Color(0xFFB45309),
      );
    case 'unavailable':
      return const _RuntimeSignal(
        label: '运行时不可用',
        message: '本机尚未完成 ZeroTier runtime 初始化，当前无法执行真实组网动作。',
        icon: Icons.portable_wifi_off_rounded,
        background: Color(0xFFFFF4E8),
        foreground: Color(0xFFB45309),
      );
    case 'error':
      return const _RuntimeSignal(
        label: '运行异常',
        message: 'ZeroTier runtime 当前处于异常状态，请查看最近事件与错误详情。',
        icon: Icons.error_outline_rounded,
        background: Color(0xFFFFE9E9),
        foreground: Color(0xFFB91C1C),
      );
    default:
      return _RuntimeSignal(
        label: '状态 ${runtimeStatus.serviceState}',
        message: '运行时已经回传状态信息，当前展示的是底层 serviceState 原始值。',
        icon: Icons.info_outline_rounded,
        background: const Color(0xFFEAF2FF),
        foreground: const Color(0xFF1D4ED8),
      );
  }
}

_NetworkVisualState _resolveNetworkVisualState({
  required ZeroTierNetworkState? localState,
  required String? managedStatus,
  required bool hasServiceAssignedIp,
  required bool hasJoinIntentEvidence,
  required bool isBusy,
  required String? lastError,
  required String runtimeServiceState,
}) {
  if (_isAuthorizationPendingLocalNetwork(localState)) {
    return const _NetworkVisualState(
      label: '等待授权',
      message: '本地已看到该 ZeroTier 网络，但仍在等待控制面授权。',
      icon: Icons.schedule_rounded,
      background: Color(0xFFFFF4E8),
      foreground: Color(0xFFB45309),
    );
  }

  if (lastError?.trim().isNotEmpty == true) {
    return const _NetworkVisualState(
      label: '运行异常',
      message: '这条组网链路最近出现了错误，请优先查看上方运行时状态和最近事件。',
      icon: Icons.error_outline_rounded,
      background: Color(0xFFFFE9E9),
      foreground: Color(0xFFB91C1C),
    );
  }

  if (runtimeServiceState == 'offline') {
    return const _NetworkVisualState(
      label: '节点离线',
      message: '本地 ZeroTier 节点当前离线，这条网络链路暂不视为可用。',
      icon: Icons.wifi_off_rounded,
      background: Color(0xFFFFF4E8),
      foreground: Color(0xFFB45309),
    );
  }

  if (localState == null) {
    if (_isAcceptedMembershipStatus(managedStatus)) {
      return _NetworkVisualState(
        label: '等待本机入网',
        message: hasServiceAssignedIp
            ? '服务端已分配虚拟 IP，正在等待本机 Agent 与 ZeroTier runtime 建立本地映射。'
            : '服务端已接受当前设备入网，正在等待本机 ZeroTier 建立本地链路。',
        icon: Icons.hourglass_top_rounded,
        background: Color(0xFFEAF2FF),
        foreground: Color(0xFF1D4ED8),
      );
    }
    if (!hasJoinIntentEvidence) {
      return const _NetworkVisualState(
        label: '尚未接入',
        message: '本机当前还未开始组网流程。',
        icon: Icons.link_off_rounded,
        background: Color(0xFFF3F4F6),
        foreground: Color(0xFF4B5563),
      );
    }
    if (isBusy) {
      return const _NetworkVisualState(
        label: '正在编排',
        message: '当前正在等待本机 Agent 与 ZeroTier runtime 完成入网或离网动作。',
        icon: Icons.sync_rounded,
        background: Color(0xFFEAF2FF),
        foreground: Color(0xFF1D4ED8),
      );
    }
    return _NetworkVisualState(
      label: '尚未接入',
      message: managedStatus?.trim().isNotEmpty == true
          ? '服务端已记录这条网络，但本机当前还没有检测到对应的 ZeroTier 本地映射。'
          : '本机当前还未接入这条网络。',
      icon: Icons.link_off_rounded,
      background: const Color(0xFFF3F4F6),
      foreground: const Color(0xFF4B5563),
    );
  }

  if (_isRevokedMembershipStatus(managedStatus)) {
    return const _NetworkVisualState(
      label: '回收中',
      message: '服务端已撤销当前设备的组网资格，正在等待本地 ZeroTier 链路完成离网回收。',
      icon: Icons.hourglass_top_rounded,
      background: Color(0xFFF3F4F6),
      foreground: Color(0xFF6B7280),
    );
  }

  if (_isAuthorizationPendingLocalNetwork(localState)) {
    return const _NetworkVisualState(
      label: '等待网络授权',
      message: 'ZeroTier 已看到这条网络，但当前仍处于等待授权阶段。',
      icon: Icons.schedule_rounded,
      background: Color(0xFFFFF4E8),
      foreground: Color(0xFFB45309),
    );
  }

  if (localState.status == 'REQUESTING_CONFIGURATION' && hasServiceAssignedIp) {
    return const _NetworkVisualState(
      label: '等待本地配置',
      message: '服务端已完成分配，当前正在等待本地 ZeroTier 接收地址与路由配置。',
      icon: Icons.hourglass_top_rounded,
      background: Color(0xFFEAF2FF),
      foreground: Color(0xFF1D4ED8),
    );
  }

  if (_isLocalNetworkMounted(localState, hasServiceAssignedIp)) {
    return const _NetworkVisualState(
      label: '网络已在线',
      message: '本机已经接入这条网络，当前可以继续查看托管地址与可达性。',
      icon: Icons.check_circle_rounded,
      background: Color(0xFFEAF8EF),
      foreground: Color(0xFF15803D),
    );
  }

  if (_isHandshakePendingLocalNetwork(localState, managedStatus)) {
    return const _NetworkVisualState(
      label: '本地握手中',
      message: '本机已经看到该网络，但仍在等待本地握手或网络配置进一步收敛。',
      icon: Icons.hourglass_top_rounded,
      background: Color(0xFFEAF2FF),
      foreground: Color(0xFF1D4ED8),
    );
  }

  if (localState.localMountState == 'ip_not_bound') {
    return _NetworkVisualState(
      label: '等待本地挂载',
      message: localState.matchedInterfaceName.trim().isNotEmpty
          ? 'ZeroTier 已分配地址，但 Windows 接口 ${localState.matchedInterfaceName} 还没有稳定挂载期望地址。'
          : 'ZeroTier 已分配地址，但 Windows 还没有把期望地址挂载到可识别接口上。',
      icon: Icons.hourglass_top_rounded,
      background: const Color(0xFFEAF2FF),
      foreground: const Color(0xFF1D4ED8),
    );
  }

  if (localState.localMountState == 'route_not_bound') {
    return _NetworkVisualState(
      label: '等待本地路由',
      message: localState.matchedInterfaceName.trim().isNotEmpty
          ? '接口 ${localState.matchedInterfaceName} 已识别，但系统路由尚未挂载完成。'
          : 'ZeroTier 本地地址已进入挂载流程，但系统路由尚未生效。',
      icon: Icons.route_rounded,
      background: const Color(0xFFEAF2FF),
      foreground: const Color(0xFF1D4ED8),
    );
  }

  if (localState.localMountState == 'adapter_down') {
    return _NetworkVisualState(
      label: '接口未就绪',
      message: localState.matchedInterfaceName.trim().isNotEmpty
          ? '已识别到接口 ${localState.matchedInterfaceName}，但它当前不是 up 状态。'
          : '已识别到本地接口，但它当前不是 up 状态。',
      icon: Icons.portable_wifi_off_rounded,
      background: const Color(0xFFFFF4E8),
      foreground: const Color(0xFFB45309),
    );
  }

  if (localState.localMountState == 'missing_adapter') {
    return const _NetworkVisualState(
      label: '未发现虚拟网卡',
      message: 'libzt 已进入本地组网流程，但 Windows 侧还没有识别到可用的 ZeroTier/TAP/Wintun 虚拟接口。',
      icon: Icons.device_unknown_rounded,
      background: Color(0xFFFFF4E8),
      foreground: Color(0xFFB45309),
    );
  }

  if (localState.status == 'REQUESTING_CONFIGURATION' || isBusy) {
    return const _NetworkVisualState(
      label: '正在入网',
      message: '本机已经发起 ZeroTier 入网，正在等待配置下发与网络状态收敛。',
      icon: Icons.sync_rounded,
      background: Color(0xFFEAF2FF),
      foreground: Color(0xFF1D4ED8),
    );
  }

  if (localState.status == 'NOT_FOUND' ||
      localState.status == 'PORT_ERROR' ||
      localState.status == 'CLIENT_TOO_OLD') {
    return _NetworkVisualState(
      label: '网络异常',
      message: 'ZeroTier 返回状态 ${localState.status}，当前这条网络链路没有正常完成。',
      icon: Icons.error_outline_rounded,
      background: const Color(0xFFFFE9E9),
      foreground: const Color(0xFFB91C1C),
    );
  }

  return _NetworkVisualState(
    label: '状态 ${localState.status}',
    message: '当前本地网络已经回传状态，但仍需要继续等待或观察后续事件。',
    icon: Icons.info_outline_rounded,
    background: const Color(0xFFEAF2FF),
    foreground: const Color(0xFF1D4ED8),
  );
}

bool _isAuthorizationPendingLocalNetwork(ZeroTierNetworkState? localState) {
  if (localState == null) {
    return false;
  }
  if (localState.status == 'ACCESS_DENIED') {
    return true;
  }
  if (localState.status == 'REQUESTING_CONFIGURATION' ||
      localState.status == 'OK' ||
      localState.status == 'UNKNOWN') {
    return false;
  }
  return !localState.isAuthorized;
}

bool _isLocalNetworkMounted(
  ZeroTierNetworkState localState,
  bool hasServiceAssignedIp,
) {
  if (!localState.isAuthorized) {
    return false;
  }
  if (localState.localInterfaceReady) {
    return true;
  }
  if (localState.localMountState == 'ready' && localState.status == 'OK') {
    return true;
  }
  if (localState.isConnected &&
      localState.assignedAddresses.isNotEmpty &&
      localState.matchedInterfaceUp) {
    return true;
  }
  return localState.status == 'OK' &&
      localState.isConnected &&
      hasServiceAssignedIp &&
      localState.localMountState == 'ready';
}

bool _isLocalNetworkNegotiating(
  ZeroTierNetworkState localState,
  bool hasServiceAssignedIp,
) {
  if (_isLocalNetworkMounted(localState, hasServiceAssignedIp)) {
    return false;
  }
  return localState.status == 'REQUESTING_CONFIGURATION' ||
      localState.status == 'OK' ||
      localState.status == 'UNKNOWN' ||
      localState.localMountState == 'awaiting_address' ||
      localState.localMountState == 'ip_not_bound' ||
      localState.localMountState == 'route_not_bound' ||
      localState.localMountState == 'adapter_down' ||
      localState.localMountState == 'missing_adapter';
}

bool _isHandshakePendingLocalNetwork(
  ZeroTierNetworkState? localState,
  String? managedStatus,
) {
  if (localState == null) {
    return false;
  }
  if (_isAuthorizationPendingLocalNetwork(localState)) {
    return false;
  }
  if (_isLocalNetworkMounted(localState, false)) {
    return false;
  }

  final String normalizedManagedStatus =
      managedStatus?.trim().toLowerCase() ?? '';
  final bool serverAlreadyAccepted = normalizedManagedStatus == 'authorized' ||
      normalizedManagedStatus == 'active';
  final bool localStillNegotiating =
      _isLocalNetworkNegotiating(localState, false);

  return serverAlreadyAccepted || localStillNegotiating;
}

bool _isEffectivelyLeftLocalNetwork(ZeroTierNetworkState? localState) {
  if (localState == null) {
    return true;
  }
  if (_isLocalNetworkMounted(localState, false)) {
    return false;
  }
  switch (localState.status) {
    case 'REQUESTING_CONFIGURATION':
    case 'UNKNOWN':
    case 'NETWORK_DOWN':
      return true;
    default:
      return false;
  }
}

_DefaultNetworkFlowState _resolveDefaultNetworkFlowState({
  required bool isLocalReady,
  required bool isLocalInitializing,
  required bool isClosing,
  required bool isGrouped,
  required bool isAwaitingAuthorization,
  required bool isSubmittingJoin,
  required bool hasActiveJoinSession,
  required bool isBootstrapping,
  required ZeroTierNetworkState? localState,
  required String? managedStatus,
  required bool hasServiceAssignedIp,
  required bool hasMembershipAccepted,
  required bool hasLastError,
}) {
  final bool hasCurrentJoinIntent = isSubmittingJoin || hasActiveJoinSession;
  if (isClosing) {
    return _DefaultNetworkFlowState.closing;
  }
  if (isLocalInitializing || !isLocalReady) {
    return _DefaultNetworkFlowState.initializing;
  }
  if (isGrouped) {
    return _DefaultNetworkFlowState.online;
  }
  if (isAwaitingAuthorization && hasCurrentJoinIntent) {
    return _DefaultNetworkFlowState.awaitingAuthorization;
  }
  if (hasCurrentJoinIntent &&
      localState != null &&
      (localState.status == 'REQUESTING_CONFIGURATION' ||
          (localState.status == 'OK' &&
              !_isLocalNetworkMounted(localState, hasServiceAssignedIp)) ||
          localState.status == 'UNKNOWN')) {
    return _DefaultNetworkFlowState.awaitingLocalConfig;
  }
  if (hasCurrentJoinIntent && hasMembershipAccepted && localState == null) {
    return _DefaultNetworkFlowState.awaitingLocalNetwork;
  }
  if (isSubmittingJoin) {
    return _DefaultNetworkFlowState.orchestrating;
  }
  if (hasLastError) {
    return _DefaultNetworkFlowState.retryableError;
  }
  return _DefaultNetworkFlowState.idle;
}

_DefaultNetworkFlowPresentation _describeDefaultNetworkFlowState(
  _DefaultNetworkFlowState state, {
  required String? transitionLabel,
  required bool hasServiceAssignedIp,
}) {
  switch (state) {
    case _DefaultNetworkFlowState.initializing:
      return const _DefaultNetworkFlowPresentation(
        label: '环境未就绪',
        subtitle: '请等待本地环境初始化',
        hint: '初始化完成前，不允许开始默认网络编排。',
        icon: Icons.hourglass_top_rounded,
        tone: _NetworkingOrbTone.disabled,
        isInProgress: true,
        isDisabled: true,
        usesLeaveAction: false,
      );
    case _DefaultNetworkFlowState.idle:
      return const _DefaultNetworkFlowPresentation(
        label: '开始组网',
        subtitle: '本地环境已就绪\n点击开始接入默认网络',
        hint: '点击开始组网后，应用会请求后端编排并等待本机 Agent 执行 join。',
        icon: Icons.flash_on_rounded,
        tone: _NetworkingOrbTone.idle,
        isInProgress: false,
        isDisabled: false,
        usesLeaveAction: false,
      );
    case _DefaultNetworkFlowState.orchestrating:
      return const _DefaultNetworkFlowPresentation(
        label: '网络编排',
        subtitle: '请求服务器网络编排中',
        hint: '当前处于服务端编排与本机执行之间，请继续等待。',
        icon: Icons.sync_rounded,
        tone: _NetworkingOrbTone.active,
        isInProgress: true,
        isDisabled: true,
        usesLeaveAction: false,
      );
    case _DefaultNetworkFlowState.awaitingLocalNetwork:
      return _DefaultNetworkFlowPresentation(
        label: '网络编排',
        subtitle: '本地网络编排中',
        hint: '控制面已经推进，但本地 runtime 还没稳定看到默认网络。',
        icon: Icons.sync_rounded,
        tone: _NetworkingOrbTone.active,
        isInProgress: true,
        isDisabled: true,
        usesLeaveAction: false,
      );
    case _DefaultNetworkFlowState.awaitingLocalConfig:
      return const _DefaultNetworkFlowPresentation(
        label: '网络编排',
        subtitle: '本地网络编排中',
        hint: '本地映射已经出现，正在等待地址和路由配置完成。',
        icon: Icons.sync_rounded,
        tone: _NetworkingOrbTone.active,
        isInProgress: true,
        isDisabled: true,
        usesLeaveAction: false,
      );
    case _DefaultNetworkFlowState.awaitingAuthorization:
      return const _DefaultNetworkFlowPresentation(
        label: '网络编排',
        subtitle: '本地网络编排中',
        hint: '入网请求已发起，当前仍在等待授权。',
        icon: Icons.sync_rounded,
        tone: _NetworkingOrbTone.active,
        isInProgress: true,
        isDisabled: true,
        usesLeaveAction: false,
      );
    case _DefaultNetworkFlowState.online:
      return const _DefaultNetworkFlowPresentation(
        label: '组网成功',
        subtitle: '点击可取消',
        hint: '绿色表示当前默认网络已经真实在线。',
        icon: Icons.check_circle_rounded,
        tone: _NetworkingOrbTone.success,
        isInProgress: false,
        isDisabled: false,
        usesLeaveAction: true,
      );
    case _DefaultNetworkFlowState.closing:
      return _DefaultNetworkFlowPresentation(
        label: '网络回收中',
        subtitle: transitionLabel ?? '正在回收相关网络链路。',
        hint: '回收完成前，按钮保持禁用，避免新旧链路相互干扰。',
        icon: Icons.sync_rounded,
        tone: _NetworkingOrbTone.active,
        isInProgress: true,
        isDisabled: true,
        usesLeaveAction: false,
      );
    case _DefaultNetworkFlowState.retryableError:
      return const _DefaultNetworkFlowPresentation(
        label: '重新组网',
        subtitle: '上一轮组网出现异常，点击重新发起编排。',
        hint: '当前链路曾出现异常，建议结合最近事件一起排查。',
        icon: Icons.error_outline_rounded,
        tone: _NetworkingOrbTone.idle,
        isInProgress: false,
        isDisabled: false,
        usesLeaveAction: false,
      );
  }
}

bool _hasCurrentServiceAssignedIp(
  ManagedNetwork? network,
  String currentDeviceId,
) {
  final String targetDeviceId = currentDeviceId.trim();
  if (network == null || targetDeviceId.isEmpty) {
    return false;
  }
  for (final ManagedNetworkMembership membership in network.memberships) {
    if (membership.deviceId.trim() != targetDeviceId) {
      continue;
    }
    if (!_isAcceptedMembershipStatus(membership.status)) {
      return false;
    }
    return membership.zeroTierAssignedIp?.trim().isNotEmpty == true;
  }
  return false;
}

bool _isAcceptedMembershipStatus(String? status) {
  final String normalized = status?.trim().toLowerCase() ?? '';
  return normalized == 'authorized' || normalized == 'active';
}

bool _isRevokedMembershipStatus(String? status) {
  return status?.trim().toLowerCase() == 'revoked';
}

String? _currentMembershipStatus(
  ManagedNetwork? network,
  String currentDeviceId,
) {
  final String targetDeviceId = currentDeviceId.trim();
  if (network == null || targetDeviceId.isEmpty) {
    return null;
  }
  for (final ManagedNetworkMembership membership in network.memberships) {
    if (membership.deviceId.trim() == targetDeviceId) {
      return membership.status.trim().isEmpty ? null : membership.status.trim();
    }
  }
  return null;
}

_RuntimeEventStyle _runtimeEventStyle(ZeroTierRuntimeEventType type) {
  switch (type) {
    case ZeroTierRuntimeEventType.error:
      return const _RuntimeEventStyle(
        background: Color(0xFFFFE9E9),
        foreground: Color(0xFFB91C1C),
        icon: Icons.error_outline_rounded,
      );
    case ZeroTierRuntimeEventType.networkWaitingAuthorization:
    case ZeroTierRuntimeEventType.nodeOffline:
      return const _RuntimeEventStyle(
        background: Color(0xFFFFF4E8),
        foreground: Color(0xFFB45309),
        icon: Icons.schedule_rounded,
      );
    case ZeroTierRuntimeEventType.networkLeft:
      return const _RuntimeEventStyle(
        background: Color(0xFFEAF2FF),
        foreground: Color(0xFF1D4ED8),
        icon: Icons.logout_rounded,
      );
    case ZeroTierRuntimeEventType.networkOnline:
    case ZeroTierRuntimeEventType.ipAssigned:
    case ZeroTierRuntimeEventType.nodeStarted:
    case ZeroTierRuntimeEventType.nodeOnline:
      return const _RuntimeEventStyle(
        background: Color(0xFFEAF8EF),
        foreground: Color(0xFF15803D),
        icon: Icons.check_circle_rounded,
      );
    case ZeroTierRuntimeEventType.environmentReady:
      return const _RuntimeEventStyle(
        background: Color(0xFFEAF8EF),
        foreground: Color(0xFF15803D),
        icon: Icons.inventory_2_rounded,
      );
    case ZeroTierRuntimeEventType.networkJoining:
      return const _RuntimeEventStyle(
        background: Color(0xFFEAF2FF),
        foreground: Color(0xFF1D4ED8),
        icon: Icons.sync_rounded,
      );
    case ZeroTierRuntimeEventType.permissionRequired:
      return const _RuntimeEventStyle(
        background: Color(0xFFFFF4E8),
        foreground: Color(0xFFB45309),
        icon: Icons.lock_outline_rounded,
      );
    case ZeroTierRuntimeEventType.nodeStopped:
      return const _RuntimeEventStyle(
        background: Color(0xFFF3F4F6),
        foreground: Color(0xFF4B5563),
        icon: Icons.pause_circle_outline_rounded,
      );
  }
}

String _runtimeEventTitle(ZeroTierRuntimeEventType type) {
  switch (type) {
    case ZeroTierRuntimeEventType.environmentReady:
      return '环境已就绪';
    case ZeroTierRuntimeEventType.permissionRequired:
      return '需要额外权限';
    case ZeroTierRuntimeEventType.nodeStarted:
      return '节点已启动';
    case ZeroTierRuntimeEventType.nodeOnline:
      return '节点已在线';
    case ZeroTierRuntimeEventType.nodeOffline:
      return '节点离线';
    case ZeroTierRuntimeEventType.nodeStopped:
      return '节点已停止';
    case ZeroTierRuntimeEventType.networkJoining:
      return '正在入网';
    case ZeroTierRuntimeEventType.networkWaitingAuthorization:
      return '等待网络授权';
    case ZeroTierRuntimeEventType.networkOnline:
      return '网络已在线';
    case ZeroTierRuntimeEventType.networkLeft:
      return '已离开网络';
    case ZeroTierRuntimeEventType.ipAssigned:
      return '地址已分配';
    case ZeroTierRuntimeEventType.error:
      return '运行异常';
  }
}

String _runtimeEventFallbackMessage(ZeroTierRuntimeEventType type) {
  switch (type) {
    case ZeroTierRuntimeEventType.environmentReady:
      return 'ZeroTier 运行时环境已经准备完成。';
    case ZeroTierRuntimeEventType.permissionRequired:
      return '当前动作仍需要额外权限或手动设置。';
    case ZeroTierRuntimeEventType.nodeStarted:
      return '本机 ZeroTier 节点已经收到启动动作。';
    case ZeroTierRuntimeEventType.nodeOnline:
      return '本机 ZeroTier 节点当前已经在线。';
    case ZeroTierRuntimeEventType.nodeOffline:
      return '本机 ZeroTier 节点当前离线，这更像是连通性问题，不等同于进程重启。';
    case ZeroTierRuntimeEventType.nodeStopped:
      return '本机 ZeroTier 节点当前已停止。';
    case ZeroTierRuntimeEventType.networkJoining:
      return '已发起入网，正在等待网络侧返回更明确状态。';
    case ZeroTierRuntimeEventType.networkWaitingAuthorization:
      return '当前网络仍在等待授权，暂时还不能视为入网成功。';
    case ZeroTierRuntimeEventType.networkOnline:
      return '网络已进入在线状态，可以继续观察地址和可达性。';
    case ZeroTierRuntimeEventType.networkLeft:
      return '本机已完成离网。';
    case ZeroTierRuntimeEventType.ipAssigned:
      return '网络已经为本机分配托管地址。';
    case ZeroTierRuntimeEventType.error:
      return '运行时返回了错误，请结合上方状态和最近事件排查。';
  }
}
