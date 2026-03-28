import 'package:file_transfer_flutter/shared/widgets/section_card.dart';
import 'package:flutter/material.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const <Widget>[
          SectionCard(
            title: '客户端配置',
            subtitle: '这里可以放主题、存储目录、带宽限制和关于信息',
            child: _PlaceholderText(
              '建议后续加入 AppConfig、环境配置、日志级别和实验功能开关。',
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaceholderText extends StatelessWidget {
  const _PlaceholderText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text);
  }
}
