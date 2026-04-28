import 'package:file_picker/file_picker.dart';
import 'package:file_transfer_flutter/core/config/app_network_config.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/p2p_presence_state.dart';
import 'package:file_transfer_flutter/core/services/launch_at_startup_service.dart';
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
  bool _minimizeToTrayOnClose = true;
  bool _launchAtStartup = false;
  bool _launchAtStartupLoading = false;
  bool _saving = false;
  bool _didInitialize = false;

  @override
  void initState() {
    super.initState();
    _serverUrlController = TextEditingController();
    _deviceNameController = TextEditingController();
    _downloadDirectoryController = TextEditingController();
    _loadLaunchAtStartup();
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
                    onChanged: _saving ? null : _setAutoOnline,
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.cloud_sync_outlined),
                    title: const Text('自动上线'),
                    subtitle: const Text('为后续自动接入信令层预留开关。'),
                  ),
                  SwitchListTile.adaptive(
                    value: _minimizeToTrayOnClose,
                    onChanged: _saving ? null : _setMinimizeToTrayOnClose,
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.system_update_alt_rounded),
                    title: const Text('\u5173\u95ed\u65f6\u6700\u5c0f\u5316\u5230\u6258\u76d8'),
                    subtitle: const Text(
                      '\u5f00\u542f\u540e\u5173\u95ed\u7a97\u53e3\u53ea\u4fdd\u7559\u6258\u76d8\uff1b\u5173\u95ed\u540e\u76f4\u63a5\u9000\u51fa\u7a0b\u5e8f',
                    ),
                  ),
                  if (LaunchAtStartupService.isSupported)
                    SwitchListTile.adaptive(
                      value: _launchAtStartup,
                      onChanged: _launchAtStartupLoading
                          ? null
                          : _setLaunchAtStartup,
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.rocket_launch_outlined),
                      title: const Text('\u5f00\u673a\u81ea\u542f\u52a8'),
                      subtitle: Text(
                        _launchAtStartupLoading
                            ? '\u6b63\u5728\u8bfb\u53d6\u5f00\u673a\u542f\u52a8\u72b6\u6001...'
                            : '\u767b\u5f55\u7cfb\u7edf\u540e\u81ea\u52a8\u542f\u52a8\u5c0f\u9a6c\u5de5\u5177\u7bb1',
                      ),
                    ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : _saveConfig,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(_saving ? '保存中...' : '保存配置'),
                    ),
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
          crossAxisAlignment: CrossAxisAlignment.center,
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
            SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _pickDirectory,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('选择'),
              ),
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
    _minimizeToTrayOnClose = config.minimizeToTrayOnClose;
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

  Future<void> _loadLaunchAtStartup() async {
    if (!LaunchAtStartupService.isSupported) {
      return;
    }

    setState(() {
      _launchAtStartupLoading = true;
    });

    try {
      final bool enabled = await LaunchAtStartupService.isEnabled();
      if (!mounted) {
        return;
      }
      setState(() {
        _launchAtStartup = enabled;
      });
    } catch (error) {
      if (mounted) {
        _showSnackBar(
          '\u8bfb\u53d6\u5f00\u673a\u81ea\u542f\u52a8\u72b6\u6001\u5931\u8d25: $error',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _launchAtStartupLoading = false;
        });
      }
    }
  }

  Future<void> _setLaunchAtStartup(bool value) async {
    setState(() {
      _launchAtStartup = value;
      _launchAtStartupLoading = true;
    });

    try {
      await LaunchAtStartupService.setEnabled(value);
      if (!mounted) {
        return;
      }
      _showSnackBar(
        value
            ? '\u5df2\u5f00\u542f\u5f00\u673a\u81ea\u542f\u52a8'
            : '\u5df2\u5173\u95ed\u5f00\u673a\u81ea\u542f\u52a8',
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _launchAtStartup = !value;
        });
        _showSnackBar(
          '\u66f4\u65b0\u5f00\u673a\u81ea\u542f\u52a8\u5931\u8d25: $error',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _launchAtStartupLoading = false;
        });
      }
    }
  }

  Future<void> _setAutoOnline(bool value) async {
    setState(() {
      _autoOnline = value;
      _saving = true;
    });

    try {
      final AppConfig currentConfig = ref.read(appConfigProvider);
      final AppConfig savedConfig =
          await ref.read(appConfigProvider.notifier).save(
                currentConfig.copyWith(autoOnline: value),
              );
      if (!mounted) {
        return;
      }
      _applyConfig(savedConfig);
      _showSnackBar(
        value
            ? '\u5df2\u5f00\u542f\u81ea\u52a8\u4e0a\u7ebf'
            : '\u5df2\u5173\u95ed\u81ea\u52a8\u4e0a\u7ebf\uff0c\u5f53\u524d\u8bbe\u5907\u5c06\u4e0b\u7ebf',
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _autoOnline = !value;
        });
        _showSnackBar(
          '\u66f4\u65b0\u81ea\u52a8\u4e0a\u7ebf\u5931\u8d25: $error',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _setMinimizeToTrayOnClose(bool value) async {
    setState(() {
      _minimizeToTrayOnClose = value;
      _saving = true;
    });

    try {
      final AppConfig currentConfig = ref.read(appConfigProvider);
      final AppConfig savedConfig =
          await ref.read(appConfigProvider.notifier).save(
                currentConfig.copyWith(minimizeToTrayOnClose: value),
              );
      if (!mounted) {
        return;
      }
      _applyConfig(savedConfig);
      _showSnackBar(
        value
            ? '\u5df2\u5f00\u542f\u5173\u95ed\u65f6\u6700\u5c0f\u5316\u5230\u6258\u76d8'
            : '\u5df2\u5173\u95ed\u6258\u76d8\u4fdd\u7559\uff0c\u5173\u95ed\u6309\u94ae\u5c06\u9000\u51fa\u7a0b\u5e8f',
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _minimizeToTrayOnClose = !value;
        });
        _showSnackBar(
          '\u66f4\u65b0\u5173\u95ed\u884c\u4e3a\u5931\u8d25: $error',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
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
      minimizeToTrayOnClose: _minimizeToTrayOnClose,
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
