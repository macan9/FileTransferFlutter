import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_transfer_flutter/core/config/app_network_config.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/p2p_presence_state.dart';
import 'package:file_transfer_flutter/shared/providers/p2p_presence_providers.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:file_transfer_flutter/shared/widgets/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _serverUrlController;
  late final TextEditingController _deviceNameController;
  late final TextEditingController _downloadDirectoryController;

  bool _autoOnline = true;
  bool _saving = false;
  bool _didInitialize = false;

  @override
  void initState() {
    super.initState();
    _serverUrlController = TextEditingController();
    _deviceNameController = TextEditingController();
    _downloadDirectoryController = TextEditingController();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _deviceNameController.dispose();
    _downloadDirectoryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppConfig config = ref.watch(appConfigProvider);
    final P2pPresenceState presence = ref.watch(p2pPresenceProvider);
    if (!_didInitialize) {
      _applyConfig(config);
      _didInitialize = true;
    }

    return Scaffold(
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            SectionCard(
              title: '客户端配置',
              subtitle: '统一维护进入实时链路前必须确定的基础配置。',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _buildTextField(
                    controller: _serverUrlController,
                    label: '服务端地址',
                    hintText: '例如 ${AppNetworkConfig.exampleLanServerUrl}',
                    keyboardType: TextInputType.url,
                    validator: _validateServerUrl,
                  ),
                  const SizedBox(height: 16),
                  _buildReadOnlyField(
                    label: '当前设备 ID',
                    value: config.deviceId,
                    action: IconButton(
                      tooltip: '复制设备 ID',
                      onPressed: () => _copyDeviceId(config.deviceId),
                      icon: const Icon(Icons.copy_rounded),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    controller: _deviceNameController,
                    label: '设备名称',
                    hintText: '用于在线列表和后续会话展示',
                    validator: _validateDeviceName,
                  ),
                  const SizedBox(height: 16),
                  _buildDirectoryField(),
                  const SizedBox(height: 16),
                  SwitchListTile.adaptive(
                    value: _autoOnline,
                    onChanged: (bool value) {
                      setState(() {
                        _autoOnline = value;
                      });
                    },
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动上线'),
                    subtitle: const Text('为后续自动接入信令层预留开关。'),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: _saving ? null : _saveConfig,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save_outlined),
                        label: Text(_saving ? '保存中...' : '保存配置'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: '信令在线状态',
              subtitle: '这里只展示 /signaling 的连接、注册和在线广播同步结果。',
              child: Column(
                children: <Widget>[
                  _InfoRow(
                      label: '当前状态', value: _presenceStatusLabel(presence)),
                  _InfoRow(
                    label: '本机设备名',
                    value:
                        presence.currentDevice?.deviceName ?? config.deviceName,
                  ),
                  _InfoRow(
                    label: '在线设备数',
                    value:
                        '${presence.devicesExcludingSelf(config.deviceId).length}',
                  ),
                  _InfoRow(label: 'Socket ID', value: presence.socketId ?? '-'),
                  _InfoRow(
                    label: '最近心跳',
                    value:
                        presence.lastHeartbeatAt?.toLocal().toString() ?? '-',
                  ),
                  if (presence.lastError != null &&
                      presence.lastError!.trim().isNotEmpty)
                    _InfoRow(label: '错误信息', value: presence.lastError!),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: '当前配置',
              subtitle: '这些值会被全局状态和后续实时链路直接读取。',
              child: Column(
                children: <Widget>[
                  _InfoRow(label: '服务端', value: config.serverUrl),
                  _InfoRow(label: '设备名称', value: config.deviceName),
                  _InfoRow(label: '保存目录', value: config.downloadDirectory),
                  _InfoRow(
                    label: '自动上线',
                    value: config.autoOnline ? '开启' : '关闭',
                  ),
                  _InfoRow(label: '平台', value: _platformLabel),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hintText,
    required String? Function(String?) validator,
    TextInputType? keyboardType,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        border: const OutlineInputBorder(),
      ),
      validator: validator,
    );
  }

  Widget _buildReadOnlyField({
    required String label,
    required String value,
    Widget? action,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: SelectableText(
                  value,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (action != null) action,
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDirectoryField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '本地保存目录',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextFormField(
                controller: _downloadDirectoryController,
                decoration: const InputDecoration(
                  hintText: '选择下载与接收文件的默认目录',
                  border: OutlineInputBorder(),
                ),
                validator: _validateDownloadDirectory,
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _saving ? null : _pickDirectory,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('选择'),
            ),
          ],
        ),
      ],
    );
  }

  void _applyConfig(AppConfig config) {
    _serverUrlController.text = config.serverUrl;
    _deviceNameController.text = config.deviceName;
    _downloadDirectoryController.text = config.downloadDirectory;
    _autoOnline = config.autoOnline;
  }

  Future<void> _pickDirectory() async {
    final String? directory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择本地保存目录',
    );

    if (!mounted || directory == null || directory.trim().isEmpty) {
      return;
    }

    setState(() {
      _downloadDirectoryController.text = directory;
    });
  }

  Future<void> _copyDeviceId(String deviceId) async {
    await Clipboard.setData(ClipboardData(text: deviceId));
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('设备 ID 已复制'),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<AppConfig?> _saveConfig({bool showFeedback = true}) async {
    final FormState? form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return null;
    }

    setState(() {
      _saving = true;
    });

    final AppConfig currentConfig = ref.read(appConfigProvider);
    final AppConfig nextConfig = currentConfig.copyWith(
      serverUrl: _serverUrlController.text,
      deviceName: _deviceNameController.text,
      downloadDirectory: _downloadDirectoryController.text,
      autoOnline: _autoOnline,
    );

    try {
      final AppConfig savedConfig =
          await ref.read(appConfigProvider.notifier).save(nextConfig);
      if (!mounted) {
        return savedConfig;
      }

      _applyConfig(savedConfig);
      if (showFeedback) {
        _showSnackBar('客户端基础配置已保存');
      }
      return savedConfig;
    } catch (error) {
      if (mounted) {
        _showSnackBar('保存失败: $error');
      }
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  String? _validateServerUrl(String? value) {
    final String text = value?.trim() ?? '';
    if (text.isEmpty) {
      return '请输入服务端地址';
    }

    final Uri? uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) {
      return '请输入完整的 http(s) 地址';
    }

    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '当前仅支持 http 或 https';
    }

    return null;
  }

  String? _validateDeviceName(String? value) {
    final String text = value?.trim() ?? '';
    if (text.isEmpty) {
      return '请输入设备名称';
    }

    if (text.length > 64) {
      return '设备名称请控制在 64 个字符以内';
    }

    return null;
  }

  String? _validateDownloadDirectory(String? value) {
    final String text = value?.trim() ?? '';
    if (text.isEmpty) {
      return '请选择本地保存目录';
    }

    return null;
  }

  String _presenceStatusLabel(P2pPresenceState presence) {
    return switch (presence.status) {
      SignalingPresenceStatus.offline => '未上线',
      SignalingPresenceStatus.connecting => '连接信令中',
      SignalingPresenceStatus.registering => '注册设备中',
      SignalingPresenceStatus.online => '在线',
    };
  }

  String get _platformLabel {
    if (Platform.isWindows) {
      return 'Windows';
    }
    if (Platform.isMacOS) {
      return 'macOS';
    }
    if (Platform.isLinux) {
      return 'Linux';
    }
    if (Platform.isAndroid) {
      return 'Android';
    }
    if (Platform.isIOS) {
      return 'iOS';
    }
    return 'Unknown';
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
