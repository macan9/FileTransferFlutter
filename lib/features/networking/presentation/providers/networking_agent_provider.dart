import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/network_agent_command.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/models/zerotier_network_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_event.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_status.dart';
import 'package:file_transfer_flutter/core/services/method_channel_zerotier_service.dart';
import 'package:file_transfer_flutter/core/services/networking_service.dart';
import 'package:file_transfer_flutter/core/services/zerotier_facade.dart';
import 'package:file_transfer_flutter/core/services/zerotier_local_service.dart';
import 'package:file_transfer_flutter/features/networking/presentation/providers/networking_providers.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final zeroTierLocalServiceProvider = Provider<ZeroTierFacade>((Ref ref) {
  if (Platform.isWindows) {
    return ZeroTierFacade(
      platformApi: MethodChannelZeroTierService(),
    );
  }

  final ProcessZeroTierLocalService platformApi = ProcessZeroTierLocalService();
  ref.onDispose(() {
    unawaited(platformApi.dispose());
  });
  return ZeroTierFacade(platformApi: platformApi);
});

final networkingAgentRuntimeProvider = NotifierProvider<
    NetworkingAgentRuntimeController, NetworkingAgentRuntimeState>(
  NetworkingAgentRuntimeController.new,
);

class NetworkingAgentRuntimeState extends Equatable {
  const NetworkingAgentRuntimeState({
    required this.runtimeStatus,
    this.isBootstrapping = false,
    this.isHeartbeating = false,
    this.isPolling = false,
    this.lastHeartbeatAt,
    this.lastCommandAt,
    this.lastCommandSummary,
    this.lastRuntimeEvent,
    this.recentRuntimeEvents = const <ZeroTierRuntimeEvent>[],
    this.lastError,
  });

  const NetworkingAgentRuntimeState.initial()
      : runtimeStatus = const ZeroTierRuntimeStatus.unavailable(),
        isBootstrapping = false,
        isHeartbeating = false,
        isPolling = false,
        lastHeartbeatAt = null,
        lastCommandAt = null,
        lastCommandSummary = null,
        lastRuntimeEvent = null,
        recentRuntimeEvents = const <ZeroTierRuntimeEvent>[],
        lastError = null;

  final ZeroTierRuntimeStatus runtimeStatus;
  final bool isBootstrapping;
  final bool isHeartbeating;
  final bool isPolling;
  final DateTime? lastHeartbeatAt;
  final DateTime? lastCommandAt;
  final String? lastCommandSummary;
  final ZeroTierRuntimeEvent? lastRuntimeEvent;
  final List<ZeroTierRuntimeEvent> recentRuntimeEvents;
  final String? lastError;

  bool get isReady =>
      runtimeStatus.cliAvailable && runtimeStatus.nodeId.trim().isNotEmpty;

  NetworkingAgentRuntimeState copyWith({
    ZeroTierRuntimeStatus? runtimeStatus,
    bool? isBootstrapping,
    bool? isHeartbeating,
    bool? isPolling,
    DateTime? lastHeartbeatAt,
    bool clearLastHeartbeatAt = false,
    DateTime? lastCommandAt,
    bool clearLastCommandAt = false,
    String? lastCommandSummary,
    bool clearLastCommandSummary = false,
    ZeroTierRuntimeEvent? lastRuntimeEvent,
    bool clearLastRuntimeEvent = false,
    List<ZeroTierRuntimeEvent>? recentRuntimeEvents,
    String? lastError,
    bool clearLastError = false,
  }) {
    return NetworkingAgentRuntimeState(
      runtimeStatus: runtimeStatus ?? this.runtimeStatus,
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
      lastRuntimeEvent: clearLastRuntimeEvent
          ? null
          : lastRuntimeEvent ?? this.lastRuntimeEvent,
      recentRuntimeEvents: recentRuntimeEvents ?? this.recentRuntimeEvents,
      lastError: clearLastError ? null : lastError ?? this.lastError,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        runtimeStatus,
        isBootstrapping,
        isHeartbeating,
        isPolling,
        lastHeartbeatAt,
        lastCommandAt,
        lastCommandSummary,
        lastRuntimeEvent,
        recentRuntimeEvents,
        lastError,
      ];
}

class NetworkingAgentRuntimeController
    extends Notifier<NetworkingAgentRuntimeState> {
  Timer? _heartbeatTimer;
  Timer? _pollTimer;
  StreamSubscription<ZeroTierRuntimeEvent>? _runtimeEventSubscription;
  bool _started = false;
  bool _busyBootstrapping = false;
  bool _busyPolling = false;

  NetworkingService get _networkingService =>
      ref.read(networkingServiceProvider);
  ZeroTierFacade get _zeroTierService => ref.read(zeroTierLocalServiceProvider);

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
    await _refreshRuntimeStatus();
  }

  Future<void> _ensureStarted() async {
    if (_started) {
      return;
    }
    _started = true;
    _runtimeEventSubscription = _zeroTierService.watchRuntimeEvents().listen(
      _handleRuntimeEvent,
    );
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
      ZeroTierRuntimeStatus status = await _zeroTierService.detectStatus();
      state = state.copyWith(runtimeStatus: status);
      status = await _zeroTierService.prepareEnvironment();
      state = state.copyWith(runtimeStatus: status);

      if (!status.cliAvailable) {
        state = state.copyWith(
          isBootstrapping: false,
          lastError: status.lastError ??
              'ZeroTier runtime is not ready yet.',
        );
        return;
      }

      status = await _zeroTierService.startNode();
      state = state.copyWith(runtimeStatus: status);
      status = await _waitForNodeReady();
      state = state.copyWith(runtimeStatus: status);
      if (!status.hasNodeId) {
        state = state.copyWith(
          isBootstrapping: false,
          lastError: status.lastError ??
              'ZeroTier node has started, but Node ID is still unavailable.',
        );
        return;
      }

      final AppConfig config = ref.read(appConfigProvider);
      final bool needsBootstrap = config.agentToken.trim().isEmpty ||
          config.zeroTierNodeId.trim() != status.nodeId ||
          config.deviceId.trim().isEmpty;
      if (!needsBootstrap) {
        state = state.copyWith(isBootstrapping: false, clearLastError: true);
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
      await _refreshRuntimeStatus();
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
            throw const RealtimeError('Command payload is missing networkId.');
          }
          await _zeroTierService.joinNetworkAndWaitForIp(networkId);
          await _waitForNetworkReady(networkId);
          break;
          }
        case 'leave_zerotier_network':
          {
          final String networkId =
              command.payload['networkId']?.toString() ?? '';
          if (networkId.isEmpty) {
            throw const RealtimeError('Command payload is missing networkId.');
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
          throw RealtimeError('Unsupported command type: ${command.type}');
      }

      await _networkingService.ackAgentCommand(
        commandId: command.id,
        deviceId: config.deviceId,
        agentToken: config.agentToken,
        status: 'acknowledged',
      );
      state = state.copyWith(
        lastCommandAt: DateTime.now(),
        lastCommandSummary: 'Executed ${command.type}',
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
        lastCommandSummary: 'Failed ${command.type}',
        lastError: error is RealtimeError ? error.message : '$error',
      );
    }
  }

  Future<void> _refreshRuntimeStatus() async {
    try {
      final ZeroTierRuntimeStatus status = await _zeroTierService.detectStatus();
      state = state.copyWith(
        runtimeStatus: status,
        lastError: status.lastError,
      );
    } catch (error) {
      state = state.copyWith(
        lastError: error is RealtimeError ? error.message : '$error',
      );
    }
  }

  Future<ZeroTierRuntimeStatus> _waitForNodeReady() async {
    ZeroTierRuntimeStatus latest = state.runtimeStatus;
    for (int attempt = 0; attempt < 30; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      latest = await _zeroTierService.detectStatus();
      if (latest.hasNodeId || latest.lastError?.trim().isNotEmpty == true) {
        return latest;
      }
    }
    return latest;
  }

  Future<void> _waitForNetworkReady(String networkId) async {
    for (int attempt = 0; attempt < 60; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final ZeroTierRuntimeStatus status = await _zeroTierService.detectStatus();
      final ZeroTierNetworkState? network = status.joinedNetworks
          .where((ZeroTierNetworkState item) => item.networkId == networkId)
          .cast<ZeroTierNetworkState?>()
          .firstWhere(
            (ZeroTierNetworkState? item) => item != null,
            orElse: () => null,
          );
      if (status.lastError?.trim().isNotEmpty == true) {
        throw RealtimeError(status.lastError!);
      }
      if (network == null) {
        continue;
      }
      if (network.status == 'ACCESS_DENIED') {
        throw const RealtimeError(
          'ZeroTier network authorization is still pending.',
        );
      }
      if (network.assignedAddresses.isNotEmpty || network.isConnected) {
        return;
      }
    }
    throw const RealtimeError(
      'Timed out waiting for a managed address from ZeroTier.',
    );
  }

  void _handleRuntimeEvent(ZeroTierRuntimeEvent event) {
    final List<ZeroTierRuntimeEvent> recentEvents =
        <ZeroTierRuntimeEvent>[event, ...state.recentRuntimeEvents]
            .take(8)
            .toList(growable: false);
    state = state.copyWith(
      lastRuntimeEvent: event,
      recentRuntimeEvents: recentEvents,
      lastError: event.type == ZeroTierRuntimeEventType.error
          ? (event.message ?? state.lastError)
          : state.lastError,
    );
    unawaited(_refreshRuntimeStatus());
    if (_shouldRefreshDashboard(event)) {
      unawaited(ref.read(networkingProvider.notifier).refresh());
    }
  }

  bool _shouldRefreshDashboard(ZeroTierRuntimeEvent event) {
    switch (event.type) {
      case ZeroTierRuntimeEventType.nodeStarted:
      case ZeroTierRuntimeEventType.networkOnline:
      case ZeroTierRuntimeEventType.networkLeft:
      case ZeroTierRuntimeEventType.ipAssigned:
      case ZeroTierRuntimeEventType.error:
        return true;
      case ZeroTierRuntimeEventType.environmentReady:
      case ZeroTierRuntimeEventType.permissionRequired:
      case ZeroTierRuntimeEventType.nodeStopped:
      case ZeroTierRuntimeEventType.networkJoining:
      case ZeroTierRuntimeEventType.networkWaitingAuthorization:
        return false;
    }
  }

  void _dispose() {
    _heartbeatTimer?.cancel();
    _pollTimer?.cancel();
    unawaited(_runtimeEventSubscription?.cancel());
  }
}
