import 'package:file_transfer_flutter/shared/widgets/section_card.dart';
import 'package:flutter/material.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const <Widget>[
          SectionCard(
            title: '局域网设备',
            subtitle: '这里可以承载设备发现、配对、信任管理和连接历史',
            child: _PlaceholderText(
              '建议后续增加协议适配器、握手流程、二维码配对和加密配置。',
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
