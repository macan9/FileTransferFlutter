import 'dart:io';

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
import 'package:open_filex/open_filex.dart';

class TransfersPage extends ConsumerStatefulWidget {
  const TransfersPage({super.key});

  @override
  ConsumerState<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends ConsumerState<TransfersPage> {
  final Set<String> _shownIncomingRequestIds = <String>{};

  @override
  void initState() {
    super.initState();
    ref.listenManual<P2pPresenceState>(
      p2pPresenceProvider,
      (
        P2pPresenceState? previous,
        P2pPresenceState next,
      ) {
        _handleIncomingRequestAutoPopup(previous, next);
      },
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final WidgetRef ref = this.ref;
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
              config: config,
              presence: presence,
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '在线设备',
            subtitle: '先发送邀请，待对方接受并建立连接后即可直接发送文件。',
            child: onlineDevices.isEmpty
                ? _EmptyOnlineDevicesState(isOnline: presence.isOnline)
                : Column(
                    children: onlineDevices.map((P2pDevice device) {
                      final P2pSession? activeSession =
                          presence.activeSessionWith(
                        selfDeviceId: config.deviceId,
                        peerDeviceId: device.deviceId,
                      );
                      final P2pSessionTransport? sessionTransport =
                          activeSession == null
                              ? null
                              : transport.transportForSession(
                                  activeSession.sessionId,
                                );

                      return _PeerActionTile(
                        config: config,
                        device: device,
                        presence: presence,
                        selfDeviceId: config.deviceId,
                        activeSession: activeSession,
                        transport: sessionTransport,
                        outgoingTransfers: activeSession == null
                            ? const <OutgoingTransferContext>[]
                            : transport.outgoingForSession(
                                activeSession.sessionId,
                              ),
                        incomingTransfers: activeSession == null
                            ? const <IncomingTransferContext>[]
                            : transport.incomingForSession(
                                activeSession.sessionId,
                              ),
                        onShowRequestDialog: (ConnectionRequest request) =>
                            _showSingleRequestDialog(
                          context,
                          selfDeviceId: config.deviceId,
                          request: request,
                          config: config,
                          presence: presence,
                        ),
                      );
                    }).toList(),
                  ),
          ),
          if (transport.lastError != null &&
              transport.lastError!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            SectionCard(
              title: '最近错误',
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
                config: config,
                presence: presence,
              ),
              child: const Text('查看传输记录'),
            ),
          ),
        ],
      ),
    );
  }

  void _handleIncomingRequestAutoPopup(
    P2pPresenceState? previous,
    P2pPresenceState next,
  ) {
    final AppConfig config = ref.read(appConfigProvider);
    final List<ConnectionRequest> incomingRequests =
        next.incomingPendingRequests(config.deviceId);
    final Set<String> activeIds = incomingRequests
        .map((ConnectionRequest item) => item.requestId)
        .toSet();
    _shownIncomingRequestIds.removeWhere(
      (String requestId) => !activeIds.contains(requestId),
    );

    final Set<String> previousIds = (previous?.incomingPendingRequests(
              config.deviceId,
            ) ??
            const <ConnectionRequest>[])
        .map((ConnectionRequest item) => item.requestId)
        .toSet();

    for (final ConnectionRequest request in incomingRequests) {
      if (_shownIncomingRequestIds.contains(request.requestId)) {
        continue;
      }
      if (previous != null && previousIds.contains(request.requestId)) {
        continue;
      }

      _shownIncomingRequestIds.add(request.requestId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _showSingleRequestDialog(
          context,
          selfDeviceId: config.deviceId,
          request: request,
          config: config,
          presence: next,
          barrierDismissible: false,
        );
      });
      break;
    }
  }

  Future<void> _showPendingRequestsDialog(
    BuildContext context, {
    required String selfDeviceId,
    required List<ConnectionRequest> pendingRequests,
    required AppConfig config,
    required P2pPresenceState presence,
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
                        popOnAction: false,
                        resolveDeviceName: (String deviceId) =>
                            _deviceDisplayName(
                          deviceId: deviceId,
                          config: config,
                          presence: presence,
                        ),
                        resolveDevicePlatform: (String deviceId) =>
                            _devicePlatformFor(
                          deviceId: deviceId,
                          config: config,
                          presence: presence,
                        ),
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
    required AppConfig config,
    required P2pPresenceState presence,
    bool barrierDismissible = true,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (BuildContext context) {
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 18, 12, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          title: Row(
            children: <Widget>[
              const Expanded(child: Text('连接邀请')),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: _LiveRequestDialogBody(
              initialRequest: request,
              selfDeviceId: selfDeviceId,
              config: config,
              fallbackPresence: presence,
            ),
          ),
        );
      },
    );
  }

  Future<void> _showTransferRecordsDialog(
    BuildContext context,
    WidgetRef ref, {
    required String deviceId,
    required AppConfig config,
    required P2pPresenceState presence,
  }) async {
    final TransferRecordService service =
        ref.read(transferRecordServiceProvider);
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('传输记录'),
          content: SizedBox(
            width: 720,
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
                      resolveDeviceName: (String targetDeviceId) =>
                          _deviceDisplayName(
                        deviceId: targetDeviceId,
                        config: config,
                        presence: presence,
                      ),
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
    final String deviceStatus = _deviceStatusLabel(
      currentDevice?.status ?? P2pDeviceStatus.offline,
    );
    final String deviceName =
        currentDevice?.deviceName.trim().isNotEmpty == true
            ? currentDevice!.deviceName
            : config.deviceName;

    return SectionCard(
      title: '实时传输',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
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
              const Spacer(),
              FilledButton.icon(
                onPressed: presence.isBusy
                    ? null
                    : () => _toggleOnlineState(context, ref),
                style: online
                    ? FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      )
                    : null,
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
            ],
          ),
          const SizedBox(height: 14),
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
                      label: '当前状态',
                      value: deviceStatus,
                    ),
                    _InfoPill(
                      label: '信令连接',
                      value: _presenceStatusLabel(presence),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  online
                      ? '已接入信令服务。发现在线设备后，先发送邀请，建立连接后即可发送文件。'
                      : '点击“上线”后会接入信令服务，成功后这里会展示可邀请的在线设备。',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '实时传输单文件上限 800MB。传输中断或超时后会自动清理残留的 .part 文件。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
    required this.config,
    required this.device,
    required this.presence,
    required this.selfDeviceId,
    required this.activeSession,
    required this.transport,
    required this.outgoingTransfers,
    required this.incomingTransfers,
    required this.onShowRequestDialog,
  });

  final AppConfig config;
  final P2pDevice device;
  final P2pPresenceState presence;
  final String selfDeviceId;
  final P2pSession? activeSession;
  final P2pSessionTransport? transport;
  final List<OutgoingTransferContext> outgoingTransfers;
  final List<IncomingTransferContext> incomingTransfers;
  final ValueChanged<ConnectionRequest> onShowRequestDialog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
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
    final bool isConnected = activeSession?.status == P2pSessionStatus.active;
    final bool isWaiting = outgoingRequest != null ||
        activeSession?.status == P2pSessionStatus.connecting;
    final bool canSendFile =
        activeSession != null && transport?.canTransfer == true;
    final bool canRequest =
        presence.isOnline && device.status == P2pDeviceStatus.online;
    final bool showInviteAction =
        !isConnected && incomingRequest == null && outgoingRequest == null;
    final Color accent = isConnected
        ? const Color(0xFF15803D)
        : incomingRequest != null
            ? const Color(0xFF9A3412)
            : theme.colorScheme.primary;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isConnected
            ? const Color(0xFFECFDF3)
            : theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isConnected
              ? const Color(0xFF86EFAC)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            device.deviceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            '${device.platform} · ${_deviceStatusLabel(device.status)}',
                            style: theme.textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isConnected) ...<Widget>[
                          const SizedBox(width: 8),
                          _RelationshipChip(
                            label: '已连接',
                            backgroundColor: accent.withValues(alpha: 0.12),
                            foregroundColor: accent,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (isConnected)
                FilledButton.icon(
                  onPressed: canSendFile
                      ? () async {
                          final ScaffoldMessengerState messenger =
                              ScaffoldMessenger.of(context);
                          final String? filePath = await FilePicker.platform
                              .pickFiles(withData: false)
                              .then((FilePickerResult? result) =>
                                  result?.files.single.path);
                          if (filePath == null || filePath.isEmpty) {
                            return;
                          }
                          await _runSend(
                            messenger,
                            ref,
                            filePath,
                            session: activeSession!,
                          );
                        }
                      : null,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('发送文件'),
                )
              else
                _RelationshipChip(
                  label: _relationshipLabel(
                    activeSession: activeSession,
                    outgoingRequest: outgoingRequest,
                    incomingRequest: incomingRequest,
                  ),
                  backgroundColor: accent.withValues(alpha: 0.12),
                  foregroundColor: accent,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _hintText(
              deviceName: device.deviceName,
              activeSession: activeSession,
              outgoingRequest: outgoingRequest,
              incomingRequest: incomingRequest,
              canSendFile: canSendFile,
            ),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    _InfoPill(
                        label: '设备状态',
                        value: _deviceStatusLabel(device.status)),
                    if (outgoingRequest != null)
                      _InfoPill(
                          label: '邀请状态',
                          value: _requestStatusLabel(outgoingRequest.status)),
                    if (incomingRequest != null)
                      _InfoPill(
                          label: '邀请状态',
                          value: _requestStatusLabel(incomingRequest.status)),
                    if (transport != null)
                      _InfoPill(
                          label: '传输通道',
                          value: _transportStatusLabel(transport!)),
                  ],
                ),
              ),
              if (showInviteAction) ...<Widget>[
                const SizedBox(width: 12),
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
                            successMessage: '邀请已发送，等待 ${device.deviceName} 接受',
                          );
                        }
                      : null,
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('发送邀请'),
                ),
              ],
            ],
          ),
          if (_shouldShowBottomActions(
            incomingRequest: incomingRequest,
            activeSession: activeSession,
            isConnected: isConnected,
            isWaiting: isWaiting,
          )) ...<Widget>[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: _buildActions(
                context,
                ref,
                outgoingRequest: outgoingRequest,
                incomingRequest: incomingRequest,
                activeSession: activeSession,
                canSendFile: canSendFile,
                isConnected: isConnected,
                isWaiting: isWaiting,
              ),
            ),
          ],
          if (outgoingTransfers.isNotEmpty ||
              incomingTransfers.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            if (outgoingTransfers.isNotEmpty) ...<Widget>[
              Text('发出中的文件', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              ...outgoingTransfers.map(
                (OutgoingTransferContext item) => _TransferProgressTile(
                  title: item.fileName,
                  subtitle: _transferStatusLabel(item.status.value),
                  progress: item.progress,
                ),
              ),
            ],
            if (incomingTransfers.isNotEmpty) ...<Widget>[
              if (outgoingTransfers.isNotEmpty) const SizedBox(height: 10),
              Text('已接收', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              ...incomingTransfers.map(
                (IncomingTransferContext item) => _TransferProgressTile(
                  title: item.fileName,
                  subtitle: _transferStatusLabel(item.status.value),
                  progress: item.progress,
                  extra: item.savePath,
                  actionLabel: item.savePath?.trim().isNotEmpty == true
                      ? _receivedFileActionLabel
                      : null,
                  onActionPressed: item.savePath?.trim().isNotEmpty == true
                      ? () => _openReceivedFile(context, item.savePath!)
                      : null,
                ),
              ),
            ],
          ],
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
    required bool canSendFile,
    required bool isConnected,
    required bool isWaiting,
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

    if (!isConnected && (activeSession != null || isWaiting)) {
      return <Widget>[
        OutlinedButton.icon(
          onPressed: null,
          icon: const _WaitingDots(),
          label: const Text('邀请已发送'),
        ),
      ];
    }

    return const <Widget>[];
  }

  bool _shouldShowBottomActions({
    required ConnectionRequest? incomingRequest,
    required P2pSession? activeSession,
    required bool isConnected,
    required bool isWaiting,
  }) {
    if (incomingRequest != null) {
      return true;
    }
    if (!isConnected && (activeSession != null || isWaiting)) {
      return true;
    }
    return false;
  }

  Future<void> _openReceivedFile(BuildContext context, String savePath) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final File file = File(savePath);
      if (!await file.exists()) {
        _showMessage(messenger, '文件不存在或已被移动');
        return;
      }

      if (Platform.isAndroid || Platform.isIOS) {
        final OpenResult result = await OpenFilex.open(savePath);
        if (result.type != ResultType.done &&
            result.message.trim().isNotEmpty) {
          _showMessage(messenger, result.message);
        }
      } else if (Platform.isWindows) {
        await Process.run('explorer.exe', <String>['/select,', savePath]);
      } else if (Platform.isMacOS) {
        await Process.run('open', <String>['-R', savePath]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', <String>[file.parent.path]);
      } else {
        _showMessage(messenger, '当前平台暂不支持直接打开文件路径');
      }
    } catch (error) {
      _showMessage(messenger, '打开文件失败: $error');
    }
  }

  String get _receivedFileActionLabel {
    if (Platform.isAndroid || Platform.isIOS) {
      return '打开文件';
    }
    return '打开位置';
  }

  Future<void> _runAction(BuildContext context, Future<void> Function() action,
      {String? successMessage}) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      if (successMessage != null) {
        _showMessage(messenger, successMessage);
      }
    } on RealtimeError catch (error) {
      _showMessage(messenger, error.message);
    } catch (error) {
      _showMessage(messenger, '$error');
    }
  }

  Future<void> _runSend(
    ScaffoldMessengerState messenger,
    WidgetRef ref,
    String filePath, {
    required P2pSession session,
  }) async {
    final P2pTransportService transportService =
        ref.read(p2pTransportServiceProvider);
    try {
      await transportService.sendFile(
        session: session,
        filePath: filePath,
      );
      _showMessage(messenger, '已开始发送文件');
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

  String _hintText({
    required String deviceName,
    required P2pSession? activeSession,
    required ConnectionRequest? outgoingRequest,
    required ConnectionRequest? incomingRequest,
    required bool canSendFile,
  }) {
    if (incomingRequest != null) {
      return '$deviceName 向你发来了连接邀请，点击“查看邀请”后可接受或拒绝。';
    }
    if (activeSession?.status == P2pSessionStatus.active && canSendFile) {
      return '连接已建立，可以直接选择文件发送给 $deviceName。';
    }
    if (activeSession?.status == P2pSessionStatus.connecting) {
      return '双方正在建立直连通道，请稍等片刻。';
    }
    if (outgoingRequest != null) {
      return '已向 $deviceName 发送邀请，等待对方接受。';
    }
    return '点击“发送邀请”后，对方接受即可建立连接并开始互传。';
  }
}

class _LiveRequestDialogBody extends ConsumerWidget {
  const _LiveRequestDialogBody({
    required this.initialRequest,
    required this.selfDeviceId,
    required this.config,
    required this.fallbackPresence,
  });

  final ConnectionRequest initialRequest;
  final String selfDeviceId;
  final AppConfig config;
  final P2pPresenceState fallbackPresence;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final P2pPresenceState livePresence = ref.watch(p2pPresenceProvider);
    final P2pPresenceState presence =
        livePresence.devices.isEmpty ? fallbackPresence : livePresence;
    final ConnectionRequest request =
        livePresence.connectionRequests.firstWhere(
      (ConnectionRequest item) => item.requestId == initialRequest.requestId,
      orElse: () => initialRequest,
    );
    final bool incoming = request.toDeviceId == selfDeviceId;
    final String remoteDeviceId =
        incoming ? request.fromDeviceId : request.toDeviceId;
    final String remoteDeviceName = _deviceDisplayName(
      deviceId: remoteDeviceId,
      config: config,
      presence: presence,
    );
    final String remotePlatform = _devicePlatformFor(
      deviceId: remoteDeviceId,
      config: config,
      presence: presence,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                remoteDeviceName,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 6),
              Text('设备类型：$remotePlatform'),
              const SizedBox(height: 4),
              Text(
                incoming ? '接受后会尝试建立直连通道。' : '等待对方处理当前邀请。',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _RequestTile(
          request: request,
          selfDeviceId: selfDeviceId,
          showActions: true,
          popOnAction: true,
          dense: true,
          resolveDeviceName: (String deviceId) => _deviceDisplayName(
            deviceId: deviceId,
            config: config,
            presence: presence,
          ),
          resolveDevicePlatform: (String deviceId) => _devicePlatformFor(
            deviceId: deviceId,
            config: config,
            presence: presence,
          ),
        ),
      ],
    );
  }
}

class _RequestTile extends ConsumerWidget {
  const _RequestTile({
    required this.request,
    required this.selfDeviceId,
    required this.showActions,
    required this.resolveDeviceName,
    required this.resolveDevicePlatform,
    this.popOnAction = true,
    this.dense = false,
  });

  final ConnectionRequest request;
  final String selfDeviceId;
  final bool showActions;
  final String Function(String deviceId) resolveDeviceName;
  final String Function(String deviceId) resolveDevicePlatform;
  final bool popOnAction;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final bool incoming = request.toDeviceId == selfDeviceId;
    final String fromDeviceName = resolveDeviceName(request.fromDeviceId);
    final String toDeviceName = resolveDeviceName(request.toDeviceId);

    return Container(
      margin: dense ? EdgeInsets.zero : const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _LabeledValue(
            label: '设备类型',
            value: incoming
                ? resolveDevicePlatform(request.fromDeviceId)
                : resolveDevicePlatform(request.toDeviceId),
          ),
          const SizedBox(height: 6),
          _LabeledValue(
            label: '发出设备',
            value: '$fromDeviceName (${request.fromDeviceId})',
          ),
          const SizedBox(height: 6),
          _LabeledValue(
            label: '接收设备',
            value: '$toDeviceName (${request.toDeviceId})',
          ),
          const SizedBox(height: 6),
          _LabeledValue(
              label: '邀请状态', value: _requestStatusLabel(request.status)),
          const SizedBox(height: 6),
          _LabeledValue(
            label: '邀请时间',
            value: DateFormat('yyyy-MM-dd HH:mm:ss')
                .format(request.createdAt.toLocal()),
          ),
          if (showActions &&
              request.status == ConnectionRequestStatus.pending) ...<Widget>[
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
                        popOnAction: popOnAction,
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
                        popOnAction: popOnAction,
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
                        popOnAction: popOnAction,
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
    Future<void> Function() action, {
    required bool popOnAction,
  }) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      if (popOnAction && context.mounted) {
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

class _TransferProgressTile extends StatelessWidget {
  const _TransferProgressTile({
    required this.title,
    required this.subtitle,
    required this.progress,
    this.extra,
    this.actionLabel,
    this.onActionPressed,
  });

  final String title;
  final String subtitle;
  final double progress;
  final String? extra;
  final String? actionLabel;
  final VoidCallback? onActionPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (actionLabel != null)
                TextButton.icon(
                  onPressed: onActionPressed,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: Text(actionLabel!),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: theme.textTheme.bodySmall),
          if (extra != null && extra!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(extra!, style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 8),
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
    required this.resolveDeviceName,
  });

  final TransferRecord record;
  final String selfDeviceId;
  final String Function(String deviceId) resolveDeviceName;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isOutgoing = record.isOutgoingFor(selfDeviceId);
    final String directionLabel = isOutgoing ? '发出' : '接收';
    final String timeLabel =
        DateFormat('yyyy-MM-dd HH:mm:ss').format(record.createdAt.toLocal());
    final String senderName = resolveDeviceName(record.senderDeviceId);
    final String receiverName = resolveDeviceName(record.receiverDeviceId);
    final Color backgroundColor =
        isOutgoing ? const Color(0xFFEAF4FF) : const Color(0xFFECFDF3);
    final Color borderColor =
        isOutgoing ? const Color(0xFFBFDBFE) : const Color(0xFFA7F3D0);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  record.fileName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _RelationshipChip(
                label: directionLabel,
                backgroundColor: borderColor.withValues(alpha: 0.28),
                foregroundColor: theme.colorScheme.onSurface,
              ),
            ],
          ),
          const SizedBox(height: 10),
          _LabeledValue(label: '文件大小', value: _formatFileSize(record.fileSize)),
          const SizedBox(height: 6),
          _LabeledValue(
            label: isOutgoing ? '接收设备' : '发出设备',
            value: isOutgoing
                ? '$receiverName (${record.receiverDeviceId})'
                : '$senderName (${record.senderDeviceId})',
          ),
          const SizedBox(height: 6),
          _LabeledValue(
            label: isOutgoing ? '发送时间' : '接收时间',
            value: timeLabel,
          ),
          const SizedBox(height: 6),
          _LabeledValue(
            label: '状态',
            value: _transferRecordStatusLabel(
              rawStatus: record.status.value,
              isOutgoing: isOutgoing,
            ),
          ),
          if (record.errorMessage != null &&
              record.errorMessage!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
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
  const _RelationshipChip({
    required this.label,
    this.backgroundColor,
    this.foregroundColor,
  });

  final String label;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor ??
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: foregroundColor,
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

class _LabeledValue extends StatelessWidget {
  const _LabeledValue({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

class _WaitingDots extends StatefulWidget {
  const _WaitingDots();

  @override
  State<_WaitingDots> createState() => _WaitingDotsState();
}

class _WaitingDotsState extends State<_WaitingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List<Widget>.generate(3, (int index) {
              final double t = (_controller.value + index * 0.18) % 1;
              final double opacity = 0.35 + (1 - (t - 0.5).abs() * 2) * 0.65;
              return Opacity(
                opacity: opacity.clamp(0.2, 1),
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(
                    color: Colors.grey,
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

String _deviceDisplayName({
  required String deviceId,
  required AppConfig config,
  required P2pPresenceState presence,
}) {
  if (deviceId == config.deviceId) {
    return config.deviceName.trim().isEmpty ? '当前设备' : config.deviceName;
  }

  for (final P2pDevice device in presence.devices) {
    if (device.deviceId == deviceId) {
      return device.deviceName.trim().isEmpty ? deviceId : device.deviceName;
    }
  }

  return deviceId;
}

String _devicePlatformFor({
  required String deviceId,
  required AppConfig config,
  required P2pPresenceState presence,
}) {
  if (deviceId == config.deviceId) {
    return _devicePlatformLabel(presence.currentDevice?.platform ?? 'unknown');
  }

  for (final P2pDevice device in presence.devices) {
    if (device.deviceId == deviceId) {
      return _devicePlatformLabel(device.platform);
    }
  }

  return '未知设备';
}

String _devicePlatformLabel(String platform) {
  return switch (platform.toLowerCase()) {
    'android' => 'Android',
    'ios' => 'iPhone / iPad',
    'windows' => 'Windows',
    'macos' => 'macOS',
    'linux' => 'Linux',
    _ => platform.trim().isEmpty ? '未知设备' : platform,
  };
}

String _deviceStatusLabel(P2pDeviceStatus status) {
  return switch (status) {
    P2pDeviceStatus.online => '在线',
    P2pDeviceStatus.stale => '心跳异常',
    P2pDeviceStatus.offline => '离线',
  };
}

String _requestStatusLabel(ConnectionRequestStatus status) {
  return switch (status) {
    ConnectionRequestStatus.pending => '等待处理',
    ConnectionRequestStatus.accepted => '已接受',
    ConnectionRequestStatus.rejected => '已拒绝',
    ConnectionRequestStatus.cancelled => '已取消',
    ConnectionRequestStatus.expired => '已过期',
  };
}

// ignore: unused_element
String _unusedSessionStatusLabel(P2pSessionStatus status) {
  return switch (status) {
    P2pSessionStatus.connecting => '连接中',
    P2pSessionStatus.active => '已连接',
    P2pSessionStatus.closed => '已关闭',
    P2pSessionStatus.failed => '连接失败',
  };
}

String _transportStatusLabel(P2pSessionTransport transport) {
  final String linkStatus = switch (transport.linkStatus) {
    TransportLinkStatus.idle => '未建立',
    TransportLinkStatus.negotiating => '协商中',
    TransportLinkStatus.connected =>
      transport.dataChannelOpen ? '可传输' : '已连接待就绪',
    TransportLinkStatus.closed => '已关闭',
    TransportLinkStatus.failed => '失败',
  };

  return linkStatus;
}

String _transferStatusLabel(String rawStatus) {
  return switch (rawStatus) {
    'pending' => '等待开始',
    'sending' => '发送中',
    'receiving' => '接收中',
    'received' => '已接收',
    'sent' => '已发送',
    'failed' => '失败',
    'cancelled' => '已取消',
    _ => rawStatus,
  };
}

String _transferRecordStatusLabel({
  required String rawStatus,
  required bool isOutgoing,
}) {
  if (!isOutgoing) {
    return switch (rawStatus) {
      'sent' ||
      'received' ||
      'receiving' =>
        rawStatus == 'receiving' ? '接收中' : '已接收',
      _ => _transferStatusLabel(rawStatus),
    };
  }
  return _transferStatusLabel(rawStatus);
}
