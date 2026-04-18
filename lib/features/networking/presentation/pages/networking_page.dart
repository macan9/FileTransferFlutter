import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/managed_network.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/private_network_creation_result.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
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
    _networkDescriptionController = TextEditingController(text: 'Private mesh');
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
    final AppConfig config = ref.watch(appConfigProvider);
    final AsyncValue<NetworkingDashboardState> networkingAsync =
        ref.watch(networkingProvider);
    final NetworkingDashboardState dashboard =
        networkingAsync.valueOrNull ?? const NetworkingDashboardState.initial();
    final NetworkingAgentRuntimeState agentState =
        ref.watch(networkingAgentRuntimeProvider);

    final bool isRegistered = config.agentToken.trim().isNotEmpty &&
        config.zeroTierNodeId.trim().isNotEmpty;

    return DefaultTabController(
      length: 2,
      child: RefreshIndicator(
        onRefresh: () async {
          await ref.read(networkingAgentRuntimeProvider.notifier).refreshNow();
          await ref.read(networkingProvider.notifier).refresh();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _AgentOverviewCard(
              config: config,
              agentState: agentState,
              isRegistered: isRegistered,
              onRetry: () async {
                await ref
                    .read(networkingAgentRuntimeProvider.notifier)
                    .refreshNow();
                await ref.read(networkingProvider.notifier).refresh();
              },
              onCopyToken: config.agentToken.trim().isEmpty
                  ? null
                  : () => _copyToClipboard(
                        config.agentToken,
                        successMessage: 'agentToken 已复制。',
                      ),
            ),
            const SizedBox(height: 16),
            if (networkingAsync.hasError)
              _ErrorCard(
                title: '控制面加载失败',
                message: _errorText(networkingAsync.error),
                onRetry: () => ref.read(networkingProvider.notifier).refresh(),
              )
            else ...<Widget>[
              _NetworkingDocReviewCard(
                defaultNetwork: dashboard.defaultNetwork,
                managedNetworkCount: dashboard.managedNetworks.length,
                deviceIdentity: dashboard.deviceIdentity,
                agentState: agentState,
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
                    Tab(text: '一键组网'),
                    Tab(text: '私域组网'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 800,
                child: TabBarView(
                  children: <Widget>[
                    _OneClickNetworkingTab(
                      defaultNetwork: dashboard.defaultNetwork,
                      isBusy: dashboard.isSubmitting,
                      isRegistered: isRegistered,
                      onPressed: () => _joinDefaultNetwork(config),
                    ),
                    _PrivateNetworkingTab(
                      codeController: _networkCodeController,
                      nameController: _networkNameController,
                      descriptionController: _networkDescriptionController,
                      generatedCode: _generatedNetworkCode,
                      isBusy: dashboard.isSubmitting,
                      isRegistered: isRegistered,
                      onJoinPressed: () => _joinByInviteCode(config),
                      onHostPressed: () => _createPrivateNetwork(config),
                      managedNetworks: dashboard.managedNetworks,
                    ),
                  ],
                ),
              ),
            ],
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

  Future<void> _joinDefaultNetwork(AppConfig config) async {
    if (!_ensureRegistered(config)) {
      return;
    }

    try {
      await ref
          .read(networkingProvider.notifier)
          .joinDefaultNetwork(deviceId: config.deviceId);
      _showPageMessage('已向服务端发起一键组网请求，等待本机 agent 执行加网命令。');
    } on RealtimeError catch (error) {
      _showPageMessage(error.message);
    }
  }

  Future<void> _joinByInviteCode(AppConfig config) async {
    if (!_ensureRegistered(config)) {
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
            deviceId: config.deviceId,
          );
      _showPageMessage('已提交邀请码入网请求，等待本机 agent 执行加网命令。');
    } on RealtimeError catch (error) {
      _showPageMessage(error.message);
    }
  }

  Future<void> _createPrivateNetwork(AppConfig config) async {
    if (!_ensureRegistered(config)) {
      return;
    }

    final String name = _networkNameController.text.trim();
    final String description = _networkDescriptionController.text.trim();
    if (name.isEmpty) {
      _showPageMessage('请先输入私域网络名称。');
      return;
    }

    try {
      final PrivateNetworkCreationResult result =
          await ref.read(networkingProvider.notifier).createPrivateNetwork(
                ownerDeviceId: config.deviceId,
                name: name,
                description: description,
              );
      setState(() {
        _generatedNetworkCode = result.inviteCode.code;
      });
      _showPageMessage('私域网络已创建，邀请码 ${result.inviteCode.code} 已生成。');
    } on RealtimeError catch (error) {
      _showPageMessage(error.message);
    }
  }

  bool _ensureRegistered(AppConfig config) {
    if (config.deviceId.trim().isEmpty ||
        config.zeroTierNodeId.trim().isEmpty ||
        config.agentToken.trim().isEmpty) {
      _showPageMessage('客户端还未完成自动注册，请先等待 ZeroTier 检测和 bootstrap 完成。');
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

class _AgentOverviewCard extends StatelessWidget {
  const _AgentOverviewCard({
    required this.config,
    required this.agentState,
    required this.isRegistered,
    required this.onRetry,
    required this.onCopyToken,
  });

  final AppConfig config;
  final NetworkingAgentRuntimeState agentState;
  final bool isRegistered;
  final VoidCallback onRetry;
  final VoidCallback? onCopyToken;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '本机 Agent',
      subtitle: '应用会自动探测本机 ZeroTier、自动 bootstrap，并持续执行心跳、命令轮询和回执。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              _InfoPill(
                label: 'ZeroTier CLI',
                value: agentState.zeroTierStatus.cliAvailable ? '已检测到' : '未检测到',
              ),
              _InfoPill(label: '设备 ID', value: config.deviceId),
              _InfoPill(label: '平台', value: config.devicePlatform),
              _InfoPill(
                label: '注册状态',
                value: isRegistered ? '已注册' : '未注册',
              ),
            ],
          ),
          const SizedBox(height: 16),
          _LabeledBlock(
            label: 'ZeroTier Node ID',
            value: agentState.zeroTierStatus.nodeId.trim().isEmpty
                ? '尚未自动探测到'
                : agentState.zeroTierStatus.nodeId,
          ),
          const SizedBox(height: 12),
          _LabeledBlock(
            label: 'Agent Token',
            value:
                config.agentToken.trim().isEmpty ? '尚未获取' : config.agentToken,
            action: onCopyToken == null
                ? null
                : IconButton(
                    tooltip: '复制 agentToken',
                    onPressed: onCopyToken,
                    icon: const Icon(Icons.copy_rounded),
                  ),
          ),
          const SizedBox(height: 12),
          _LabeledBlock(
            label: '最近心跳',
            value: agentState.lastHeartbeatAt?.toLocal().toString() ?? '-',
          ),
          const SizedBox(height: 12),
          _LabeledBlock(
            label: '最近命令',
            value: agentState.lastCommandSummary ?? '-',
          ),
          if (agentState.lastError != null &&
              agentState.lastError!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF4E8),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                agentState.lastError!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFFB45309),
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.sync_rounded),
              label: Text(
                agentState.isBootstrapping || agentState.isPolling
                    ? '处理中...'
                    : '立即重试',
              ),
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
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
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

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(message),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重新加载'),
          ),
        ],
      ),
    );
  }
}

class _NetworkingDocReviewCard extends StatelessWidget {
  const _NetworkingDocReviewCard({
    required this.defaultNetwork,
    required this.managedNetworkCount,
    required this.deviceIdentity,
    required this.agentState,
  });

  final ManagedNetwork? defaultNetwork;
  final int managedNetworkCount;
  final NetworkDeviceIdentity? deviceIdentity;
  final NetworkingAgentRuntimeState agentState;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '能力对齐',
      subtitle:
          '客户端现在按“自动发现 ZeroTier -> 自动 bootstrap -> agent 心跳/轮询/回执”的方式工作，更贴近你要的快速组网工具。',
      child: Column(
        children: <Widget>[
          _CapabilityItem(
            label: agentState.zeroTierStatus.cliAvailable
                ? '本机 ZeroTier CLI 已可用，Node ID 自动发现已开启。'
                : '尚未检测到 ZeroTier CLI，本机无法自动入网。',
            tone: agentState.zeroTierStatus.cliAvailable
                ? _CapabilityTone.ready
                : _CapabilityTone.warning,
          ),
          const SizedBox(height: 10),
          _CapabilityItem(
            label: deviceIdentity == null
                ? '当前还没拿到服务端注册身份，agent 正在自动 bootstrap。'
                : '服务端设备身份已就绪：${deviceIdentity!.id}',
            tone: deviceIdentity == null
                ? _CapabilityTone.warning
                : _CapabilityTone.ready,
          ),
          const SizedBox(height: 10),
          _CapabilityItem(
            label: defaultNetwork == null
                ? '默认网络信息正在等待服务端返回。'
                : '默认网络已可读取：${defaultNetwork!.name} (${defaultNetwork!.status})',
            tone: _CapabilityTone.ready,
          ),
          const SizedBox(height: 10),
          _CapabilityItem(
            label: '当前已加载 $managedNetworkCount 条长期网络，并支持邀请码加入。',
            tone: _CapabilityTone.ready,
          ),
        ],
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
    final ThemeData theme = Theme.of(context);
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
              style: theme.textTheme.bodyMedium?.copyWith(
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

class _OneClickNetworkingTab extends StatelessWidget {
  const _OneClickNetworkingTab({
    required this.defaultNetwork,
    required this.isBusy,
    required this.isRegistered,
    required this.onPressed,
  });

  final ManagedNetwork? defaultNetwork;
  final bool isBusy;
  final bool isRegistered;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '一键组网',
      subtitle: '把当前设备加入默认长期网络，真正执行动作由本机 agent 处理。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (defaultNetwork != null) ...<Widget>[
            _NetworkSummaryCard(
              network: defaultNetwork!,
              accentColor: const Color(0xFFF97316),
            ),
            const SizedBox(height: 18),
          ],
          _NetworkingActionOrb(
            label: isBusy ? '提交中' : '一键组网',
            icon: isBusy ? Icons.hourglass_top_rounded : Icons.flash_on_rounded,
            subtitle: isRegistered ? '连接后台服务\n组进默认网络' : '等待自动注册完成',
            onTap: isBusy || !isRegistered ? null : onPressed,
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF4E8),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              '服务端收到请求后会下发 join_zerotier_network，本机 agent 会自动 join 并等待拿到 IP。',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivateNetworkingTab extends StatelessWidget {
  const _PrivateNetworkingTab({
    required this.codeController,
    required this.nameController,
    required this.descriptionController,
    required this.generatedCode,
    required this.isBusy,
    required this.isRegistered,
    required this.onJoinPressed,
    required this.onHostPressed,
    required this.managedNetworks,
  });

  final TextEditingController codeController;
  final TextEditingController nameController;
  final TextEditingController descriptionController;
  final String? generatedCode;
  final bool isBusy;
  final bool isRegistered;
  final VoidCallback onJoinPressed;
  final VoidCallback onHostPressed;
  final List<ManagedNetwork> managedNetworks;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '私域组网',
      subtitle: '支持创建长期私域网络、生成邀请码，以及通过邀请码加入已有网络。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: nameController,
            enabled: !isBusy,
            decoration: const InputDecoration(
              labelText: '私域网络名称',
              hintText: '例如 My Private Network',
              prefixIcon: Icon(Icons.drive_file_rename_outline_rounded),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: descriptionController,
            enabled: !isBusy,
            decoration: const InputDecoration(
              labelText: '网络说明',
              hintText: '例如 Private mesh',
              prefixIcon: Icon(Icons.notes_rounded),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: codeController,
            enabled: !isBusy,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: '邀请码',
              hintText: '请输入服务端返回的邀请码',
              prefixIcon: Icon(Icons.password_rounded),
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 18,
            runSpacing: 18,
            children: <Widget>[
              _NetworkingActionOrb(
                label: isBusy ? '处理中' : '加入网络',
                icon:
                    isBusy ? Icons.hourglass_top_rounded : Icons.login_rounded,
                subtitle: isRegistered ? '输入邀请码\n加入指定网络' : '等待自动注册完成',
                diameter: 190,
                onTap: isBusy || !isRegistered ? null : onJoinPressed,
              ),
              _NetworkingActionOrb(
                label: isBusy ? '处理中' : '主持网络',
                icon: isBusy
                    ? Icons.hourglass_top_rounded
                    : Icons.wifi_tethering_rounded,
                subtitle: isRegistered ? '创建网络\n返回邀请码' : '等待自动注册完成',
                diameter: 190,
                onTap: isBusy || !isRegistered ? null : onHostPressed,
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
                  colors: <Color>[
                    Color(0xFFFFF1E6),
                    Color(0xFFFFE0BF),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(22),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x1AFF8A00),
                    blurRadius: 24,
                    offset: Offset(0, 12),
                  ),
                ],
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
                          letterSpacing: 6,
                          color: const Color(0xFF7C2D12),
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '这是服务端真实返回的邀请码，可用于其他设备通过邀请码入网。',
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 22),
          Text(
            '当前长期网络',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 12),
          if (managedNetworks.isEmpty)
            const _EmptyManagedNetworksState()
          else
            Column(
              children: managedNetworks
                  .map(
                    (ManagedNetwork network) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _NetworkSummaryCard(
                        network: network,
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
}

class _NetworkSummaryCard extends StatelessWidget {
  const _NetworkSummaryCard({
    required this.network,
    required this.accentColor,
  });

  final ManagedNetwork network;
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
                label: network.status.isEmpty ? 'unknown' : network.status,
                color: accentColor,
              ),
            ],
          ),
          if (network.description != null &&
              network.description!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(network.description!),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _InfoPill(label: '类型', value: network.type),
              if (network.zeroTierNetworkName != null)
                _InfoPill(
                  label: 'ZeroTier 名称',
                  value: network.zeroTierNetworkName!,
                ),
              if (network.zeroTierNetworkId != null)
                _InfoPill(
                  label: 'ZeroTier ID',
                  value: network.zeroTierNetworkId!,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyManagedNetworksState extends StatelessWidget {
  const _EmptyManagedNetworksState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Text(
        '当前设备还没有查到已加入的长期网络。可以先主持一个私域网络，或下拉刷新。',
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _NetworkingActionOrb extends StatelessWidget {
  const _NetworkingActionOrb({
    required this.label,
    required this.icon,
    required this.subtitle,
    required this.onTap,
    this.diameter = 240,
  });

  final String label;
  final IconData icon;
  final String subtitle;
  final VoidCallback? onTap;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = onTap != null;

    return Center(
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.65,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: diameter,
            height: diameter,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: <Color>[
                  Color(0xFFFFC36B),
                  Color(0xFFF97316),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x40F97316),
                  blurRadius: 28,
                  offset: Offset(0, 16),
                ),
                BoxShadow(
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
                  Icon(icon, size: diameter * 0.18, color: Colors.white),
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
