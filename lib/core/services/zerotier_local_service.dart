import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/models/zerotier_adapter_bridge_status.dart';
import 'package:file_transfer_flutter/core/models/zerotier_network_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_permission_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_event.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_status.dart';
import 'package:file_transfer_flutter/core/services/zerotier_platform_api.dart';

abstract class ZeroTierLocalService implements ZeroTierPlatformApi {}

class ProcessZeroTierLocalService implements ZeroTierLocalService {
  ProcessZeroTierLocalService();

  static const List<String> _windowsCandidates = <String>[
    r'C:\Program Files\ZeroTier\One\zerotier-cli.bat',
    r'C:\Program Files\ZeroTier\One\zerotier-cli.exe',
    r'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat',
    r'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.exe',
    r'C:\ProgramData\ZeroTier\One\zerotier-cli.bat',
    r'C:\ProgramData\ZeroTier\One\zerotier-cli.exe',
  ];

  final StreamController<ZeroTierRuntimeEvent> _events =
      StreamController<ZeroTierRuntimeEvent>.broadcast();

  @override
  Future<ZeroTierRuntimeStatus> detectStatus() async {
    final String? executable = await _resolveCliExecutable();
    if (executable == null) {
      return ZeroTierRuntimeStatus.unavailable().copyWith(
        permissionState: _detectPermissionState(),
        updatedAt: DateTime.now(),
      );
    }

    final _CommandResult versionResult =
        await _run(executable, const <String>['-v']);
    final _CommandResult infoResult =
        await _run(executable, const <String>['info', '-j']);
    final List<ZeroTierNetworkState> joinedNetworks =
        await _listNetworksInternal(executable);

    if (!infoResult.succeeded) {
      final _CommandResult fallbackInfo =
          await _run(executable, const <String>['info']);
      final String nodeId = _parseNodeIdFromInfoText(fallbackInfo.output);
      return ZeroTierRuntimeStatus(
        nodeId: nodeId,
        version: _normalizedVersion(versionResult.output),
        serviceState: fallbackInfo.succeeded ? 'available' : 'error',
        permissionState: _detectPermissionState(),
        isNodeRunning: nodeId.isNotEmpty,
        joinedNetworks: joinedNetworks,
        adapterBridge: const ZeroTierAdapterBridgeStatus.unknown(),
        lastError: fallbackInfo.succeeded ? null : fallbackInfo.output.trim(),
        updatedAt: DateTime.now(),
      );
    }

    final String nodeId = _parseNodeIdFromInfoJson(infoResult.output);
    return ZeroTierRuntimeStatus(
      nodeId: nodeId,
      version: _normalizedVersion(versionResult.output),
      serviceState: 'available',
      permissionState: _detectPermissionState(),
      isNodeRunning: nodeId.isNotEmpty,
      joinedNetworks: joinedNetworks,
      adapterBridge: const ZeroTierAdapterBridgeStatus.unknown(),
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<ZeroTierRuntimeStatus> prepareEnvironment() async {
    final ZeroTierRuntimeStatus status = await detectStatus();
    if (!status.cliAvailable) {
      _emit(
        ZeroTierRuntimeEventType.error,
        message: 'ZeroTier CLI is not available on this device.',
      );
      return status.copyWith(lastError: 'ZeroTier CLI is not available.');
    }

    final ZeroTierPermissionState permissionState = status.permissionState;
    if (!permissionState.isGranted) {
      _emit(
        ZeroTierRuntimeEventType.permissionRequired,
        message: permissionState.summary ?? 'ZeroTier requires extra setup.',
      );
      return status.copyWith(
        lastError: permissionState.summary ?? 'Permission required.',
      );
    }

    _emit(ZeroTierRuntimeEventType.environmentReady);
    return status.copyWith(clearLastError: true);
  }

  @override
  Future<ZeroTierRuntimeStatus> startNode() async {
    final ZeroTierRuntimeStatus status = await detectStatus();
    if (status.hasNodeId) {
      _emit(ZeroTierRuntimeEventType.nodeStarted, payload: <String, Object?>{
        'nodeId': status.nodeId,
      });
    }
    return status;
  }

  @override
  Future<ZeroTierRuntimeStatus> stopNode() async {
    final ZeroTierRuntimeStatus status = await detectStatus();
    _emit(ZeroTierRuntimeEventType.nodeStopped, payload: <String, Object?>{
      'nodeId': status.nodeId,
    });
    return status.copyWith(
      serviceState: status.cliAvailable ? 'available' : 'unavailable',
      isNodeRunning: false,
    );
  }

  @override
  Future<void> joinNetworkAndWaitForIp(
    String networkId, {
    Duration timeout = const Duration(seconds: 30),
    bool allowMountDegraded = false,
  }) async {
    final String executable = await _requireCliExecutable();
    _emit(
      ZeroTierRuntimeEventType.networkJoining,
      networkId: networkId,
    );
    final _CommandResult joinResult =
        await _run(executable, <String>['join', networkId]);
    if (!joinResult.succeeded) {
      _emit(
        ZeroTierRuntimeEventType.error,
        networkId: networkId,
        message: 'Failed to join ZeroTier network: ${joinResult.output.trim()}',
      );
      throw RealtimeError(
        'Failed to join ZeroTier network: ${joinResult.output.trim()}',
      );
    }

    final DateTime deadline = DateTime.now().add(timeout);
    bool authorizationEventSent = false;

    while (DateTime.now().isBefore(deadline)) {
      final List<ZeroTierNetworkState> networks =
          await _listNetworksInternal(executable);
      final ZeroTierNetworkState? network = _findNetwork(networks, networkId);
      if (network == null) {
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }

      if (!network.isAuthorized && !authorizationEventSent) {
        authorizationEventSent = true;
        _emit(
          ZeroTierRuntimeEventType.networkWaitingAuthorization,
          networkId: networkId,
          message: 'Waiting for ZeroTier network authorization.',
        );
      }

      if (network.assignedAddresses.isNotEmpty) {
        _emit(
          ZeroTierRuntimeEventType.ipAssigned,
          networkId: networkId,
          payload: <String, Object?>{
            'assignedAddresses': network.assignedAddresses,
          },
        );
        _emit(
          ZeroTierRuntimeEventType.networkOnline,
          networkId: networkId,
          payload: <String, Object?>{
            'assignedAddresses': network.assignedAddresses,
          },
        );
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    _emit(
      ZeroTierRuntimeEventType.error,
      networkId: networkId,
      message: 'Timed out while waiting for a ZeroTier address.',
    );
    throw const RealtimeError(
      'ZeroTier network joined, but timed out waiting for an assigned IP.',
    );
  }

  @override
  Future<void> leaveNetwork(
    String networkId, {
    String source = 'unknown',
  }) async {
    final String executable = await _requireCliExecutable();
    final _CommandResult leaveResult =
        await _run(executable, <String>['leave', networkId]);
    if (!leaveResult.succeeded) {
      _emit(
        ZeroTierRuntimeEventType.error,
        networkId: networkId,
        message:
            'Failed to leave ZeroTier network: ${leaveResult.output.trim()}',
      );
      throw RealtimeError(
        'Failed to leave ZeroTier network: ${leaveResult.output.trim()}',
      );
    }

    _emit(
      ZeroTierRuntimeEventType.networkLeft,
      networkId: networkId,
      payload: <String, Object?>{
        'leaveSource': source,
      },
    );
  }

  @override
  Future<List<ZeroTierNetworkState>> listNetworks() async {
    final String executable = await _requireCliExecutable();
    return _listNetworksInternal(executable);
  }

  @override
  Future<ZeroTierNetworkState?> getNetworkDetail(String networkId) async {
    final List<ZeroTierNetworkState> networks = await listNetworks();
    return _findNetwork(networks, networkId);
  }

  @override
  Future<void> applyFirewallRules({
    required String ruleScopeId,
    required String peerZeroTierIp,
    required List<Map<String, dynamic>> allowedInboundPorts,
  }) async {
    if (allowedInboundPorts.isEmpty || !Platform.isWindows) {
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
          'Failed to apply firewall rule: ${(result.stderr ?? result.stdout).toString().trim()}',
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

  @override
  Stream<ZeroTierRuntimeEvent> watchRuntimeEvents() => _events.stream;

  Future<void> dispose() => _events.close();

  Future<String> _requireCliExecutable() async {
    final String? executable = await _resolveCliExecutable();
    if (executable == null) {
      throw const RealtimeError(
        'ZeroTier CLI was not found. Install ZeroTier One first.',
      );
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

  Future<List<ZeroTierNetworkState>> _listNetworksInternal(
    String executable,
  ) async {
    final _CommandResult networksResult =
        await _run(executable, const <String>['listnetworks', '-j']);
    if (!networksResult.succeeded) {
      return const <ZeroTierNetworkState>[];
    }

    try {
      final dynamic decoded = jsonDecode(networksResult.output);
      if (decoded is! List) {
        return const <ZeroTierNetworkState>[];
      }
      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map(_parseNetworkState)
          .toList(growable: false);
    } catch (_) {
      return const <ZeroTierNetworkState>[];
    }
  }

  ZeroTierNetworkState _parseNetworkState(Map<dynamic, dynamic> raw) {
    final List<String> assignedAddresses =
        ((raw['assignedAddresses'] as List?) ?? const <dynamic>[])
            .map((dynamic item) => item.toString())
            .where((String item) => item.trim().isNotEmpty)
            .toList(growable: false);
    final String status = raw['status']?.toString() ?? 'UNKNOWN';
    final bool isAuthorized = _parseAuthorized(raw['authorized'], status);
    return ZeroTierNetworkState(
      networkId:
          (raw['nwid'] ?? raw['networkId'] ?? raw['id'])?.toString() ?? '',
      networkName:
          (raw['name'] ?? raw['networkName'] ?? raw['mac'])?.toString() ?? '',
      status: status,
      assignedAddresses: assignedAddresses,
      isAuthorized: isAuthorized,
      isConnected: assignedAddresses.isNotEmpty || status.toUpperCase() == 'OK',
      localInterfaceReady: false,
      matchedInterfaceName: '',
      matchedInterfaceUp: false,
      mountDriverKind: 'unknown',
      mountCandidateNames: const <String>[],
      routeExpected: false,
      expectedRouteCount: 0,
      systemIpBound: assignedAddresses.isNotEmpty,
      systemRouteBound: true,
      tapMediaStatus: assignedAddresses.isNotEmpty ? 'disconnected' : 'unknown',
      tapDeviceInstanceId: '',
      tapNetCfgInstanceId: '',
      localMountState: assignedAddresses.isNotEmpty ? 'adapter_down' : 'unknown',
    );
  }

  bool _parseAuthorized(dynamic value, String status) {
    if (value is bool) {
      return value;
    }
    final String normalized = value?.toString().toLowerCase() ?? '';
    if (normalized == 'true' || normalized == '1') {
      return true;
    }
    if (normalized == 'false' || normalized == '0') {
      return false;
    }
    return !status.toLowerCase().contains('access_denied') &&
        !status.toLowerCase().contains('authorization');
  }

  String _normalizedVersion(String raw) {
    final String version = raw.trim();
    return version.isEmpty ? '' : version;
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

  ZeroTierPermissionState _detectPermissionState() {
    if (Platform.isWindows) {
      return const ZeroTierPermissionState(
        isGranted: true,
        requiresManualSetup: false,
        isFirewallSupported: true,
        summary: 'Windows firewall rules can be managed automatically.',
      );
    }

    return const ZeroTierPermissionState(
      isGranted: true,
      requiresManualSetup: false,
      isFirewallSupported: false,
      summary:
          'Additional platform-specific permission integration is pending.',
    );
  }

  ZeroTierNetworkState? _findNetwork(
    List<ZeroTierNetworkState> networks,
    String networkId,
  ) {
    for (final ZeroTierNetworkState network in networks) {
      if (network.networkId == networkId) {
        return network;
      }
    }
    return null;
  }

  void _emit(
    ZeroTierRuntimeEventType type, {
    String? message,
    String? networkId,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    if (_events.isClosed) {
      return;
    }
    _events.add(
      ZeroTierRuntimeEvent(
        type: type,
        occurredAt: DateTime.now(),
        message: message,
        networkId: networkId,
        payload: payload,
      ),
    );
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
