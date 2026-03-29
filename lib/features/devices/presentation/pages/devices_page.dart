import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/p2p_device.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';
import 'package:file_transfer_flutter/shared/providers/p2p_presence_providers.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:file_transfer_flutter/shared/widgets/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DevicesPage extends ConsumerWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presence = ref.watch(p2pPresenceProvider);
    final AppConfig config = ref.watch(appConfigProvider);
    final List<P2pDevice> devices =
        presence.devicesExcludingSelf(config.deviceId);

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          SectionCard(
            title: '在线设备',
            subtitle: '来自 /signaling 的在线列表、上下线和心跳状态会实时反映在这里。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _PresenceSummary(
                  localDeviceName:
                      presence.currentDevice?.deviceName ?? config.deviceName,
                  isOnline: presence.isOnline,
                  error: presence.lastError,
                ),
                const SizedBox(height: 16),
                if (devices.isEmpty)
                  const _EmptyHint(
                    text: '当前还没有发现其它设备。让另一台客户端点击“上线”后，这里会自动出现。',
                  )
                else
                  Column(
                    children: devices
                        .map((P2pDevice device) => _DeviceTile(device: device))
                        .toList(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PresenceSummary extends StatelessWidget {
  const _PresenceSummary({
    required this.localDeviceName,
    required this.isOnline,
    this.error,
  });

  final String localDeviceName;
  final bool isOnline;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color statusColor =
        isOnline ? const Color(0xFF15803D) : const Color(0xFFB42318);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                localDeviceName,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                isOnline ? '已上线' : '未上线',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (error != null && error!.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device});

  final P2pDevice device;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color statusColor = switch (device.status) {
      P2pDeviceStatus.online => const Color(0xFF15803D),
      P2pDeviceStatus.stale => const Color(0xFFB54708),
      P2pDeviceStatus.offline => const Color(0xFF667085),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            backgroundColor: statusColor.withValues(alpha: 0.12),
            foregroundColor: statusColor,
            child: const Icon(Icons.devices_other_outlined),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  device.deviceName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${device.platform} · ${device.deviceId}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              device.status.value,
              style: theme.textTheme.labelMedium?.copyWith(
                color: statusColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text);
  }
}
