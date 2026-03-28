import 'package:file_transfer_flutter/shared/widgets/section_card.dart';
import 'package:flutter/material.dart';

class TransfersPage extends StatelessWidget {
  const TransfersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const <Widget>[
          SectionCard(
            title: '任务队列',
            subtitle: '这里适合扩展上传、下载、暂停、恢复、失败重试和速度统计',
            child: _PlaceholderText(
              '建议后续围绕 TransferTask 增加任务调度器、事件流和断点续传策略。',
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
