import 'dart:async';

import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/managed_network.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/private_network_creation_result.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
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

class NetworkingPage extends ConsumerStatefulWidget {
  const NetworkingPage({super.key});

  @override
  ConsumerState<NetworkingPage> createState() => _NetworkingPageState();
}

class _NetworkingPageState extends ConsumerState<NetworkingPage> {
  late final TextEditingController _networkCodeController;
  late final TextEditingController _networkNameController;
  late final TextEditingController _networkDescriptionController;
  String? _generatedNetworkCode;

  @override
  void initState() {
    super.initState();
    _networkCodeController = TextEditingController();
    _networkNameController = TextEditingController(text: 'My Private Network');
    _networkDescriptionController =
        TextEditingController(text: 'Private mesh for trusted devices');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(networkingAgentRuntimeProvider.notifier)
          .initializeLocalRuntime();
    });
  }

  @override
  void dispose() {
    _networkCodeController.dispose();
    _networkNameController.dispose();
    _networkDescriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<NetworkingAgentRuntimeState>(
      networkingAgentRuntimeProvider,
      (NetworkingAgentRuntimeState? previous,
          NetworkingAgentRuntimeState next) {
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
    final bool showNodeOfflineHint = agentState.lastRuntimeEvent?.type ==
        ZeroTierRuntimeEventType.nodeOffline;

    final bool isRegistered = config.agentToken.trim().isNotEmpty &&
        config.zeroTierNodeId.trim().isNotEmpty &&
        config.deviceId.trim().isNotEmpty;

    return DefaultTabController(
      length: 2,
      child: RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _HeroStatusCard(
              runtimeStatus: runtimeStatus,
              agentState: agentState,
              config: config,
              isRegistered: isRegistered,
              recentEvents: agentState.recentRuntimeEvents,
              lastError: agentState.lastError,
              onRefresh: _refreshAll,
              onCopyToken: config.agentToken.trim().isEmpty
                  ? null
                  : () => _copyToClipboard(
                        config.agentToken,
                        successMessage: '已复制 Agent Token',
                      ),
            ),
            const SizedBox(height: 16),
            _RuntimeInsightCard(
              runtimeStatus: runtimeStatus,
              recentEvents: agentState.recentRuntimeEvents,
              lastError: agentState.lastError,
              onRefresh: _refreshAll,
            ),
            const SizedBox(height: 16),
            if (agentState.isNetworkTransitioning &&
                agentState.networkTransitionLabel?.trim().isNotEmpty ==
                    true) ...<Widget>[
              _InlineBanner(
                icon: Icons.sync_rounded,
                color: const Color(0xFF1D4ED8),
                background: const Color(0xFFEAF2FF),
                title: '本地链路收口中',
                message: agentState.networkTransitionLabel!,
              ),
              const SizedBox(height: 16),
            ],
            if (showNodeOfflineHint) ...<Widget>[
              const _InlineBanner(
                icon: Icons.wifi_off_rounded,
                color: Color(0xFFB45309),
                background: Color(0xFFFFF4E8),
                title: 'ZeroTier 节点离线',
                message:
                    '当前检测到 ZeroTier node offline。这更像是本地节点暂时失去在线连通性，不等同于节点重新启动。',
              ),
              const SizedBox(height: 16),
            ],
            if (agentState.lastError != null &&
                agentState.lastError!.trim().isNotEmpty) ...<Widget>[
              _InlineBanner(
                icon: Icons.error_outline_rounded,
                color: const Color(0xFFB45309),
                background: const Color(0xFFFFF4E8),
                title: '最近错误',
                message: agentState.lastError!,
              ),
              const SizedBox(height: 16),
            ],
            if (networkingAsync.hasError) ...<Widget>[
              _InlineBanner(
                icon: Icons.cloud_off_rounded,
                color: const Color(0xFFB91C1C),
                background: const Color(0xFFFFE9E9),
                title: '服务端编排加载失败',
                message: _errorText(networkingAsync.error),
                trailing: FilledButton.icon(
                  onPressed: () =>
                      ref.read(networkingProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重试'),
                ),
              ),
              const SizedBox(height: 16),
            ],
            _NetworkingAlignmentCard(
              defaultNetwork: dashboard.defaultNetwork,
              managedNetworks: dashboard.managedNetworks,
              deviceIdentity: dashboard.deviceIdentity,
              runtimeStatus: runtimeStatus,
            ),
            const SizedBox(height: 16),
            _LocalNetworksCard(
              runtimeStatus: runtimeStatus,
              managedNetworks: dashboard.managedNetworks,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: const TabBar(
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                indicator: BoxDecoration(
                  color: Color(0xFFFFE9D6),
                  borderRadius: BorderRadius.all(Radius.circular(18)),
                ),
                labelColor: Color(0xFFB45309),
                unselectedLabelColor: Color(0xFF6B7280),
                tabs: <Widget>[
                  Tab(text: '默认网络'),
                  Tab(text: '私有组网'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 920,
              child: TabBarView(
                children: <Widget>[
                  _OneClickNetworkingTab(
                    defaultNetwork: dashboard.defaultNetwork,
                    agentState: agentState,
                    isBusy: dashboard.isSubmitting,
                    isLocalReady: isLocalReady,
                    runtimeStatus: runtimeStatus,
                    onJoin: () => _joinDefaultNetwork(config),
                    onLeave: () =>
                        _leaveDefaultNetwork(dashboard.defaultNetwork),
                    onCopyIp: (String ip) => _copyToClipboard(
                      ip,
                      successMessage: '已复制虚拟 IP',
                    ),
                  ),
                  _PrivateNetworkingTab(
                    codeController: _networkCodeController,
                    nameController: _networkNameController,
                    descriptionController: _networkDescriptionController,
                    generatedCode: _generatedNetworkCode,
                    agentState: agentState,
                    isBusy: dashboard.isSubmitting,
                    isLocalReady: isLocalReady,
                    managedNetworks: dashboard.managedNetworks,
                    runtimeStatus: runtimeStatus,
                    onJoinPressed: () => _joinByInviteCode(config),
                    onHostPressed: () => _createPrivateNetwork(config),
                  ),
                ],
              ),
            ),
            if (networkingAsync.isLoading &&
                networkingAsync.valueOrNull == null)
              const Padding(
                padding: EdgeInsets.only(top: 18),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _refreshAll() async {
    await ref.read(networkingAgentRuntimeProvider.notifier).refreshNow();
    await ref.read(networkingProvider.notifier).refresh();
  }

  Future<void> _joinDefaultNetwork(AppConfig config) async {
    await ref.read(networkingAgentRuntimeProvider.notifier).activate();
    final AppConfig readyConfig = ref.read(appConfigProvider);
    if (!_ensureRegistered(readyConfig)) {
      return;
    }

    try {
      await ref
          .read(networkingProvider.notifier)
          .joinDefaultNetwork(deviceId: readyConfig.deviceId);
      unawaited(ref.read(networkingAgentRuntimeProvider.notifier).refreshNow());
      unawaited(ref.read(networkingProvider.notifier).refresh());
      _showPageMessage('默认网络入网请求已提交，等待本机 Agent 执行 join。');
    } on RealtimeError catch (error) {
      _showPageMessage(error.message);
    }
  }

  Future<void> _leaveDefaultNetwork(ManagedNetwork? defaultNetwork) async {
    final String networkId = defaultNetwork?.zeroTierNetworkId?.trim() ?? '';
    if (networkId.isEmpty) {
      _showPageMessage('当前默认网络缺少 ZeroTier Network ID，无法取消组网。');
      return;
    }

    try {
      await ref.read(networkingAgentRuntimeProvider.notifier).leaveNetwork(
            networkId,
            deactivateWhenIdle: true,
            source: 'ui.defaultNetworkCard',
          );
      await ref.read(networkingProvider.notifier).refresh();
      _showPageMessage('已取消默认网络组网。');
    } on RealtimeError catch (error) {
      _showPageMessage(error.message);
    } catch (error) {
      _showPageMessage('$error');
    }
  }

  Future<void> _joinByInviteCode(AppConfig config) async {
    await ref.read(networkingAgentRuntimeProvider.notifier).activate();
    final AppConfig readyConfig = ref.read(appConfigProvider);
    if (!_ensureRegistered(readyConfig)) {
      return;
    }

    final String code = _networkCodeController.text.trim();
    if (code.isEmpty) {
      _showPageMessage('请先输入邀请码。');
      return;
    }

    try {
      await ref.read(networkingProvider.notifier).joinByInviteCode(
            code: code,
            deviceId: readyConfig.deviceId,
          );
      unawaited(ref.read(networkingAgentRuntimeProvider.notifier).refreshNow());
      _showPageMessage('邀请码组网请求已提交，等待本机 Agent 执行 join。');
    } on RealtimeError catch (error) {
      _showPageMessage(error.message);
    }
  }

  Future<void> _createPrivateNetwork(AppConfig config) async {
    await ref.read(networkingAgentRuntimeProvider.notifier).activate();
    final AppConfig readyConfig = ref.read(appConfigProvider);
    if (!_ensureRegistered(readyConfig)) {
      return;
    }

    final String name = _networkNameController.text.trim();
    final String description = _networkDescriptionController.text.trim();
    if (name.isEmpty) {
      _showPageMessage('请先输入私有网络名称。');
      return;
    }

    try {
      final PrivateNetworkCreationResult result =
          await ref.read(networkingProvider.notifier).createPrivateNetwork(
                ownerDeviceId: readyConfig.deviceId,
                name: name,
                description: description,
              );
      setState(() {
        _generatedNetworkCode = result.inviteCode.code;
      });
      _showPageMessage('私有网络已创建，邀请码 ${result.inviteCode.code} 已生成。');
    } on RealtimeError catch (error) {
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

  String _errorText(Object? error) {
    if (error is RealtimeError) {
      return error.message;
    }
    return '$error';
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
              _InfoPill(
                  label: '运行状态', value: _serviceStateLabel(runtimeStatus)),
              _InfoPill(
                label: '节点',
                value: runtimeStatus.isNodeRunning ? '运行中' : '未运行',
              ),
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
                  label: 'Node ID',
                  value: runtimeStatus.nodeId.isEmpty
                      ? '等待初始化'
                      : runtimeStatus.nodeId,
                ),
                _MetricBlock(
                  label: 'Runtime Version',
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
            label: 'Device ID',
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
              _InfoPill(
                  label: 'Service State', value: runtimeStatus.serviceState),
              _InfoPill(
                label: 'Last Updated',
                value: _timeOrDash(runtimeStatus.updatedAt),
              ),
              _InfoPill(
                label: 'Last Error',
                value: runtimeStatus.lastError ?? '无',
              ),
              _InfoPill(label: 'Current Signal', value: signal.label),
            ],
          ),
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
                ? 'Windows libzt 运行时可用，Node ID 与网络状态会通过统一接口回流。'
                : '当前 ZeroTier 运行时仍不可用，本机无法执行真实入网动作。',
          ),
          const SizedBox(height: 10),
          _CapabilityItem(
            tone: deviceIdentity == null
                ? _CapabilityTone.warning
                : _CapabilityTone.ready,
            label: deviceIdentity == null
                ? '设备还未完成服务端 bootstrap，Agent Token 与 Device ID 尚未就绪。'
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
    required this.runtimeStatus,
    required this.managedNetworks,
  });

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
    required this.defaultNetwork,
    required this.agentState,
    required this.isBusy,
    required this.isLocalReady,
    required this.runtimeStatus,
    required this.onJoin,
    required this.onLeave,
    required this.onCopyIp,
  });

  final ManagedNetwork? defaultNetwork;
  final NetworkingAgentRuntimeState agentState;
  final bool isBusy;
  final bool isLocalReady;
  final ZeroTierRuntimeStatus runtimeStatus;
  final VoidCallback onJoin;
  final VoidCallback onLeave;
  final ValueChanged<String> onCopyIp;

  @override
  Widget build(BuildContext context) {
    final ZeroTierNetworkState? localState = defaultNetwork == null
        ? null
        : _findLocal(runtimeStatus, defaultNetwork!);
    final String transitionNetworkId =
        agentState.transitioningNetworkId?.trim().toLowerCase() ?? '';
    final String defaultNetworkId =
        defaultNetwork?.zeroTierNetworkId?.trim().toLowerCase() ?? '';
    final bool isTransitionLocked = agentState.isNetworkActionLocked &&
        (transitionNetworkId.isEmpty ||
            transitionNetworkId == defaultNetworkId);
    final bool isGrouped = localState != null &&
        (localState.isConnected ||
            localState.assignedAddresses.isNotEmpty ||
            localState.status == 'OK');
    final bool isConnecting = !isGrouped &&
        (isBusy ||
            agentState.isBootstrapping ||
            localState?.status == 'REQUESTING_CONFIGURATION');
    final bool isDisabled =
        agentState.isLocalInitializing || !isLocalReady || isTransitionLocked;
    final _NetworkVisualState visualState = _resolveNetworkVisualState(
      localState: localState,
      managedStatus: defaultNetwork?.status,
      isBusy: isTransitionLocked || isConnecting,
      lastError: agentState.lastError,
      runtimeServiceState: runtimeStatus.serviceState,
    );
    final _NetworkingOrbTone orbTone = isDisabled
        ? _NetworkingOrbTone.disabled
        : (isGrouped
            ? _NetworkingOrbTone.success
            : (isConnecting
                ? _NetworkingOrbTone.active
                : _NetworkingOrbTone.idle));

    return SectionCard(
      title: '默认网络编排',
      subtitle: visualState.message,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (defaultNetwork != null) ...<Widget>[
            _ManagedNetworkCard(
              network: defaultNetwork!,
              localState: localState,
              visualState: visualState,
              accentColor: const Color(0xFFF97316),
            ),
            const SizedBox(height: 18),
          ] else ...<Widget>[
            _NetworkStateBanner(state: visualState),
            const SizedBox(height: 18),
          ],
          _NetworkingActionOrb(
            label: isDisabled
                ? (isTransitionLocked ? '收口中' : '本地初始化')
                : (isGrouped ? '已组网' : (isConnecting ? '组网中' : '开始组网')),
            icon: isDisabled
                ? Icons.power_settings_new_rounded
                : (isGrouped
                    ? Icons.check_circle_rounded
                    : (isConnecting
                        ? Icons.sync_rounded
                        : Icons.flash_on_rounded)),
            subtitle: isDisabled
                ? (isTransitionLocked
                    ? (agentState.networkTransitionLabel ??
                        '正在等待本地 ZeroTier 链路恢复稳定')
                    : '等待本地 ZeroTier 初始化完成')
                : (isGrouped
                    ? '按钮为绿色\n点击即可取消组网'
                    : (isConnecting
                        ? '按钮为蓝色\n点击即可中止组网'
                        : '本地准备完成后\n点击开始接入默认网络')),
            tone: orbTone,
            spinning: isConnecting,
            onTap: isDisabled
                ? null
                : ((isGrouped || isConnecting) ? onLeave : onJoin),
          ),
          if (localState != null &&
              localState.assignedAddresses.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            _VirtualIpPanel(
              addresses: localState.assignedAddresses,
              onCopy: onCopyIp,
            ),
          ],
          const SizedBox(height: 20),
          _InlineHint(
            message: isDisabled
                ? (isTransitionLocked
                    ? '离网收口完成前，按钮会暂时灰掉，避免旧事件和新 join 链路互相打架。'
                    : '未完成本地初始化前，圆形开始组网按钮会保持灰色。')
                : (isGrouped
                    ? '绿色表示已经组网成功。'
                    : (isConnecting
                        ? '蓝色表示正在组网，可直接点击取消。'
                        : '点击开始组网后，应用才会启动 Agent、完成注册并接入后台编排。')),
          ),
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
    required this.codeController,
    required this.nameController,
    required this.descriptionController,
    required this.generatedCode,
    required this.agentState,
    required this.isBusy,
    required this.isLocalReady,
    required this.managedNetworks,
    required this.runtimeStatus,
    required this.onJoinPressed,
    required this.onHostPressed,
  });

  final TextEditingController codeController;
  final TextEditingController nameController;
  final TextEditingController descriptionController;
  final String? generatedCode;
  final NetworkingAgentRuntimeState agentState;
  final bool isBusy;
  final bool isLocalReady;
  final List<ManagedNetwork> managedNetworks;
  final ZeroTierRuntimeStatus runtimeStatus;
  final VoidCallback onJoinPressed;
  final VoidCallback onHostPressed;

  @override
  Widget build(BuildContext context) {
    final bool isDisabled = agentState.isLocalInitializing || !isLocalReady;

    return SectionCard(
      title: '私有网络编排',
      subtitle: '先完成本地 ZeroTier 初始化，再通过邀请码或创建私有网络发起后台组网。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: nameController,
            enabled: !isBusy && !isDisabled,
            decoration: const InputDecoration(
              labelText: '私有网络名称',
              hintText: '例如 My Private Network',
              prefixIcon: Icon(Icons.drive_file_rename_outline_rounded),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: descriptionController,
            enabled: !isBusy && !isDisabled,
            decoration: const InputDecoration(
              labelText: '网络说明',
              hintText: '例如 Private mesh for trusted devices',
              prefixIcon: Icon(Icons.notes_rounded),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: codeController,
            enabled: !isBusy && !isDisabled,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: '邀请码',
              hintText: '输入服务端返回的邀请码',
              prefixIcon: Icon(Icons.password_rounded),
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 18,
            runSpacing: 18,
            children: <Widget>[
              _NetworkingActionOrb(
                label: isDisabled ? '本地初始化' : (isBusy ? '处理中' : '加入网络'),
                icon: isDisabled
                    ? Icons.power_settings_new_rounded
                    : (isBusy
                        ? Icons.hourglass_top_rounded
                        : Icons.login_rounded),
                subtitle: isDisabled
                    ? '等待本地 ZeroTier 初始化'
                    : '按邀请码发起请求\n等待本机 Agent 执行',
                diameter: 190,
                tone: isDisabled
                    ? _NetworkingOrbTone.disabled
                    : _NetworkingOrbTone.idle,
                onTap: isBusy || isDisabled ? null : onJoinPressed,
              ),
              _NetworkingActionOrb(
                label: isDisabled ? '本地初始化' : (isBusy ? '处理中' : '主持网络'),
                icon: isDisabled
                    ? Icons.power_settings_new_rounded
                    : (isBusy
                        ? Icons.hourglass_top_rounded
                        : Icons.wifi_tethering_rounded),
                subtitle: isDisabled ? '等待本地 ZeroTier 初始化' : '创建私有网络\n返回邀请码',
                diameter: 190,
                tone: isDisabled
                    ? _NetworkingOrbTone.disabled
                    : _NetworkingOrbTone.idle,
                onTap: isBusy || isDisabled ? null : onHostPressed,
              ),
            ],
          ),
          if (generatedCode != null) ...<Widget>[
            const SizedBox(height: 22),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: <Color>[Color(0xFFFFF1E6), Color(0xFFFFE0BF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '最新邀请码',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: const Color(0xFF9A3412),
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    generatedCode!,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 4,
                          color: const Color(0xFF7C2D12),
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text('可将该邀请码分发给其他设备，通过同一编排链路接入私有网络。'),
                ],
              ),
            ),
          ],
          const SizedBox(height: 22),
          Text(
            '服务端托管网络',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 12),
          if (managedNetworks.isEmpty)
            const _EmptyStateBox(message: '当前设备还没有服务端侧的托管网络记录。')
          else
            Column(
              children: managedNetworks
                  .map(
                    (ManagedNetwork network) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _ManagedNetworkCard(
                        network: network,
                        localState: _findLocal(runtimeStatus, network),
                        visualState: _resolveNetworkVisualState(
                          localState: _findLocal(runtimeStatus, network),
                          managedStatus: network.status,
                          isBusy: isBusy,
                          lastError: agentState.lastError,
                          runtimeServiceState: runtimeStatus.serviceState,
                        ),
                        accentColor: network.isDefault
                            ? const Color(0xFF2563EB)
                            : const Color(0xFFEA580C),
                      ),
                    ),
                  )
                  .toList(),
            ),
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

class _ManagedNetworkCard extends StatelessWidget {
  const _ManagedNetworkCard({
    required this.network,
    required this.localState,
    required this.visualState,
    required this.accentColor,
  });

  final ManagedNetwork network;
  final ZeroTierNetworkState? localState;
  final _NetworkVisualState visualState;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accentColor.withValues(alpha: 0.24)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: accentColor.withValues(alpha: 0.08),
            blurRadius: 24,
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
                  network.name.isEmpty ? network.id : network.name,
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
          if (network.description?.trim().isNotEmpty == true) ...<Widget>[
            const SizedBox(height: 8),
            Text(network.description!),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _InfoPill(label: '类型', value: network.type),
              _InfoPill(label: '编排状态', value: network.status),
              if (network.zeroTierNetworkName?.trim().isNotEmpty == true)
                _InfoPill(
                    label: 'ZeroTier 名称', value: network.zeroTierNetworkName!),
              if (network.zeroTierNetworkId?.trim().isNotEmpty == true)
                _InfoPill(
                    label: 'ZeroTier ID', value: network.zeroTierNetworkId!),
              _InfoPill(
                label: '本地映射',
                value: localState == null ? '未发现' : localState!.status,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _NetworkStateBanner(state: visualState),
          if (localState != null &&
              localState!.assignedAddresses.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _NetworkSegmentPanel(addresses: localState!.assignedAddresses),
            const SizedBox(height: 12),
            _AddressWrap(addresses: localState!.assignedAddresses),
          ],
        ],
      ),
    );
  }
}

class _LocalNetworkCard extends StatelessWidget {
  const _LocalNetworkCard({
    required this.network,
    required this.managedNetwork,
  });

  final ZeroTierNetworkState network;
  final ManagedNetwork? managedNetwork;

  @override
  Widget build(BuildContext context) {
    final Color accentColor =
        network.isConnected ? const Color(0xFF15803D) : const Color(0xFFB45309);
    final _NetworkVisualState visualState = _resolveNetworkVisualState(
      localState: network,
      managedStatus: managedNetwork?.status,
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
              _InfoPill(label: 'Network ID', value: network.networkId),
              _InfoPill(
                  label: 'Authorized',
                  value: network.isAuthorized ? 'Yes' : 'No'),
              _InfoPill(
                  label: 'Connected',
                  value: network.isConnected ? 'Yes' : 'No'),
              if (managedNetwork != null)
                _InfoPill(label: '服务端网络', value: managedNetwork!.name),
            ],
          ),
          const SizedBox(height: 12),
          _NetworkStateBanner(state: visualState),
          const SizedBox(height: 12),
          if (network.assignedAddresses.isEmpty)
            const Text('暂未分配托管地址。')
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

class _NetworkStateBanner extends StatelessWidget {
  const _NetworkStateBanner({
    required this.state,
  });

  final _NetworkVisualState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: state.background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(state.icon, color: state.foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  state.label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: state.foreground,
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  state.message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: state.foreground,
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

class _InlineBanner extends StatelessWidget {
  const _InlineBanner({
    required this.icon,
    required this.color,
    required this.background,
    required this.title,
    required this.message,
    this.trailing,
  });

  final IconData icon;
  final Color color;
  final Color background;
  final String title;
  final String message;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                Text(message),
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
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
    final List<String> segments = _derivedSegmentsFromAddresses(addresses);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF8EF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF86EFAC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '已分配虚拟 IP',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: const Color(0xFF166534),
                  fontWeight: FontWeight.w800,
                ),
          ),
          if (segments.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '共享网段：${segments.join(' / ')}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF166534),
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
          const SizedBox(height: 12),
          ...addresses.map(
            (String address) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
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

class _NetworkingActionOrb extends StatelessWidget {
  const _NetworkingActionOrb({
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
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = onTap != null;
    final ({List<Color> colors, Color shadow}) palette = switch (tone) {
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
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.82,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: diameter,
            height: diameter,
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
                  blurRadius: 28,
                  offset: const Offset(0, 16),
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
                  color: Colors.white.withValues(alpha: 0.30),
                  width: 1.6,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  AnimatedRotation(
                    turns: spinning ? 1 : 0,
                    duration: const Duration(milliseconds: 1200),
                    child:
                        Icon(icon, size: diameter * 0.18, color: Colors.white),
                  ),
                  SizedBox(height: diameter * 0.06),
                  Text(
                    label,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: diameter * 0.05),
                  Text(
                    subtitle,
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

_RuntimeSignal _resolveRuntimeSignal({
  required ZeroTierRuntimeStatus runtimeStatus,
  required List<ZeroTierRuntimeEvent> recentEvents,
  required String? lastError,
}) {
  final bool hasActiveJoinedNetwork = runtimeStatus.joinedNetworks.any(
    (ZeroTierNetworkState network) =>
        network.isConnected ||
        network.assignedAddresses.isNotEmpty ||
        network.status == 'OK',
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

  if (hasActiveJoinedNetwork) {
    return const _RuntimeSignal(
      label: '网络已在线',
      message: '当前本机仍检测到可用的 ZeroTier 本地网络映射，运行时状态以实际 joined network 为准。',
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
              : 'ZeroTier 节点当前失去在线连接，这更像是连通性抖动，不等同于进程重启。',
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
      return const _RuntimeSignal(
        label: '运行稳定',
        message: 'ZeroTier runtime 正在运行，等待新的组网事件或网络状态变化。',
        icon: Icons.verified_rounded,
        background: Color(0xFFEAF8EF),
        foreground: Color(0xFF15803D),
      );
    case 'offline':
      return const _RuntimeSignal(
        label: '节点离线',
        message: 'ZeroTier 节点当前未在线，但本地 runtime 仍然存活；这更像是离线状态，不等同于重新启动中。',
        icon: Icons.wifi_off_rounded,
        background: Color(0xFFFFF4E8),
        foreground: Color(0xFFB45309),
      );
    case 'starting':
      return const _RuntimeSignal(
        label: '正在启动',
        message: '本机 ZeroTier runtime 已开始启动，Node ID 与网络状态会在后续事件中回流。',
        icon: Icons.autorenew_rounded,
        background: Color(0xFFEAF2FF),
        foreground: Color(0xFF1D4ED8),
      );
    case 'prepared':
      return const _RuntimeSignal(
        label: '本地已就绪',
        message: '运行时环境已经准备完成，下一步可以发起节点启动和入网动作。',
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
  required bool isBusy,
  required String? lastError,
  required String runtimeServiceState,
}) {
  if (_isAuthorizationPendingLocalNetwork(localState)) {
    return const _NetworkVisualState(
      label: 'Waiting Authorization',
      message:
          'The ZeroTier network is visible locally, but it is still waiting for authorization.',
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
      message: '本地 ZeroTier 节点当前离线，网络条目暂不视为可继续操作完成。',
      icon: Icons.wifi_off_rounded,
      background: Color(0xFFFFF4E8),
      foreground: Color(0xFFB45309),
    );
  }

  if (localState == null) {
    if (isBusy) {
      return const _NetworkVisualState(
        label: '正在编排',
        message: '当前正在等待本机 Agent 和 ZeroTier runtime 完成入网或离网收口动作。',
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

  if (localState.status == 'ACCESS_DENIED' || !localState.isAuthorized) {
    return const _NetworkVisualState(
      label: '等待网络授权',
      message: 'ZeroTier 已看到这条网络，但当前仍处于等待授权阶段，还不能视为组网完成。',
      icon: Icons.schedule_rounded,
      background: Color(0xFFFFF4E8),
      foreground: Color(0xFFB45309),
    );
  }

  if (localState.assignedAddresses.isNotEmpty) {
    return const _NetworkVisualState(
      label: '网络已在线',
      message: '本机已经接入这条网络，当前可以继续查看托管地址与后续可达性。',
      icon: Icons.check_circle_rounded,
      background: Color(0xFFEAF8EF),
      foreground: Color(0xFF15803D),
    );
  }

  if (_isHandshakePendingLocalNetwork(localState, managedStatus)) {
    return const _NetworkVisualState(
      label: 'Waiting Handshake',
      message:
          'The network is already accepted, but the node is still waiting for controller handshake or managed address assignment.',
      icon: Icons.hourglass_top_rounded,
      background: Color(0xFFEAF2FF),
      foreground: Color(0xFF1D4ED8),
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
  return localState.status == 'ACCESS_DENIED' || !localState.isAuthorized;
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
  if (localState.isConnected || localState.assignedAddresses.isNotEmpty) {
    return false;
  }

  final String normalizedManagedStatus =
      managedStatus?.trim().toLowerCase() ?? '';
  final bool serverAlreadyAccepted = normalizedManagedStatus == 'authorized' ||
      normalizedManagedStatus == 'active';
  final bool localStillNegotiating =
      localState.status == 'REQUESTING_CONFIGURATION' ||
          localState.status == 'OK' ||
          localState.status == 'UNKNOWN';

  return serverAlreadyAccepted || localStillNegotiating;
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
