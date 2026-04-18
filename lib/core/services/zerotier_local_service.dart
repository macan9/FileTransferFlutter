import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/models/zerotier_local_status.dart';

abstract class ZeroTierLocalService {
  Future<ZeroTierLocalStatus> detectStatus();
  Future<void> joinNetworkAndWaitForIp(
    String networkId, {
    Duration timeout,
  });
  Future<void> leaveNetwork(String networkId);
  Future<void> applyFirewallRules({
    required String ruleScopeId,
    required String peerZeroTierIp,
    required List<Map<String, dynamic>> allowedInboundPorts,
  });
  Future<void> removeFirewallRules({
    required String ruleScopeId,
  });
}

class ProcessZeroTierLocalService implements ZeroTierLocalService {
  const ProcessZeroTierLocalService();

  static const List<String> _windowsCandidates = <String>[
    r'C:\Program Files\ZeroTier\One\zerotier-cli.bat',
    r'C:\Program Files\ZeroTier\One\zerotier-cli.exe',
    r'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat',
    r'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.exe',
    r'C:\ProgramData\ZeroTier\One\zerotier-cli.bat',
    r'C:\ProgramData\ZeroTier\One\zerotier-cli.exe',
  ];

  @override
  Future<ZeroTierLocalStatus> detectStatus() async {
    final String? executable = await _resolveCliExecutable();
    if (executable == null) {
      return const ZeroTierLocalStatus.unavailable();
    }

    final _CommandResult versionResult =
        await _run(executable, const <String>['-v']);
    final _CommandResult infoResult =
        await _run(executable, const <String>['info', '-j']);

    if (!infoResult.succeeded) {
      final _CommandResult fallbackInfo =
          await _run(executable, const <String>['info']);
      final String nodeId = _parseNodeIdFromInfoText(fallbackInfo.output);
      return ZeroTierLocalStatus(
        cliAvailable: fallbackInfo.succeeded,
        nodeId: nodeId,
        version: versionResult.output.trim().isEmpty
            ? null
            : versionResult.output.trim(),
      );
    }

    final String nodeId = _parseNodeIdFromInfoJson(infoResult.output);
    return ZeroTierLocalStatus(
      cliAvailable: true,
      nodeId: nodeId,
      version: versionResult.output.trim().isEmpty
          ? null
          : versionResult.output.trim(),
    );
  }

  @override
  Future<void> joinNetworkAndWaitForIp(
    String networkId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final String executable = await _requireCliExecutable();
    final _CommandResult joinResult =
        await _run(executable, <String>['join', networkId]);
    if (!joinResult.succeeded) {
      throw RealtimeError(
        'ZeroTier 加入网络失败：${joinResult.output.trim()}',
      );
    }

    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final _CommandResult networksResult =
          await _run(executable, const <String>['listnetworks', '-j']);
      if (networksResult.succeeded &&
          _networkHasAssignedIp(networksResult.output, networkId)) {
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    throw const RealtimeError('ZeroTier 网络已加入，但等待分配 IP 超时。');
  }

  @override
  Future<void> leaveNetwork(String networkId) async {
    final String executable = await _requireCliExecutable();
    final _CommandResult leaveResult =
        await _run(executable, <String>['leave', networkId]);
    if (!leaveResult.succeeded) {
      throw RealtimeError(
        'ZeroTier 离开网络失败：${leaveResult.output.trim()}',
      );
    }
  }

  @override
  Future<void> applyFirewallRules({
    required String ruleScopeId,
    required String peerZeroTierIp,
    required List<Map<String, dynamic>> allowedInboundPorts,
  }) async {
    if (allowedInboundPorts.isEmpty) {
      return;
    }

    if (!Platform.isWindows) {
      return;
    }

    for (final Map<String, dynamic> portRule in allowedInboundPorts) {
      final int? port = (portRule['port'] as num?)?.toInt();
      final String protocol =
          portRule['protocol']?.toString().toUpperCase() ?? '';
      if (port == null || port <= 0 || protocol.isEmpty) {
        continue;
      }

      final String displayName =
          'FileTransferFlutter-$ruleScopeId-$protocol-$port';
      final String command = '''
New-NetFirewallRule -DisplayName "$displayName" -Direction Inbound -Action Allow -RemoteAddress "$peerZeroTierIp" -Protocol "$protocol" -LocalPort $port -Profile Any
''';
      final ProcessResult result = await Process.run(
        'powershell.exe',
        <String>['-NoProfile', '-Command', command],
      );
      if (result.exitCode != 0) {
        throw RealtimeError(
          '应用防火墙规则失败：${(result.stderr ?? result.stdout).toString().trim()}',
        );
      }
    }
  }

  @override
  Future<void> removeFirewallRules({
    required String ruleScopeId,
  }) async {
    if (!Platform.isWindows) {
      return;
    }

    final String command = '''
Get-NetFirewallRule -DisplayName "FileTransferFlutter-$ruleScopeId-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
''';
    await Process.run(
      'powershell.exe',
      <String>['-NoProfile', '-Command', command],
    );
  }

  Future<String> _requireCliExecutable() async {
    final String? executable = await _resolveCliExecutable();
    if (executable == null) {
      throw const RealtimeError('未检测到 ZeroTier CLI，请先安装 ZeroTier One。');
    }
    return executable;
  }

  Future<String?> _resolveCliExecutable() async {
    if (Platform.isWindows) {
      for (final String candidate in _windowsCandidates) {
        if (await File(candidate).exists()) {
          return candidate;
        }
      }
      final _CommandResult whereResult =
          await _run('where', const <String>['zerotier-cli']);
      final String firstLine = whereResult.output
          .split(RegExp(r'[\r\n]+'))
          .map((String line) => line.trim())
          .firstWhere(
            (String line) => line.isNotEmpty,
            orElse: () => '',
          );
      return firstLine.isEmpty ? null : firstLine;
    }

    final _CommandResult whichResult =
        await _run('which', const <String>['zerotier-cli']);
    final String path = whichResult.output.trim();
    return path.isEmpty ? null : path;
  }

  Future<_CommandResult> _run(String executable, List<String> arguments) async {
    try {
      final ProcessResult result = await Process.run(executable, arguments);
      final String output = <String>[
        result.stdout?.toString() ?? '',
        result.stderr?.toString() ?? '',
      ].where((String item) => item.trim().isNotEmpty).join('\n');
      return _CommandResult(
        exitCode: result.exitCode,
        output: output,
      );
    } catch (_) {
      return const _CommandResult(exitCode: 1, output: '');
    }
  }

  String _parseNodeIdFromInfoJson(String raw) {
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map) {
        final dynamic address = decoded['address'] ?? decoded['nodeId'];
        return address?.toString() ?? '';
      }
    } catch (_) {
      // Fall through to empty string.
    }
    return '';
  }

  String _parseNodeIdFromInfoText(String raw) {
    final List<String> parts = raw
        .split(RegExp(r'\s+'))
        .where((String item) => item.trim().isNotEmpty)
        .toList();
    if (parts.length >= 3) {
      return parts[2];
    }
    return '';
  }

  bool _networkHasAssignedIp(String raw, String networkId) {
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) {
        return false;
      }
      for (final dynamic item in decoded) {
        if (item is! Map) {
          continue;
        }
        final String id =
            (item['nwid'] ?? item['networkId'] ?? item['id'])?.toString() ?? '';
        if (id != networkId) {
          continue;
        }
        final List<dynamic> assigned =
            (item['assignedAddresses'] as List?) ?? const <dynamic>[];
        final String status = item['status']?.toString().toUpperCase() ?? '';
        return assigned.isNotEmpty || status == 'OK';
      }
    } catch (_) {
      return false;
    }
    return false;
  }
}

class _CommandResult {
  const _CommandResult({
    required this.exitCode,
    required this.output,
  });

  final int exitCode;
  final String output;

  bool get succeeded => exitCode == 0;
}
