import 'package:file_picker/file_picker.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/connection_request.dart';
import 'package:file_transfer_flutter/core/models/incoming_transfer_context.dart';
import 'package:file_transfer_flutter/core/models/outgoing_transfer_context.dart';
import 'package:file_transfer_flutter/core/models/p2p_device.dart';
import 'package:file_transfer_flutter/core/models/p2p_presence_state.dart';
import 'package:file_transfer_flutter/core/models/p2p_session.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';
import 'package:file_transfer_flutter/core/models/p2p_transport_state.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/models/transfer_record.dart';
import 'package:file_transfer_flutter/core/services/p2p_transport_service.dart';
import 'package:file_transfer_flutter/core/services/transfer_record_service.dart';
import 'package:file_transfer_flutter/shared/providers/p2p_presence_providers.dart';
import 'package:file_transfer_flutter/shared/providers/p2p_transport_providers.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:file_transfer_flutter/shared/widgets/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

class TransfersPage extends ConsumerWidget {
  const TransfersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppConfig config = ref.watch(appConfigProvider);
    final P2pPresenceState presence = ref.watch(p2pPresenceProvider);
    final AsyncValue<P2pTransportState> transportAsync =
        ref.watch(p2pTransportStreamProvider);
    final P2pTransportState transport =
        transportAsync.value ?? const P2pTransportState.initial();
    final List<P2pDevice> onlineDevices = presence
        .devicesExcludingSelf(config.deviceId)
        .where((P2pDevice device) => device.status.isReachable)
        .toList();
    final List<ConnectionRequest> pendingRequests = presence
        .requestsForDevice(config.deviceId)
        .where(
          (ConnectionRequest request) =>
              request.status == ConnectionRequestStatus.pending,
        )
        .toList()
      ..sort(
        (ConnectionRequest a, ConnectionRequest b) =>
            b.createdAt.compareTo(a.createdAt),
      );
    final List<P2pSession> sessions =
        presence.sessionsForDevice(config.deviceId);

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _RealtimeHeader(
            config: config,
            presence: presence,
            pendingRequests: pendingRequests,
            onShowPendingRequests: () => _showPendingRequestsDialog(
              context,
              selfDeviceId: config.deviceId,
              pendingRequests: pendingRequests,
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '在线设备',
            subtitle: '这里展示当前可直接发起互传的在线设备，已有邀请会通过弹窗查看和处理。',
            child: onlineDevices.isEmpty
                ? _EmptyOnlineDevicesState(isOnline: presence.isOnline)
                : Column(
                    children: onlineDevices
                        .map(
                          (P2pDevice device) => _PeerActionTile(
                            device: device,
                            presence: presence,
                            selfDeviceId: config.deviceId,
                            onShowRequestDialog: (ConnectionRequest request) =>
                                _showSingleRequestDialog(
                              context,
                              selfDeviceId: config.deviceId,
                              request: request,
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '活动会话',
            subtitle:
                '同一条活动 session 会复用同一条 PeerConnection 和 DataChannel，支持后续双向多次互传，单文件上限 800MB。',
            child: sessions.isEmpty
                ? const Text('当前还没有任何会话。')
                : Column(
                    children: sessions
                        .map(
                          (P2pSession session) => _SessionTile(
                            session: session,
                            selfDeviceId: config.deviceId,
                            transport: transport.transportForSession(
                              session.sessionId,
                            ),
                            outgoingTransfers: transport.outgoingForSession(
                              session.sessionId,
                            ),
                            incomingTransfers: transport.incomingForSession(
                              session.sessionId,
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          if (transport.lastError != null &&
              transport.lastError!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            SectionCard(
              title: '传输错误',
              child: Text(transport.lastError!),
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.center,
            child: TextButton(
              onPressed: () => _showTransferRecordsDialog(
                context,
                ref,
                deviceId: config.deviceId,
              ),
              child: const Text('查看传输记录'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showPendingRequestsDialog(
    BuildContext context, {
    required String selfDeviceId,
    required List<ConnectionRequest> pendingRequests,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('待处理邀请'),
          content: SizedBox(
            width: 560,
            child: pendingRequests.isEmpty
                ? const SizedBox(
                    height: 180,
                    child: Center(
                      child: Text('当前没有待处理的邀请或连接请求。'),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: pendingRequests.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final ConnectionRequest request = pendingRequests[index];
                      return _RequestTile(
                        request: request,
                        selfDeviceId: selfDeviceId,
                        showActions: true,
                      );
                    },
                  ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showSingleRequestDialog(
    BuildContext context, {
    required String selfDeviceId,
    required ConnectionRequest request,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('连接邀请'),
          content: SizedBox(
            width: 520,
            child: _RequestTile(
              request: request,
              selfDeviceId: selfDeviceId,
              showActions: true,
              dense: true,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showTransferRecordsDialog(
    BuildContext context,
    WidgetRef ref, {
    required String deviceId,
  }) async {
    final TransferRecordService service =
        ref.read(transferRecordServiceProvider);
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('传输记录'),
          content: SizedBox(
            width: 560,
            child: FutureBuilder<List<TransferRecord>>(
              future: service.fetchDeviceTransfers(deviceId: deviceId),
              builder: (
                BuildContext context,
                AsyncSnapshot<List<TransferRecord>> snapshot,
              ) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox(
                    height: 180,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                if (snapshot.hasError) {
                  final Object? error = snapshot.error;
                  final String message =
                      error is RealtimeError ? error.message : '$error';
                  return SizedBox(
                    height: 180,
                    child: Center(
                      child: Text(message, textAlign: TextAlign.center),
                    ),
                  );
                }

                final List<TransferRecord> records =
                    snapshot.data ?? const <TransferRecord>[];
                if (records.isEmpty) {
                  return const SizedBox(
                    height: 180,
                    child: Center(child: Text('当前设备还没有传输记录。')),
                  );
                }

                return ListView.separated(
                  shrinkWrap: true,
                  itemCount: records.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) {
                    final TransferRecord record = records[index];
                    return _TransferRecordTile(
                      record: record,
                      selfDeviceId: deviceId,
                    );
                  },
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}

class _PresenceBanner extends StatelessWidget {
  const _PresenceBanner({required this.presence});

  final P2pPresenceState presence;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool online = presence.isOnline;
    final Color color =
        online ? const Color(0xFF15803D) : const Color(0xFFB42318);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        online ? '信令已上线，可以发起连接请求。' : '当前未上线，请先点击“上线”。',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _RealtimeHeader extends ConsumerWidget {
  const _RealtimeHeader({
    required this.config,
    required this.presence,
    required this.pendingRequests,
    required this.onShowPendingRequests,
  });

  final AppConfig config;
  final P2pPresenceState presence;
  final List<ConnectionRequest> pendingRequests;
  final VoidCallback onShowPendingRequests;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final P2pDevice? currentDevice = presence.currentDevice;
    final bool online = presence.isOnline;
    final Color accent =
        online ? const Color(0xFF15803D) : const Color(0xFFB42318);
    final String deviceStatus = currentDevice?.status.value ?? 'offline';
    final String deviceName =
        currentDevice?.deviceName.trim().isNotEmpty == true
            ? currentDevice!.deviceName
            : config.deviceName;

    return SectionCard(
      title: '实时传输',
      subtitle:
          '上线后将连接 /signaling，进入设备发现、会话协商和双向互传链路。实时传输单文件上限 800MB，中断或超时会自动清理临时文件。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _PresenceBanner(presence: presence),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: accent.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  deviceName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    _InfoPill(
                      label: '信令状态',
                      value: _presenceStatusLabel(presence),
                    ),
                    _InfoPill(
                      label: '设备状态',
                      value: deviceStatus,
                    ),
                    _InfoPill(
                      label: '设备 ID',
                      value: config.deviceId,
                    ),
                  ],
                ),
                if (presence.lastError != null &&
                    presence.lastError!.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    presence.lastError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FilledButton.icon(
                onPressed: presence.isBusy
                    ? null
                    : () => _toggleOnlineState(context, ref),
                icon: presence.isBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        online
                            ? Icons.cloud_off_outlined
                            : Icons.cloud_done_outlined,
                      ),
                label: Text(_presenceActionLabel(presence)),
              ),
              OutlinedButton.icon(
                onPressed: onShowPendingRequests,
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    const Icon(Icons.mark_email_unread_outlined),
                    if (pendingRequests.isNotEmpty)
                      Positioned(
                        right: -6,
                        top: -6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.error,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${pendingRequests.length}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onError,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                label: Text(
                  pendingRequests.isEmpty
                      ? '查看邀请'
                      : '查看邀请 (${pendingRequests.length})',
                ),
              ),
              Text(
                '配置来自设置页，校验未通过时会先提示补全配置。',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                '实时传输单文件上限 800MB，接收中断或超时后会自动清理残留 .part 文件。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _toggleOnlineState(BuildContext context, WidgetRef ref) async {
    final P2pPresenceController notifier =
        ref.read(p2pPresenceProvider.notifier);
    final P2pPresenceState latestPresence = ref.read(p2pPresenceProvider);
    if (latestPresence.isOnline) {
      await notifier.goOffline();
      if (context.mounted) {
        _showSnackBar(context, '已下线');
      }
      return;
    }

    final String? validationError = _validateConfig(config);
    if (validationError != null) {
      _showSnackBar(context, validationError);
      return;
    }

    await notifier.goOnline();
    if (context.mounted) {
      _showSnackBar(context, '正在连接信令服务...');
    }
  }

  String? _validateConfig(AppConfig config) {
    final Uri? uri = Uri.tryParse(config.serverUrl.trim());
    if (config.serverUrl.trim().isEmpty) {
      return '请先到设置页填写服务端地址';
    }
    if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) {
      return '服务端地址格式不正确，请先到设置页修正';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '服务端地址仅支持 http 或 https';
    }
    if (config.deviceName.trim().isEmpty) {
      return '请先到设置页填写设备名称';
    }
    if (config.downloadDirectory.trim().isEmpty) {
      return '请先到设置页选择本地保存目录';
    }
    return null;
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  String _presenceActionLabel(P2pPresenceState presence) {
    return switch (presence.status) {
      SignalingPresenceStatus.offline => '上线',
      SignalingPresenceStatus.connecting => '连接中...',
      SignalingPresenceStatus.registering => '注册中...',
      SignalingPresenceStatus.online => '下线',
    };
  }

  String _presenceStatusLabel(P2pPresenceState presence) {
    return switch (presence.status) {
      SignalingPresenceStatus.offline => '未上线',
      SignalingPresenceStatus.connecting => '连接信令中',
      SignalingPresenceStatus.registering => '注册设备中',
      SignalingPresenceStatus.online => '在线',
    };
  }
}

class _EmptyOnlineDevicesState extends StatelessWidget {
  const _EmptyOnlineDevicesState({required this.isOnline});

  final bool isOnline;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: <Widget>[
          Icon(
            Icons.devices_other_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            '暂无在线设备',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isOnline
                ? '暂时没有发现其他在线客户端。让另一台设备先上线，随后就可以在这里发起互传。'
                : '当前你还没有接入信令服务。先点击“上线”，在线设备出现后即可发起互传。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _PeerActionTile extends ConsumerWidget {
  const _PeerActionTile({
    required this.device,
    required this.presence,
    required this.selfDeviceId,
    required this.onShowRequestDialog,
  });

  final P2pDevice device;
  final P2pPresenceState presence;
  final String selfDeviceId;
  final ValueChanged<ConnectionRequest> onShowRequestDialog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ConnectionRequest? outgoingRequest =
        presence.outgoingPendingRequestTo(
      selfDeviceId: selfDeviceId,
      peerDeviceId: device.deviceId,
    );
    final ConnectionRequest? incomingRequest =
        presence.incomingPendingRequestFrom(
      selfDeviceId: selfDeviceId,
      peerDeviceId: device.deviceId,
    );
    final P2pSession? activeSession = presence.activeSessionWith(
      selfDeviceId: selfDeviceId,
      peerDeviceId: device.deviceId,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      device.deviceName,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${device.platform} | ${device.status.value}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              _RelationshipChip(
                label: _relationshipLabel(
                  activeSession: activeSession,
                  outgoingRequest: outgoingRequest,
                  incomingRequest: incomingRequest,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              if (activeSession != null)
                _InfoPill(label: '会话', value: activeSession.status.value),
              if (outgoingRequest != null)
                _InfoPill(label: '请求', value: outgoingRequest.status.value),
              if (incomingRequest != null)
                _InfoPill(label: '收到邀请', value: incomingRequest.status.value),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _buildActions(
              context,
              ref,
              outgoingRequest: outgoingRequest,
              incomingRequest: incomingRequest,
              activeSession: activeSession,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildActions(
    BuildContext context,
    WidgetRef ref, {
    required ConnectionRequest? outgoingRequest,
    required ConnectionRequest? incomingRequest,
    required P2pSession? activeSession,
  }) {
    if (incomingRequest != null) {
      return <Widget>[
        FilledButton.icon(
          onPressed: () => onShowRequestDialog(incomingRequest),
          icon: const Icon(Icons.mark_email_read_outlined),
          label: const Text('查看邀请'),
        ),
      ];
    }

    if (activeSession != null) {
      return <Widget>[
        OutlinedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.link_rounded),
          label: Text(
            activeSession.status == P2pSessionStatus.active ? '已连接' : '连接中',
          ),
        ),
      ];
    }

    if (outgoingRequest != null) {
      return <Widget>[
        OutlinedButton.icon(
          onPressed: () => onShowRequestDialog(outgoingRequest),
          icon: const Icon(Icons.hourglass_top_rounded),
          label: const Text('查看请求'),
        ),
      ];
    }

    final bool canRequest =
        presence.isOnline && device.status == P2pDeviceStatus.online;

    return <Widget>[
      FilledButton.icon(
        onPressed: canRequest
            ? () async {
                await _runAction(
                  context,
                  () => ref
                      .read(p2pPresenceProvider.notifier)
                      .sendConnectionRequest(
                        toDeviceId: device.deviceId,
                      ),
                );
              }
            : null,
        icon: const Icon(Icons.send_outlined),
        label: const Text('发起互传'),
      ),
    ];
  }

  Future<void> _runAction(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } on RealtimeError catch (error) {
      _showMessage(messenger, error.message);
    } catch (error) {
      _showMessage(messenger, '$error');
    }
  }

  void _showMessage(ScaffoldMessengerState messenger, String message) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  String _relationshipLabel({
    required P2pSession? activeSession,
    required ConnectionRequest? outgoingRequest,
    required ConnectionRequest? incomingRequest,
  }) {
    if (activeSession != null) {
      return activeSession.status == P2pSessionStatus.active ? '已连接' : '连接中';
    }
    if (incomingRequest != null) {
      return '待你处理';
    }
    if (outgoingRequest != null) {
      return '请求中';
    }
    return '未连接';
  }
}

class _RequestTile extends ConsumerWidget {
  const _RequestTile({
    required this.request,
    required this.selfDeviceId,
    required this.showActions,
    this.dense = false,
  });

  final ConnectionRequest request;
  final String selfDeviceId;
  final bool showActions;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool incoming = request.toDeviceId == selfDeviceId;
    return Container(
      margin: dense ? EdgeInsets.zero : const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            incoming
                ? '来自 ${request.fromDeviceId}'
                : '发给 ${request.toDeviceId}',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 6),
          Text(request.message ?? '请求建立直连通道'),
          const SizedBox(height: 8),
          Text(
            '状态: ${request.status.value}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (showActions) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              children: <Widget>[
                if (incoming) ...<Widget>[
                  FilledButton(
                    onPressed: () async {
                      await _runAction(
                        context,
                        () => ref
                            .read(p2pPresenceProvider.notifier)
                            .respondToConnectionRequest(
                              requestId: request.requestId,
                              accepted: true,
                            ),
                      );
                    },
                    child: const Text('接受'),
                  ),
                  OutlinedButton(
                    onPressed: () async {
                      await _runAction(
                        context,
                        () => ref
                            .read(p2pPresenceProvider.notifier)
                            .respondToConnectionRequest(
                              requestId: request.requestId,
                              accepted: false,
                            ),
                      );
                    },
                    child: const Text('拒绝'),
                  ),
                ] else ...<Widget>[
                  OutlinedButton(
                    onPressed: () async {
                      await _runAction(
                        context,
                        () => ref
                            .read(p2pPresenceProvider.notifier)
                            .cancelConnectionRequest(request.requestId),
                      );
                    },
                    child: const Text('取消请求'),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _runAction(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    } on RealtimeError catch (error) {
      _showMessage(messenger, error.message);
    } catch (error) {
      _showMessage(messenger, '$error');
    }
  }

  void _showMessage(ScaffoldMessengerState messenger, String message) {
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

class _SessionTile extends ConsumerWidget {
  const _SessionTile({
    required this.session,
    required this.selfDeviceId,
    required this.transport,
    required this.outgoingTransfers,
    required this.incomingTransfers,
  });

  final P2pSession session;
  final String selfDeviceId;
  final P2pSessionTransport? transport;
  final List<OutgoingTransferContext> outgoingTransfers;
  final List<IncomingTransferContext> incomingTransfers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String peerId = session.peerDeviceIdOf(selfDeviceId);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '对端: $peerId',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              _RelationshipChip(label: _sessionLabel(session.status)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _InfoPill(label: 'sessionId', value: session.sessionId),
              if (transport != null)
                _InfoPill(
                  label: '链路',
                  value:
                      '${transport!.linkStatus.name}/${transport!.dataChannelOpen ? 'dc-open' : 'dc-closed'}',
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              FilledButton.icon(
                onPressed: transport?.canTransfer == true
                    ? () async {
                        final ScaffoldMessengerState messenger =
                            ScaffoldMessenger.of(context);
                        final String? filePath = await FilePicker.platform
                            .pickFiles(withData: false)
                            .then(
                              (FilePickerResult? result) =>
                                  result?.files.single.path,
                            );
                        if (filePath == null || filePath.isEmpty) {
                          return;
                        }
                        await _runSend(messenger, ref, filePath);
                      }
                    : null,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('发送文件'),
              ),
            ],
          ),
          if (outgoingTransfers.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text('我发出的文件', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ...outgoingTransfers.map(
              (OutgoingTransferContext item) => _TransferProgressTile(
                title: item.fileName,
                subtitle: item.status.value,
                progress: item.progress,
              ),
            ),
          ],
          if (incomingTransfers.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text('我接收的文件', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ...incomingTransfers.map(
              (IncomingTransferContext item) => _TransferProgressTile(
                title: item.fileName,
                subtitle: item.status.value,
                progress: item.progress,
                extra: item.savePath,
              ),
            ),
          ],
          if (session.closeReason != null &&
              session.closeReason!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('closeReason: ${session.closeReason!}'),
            ),
        ],
      ),
    );
  }

  Future<void> _runSend(
    ScaffoldMessengerState messenger,
    WidgetRef ref,
    String filePath,
  ) async {
    final P2pTransportService transportService =
        ref.read(p2pTransportServiceProvider);
    try {
      await transportService.sendFile(
        session: session,
        filePath: filePath,
      );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('已开始发送文件'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } on RealtimeError catch (error) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(error.message),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (error) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('$error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  String _sessionLabel(P2pSessionStatus status) {
    return switch (status) {
      P2pSessionStatus.connecting => '连接中',
      P2pSessionStatus.active => '已连接',
      P2pSessionStatus.closed => '已关闭',
      P2pSessionStatus.failed => '失败',
    };
  }
}

class _TransferProgressTile extends StatelessWidget {
  const _TransferProgressTile({
    required this.title,
    required this.subtitle,
    required this.progress,
    this.extra,
  });

  final String title;
  final String subtitle;
  final double progress;
  final String? extra;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title),
          const SizedBox(height: 4),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          if (extra != null && extra!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(extra!, style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress == 0 ? null : progress),
        ],
      ),
    );
  }
}

class _TransferRecordTile extends StatelessWidget {
  const _TransferRecordTile({
    required this.record,
    required this.selfDeviceId,
  });

  final TransferRecord record;
  final String selfDeviceId;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String directionLabel =
        record.isOutgoingFor(selfDeviceId) ? '发出' : '接收';
    final String timeLabel =
        DateFormat('yyyy-MM-dd HH:mm:ss').format(record.createdAt.toLocal());

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            record.fileName,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$directionLabel | ${record.status.value} | ${_formatFileSize(record.fileSize)}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text('会话 ${record.sessionId}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(timeLabel, style: theme.textTheme.bodySmall),
          if (record.errorMessage != null &&
              record.errorMessage!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                record.errorMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _RelationshipChip extends StatelessWidget {
  const _RelationshipChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
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
