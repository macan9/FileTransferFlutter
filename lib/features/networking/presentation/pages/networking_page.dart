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
      ref.read(networkingAgentRuntimeProvider.notifier).activate();
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
              currentDeviceId: config.deviceId,
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
                  SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _OneClickNetworkingTab(
                      defaultNetwork: dashboard.defaultNetwork,
                      currentDeviceId: config.deviceId,
                      agentState: agentState,
                      isBusy: dashboard.isSubmitting,
                      activeAction: dashboard.activeAction,
                      isLocalReady: isLocalReady,
                      runtimeStatus: runtimeStatus,
                      onJoin: () => _joinDefaultNetwork(config),
                      onLeave: () => _leaveDefaultNetwork(
                          dashboard.defaultNetwork, runtimeStatus),
                      onCopyIp: (String ip) => _copyToClipboard(
                        ip,
                        successMessage: '已复制虚拟 IP',
                      ),
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _PrivateNetworkingTab(
                      codeController: _networkCodeController,
                      nameController: _networkNameController,
                      descriptionController: _networkDescriptionController,
                      generatedCode: _generatedNetworkCode,
                      currentDeviceId: config.deviceId,
                      agentState: agentState,
                      isBusy: dashboard.isSubmitting,
                      isLocalReady: isLocalReady,
                      managedNetworks: dashboard.managedNetworks,
                      runtimeStatus: runtimeStatus,
                      onJoinPressed: () => _joinByInviteCode(config),
                      onHostPressed: () => _createPrivateNetwork(config),
                    ),
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

  Future<void> _leaveDefaultNetwork(
    ManagedNetwork? defaultNetwork,
    ZeroTierRuntimeStatus runtimeStatus,
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

      await ref.read(networkingProvider.notifier).leaveDefaultNetwork(
            deviceId: readyConfig.deviceId,
          );
      unawaited(ref.read(networkingAgentRuntimeProvider.notifier).refreshNow());
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
    required this.defaultNetwork,
    required this.currentDeviceId,
    required this.agentState,
    required this.isBusy,
    required this.activeAction,
    required this.isLocalReady,
    required this.runtimeStatus,
    required this.onJoin,
    required this.onLeave,
    required this.onCopyIp,
  });

  final ManagedNetwork? defaultNetwork;
  final String currentDeviceId;
  final NetworkingAgentRuntimeState agentState;
  final bool isBusy;
  final String? activeAction;
  final bool isLocalReady;
  final ZeroTierRuntimeStatus runtimeStatus;
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
    final String? currentMembershipStatus = _currentMembershipStatus(
      defaultNetwork,
      currentDeviceId,
    );
    final bool hasServiceAssignedIp = _hasCurrentServiceAssignedIp(
      defaultNetwork,
      currentDeviceId,
    );
    final bool isMembershipRevoked =
        currentMembershipStatus?.trim().toLowerCase() == 'revoked';
    final ZeroTierNetworkState? localState = isMembershipRevoked &&
            _isEffectivelyLeftLocalNetwork(rawLocalState)
        ? null
        : rawLocalState;
    final bool isMembershipAccepted =
        _isAcceptedMembershipStatus(currentMembershipStatus);
    final bool isSubmittingJoin = activeAction == 'join-default-network';
    final bool isSubmittingLeave = activeAction == 'leave-default-network';
    final bool isLocalAuthorizationPending =
        _isAuthorizationPendingLocalNetwork(localState);
    final bool isTransitionLocked =
        (agentState.isNetworkActionLocked || isSubmittingLeave) &&
            (transitionNetworkId.isEmpty ||
                transitionNetworkId == defaultNetworkId);
    final bool hasLocalMapping = localState != null &&
        !isLocalAuthorizationPending &&
        (localState.isConnected ||
            localState.assignedAddresses.isNotEmpty ||
            (localState.status == 'OK' && hasServiceAssignedIp));
    final bool isClosing =
        isTransitionLocked || (isMembershipRevoked && localState != null);
    final bool isGrouped = !isMembershipRevoked && hasLocalMapping;
    final bool isAwaitingAuthorization =
        !isClosing && isLocalAuthorizationPending;
    final bool localStillNegotiating = localState != null &&
        !isGrouped &&
        (localState.status == 'REQUESTING_CONFIGURATION' ||
            localState.status == 'OK' ||
            localState.status == 'UNKNOWN');
    final bool hasJoinIntentEvidence = isSubmittingJoin ||
        localStillNegotiating ||
        _hasRecentJoinIntent(agentState.recentRuntimeEvents, defaultNetworkId);
    final bool isActivelyJoining = isSubmittingJoin || localStillNegotiating;
    final _DefaultNetworkFlowState flowState = _resolveDefaultNetworkFlowState(
      isLocalReady: isLocalReady,
      isLocalInitializing: agentState.isLocalInitializing,
      isClosing: isClosing,
      isGrouped: isGrouped,
      isAwaitingAuthorization: isAwaitingAuthorization,
      isSubmittingJoin: isSubmittingJoin,
      isBootstrapping: agentState.isBootstrapping,
      localState: localState,
      managedStatus: currentMembershipStatus,
      hasServiceAssignedIp: hasServiceAssignedIp,
      hasMembershipAccepted: isMembershipAccepted,
      hasJoinIntentEvidence: hasJoinIntentEvidence,
      hasLastError: agentState.lastError?.trim().isNotEmpty == true,
    );
    final _DefaultNetworkFlowPresentation flowPresentation =
        _describeDefaultNetworkFlowState(
      flowState,
      transitionLabel: agentState.networkTransitionLabel,
      hasServiceAssignedIp: hasServiceAssignedIp,
    );
    final bool isDisabled = flowPresentation.isDisabled ||
        agentState.isLocalInitializing ||
        !isLocalReady;
    final _NetworkVisualState visualState = _resolveNetworkVisualState(
      localState: localState,
      managedStatus: currentMembershipStatus,
      hasServiceAssignedIp: hasServiceAssignedIp,
      hasJoinIntentEvidence: hasJoinIntentEvidence,
      isBusy: isClosing || isActivelyJoining,
      lastError: agentState.lastError,
      runtimeServiceState: runtimeStatus.serviceState,
    );

    return SectionCard(
      title: '默认网络编排',
      subtitle: visualState.message,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (defaultNetwork != null) ...<Widget>[
            _ManagedNetworkCard(
              network: defaultNetwork!,
              currentDeviceId: currentDeviceId,
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
          if (!isClosing &&
              localState != null &&
              localState.assignedAddresses.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            _VirtualIpPanel(
              addresses: localState.assignedAddresses,
              onCopy: onCopyIp,
            ),
          ],
          const SizedBox(height: 20),
          _InlineHint(
            message: flowPresentation.hint,
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
    required this.currentDeviceId,
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
  final String currentDeviceId;
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
                        currentDeviceId: currentDeviceId,
                        localState: _findLocal(runtimeStatus, network),
                        visualState: _resolveNetworkVisualState(
                          localState: _findLocal(runtimeStatus, network),
                          managedStatus: _currentMembershipStatus(
                            network,
                            currentDeviceId,
                          ),
                          hasServiceAssignedIp: _hasCurrentServiceAssignedIp(
                            network,
                            currentDeviceId,
                          ),
                          hasJoinIntentEvidence: false,
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
    required this.currentDeviceId,
    required this.localState,
    required this.visualState,
    required this.accentColor,
  });

  final ManagedNetwork network;
  final String currentDeviceId;
  final ZeroTierNetworkState? localState;
  final _NetworkVisualState visualState;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final ManagedNetworkMembership? currentMembership =
        _findCurrentMembership();
    final String? currentMembershipStatus = currentMembership?.status;
    final bool hasAcceptedMembership =
        _isAcceptedMembershipStatus(currentMembershipStatus);
    final String? serverAssignedIp = hasAcceptedMembership &&
            currentMembership?.zeroTierAssignedIp?.trim().isNotEmpty == true
        ? currentMembership!.zeroTierAssignedIp!.trim()
        : null;
    final bool showServerAssignedIp = localState != null &&
        localState!.status == 'OK' &&
        localState!.assignedAddresses.isEmpty &&
        serverAssignedIp != null;

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
              if (serverAssignedIp != null)
                _InfoPill(label: 'Service IP', value: serverAssignedIp),
            ],
          ),
          const SizedBox(height: 12),
          _NetworkStateBanner(state: visualState),
          if (showServerAssignedIp) ...<Widget>[
            const SizedBox(height: 12),
            _NetworkSegmentPanel(addresses: <String>[serverAssignedIp]),
            const SizedBox(height: 12),
            _AddressWrap(addresses: <String>[serverAssignedIp]),
          ],
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

  ManagedNetworkMembership? _findCurrentMembership() {
    final String targetDeviceId = currentDeviceId.trim();
    if (targetDeviceId.isEmpty) {
      return null;
    }
    for (final ManagedNetworkMembership membership in network.memberships) {
      if (membership.deviceId.trim() == targetDeviceId) {
        return membership;
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
    final Color accentColor =
        network.isConnected ? const Color(0xFF15803D) : const Color(0xFFB45309);
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
  required bool hasServiceAssignedIp,
  required bool hasJoinIntentEvidence,
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
    if (!hasJoinIntentEvidence) {
      return const _NetworkVisualState(
        label: '尚未接入',
        message: '本机当前还未开始默认网络接入，点击开始组网后再进入后续握手与配置流程。',
        icon: Icons.link_off_rounded,
        background: Color(0xFFF3F4F6),
        foreground: Color(0xFF4B5563),
      );
    }
    if (_isAcceptedMembershipStatus(managedStatus) && hasServiceAssignedIp) {
      return const _NetworkVisualState(
        label: '等待本机入网',
        message: '服务端已经分配 Service IP，正在等待本机 Agent 和 ZeroTier runtime 建立本地映射。',
        icon: Icons.hourglass_top_rounded,
        background: Color(0xFFEAF2FF),
        foreground: Color(0xFF1D4ED8),
      );
    }
    if (_isAcceptedMembershipStatus(managedStatus)) {
      return const _NetworkVisualState(
        label: '正在入网',
        message: '服务端已接受当前设备入网，正在等待本机 ZeroTier 本地链路建立。',
        icon: Icons.sync_rounded,
        background: Color(0xFFEAF2FF),
        foreground: Color(0xFF1D4ED8),
      );
    }
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

  if (_isRevokedMembershipStatus(managedStatus)) {
    return const _NetworkVisualState(
      label: '收口中',
      message: '服务端已撤销当前设备的组网资格，正在等待本地 ZeroTier 链路完成离网收口。',
      icon: Icons.hourglass_top_rounded,
      background: Color(0xFFF3F4F6),
      foreground: Color(0xFF6B7280),
    );
  }

  if (_isAuthorizationPendingLocalNetwork(localState)) {
    return const _NetworkVisualState(
      label: '等待网络授权',
      message: 'ZeroTier 已看到这条网络，但当前仍处于等待授权阶段，还不能视为组网完成。',
      icon: Icons.schedule_rounded,
      background: Color(0xFFFFF4E8),
      foreground: Color(0xFFB45309),
    );
  }

  if (localState.status == 'REQUESTING_CONFIGURATION' && hasServiceAssignedIp) {
    return const _NetworkVisualState(
      label: '等待本地配置',
      message: '服务端已完成分配，当前正在等待本地 ZeroTier 收敛地址与路由配置。',
      icon: Icons.hourglass_top_rounded,
      background: Color(0xFFEAF2FF),
      foreground: Color(0xFF1D4ED8),
    );
  }

  if (localState.assignedAddresses.isNotEmpty ||
      (localState.status == 'OK' && hasServiceAssignedIp)) {
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
      label: '本地握手中',
      message: '本机已经看到该网络，但仍在等待本地握手或网络配置进一步收敛。',
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

bool _hasRecentJoinIntent(
  List<ZeroTierRuntimeEvent> events,
  String networkId,
) {
  final String targetNetworkId = networkId.trim().toLowerCase();
  for (final ZeroTierRuntimeEvent event in events) {
    final String eventNetworkId = event.networkId?.trim().toLowerCase() ?? '';
    if (targetNetworkId.isNotEmpty && eventNetworkId != targetNetworkId) {
      continue;
    }
    switch (event.type) {
      case ZeroTierRuntimeEventType.networkJoining:
      case ZeroTierRuntimeEventType.networkWaitingAuthorization:
      case ZeroTierRuntimeEventType.networkOnline:
      case ZeroTierRuntimeEventType.ipAssigned:
        return true;
      case ZeroTierRuntimeEventType.environmentReady:
      case ZeroTierRuntimeEventType.permissionRequired:
      case ZeroTierRuntimeEventType.nodeStarted:
      case ZeroTierRuntimeEventType.nodeOnline:
      case ZeroTierRuntimeEventType.nodeOffline:
      case ZeroTierRuntimeEventType.nodeStopped:
      case ZeroTierRuntimeEventType.networkLeft:
      case ZeroTierRuntimeEventType.error:
        continue;
    }
  }
  return false;
}

bool _isEffectivelyLeftLocalNetwork(ZeroTierNetworkState? localState) {
  if (localState == null) {
    return true;
  }
  if (localState.isConnected || localState.assignedAddresses.isNotEmpty) {
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
  required bool isBootstrapping,
  required ZeroTierNetworkState? localState,
  required String? managedStatus,
  required bool hasServiceAssignedIp,
  required bool hasMembershipAccepted,
  required bool hasJoinIntentEvidence,
  required bool hasLastError,
}) {
  if (isClosing) {
    return _DefaultNetworkFlowState.closing;
  }
  if (isLocalInitializing || !isLocalReady) {
    return _DefaultNetworkFlowState.initializing;
  }
  if (isGrouped) {
    return _DefaultNetworkFlowState.online;
  }
  if (isAwaitingAuthorization) {
    return _DefaultNetworkFlowState.awaitingAuthorization;
  }
  if (localState != null &&
      (localState.status == 'REQUESTING_CONFIGURATION' ||
          (localState.status == 'OK' && !hasServiceAssignedIp) ||
          localState.status == 'UNKNOWN')) {
    return _DefaultNetworkFlowState.awaitingLocalConfig;
  }
  if (hasMembershipAccepted && localState == null && hasJoinIntentEvidence) {
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
        label: '本地初始化',
        subtitle: '等待本地 ZeroTier 初始化完成',
        hint: '未完成本地初始化前，圆形按钮会保持灰色。',
        icon: Icons.power_settings_new_rounded,
        tone: _NetworkingOrbTone.disabled,
        isInProgress: false,
        isDisabled: true,
        usesLeaveAction: false,
      );
    case _DefaultNetworkFlowState.idle:
      return const _DefaultNetworkFlowPresentation(
        label: '开始组网',
        subtitle: '本地准备完成后\n点击开始接入默认网络',
        hint: '点击开始组网后，应用会请求后端编排并等待本机 Agent 执行 join。',
        icon: Icons.flash_on_rounded,
        tone: _NetworkingOrbTone.idle,
        isInProgress: false,
        isDisabled: false,
        usesLeaveAction: false,
      );
    case _DefaultNetworkFlowState.orchestrating:
      return const _DefaultNetworkFlowPresentation(
        label: '组网中',
        subtitle: '正在请求服务端编排\n等待本机 Agent 开始执行',
        hint: '这一步主要发生在服务端编排和本地 Agent 接单之间。',
        icon: Icons.sync_rounded,
        tone: _NetworkingOrbTone.active,
        isInProgress: true,
        isDisabled: false,
        usesLeaveAction: true,
      );
    case _DefaultNetworkFlowState.awaitingLocalNetwork:
      return _DefaultNetworkFlowPresentation(
        label: '等待本机入网',
        subtitle: hasServiceAssignedIp
            ? '服务端已分配地址\n等待本地建立网络映射'
            : '服务端已接受入网\n等待本地看到该网络',
        hint: '控制面已经推进，但本地 runtime 还没稳定看到默认网络。',
        icon: Icons.sync_rounded,
        tone: _NetworkingOrbTone.active,
        isInProgress: true,
        isDisabled: false,
        usesLeaveAction: true,
      );
    case _DefaultNetworkFlowState.awaitingLocalConfig:
      return const _DefaultNetworkFlowPresentation(
        label: '等待本地配置',
        subtitle: '本地已看到默认网络\n等待地址和路由收敛',
        hint: '当前通常对应 REQUESTING_CONFIGURATION，说明控制面已完成但本地配置尚未收敛。',
        icon: Icons.hourglass_top_rounded,
        tone: _NetworkingOrbTone.active,
        isInProgress: true,
        isDisabled: false,
        usesLeaveAction: true,
      );
    case _DefaultNetworkFlowState.awaitingAuthorization:
      return const _DefaultNetworkFlowPresentation(
        label: '等待授权',
        subtitle: '本地已看到该网络\n等待控制面授权完成',
        hint: '这一步说明本地 join 已发起，但服务端还没有确认授权。',
        icon: Icons.schedule_rounded,
        tone: _NetworkingOrbTone.active,
        isInProgress: true,
        isDisabled: false,
        usesLeaveAction: true,
      );
    case _DefaultNetworkFlowState.online:
      return const _DefaultNetworkFlowPresentation(
        label: '取消组网',
        subtitle: '按钮为绿色\n点击即可取消组网',
        hint: '绿色表示当前默认网络已经真实在线。',
        icon: Icons.check_circle_rounded,
        tone: _NetworkingOrbTone.success,
        isInProgress: false,
        isDisabled: false,
        usesLeaveAction: true,
      );
    case _DefaultNetworkFlowState.closing:
      return _DefaultNetworkFlowPresentation(
        label: '收口中',
        subtitle: transitionLabel ?? '正在离开 ZeroTier 网络并收口本地链路',
        hint: '收口完成前，按钮会保持灰色，避免旧事件和新 join 链路互相打架。',
        icon: Icons.power_settings_new_rounded,
        tone: _NetworkingOrbTone.disabled,
        isInProgress: false,
        isDisabled: true,
        usesLeaveAction: true,
      );
    case _DefaultNetworkFlowState.retryableError:
      return const _DefaultNetworkFlowPresentation(
        label: '重新组网',
        subtitle: '上一次组网出现异常\n点击重新发起编排',
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
