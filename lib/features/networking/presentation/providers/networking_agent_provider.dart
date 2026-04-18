import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/network_agent_command.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/models/zerotier_local_status.dart';
import 'package:file_transfer_flutter/core/services/networking_service.dart';
import 'package:file_transfer_flutter/core/services/zerotier_local_service.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final zeroTierLocalServiceProvider = Provider<ZeroTierLocalService>((Ref ref) {
  return const ProcessZeroTierLocalService();
});

final networkingAgentRuntimeProvider = NotifierProvider<
    NetworkingAgentRuntimeController, NetworkingAgentRuntimeState>(
  NetworkingAgentRuntimeController.new,
);

class NetworkingAgentRuntimeState extends Equatable {
  const NetworkingAgentRuntimeState({
    required this.zeroTierStatus,
    this.isBootstrapping = false,
    this.isHeartbeating = false,
    this.isPolling = false,
    this.lastHeartbeatAt,
    this.lastCommandAt,
    this.lastCommandSummary,
    this.lastError,
  });

  const NetworkingAgentRuntimeState.initial()
      : zeroTierStatus = const ZeroTierLocalStatus.unavailable(),
        isBootstrapping = false,
        isHeartbeating = false,
        isPolling = false,
        lastHeartbeatAt = null,
        lastCommandAt = null,
        lastCommandSummary = null,
        lastError = null;

  final ZeroTierLocalStatus zeroTierStatus;
  final bool isBootstrapping;
  final bool isHeartbeating;
  final bool isPolling;
  final DateTime? lastHeartbeatAt;
  final DateTime? lastCommandAt;
  final String? lastCommandSummary;
  final String? lastError;

  bool get isReady =>
      zeroTierStatus.cliAvailable && zeroTierStatus.nodeId.trim().isNotEmpty;

  NetworkingAgentRuntimeState copyWith({
    ZeroTierLocalStatus? zeroTierStatus,
    bool? isBootstrapping,
    bool? isHeartbeating,
    bool? isPolling,
    DateTime? lastHeartbeatAt,
    bool clearLastHeartbeatAt = false,
    DateTime? lastCommandAt,
    bool clearLastCommandAt = false,
    String? lastCommandSummary,
    bool clearLastCommandSummary = false,
    String? lastError,
    bool clearLastError = false,
  }) {
    return NetworkingAgentRuntimeState(
      zeroTierStatus: zeroTierStatus ?? this.zeroTierStatus,
      isBootstrapping: isBootstrapping ?? this.isBootstrapping,
      isHeartbeating: isHeartbeating ?? this.isHeartbeating,
      isPolling: isPolling ?? this.isPolling,
      lastHeartbeatAt:
          clearLastHeartbeatAt ? null : lastHeartbeatAt ?? this.lastHeartbeatAt,
      lastCommandAt:
          clearLastCommandAt ? null : lastCommandAt ?? this.lastCommandAt,
      lastCommandSummary: clearLastCommandSummary
          ? null
          : lastCommandSummary ?? this.lastCommandSummary,
      lastError: clearLastError ? null : lastError ?? this.lastError,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        zeroTierStatus,
        isBootstrapping,
        isHeartbeating,
        isPolling,
        lastHeartbeatAt,
        lastCommandAt,
        lastCommandSummary,
        lastError,
      ];
}

class NetworkingAgentRuntimeController
    extends Notifier<NetworkingAgentRuntimeState> {
  Timer? _heartbeatTimer;
  Timer? _pollTimer;
  bool _started = false;
  bool _busyBootstrapping = false;
  bool _busyPolling = false;

  NetworkingService get _networkingService =>
      ref.read(networkingServiceProvider);
  ZeroTierLocalService get _zeroTierService =>
      ref.read(zeroTierLocalServiceProvider);

  @override
  NetworkingAgentRuntimeState build() {
    ref.onDispose(_dispose);
    ref.listen<AppConfig>(appConfigProvider,
        (AppConfig? previous, AppConfig next) {
      if (previous?.agentToken != next.agentToken ||
          previous?.deviceId != next.deviceId ||
          previous?.zeroTierNodeId != next.zeroTierNodeId) {
        Future<void>.microtask(_ensureStarted);
      }
    });
    Future<void>.microtask(_ensureStarted);
    return const NetworkingAgentRuntimeState.initial();
  }

  Future<void> refreshNow() async {
    await _initializeIdentity();
    await _sendHeartbeat();
    await _pollCommands();
  }

  Future<void> _ensureStarted() async {
    if (_started) {
      return;
    }
    _started = true;
    await _initializeIdentity();
    _heartbeatTimer?.cancel();
    _pollTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) => _sendHeartbeat(),
    );
    _pollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _pollCommands(),
    );
    unawaited(_sendHeartbeat());
    unawaited(_pollCommands());
  }

  Future<void> _initializeIdentity() async {
    if (_busyBootstrapping) {
      return;
    }
    _busyBootstrapping = true;
    state = state.copyWith(
      isBootstrapping: true,
      clearLastError: true,
    );

    try {
      final ZeroTierLocalStatus status = await _zeroTierService.detectStatus();
      state = state.copyWith(zeroTierStatus: status);
      if (!status.cliAvailable || !status.hasNodeId) {
        state = state.copyWith(
          isBootstrapping: false,
          lastError: '未检测到可用的 ZeroTier CLI 或 Node ID。',
        );
        return;
      }

      final AppConfig config = ref.read(appConfigProvider);
      final bool needsBootstrap = config.agentToken.trim().isEmpty ||
          config.zeroTierNodeId.trim() != status.nodeId ||
          config.deviceId.trim().isEmpty;
      if (!needsBootstrap) {
        state = state.copyWith(isBootstrapping: false);
        return;
      }

      final NetworkDeviceIdentity identity =
          await _networkingService.bootstrapDevice(
        deviceName: config.deviceName,
        platform: config.devicePlatform,
        zeroTierNodeId: status.nodeId,
      );

      await ref.read(appConfigProvider.notifier).save(
            config.copyWith(
              deviceId: identity.id,
              deviceName: identity.deviceName.isEmpty
                  ? config.deviceName
                  : identity.deviceName,
              devicePlatform: identity.platform.isEmpty
                  ? config.devicePlatform
                  : identity.platform,
              zeroTierNodeId: identity.zeroTierNodeId,
              agentToken: identity.agentToken,
            ),
          );
      state = state.copyWith(
        isBootstrapping: false,
        clearLastError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isBootstrapping: false,
        lastError: error is RealtimeError ? error.message : '$error',
      );
    } finally {
      _busyBootstrapping = false;
    }
  }

  Future<void> _sendHeartbeat() async {
    final AppConfig config = ref.read(appConfigProvider);
    if (config.agentToken.trim().isEmpty ||
        config.deviceId.trim().isEmpty ||
        config.zeroTierNodeId.trim().isEmpty) {
      return;
    }

    state = state.copyWith(isHeartbeating: true);
    try {
      await _networkingService.heartbeatAgent(
        deviceId: config.deviceId,
        agentToken: config.agentToken,
        zeroTierNodeId: config.zeroTierNodeId,
      );
      state = state.copyWith(
        isHeartbeating: false,
        lastHeartbeatAt: DateTime.now(),
        clearLastError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isHeartbeating: false,
        lastError: error is RealtimeError ? error.message : '$error',
      );
    }
  }

  Future<void> _pollCommands() async {
    if (_busyPolling) {
      return;
    }
    final AppConfig config = ref.read(appConfigProvider);
    if (config.agentToken.trim().isEmpty ||
        config.deviceId.trim().isEmpty ||
        config.zeroTierNodeId.trim().isEmpty) {
      return;
    }

    _busyPolling = true;
    state = state.copyWith(isPolling: true);
    try {
      final List<NetworkAgentCommand> commands =
          await _networkingService.fetchAgentCommands(
        deviceId: config.deviceId,
        agentToken: config.agentToken,
      );

      if (commands.isEmpty) {
        state = state.copyWith(
          isPolling: false,
          clearLastError: true,
        );
        _busyPolling = false;
        return;
      }

      for (final NetworkAgentCommand command in commands) {
        await _executeCommand(config, command);
      }
      state = state.copyWith(isPolling: false);
    } catch (error) {
      state = state.copyWith(
        isPolling: false,
        lastError: error is RealtimeError ? error.message : '$error',
      );
    } finally {
      _busyPolling = false;
    }
  }

  Future<void> _executeCommand(
    AppConfig config,
    NetworkAgentCommand command,
  ) async {
    try {
      switch (command.type) {
        case 'join_zerotier_network':
          {
            final String networkId =
                command.payload['networkId']?.toString() ?? '';
            if (networkId.isEmpty) {
              throw const RealtimeError('命令缺少 networkId。');
            }
            await _zeroTierService.joinNetworkAndWaitForIp(networkId);
            break;
          }
        case 'leave_zerotier_network':
          {
            final String networkId =
                command.payload['networkId']?.toString() ?? '';
            if (networkId.isEmpty) {
              throw const RealtimeError('命令缺少 networkId。');
            }
            await _zeroTierService.leaveNetwork(networkId);
            break;
          }
        case 'apply_firewall_rules':
          {
            final String scopeId = (command.payload['sessionId'] ??
                    command.payload['managedNetworkId'] ??
                    command.sessionId ??
                    command.id)
                .toString();
            final String peerIp =
                command.payload['peerZeroTierIp']?.toString() ?? '';
            final List<Map<String, dynamic>> ports =
                ((command.payload['allowedInboundPorts'] as List?) ??
                        const <dynamic>[])
                    .whereType<Map>()
                    .map(
                      (Map<dynamic, dynamic> item) => item.map(
                        (dynamic key, dynamic value) =>
                            MapEntry(key.toString(), value),
                      ),
                    )
                    .toList();
            await _zeroTierService.applyFirewallRules(
              ruleScopeId: scopeId,
              peerZeroTierIp: peerIp,
              allowedInboundPorts: ports,
            );
            break;
          }
        case 'remove_firewall_rules':
          {
            final String scopeId = (command.payload['sessionId'] ??
                    command.payload['managedNetworkId'] ??
                    command.payload['networkId'] ??
                    command.sessionId ??
                    command.id)
                .toString();
            await _zeroTierService.removeFirewallRules(ruleScopeId: scopeId);
            break;
          }
        default:
          throw RealtimeError('暂不支持的命令类型：${command.type}');
      }

      await _networkingService.ackAgentCommand(
        commandId: command.id,
        deviceId: config.deviceId,
        agentToken: config.agentToken,
        status: 'acknowledged',
      );
      state = state.copyWith(
        lastCommandAt: DateTime.now(),
        lastCommandSummary: '已执行 ${command.type}',
        clearLastError: true,
      );
    } catch (error, stackTrace) {
      debugPrint('networking command failed: $error\n$stackTrace');
      await _networkingService.ackAgentCommand(
        commandId: command.id,
        deviceId: config.deviceId,
        agentToken: config.agentToken,
        status: 'failed',
        errorMessage: error is RealtimeError ? error.message : '$error',
      );
      state = state.copyWith(
        lastCommandAt: DateTime.now(),
        lastCommandSummary: '执行失败 ${command.type}',
        lastError: error is RealtimeError ? error.message : '$error',
      );
    }
  }

  void _dispose() {
    _heartbeatTimer?.cancel();
    _pollTimer?.cancel();
  }
}
