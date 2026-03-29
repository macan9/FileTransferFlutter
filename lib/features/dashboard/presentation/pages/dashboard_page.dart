import 'package:file_transfer_flutter/core/constants/app_constants.dart';
import 'package:file_transfer_flutter/features/dashboard/presentation/providers/dashboard_providers.dart';
import 'package:file_transfer_flutter/shared/widgets/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recentFiles = ref.watch(recentFilesProvider);
    final devices = ref.watch(dashboardDevicesProvider);
    final transfers = ref.watch(dashboardTransfersProvider);

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                colors: <Color>[Color(0xFF1565C0), Color(0xFF42A5F5)],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  AppConstants.appName,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  '一个面向本地优先的文件同步与局域网传输客户端。',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '最近文件',
            subtitle: '后续可接入本地索引、收藏夹和最近访问记录。',
            child: recentFiles.when(
              data: (List<String> files) {
                return Column(
                  children: files
                      .map(
                        (String file) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            child: Icon(Icons.insert_drive_file_outlined),
                          ),
                          title: Text(file),
                        ),
                      )
                      .toList(),
                );
              },
              loading: () => const LinearProgressIndicator(),
              error: (Object error, StackTrace stackTrace) {
                return Text('加载失败：$error');
              },
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '设备概览',
            subtitle: '这里已经接入全局信令在线状态，可看到其它客户端的上线结果。',
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _MetricTile(
                    label: '在线设备',
                    value: '${devices.where((item) => item.isOnline).length}',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MetricTile(
                    label: '已发现设备',
                    value: '${devices.length}',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '传输状态',
            subtitle: '后续可扩展上传、下载、局域网直传和任务调度。',
            child: transfers.when(
              data: (items) {
                return Column(
                  children: items
                      .map(
                        (item) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(item.fileName),
                              const SizedBox(height: 8),
                              LinearProgressIndicator(value: item.progress),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                );
              },
              loading: () => const LinearProgressIndicator(),
              error: (Object error, StackTrace stackTrace) {
                return Text('加载失败：$error');
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(label),
        ],
      ),
    );
  }
}
