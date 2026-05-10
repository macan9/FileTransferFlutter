import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/network_agent_command.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/models/zerotier_network_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_event.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_status.dart';
import 'package:file_transfer_flutter/core/services/method_channel_zerotier_service.dart';
import 'package:file_transfer_flutter/core/services/networking_service.dart';
import 'package:file_transfer_flutter/core/services/zerotier_facade.dart';
import 'package:file_transfer_flutter/core/services/zerotier_local_service.dart';
import 'package:file_transfer_flutter/features/networking/presentation/providers/networking_providers.dart';
import 'package:file_transfer_flutter/shared/providers/p2p_transport_providers.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void debugPrint(String? message, {int? wrapWidth}) {}

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
    this.isServerReachable = false,
    this.isActivated = false,
    this.isLocalInitializing = false,
    this.isBootstrapping = false,
    this.isNetworkActionLocked = false,
    this.isNetworkTransitioning = false,
    this.networkTransitionLabel,
    this.transitioningNetworkId,
    this.isHeartbeating = false,
    this.isPolling = false,
    this.lastHeartbeatAt,
    this.lastCommandAt,
    this.lastCommandSummary,
    this.lastRuntimeEvent,
    this.recentRuntimeEvents = const <ZeroTierRuntimeEvent>[],
    this.lastError,
    this.activeNetworkActionType,
    this.activeNetworkActionNetworkId,
    this.activeNetworkActionStartedAt,
    this.observedConnectionMode = 'unknown',
    this.observedRelayNodeId,
    this.preferredRelayNodeId,
    this.relayPolicy,
    this.observedRttMs,
    this.observedTxBytes,
    this.observedRxBytes,
  });

  const NetworkingAgentRuntimeState.initial()
      : runtimeStatus = const ZeroTierRuntimeStatus.unavailable(),
        isServerReachable = false,
        isActivated = false,
        isLocalInitializing = false,
        isBootstrapping = false,
        isNetworkActionLocked = false,
        isNetworkTransitioning = false,
        networkTransitionLabel = null,
        transitioningNetworkId = null,
        isHeartbeating = false,
        isPolling = false,
        lastHeartbeatAt = null,
        lastCommandAt = null,
        lastCommandSummary = null,
        lastRuntimeEvent = null,
        recentRuntimeEvents = const <ZeroTierRuntimeEvent>[],
        lastError = null,
        activeNetworkActionType = null,
        activeNetworkActionNetworkId = null,
        activeNetworkActionStartedAt = null,
        observedConnectionMode = 'unknown',
        observedRelayNodeId = null,
        preferredRelayNodeId = null,
        relayPolicy = null,
        observedRttMs = null,
        observedTxBytes = null,
        observedRxBytes = null;

  final ZeroTierRuntimeStatus runtimeStatus;
  final bool isServerReachable;
  final bool isActivated;
  final bool isLocalInitializing;
  final bool isBootstrapping;
  final bool isNetworkActionLocked;
  final bool isNetworkTransitioning;
  final String? networkTransitionLabel;
  final String? transitioningNetworkId;
  final bool isHeartbeating;
  final bool isPolling;
  final DateTime? lastHeartbeatAt;
  final DateTime? lastCommandAt;
  final String? lastCommandSummary;
  final ZeroTierRuntimeEvent? lastRuntimeEvent;
  final List<ZeroTierRuntimeEvent> recentRuntimeEvents;
  final String? lastError;
  final String? activeNetworkActionType;
  final String? activeNetworkActionNetworkId;
  final DateTime? activeNetworkActionStartedAt;
  final String observedConnectionMode;
  final String? observedRelayNodeId;
  final String? preferredRelayNodeId;
  final String? relayPolicy;
  final int? observedRttMs;
  final int? observedTxBytes;
  final int? observedRxBytes;

  bool get isReady => runtimeStatus.isNodeReady;
  bool get isLocalReady => runtimeStatus.isNodeReady;
  bool get hasActiveJoinSession => activeNetworkActionType == 'join';
  bool get hasActiveLeaveSession => activeNetworkActionType == 'leave';

  NetworkingAgentRuntimeState copyWith({
    ZeroTierRuntimeStatus? runtimeStatus,
    bool? isServerReachable,
    bool? isActivated,
    bool? isLocalInitializing,
    bool? isBootstrapping,
    bool? isNetworkActionLocked,
    bool? isNetworkTransitioning,
    String? networkTransitionLabel,
    bool clearNetworkTransitionLabel = false,
    String? transitioningNetworkId,
    bool clearTransitioningNetworkId = false,
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
    String? activeNetworkActionType,
    bool clearActiveNetworkActionType = false,
    String? activeNetworkActionNetworkId,
    bool clearActiveNetworkActionNetworkId = false,
    DateTime? activeNetworkActionStartedAt,
    bool clearActiveNetworkActionStartedAt = false,
    String? observedConnectionMode,
    String? observedRelayNodeId,
    bool clearObservedRelayNodeId = false,
    String? preferredRelayNodeId,
    bool clearPreferredRelayNodeId = false,
    String? relayPolicy,
    bool clearRelayPolicy = false,
    int? observedRttMs,
    bool clearObservedRttMs = false,
    int? observedTxBytes,
    bool clearObservedTxBytes = false,
    int? observedRxBytes,
    bool clearObservedRxBytes = false,
  }) {
    return NetworkingAgentRuntimeState(
      runtimeStatus: runtimeStatus ?? this.runtimeStatus,
      isServerReachable: isServerReachable ?? this.isServerReachable,
      isActivated: isActivated ?? this.isActivated,
      isLocalInitializing: isLocalInitializing ?? this.isLocalInitializing,
      isBootstrapping: isBootstrapping ?? this.isBootstrapping,
      isNetworkActionLocked:
          isNetworkActionLocked ?? this.isNetworkActionLocked,
      isNetworkTransitioning:
          isNetworkTransitioning ?? this.isNetworkTransitioning,
      networkTransitionLabel: clearNetworkTransitionLabel
          ? null
          : networkTransitionLabel ?? this.networkTransitionLabel,
      transitioningNetworkId: clearTransitioningNetworkId
          ? null
          : transitioningNetworkId ?? this.transitioningNetworkId,
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
      activeNetworkActionType: clearActiveNetworkActionType
          ? null
          : activeNetworkActionType ?? this.activeNetworkActionType,
      activeNetworkActionNetworkId: clearActiveNetworkActionNetworkId
          ? null
          : activeNetworkActionNetworkId ?? this.activeNetworkActionNetworkId,
      activeNetworkActionStartedAt: clearActiveNetworkActionStartedAt
          ? null
          : activeNetworkActionStartedAt ?? this.activeNetworkActionStartedAt,
      observedConnectionMode:
          observedConnectionMode ?? this.observedConnectionMode,
      observedRelayNodeId: clearObservedRelayNodeId
          ? null
          : observedRelayNodeId ?? this.observedRelayNodeId,
      preferredRelayNodeId: clearPreferredRelayNodeId
          ? null
          : preferredRelayNodeId ?? this.preferredRelayNodeId,
      relayPolicy: clearRelayPolicy ? null : relayPolicy ?? this.relayPolicy,
      observedRttMs:
          clearObservedRttMs ? null : observedRttMs ?? this.observedRttMs,
      observedTxBytes:
          clearObservedTxBytes ? null : observedTxBytes ?? this.observedTxBytes,
      observedRxBytes:
          clearObservedRxBytes ? null : observedRxBytes ?? this.observedRxBytes,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        runtimeStatus,
        isServerReachable,
        isActivated,
        isLocalInitializing,
        isBootstrapping,
        isNetworkActionLocked,
        isNetworkTransitioning,
        networkTransitionLabel,
        transitioningNetworkId,
        isHeartbeating,
        isPolling,
        lastHeartbeatAt,
        lastCommandAt,
        lastCommandSummary,
        lastRuntimeEvent,
        recentRuntimeEvents,
        lastError,
        activeNetworkActionType,
        activeNetworkActionNetworkId,
        activeNetworkActionStartedAt,
        observedConnectionMode,
        observedRelayNodeId,
        preferredRelayNodeId,
        relayPolicy,
        observedRttMs,
        observedTxBytes,
        observedRxBytes,
      ];
}

class NetworkingAgentRuntimeController
    extends Notifier<NetworkingAgentRuntimeState> {
  Timer? _heartbeatTimer;
  Timer? _pollTimer;
  StreamSubscription<ZeroTierRuntimeEvent>? _runtimeEventSubscription;
  final Map<String, int> _latestNetworkEventGeneration = <String, int>{};
  final Map<String, DateTime> _awaitingAddressLogAt = <String, DateTime>{};
  bool _started = false;
  bool _busyBootstrapping = false;
  bool _busyPolling = false;
  bool _suppressCommandPollingDuringRuntimeRecovery = false;
  DateTime? _commandPollingSuppressedAt;
  int _runtimeRefreshRevision = 0;
  int _consecutiveHeartbeatTransportFailureCount = 0;

  NetworkingService get _networkingService =>
      ref.read(networkingServiceProvider);
  ZeroTierFacade get _zeroTierService => ref.read(zeroTierLocalServiceProvider);

  @override
  NetworkingAgentRuntimeState build() {
    ref.onDispose(_dispose);
    return const NetworkingAgentRuntimeState.initial();
  }

  Future<void> refreshNow() async {
    await _refreshServerReachability();
    if (!_started) {
      await _refreshRuntimeStatus();
      return;
    }
    await _sendHeartbeat();
    await _pollCommands();
    await _refreshRuntimeStatus();
  }

  Future<void> activate() async {
    await _ensureStarted();
    await refreshNow();
  }

  Future<void> _refreshServerReachability() async {
    try {
      final bool reachable = await _networkingService.probeServerReachability();
      state = state.copyWith(
        isServerReachable: reachable,
      );
    } catch (_) {
      state = state.copyWith(
        isServerReachable: false,
      );
    }
  }

  Future<void> initializeLocalRuntime() async {
    if (_busyBootstrapping || state.isLocalReady) {
      await _refreshRuntimeStatus();
      return;
    }

    state = state.copyWith(
      isLocalInitializing: true,
      isNetworkTransitioning: true,
      networkTransitionLabel: '正在准备本地 ZeroTier 环境',
      clearLastError: true,
    );

    try {
      ZeroTierRuntimeStatus status = await _zeroTierService.detectStatus();
      state = state.copyWith(runtimeStatus: status);

      status = await _zeroTierService.prepareEnvironment();
      state = state.copyWith(runtimeStatus: status);

      if (!status.cliAvailable) {
        state = state.copyWith(
          isLocalInitializing: false,
          isNetworkTransitioning: false,
          clearNetworkTransitionLabel: true,
          lastError: status.lastError ?? 'ZeroTier runtime is not ready yet.',
        );
        return;
      }
      state = state.copyWith(
        runtimeStatus: status,
        isLocalInitializing: false,
        isNetworkTransitioning: false,
        clearNetworkTransitionLabel: true,
        clearLastError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLocalInitializing: false,
        isNetworkTransitioning: false,
        clearNetworkTransitionLabel: true,
        lastError: error is RealtimeError ? error.message : '$error',
      );
    }
  }

  Future<void> leaveNetwork(
    String networkId, {
    bool deactivateWhenIdle = false,
    String source = 'ui.unknown',
  }) async {
    if (networkId.trim().isEmpty) {
      return;
    }

    state = state.copyWith(
      isNetworkActionLocked: true,
      isNetworkTransitioning: true,
      networkTransitionLabel: '正在离开 ZeroTier 网络并收口本地链路',
      transitioningNetworkId: networkId,
      activeNetworkActionType: 'leave',
      activeNetworkActionNetworkId: networkId,
      activeNetworkActionStartedAt: DateTime.now(),
      clearLastError: true,
    );
    debugPrint(
      'ZeroTier leave requested: networkId=$networkId, source=$source',
    );
    try {
      await _zeroTierService.leaveNetwork(
        networkId,
        source: source,
      );
      if (_shouldWaitInDartForNetworkLeave) {
        await _waitForNetworkLeft(networkId);
      }
      await _finalizeRuntimeRecoveryAfterLeave(
        networkId,
        deactivateWhenIdle: deactivateWhenIdle,
      );
      state = state.copyWith(
        isNetworkActionLocked: false,
        isNetworkTransitioning: false,
        clearNetworkTransitionLabel: true,
        clearTransitioningNetworkId: true,
        clearActiveNetworkActionType: true,
        clearActiveNetworkActionNetworkId: true,
        clearActiveNetworkActionStartedAt: true,
      );
    } catch (error) {
      state = state.copyWith(
        isNetworkActionLocked: false,
        isNetworkTransitioning: false,
        clearNetworkTransitionLabel: true,
        clearTransitioningNetworkId: true,
        clearActiveNetworkActionType: true,
        clearActiveNetworkActionNetworkId: true,
        clearActiveNetworkActionStartedAt: true,
      );
      rethrow;
    }
  }

  Future<void> _finalizeRuntimeRecoveryAfterLeave(
    String networkId, {
    required bool deactivateWhenIdle,
  }) async {
    _suppressCommandPollingDuringRuntimeRecovery = true;
    _commandPollingSuppressedAt = DateTime.now();
    try {
      await _waitForRuntimeRecoveryAfterLeave(networkId);
      await _refreshRuntimeStatus();
      if (deactivateWhenIdle &&
          !Platform.isWindows &&
          state.runtimeStatus.joinedNetworks.isEmpty) {
        debugPrint(
          'ZeroTier runtime deactivating after leave: networkId=$networkId',
        );
        await deactivate(skipNativeStop: Platform.isWindows);
        return;
      }
      if (deactivateWhenIdle && Platform.isWindows) {
        debugPrint(
          'ZeroTier runtime stays active after leave on Windows: '
          'networkId=$networkId, joinedNetworks=${state.runtimeStatus.joinedNetworks.length}',
        );
      }
    } catch (error) {
      state = state.copyWith(
        lastError: error is RealtimeError ? error.message : '$error',
      );
    } finally {
      _suppressCommandPollingDuringRuntimeRecovery = false;
      _commandPollingSuppressedAt = null;
      unawaited(_pollCommands());
    }
  }

  Future<void> deactivate({
    bool skipNativeStop = false,
  }) async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _runtimeEventSubscription?.cancel();
    _runtimeEventSubscription = null;

    ZeroTierRuntimeStatus status = state.runtimeStatus;
    if (!skipNativeStop &&
        (_started || status.isNodeRunning || status.hasNodeId)) {
      try {
        status = await _zeroTierService.stopNode();
      } catch (_) {
        // Preserve the last known status if the local runtime is already gone.
      }
    }

    _started = false;
    _busyBootstrapping = false;
    _busyPolling = false;
    _suppressCommandPollingDuringRuntimeRecovery = false;
    _commandPollingSuppressedAt = null;
    state = state.copyWith(
      runtimeStatus: status,
      isActivated: false,
      isLocalInitializing: false,
      isBootstrapping: false,
      isNetworkActionLocked: false,
      isNetworkTransitioning: false,
      clearNetworkTransitionLabel: true,
      clearTransitioningNetworkId: true,
      isHeartbeating: false,
      isPolling: false,
      clearLastRuntimeEvent: true,
      recentRuntimeEvents: const <ZeroTierRuntimeEvent>[],
      clearActiveNetworkActionType: true,
      clearActiveNetworkActionNetworkId: true,
      clearActiveNetworkActionStartedAt: true,
    );
    _latestNetworkEventGeneration.clear();
  }

  Future<void> _ensureStarted() async {
    if (_started) {
      state = state.copyWith(isActivated: true);
      return;
    }
    _started = true;
    state = state.copyWith(isActivated: true);
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
          lastError: status.lastError ?? 'ZeroTier runtime is not ready yet.',
        );
        return;
      }

      status = await _ensureNodeReadyForBootstrap(status);
      state = state.copyWith(runtimeStatus: status);
      if (!status.isNodeReady) {
        state = state.copyWith(
          isBootstrapping: false,
          lastError: status.lastError ??
              'ZeroTier node has not reached the running state yet.',
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
    AppConfig config = ref.read(appConfigProvider);
    if (config.agentToken.trim().isEmpty ||
        config.deviceId.trim().isEmpty ||
        config.zeroTierNodeId.trim().isEmpty) {
      await _initializeIdentity();
      config = ref.read(appConfigProvider);
    }
    if (config.agentToken.trim().isEmpty ||
        config.deviceId.trim().isEmpty ||
        config.zeroTierNodeId.trim().isEmpty) {
      return;
    }

    config = await _alignIdentityWithRuntimeNode(config);
    if (config.agentToken.trim().isEmpty ||
        config.deviceId.trim().isEmpty ||
        config.zeroTierNodeId.trim().isEmpty) {
      return;
    }

    state = state.copyWith(isHeartbeating: true);
    final _ObservedRelayState observedRelayState = _resolveObservedRelayState();
    try {
      try {
        await _networkingService.heartbeatAgent(
          deviceId: config.deviceId,
          agentToken: config.agentToken,
          zeroTierNodeId: config.zeroTierNodeId,
          connectionMode: observedRelayState.connectionMode,
          relayNodeId: observedRelayState.relayNodeId,
          rttMs: observedRelayState.rttMs,
          txBytes: observedRelayState.txBytes,
          rxBytes: observedRelayState.rxBytes,
        );
      } on RealtimeError catch (error) {
        if (!await _recoverIdentityIfRequired(error)) {
          rethrow;
        }
        config = ref.read(appConfigProvider);
        if (config.agentToken.trim().isEmpty ||
            config.deviceId.trim().isEmpty ||
            config.zeroTierNodeId.trim().isEmpty) {
          throw const RealtimeError(
            'Agent identity recovery completed without usable credentials.',
          );
        }
        await _networkingService.heartbeatAgent(
          deviceId: config.deviceId,
          agentToken: config.agentToken,
          zeroTierNodeId: config.zeroTierNodeId,
          connectionMode: observedRelayState.connectionMode,
          relayNodeId: observedRelayState.relayNodeId,
          rttMs: observedRelayState.rttMs,
          txBytes: observedRelayState.txBytes,
          rxBytes: observedRelayState.rxBytes,
        );
      }
      state = state.copyWith(
        isHeartbeating: false,
        lastHeartbeatAt: DateTime.now(),
        observedConnectionMode: observedRelayState.connectionMode.value,
        observedRelayNodeId: observedRelayState.relayNodeId,
        clearObservedRelayNodeId: observedRelayState.relayNodeId == null,
        observedRttMs: observedRelayState.rttMs,
        observedTxBytes: observedRelayState.txBytes,
        observedRxBytes: observedRelayState.rxBytes,
        clearObservedRttMs: observedRelayState.rttMs == null,
        clearObservedTxBytes: observedRelayState.txBytes == null,
        clearObservedRxBytes: observedRelayState.rxBytes == null,
        clearLastError: true,
      );
      _consecutiveHeartbeatTransportFailureCount = 0;
    } catch (error) {
      if (_isTransientHeartbeatTransportError(error)) {
        _consecutiveHeartbeatTransportFailureCount += 1;
        if (_consecutiveHeartbeatTransportFailureCount < 3) {
          debugPrint(
            'Ignoring transient heartbeat transport error '
            '($_consecutiveHeartbeatTransportFailureCount/3): $error',
          );
          state = state.copyWith(isHeartbeating: false);
          return;
        }
      } else {
        _consecutiveHeartbeatTransportFailureCount = 0;
      }
      state = state.copyWith(
        isHeartbeating: false,
        lastError: error is RealtimeError ? error.message : '$error',
      );
    }
  }

  bool _isTransientHeartbeatTransportError(Object error) {
    final String message = error.toString().toLowerCase();
    return message
            .contains('connection closed before full header was received') ||
        message.contains('connection reset by peer') ||
        message.contains('connection terminated during handshake') ||
        message.contains('connection refused') ||
        message.contains('software caused connection abort') ||
        message.contains('connection aborted') ||
        message.contains('broken pipe') ||
        message.contains('failed host lookup') ||
        message.contains('timed out') ||
        message.contains('socketexception') ||
        message.contains('clientexception');
  }

  _ObservedRelayState _resolveObservedRelayState() {
    final transportState = ref.read(p2pTransportStreamProvider).valueOrNull;
    P2pConnectionMode mode = P2pConnectionMode.unknown;
    if (transportState != null) {
      for (final transport in transportState.sessionTransports) {
        if (transport.connectionMode == P2pConnectionMode.relay) {
          mode = P2pConnectionMode.relay;
          break;
        }
        if (transport.connectionMode == P2pConnectionMode.direct) {
          mode = P2pConnectionMode.direct;
        }
      }
    }

    final String? relayNodeId = mode == P2pConnectionMode.relay
        ? _firstNonEmpty(
            state.observedRelayNodeId,
            state.preferredRelayNodeId,
          )
        : null;
    return _ObservedRelayState(
      connectionMode: mode,
      relayNodeId: relayNodeId,
      rttMs: _firstObservedMetric(
        transportState?.sessionTransports
            .map((item) => item.rttMs)
            .whereType<int>(),
      ),
      txBytes: _firstObservedMetric(
        transportState?.sessionTransports
            .map((item) => item.txBytes)
            .whereType<int>(),
      ),
      rxBytes: _firstObservedMetric(
        transportState?.sessionTransports
            .map((item) => item.rxBytes)
            .whereType<int>(),
      ),
    );
  }

  void _captureRelayHint(NetworkAgentCommand command) {
    final String? relayNodeId = command.preferredRelayNodeId;
    final RelayPolicy? relayPolicy = command.relayPolicy;
    if (relayNodeId == null && relayPolicy == null) {
      return;
    }
    state = state.copyWith(
      preferredRelayNodeId: relayNodeId,
      clearPreferredRelayNodeId: relayNodeId == null,
      relayPolicy: relayPolicy?.value,
      clearRelayPolicy: relayPolicy == null,
    );
  }

  Future<void> _pollCommands() async {
    if (_busyPolling) {
      return;
    }
    if (_suppressCommandPollingDuringRuntimeRecovery) {
      final DateTime now = DateTime.now();
      final DateTime? suppressedAt = _commandPollingSuppressedAt;
      final bool suppressionExpired = suppressedAt == null ||
          now.difference(suppressedAt) > const Duration(seconds: 20);
      if (suppressionExpired) {
        debugPrint(
          'Command polling suppression exceeded safety timeout; '
          'resuming polling automatically.',
        );
        _suppressCommandPollingDuringRuntimeRecovery = false;
        _commandPollingSuppressedAt = null;
      } else {
        debugPrint(
          'Skip polling agent commands while ZeroTier runtime recovery is running in background.',
        );
        return;
      }
    }
    AppConfig config = ref.read(appConfigProvider);
    if (config.agentToken.trim().isEmpty ||
        config.deviceId.trim().isEmpty ||
        config.zeroTierNodeId.trim().isEmpty) {
      await _initializeIdentity();
      config = ref.read(appConfigProvider);
    }
    if (config.agentToken.trim().isEmpty ||
        config.deviceId.trim().isEmpty ||
        config.zeroTierNodeId.trim().isEmpty) {
      return;
    }

    config = await _alignIdentityWithRuntimeNode(config);
    if (config.agentToken.trim().isEmpty ||
        config.deviceId.trim().isEmpty ||
        config.zeroTierNodeId.trim().isEmpty) {
      return;
    }

    _busyPolling = true;
    state = state.copyWith(isPolling: true);
    try {
      List<NetworkAgentCommand> commands;
      try {
        commands = await _networkingService.fetchAgentCommands(
          deviceId: config.deviceId,
          agentToken: config.agentToken,
        );
      } on RealtimeError catch (error) {
        if (!await _recoverIdentityIfRequired(error)) {
          rethrow;
        }
        config = ref.read(appConfigProvider);
        if (config.agentToken.trim().isEmpty ||
            config.deviceId.trim().isEmpty ||
            config.zeroTierNodeId.trim().isEmpty) {
          throw const RealtimeError(
            'Agent identity recovery completed without usable credentials.',
          );
        }
        commands = await _networkingService.fetchAgentCommands(
          deviceId: config.deviceId,
          agentToken: config.agentToken,
        );
      }

      if (commands.isEmpty) {
        state = state.copyWith(
          isPolling: false,
          clearLastError: true,
        );
        _busyPolling = false;
        return;
      }

      for (final NetworkAgentCommand command in commands) {
        if (command.isSkipped) {
          state = state.copyWith(
            lastCommandAt: DateTime.now(),
            lastCommandSummary: 'Skipped ${command.status} ${command.type}',
            clearLastError: true,
          );
          continue;
        }
        if (command.isFinal) {
          continue;
        }
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
    String? activeActionType;
    String? activeActionNetworkId;
    try {
      _captureRelayHint(command);
      switch (command.type) {
        case 'join_zerotier_network':
          {
            final String networkId =
                command.payload['networkId']?.toString() ?? '';
            if (networkId.isEmpty) {
              throw const RealtimeError(
                  'Command payload is missing networkId.');
            }
            debugPrint(
              'ZT join checkpoint[1] command-start '
              'networkId=$networkId commandId=${command.id} '
              'sessionId=${command.sessionId ?? '-'}',
            );
            activeActionType = 'join';
            activeActionNetworkId = networkId;
            _beginNetworkActionSession(activeActionType, activeActionNetworkId);
            await _joinNetworkWithRecovery(networkId);
            await _ensureManagedAddressAssignedForCommand(networkId);
            await _refreshRuntimeStatus();
            await ref.read(networkingProvider.notifier).refresh();
            _endNetworkActionSession(
              actionType: activeActionType,
              networkId: activeActionNetworkId,
            );
            break;
          }
        case 'leave_zerotier_network':
          {
            final String networkId =
                command.payload['networkId']?.toString() ?? '';
            if (networkId.isEmpty) {
              throw const RealtimeError(
                  'Command payload is missing networkId.');
            }
            final String leaveSource =
                'agent.command:${command.id.isEmpty ? 'unknown' : command.id}';
            debugPrint(
              'ZT leave checkpoint command-start '
              'networkId=$networkId commandId=${command.id} '
              'sessionId=${command.sessionId ?? '-'} source=$leaveSource',
            );
            if (await _shouldSuppressLeaveCommand(
              config,
              command: command,
              networkId: networkId,
            )) {
              debugPrint(
                'Skipping stale leave command: id=${command.id}, '
                'networkId=$networkId because a newer join command is pending.',
              );
              break;
            }
            activeActionType = 'leave';
            activeActionNetworkId = networkId;
            _beginNetworkActionSession(activeActionType, activeActionNetworkId);
            await _zeroTierService.leaveNetwork(
              networkId,
              source: leaveSource,
            );
            if (_shouldWaitInDartForNetworkLeave) {
              await _waitForNetworkLeft(networkId);
            }
            await _refreshRuntimeStatus();
            await ref.read(networkingProvider.notifier).refresh();
            _endNetworkActionSession(
              actionType: activeActionType,
              networkId: activeActionNetworkId,
            );
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
      debugPrint(
        'Agent command completed: id=${command.id}, type=${command.type}, '
        'status=acknowledged',
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
      _endNetworkActionSession(
        actionType: activeActionType,
        networkId: activeActionNetworkId,
      );
    }
  }

  void _beginNetworkActionSession(String? actionType, String? networkId) {
    if (actionType == null || networkId == null || networkId.trim().isEmpty) {
      return;
    }
    state = state.copyWith(
      activeNetworkActionType: actionType,
      activeNetworkActionNetworkId: networkId,
      activeNetworkActionStartedAt: DateTime.now(),
    );
  }

  void _endNetworkActionSession({
    required String? actionType,
    required String? networkId,
  }) {
    final String currentType = state.activeNetworkActionType?.trim() ?? '';
    final String currentNetworkId =
        state.activeNetworkActionNetworkId?.trim().toLowerCase() ?? '';
    final String targetType = actionType?.trim() ?? '';
    final String targetNetworkId = networkId?.trim().toLowerCase() ?? '';
    if (currentType.isEmpty || currentNetworkId.isEmpty) {
      return;
    }
    if (targetType.isNotEmpty && currentType != targetType) {
      return;
    }
    if (targetNetworkId.isNotEmpty && currentNetworkId != targetNetworkId) {
      return;
    }
    state = state.copyWith(
      clearActiveNetworkActionType: true,
      clearActiveNetworkActionNetworkId: true,
      clearActiveNetworkActionStartedAt: true,
    );
  }

  Future<void> _refreshRuntimeStatus() async {
    final int revision = ++_runtimeRefreshRevision;
    try {
      final ZeroTierRuntimeStatus previous = state.runtimeStatus;
      ZeroTierRuntimeStatus status = await _zeroTierService.detectStatus();
      if (revision != _runtimeRefreshRevision) {
        return;
      }
      status = _stabilizeTransientWindowsStatus(previous, status);
      if (_shouldClearRecoveredRuntimeError(status)) {
        status = status.copyWith(clearLastError: true);
      }
      _logRuntimeStatusChange(previous, status);
      state = state.copyWith(
        runtimeStatus: status,
        lastError: status.lastError,
        clearLastError: status.lastError?.trim().isNotEmpty != true,
      );
      _logAwaitingAddressCheckpoint(status);
    } catch (error) {
      if (revision != _runtimeRefreshRevision) {
        return;
      }
      state = state.copyWith(
        lastError: error is RealtimeError ? error.message : '$error',
      );
    }
  }

  Future<void> _joinNetworkWithRecovery(String networkId) async {
    if (await _shouldSkipJoinBecauseNetworkReady(networkId)) {
      return;
    }
    await _ensureNodeOnlineForJoin();
    if (await _shouldSkipJoinBecauseNetworkReady(networkId)) {
      return;
    }
    try {
      await _joinNetworkWithNativeTimeoutGuard(networkId);
    } catch (error) {
      if (!_shouldAttemptWindowsJoinRecovery(error)) {
        rethrow;
      }
      debugPrint(
        'ZeroTier join recovery: networkId=$networkId, '
        'reason=${error is RealtimeError ? error.message : error}',
      );
      await _recoverWindowsJoinMapping(networkId);
    }

    if (_shouldWaitInDartForNetworkJoin) {
      await _waitForNetworkReady(networkId);
    }
  }

  Future<bool> _shouldSkipJoinBecauseNetworkReady(String networkId) async {
    ZeroTierRuntimeStatus status = state.runtimeStatus;
    ZeroTierNetworkState? network = _findJoinedNetwork(status, networkId);
    if (network == null) {
      status = await _zeroTierService.detectStatus();
      state = state.copyWith(runtimeStatus: status);
      network = _findJoinedNetwork(status, networkId);
    }
    return network != null && _isNetworkFullyReadyForCommand(network);
  }

  bool _shouldAttemptWindowsJoinRecovery(Object error) {
    if (!Platform.isWindows) {
      return false;
    }
    final String message = error is RealtimeError
        ? error.message.toLowerCase()
        : '$error'.toLowerCase();
    return message.contains('timed out waiting for a managed address') ||
        message.contains('system mount readiness') ||
        message.contains('requesting_configuration') ||
        message.contains('node stayed offline');
  }

  Future<void> _recoverWindowsJoinMapping(String networkId) async {
    try {
      await _zeroTierService.leaveNetwork(
        networkId,
        source: 'agent.windows-recovery',
      );
      debugPrint(
        'ZeroTier join recovery: local leave requested for networkId=$networkId',
      );
    } catch (error) {
      debugPrint(
        'ZeroTier join recovery: leave skipped for networkId=$networkId, '
        'reason=${error is RealtimeError ? error.message : error}',
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 800));
    final ZeroTierRuntimeStatus restarted = await _zeroTierService.startNode();
    debugPrint(
      'ZeroTier join recovery: startNode result '
      'serviceState=${restarted.serviceState}, '
      'isNodeRunning=${restarted.isNodeRunning}, '
      'joinedNetworks=${restarted.joinedNetworks.length}, '
      'lastError=${restarted.lastError ?? '-'}',
    );
    await _ensureNodeOnlineForJoin();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _joinNetworkWithNativeTimeoutGuard(networkId);
  }

  Future<void> _joinNetworkWithNativeTimeoutGuard(String networkId) async {
    final Duration nativeTimeout = _joinWaitTimeout;
    final Duration guardTimeout = nativeTimeout + const Duration(seconds: 15);
    try {
      await _zeroTierService
          .joinNetworkAndWaitForIp(
            networkId,
            timeout: nativeTimeout,
            allowMountDegraded: _allowMountDegradedJoin,
          )
          .timeout(guardTimeout);
    } on TimeoutException {
      throw RealtimeError(
        'ZeroTier native join call timed out after '
        '${guardTimeout.inSeconds}s (networkId=$networkId).',
      );
    }
  }

  Future<bool> _shouldSuppressLeaveCommand(
    AppConfig config, {
    required NetworkAgentCommand command,
    required String networkId,
  }) async {
    final List<NetworkAgentCommand> latestCommands =
        await _networkingService.fetchAgentCommands(
      deviceId: config.deviceId,
      agentToken: config.agentToken,
    );
    final DateTime commandCreatedAt =
        command.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    for (final NetworkAgentCommand candidate in latestCommands) {
      if (candidate.type != 'join_zerotier_network' ||
          candidate.isSkipped ||
          candidate.isFinal) {
        continue;
      }
      final String candidateNetworkId =
          candidate.payload['networkId']?.toString() ?? '';
      if (candidateNetworkId.trim() != networkId.trim()) {
        continue;
      }
      final DateTime candidateCreatedAt =
          candidate.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      if (!candidateCreatedAt.isBefore(commandCreatedAt)) {
        return true;
      }
    }
    return false;
  }

  ZeroTierRuntimeStatus _stabilizeTransientWindowsStatus(
    ZeroTierRuntimeStatus previous,
    ZeroTierRuntimeStatus next,
  ) {
    if (!Platform.isWindows) {
      return next;
    }
    final ZeroTierRuntimeStatus merged = _mergeTransientRegressedNetworks(
      previous,
      next,
    );
    if (merged != next) {
      return merged;
    }
    if (next.joinedNetworks.isNotEmpty || previous.joinedNetworks.isEmpty) {
      return next;
    }
    if (state.isNetworkTransitioning &&
        state.transitioningNetworkId?.trim().isNotEmpty == true) {
      return next;
    }

    final ZeroTierRuntimeEventType? lastEventType =
        state.lastRuntimeEvent?.type;
    final bool sawSuccessfulNetworkEvent =
        lastEventType == ZeroTierRuntimeEventType.networkOnline ||
            lastEventType == ZeroTierRuntimeEventType.ipAssigned;
    final bool previousHadUsableNetwork = previous.joinedNetworks.any(
      (ZeroTierNetworkState item) =>
          item.localInterfaceReady ||
          item.isConnected ||
          item.assignedAddresses.isNotEmpty,
    );
    final bool nextLooksTransient = next.serviceState == 'offline' ||
        next.serviceState == 'starting' ||
        next.serviceState == 'error';

    if (!sawSuccessfulNetworkEvent ||
        !previousHadUsableNetwork ||
        !nextLooksTransient) {
      return next;
    }

    debugPrint(
      'ZeroTier runtime status: retaining previous joined networks during '
      'transient Windows runtime wobble. '
      'previous=${_summarizeNetworks(previous.joinedNetworks)}, '
      'nextServiceState=${next.serviceState}, '
      'lastEvent=${lastEventType?.name ?? '-'}',
    );
    return next.copyWith(joinedNetworks: previous.joinedNetworks);
  }

  ZeroTierRuntimeStatus _mergeTransientRegressedNetworks(
    ZeroTierRuntimeStatus previous,
    ZeroTierRuntimeStatus next,
  ) {
    if (previous.joinedNetworks.isEmpty || next.joinedNetworks.isEmpty) {
      return next;
    }

    final Map<String, ZeroTierNetworkState> previousById =
        <String, ZeroTierNetworkState>{
      for (final ZeroTierNetworkState item in previous.joinedNetworks)
        item.networkId.trim().toLowerCase(): item,
    };

    bool changed = false;
    final List<ZeroTierNetworkState> merged =
        next.joinedNetworks.map((ZeroTierNetworkState current) {
      final String key = current.networkId.trim().toLowerCase();
      final ZeroTierNetworkState? prev = previousById[key];
      if (prev == null) {
        return current;
      }
      final bool prevReady = prev.status == 'OK' &&
          (prev.localInterfaceReady ||
              prev.isConnected ||
              prev.assignedAddresses.isNotEmpty);
      final bool currentRegressed =
          current.status == 'REQUESTING_CONFIGURATION' &&
              !current.isConnected &&
              current.assignedAddresses.isEmpty;
      if (!prevReady || !currentRegressed) {
        return current;
      }
      changed = true;
      return prev;
    }).toList(growable: false);

    if (!changed) {
      return next;
    }

    debugPrint(
      'ZeroTier runtime status: retained previous ready network state to '
      'avoid transient REQUESTING_CONFIGURATION regression. '
      'previous=${_summarizeNetworks(previous.joinedNetworks)}, '
      'next=${_summarizeNetworks(next.joinedNetworks)}',
    );
    return next.copyWith(joinedNetworks: merged);
  }

  Future<ZeroTierRuntimeStatus> _waitForNodeReady() async {
    ZeroTierRuntimeStatus latest = state.runtimeStatus;
    for (int attempt = 0; attempt < 30; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      latest = await _zeroTierService.detectStatus();
      if (latest.isNodeReady ||
          latest.serviceState == 'error' ||
          latest.lastError?.trim().isNotEmpty == true) {
        return latest;
      }
    }
    return latest;
  }

  Future<ZeroTierRuntimeStatus> _ensureNodeReadyForBootstrap(
    ZeroTierRuntimeStatus status,
  ) async {
    if (status.isNodeReady) {
      return status;
    }

    if (status.serviceState == 'starting') {
      debugPrint(
        'ZeroTier bootstrap preflight: node already starting, '
        'waiting instead of requesting another startNode.',
      );
      return _waitForNodeReady();
    }

    if (status.serviceState == 'offline') {
      debugPrint(
        'ZeroTier bootstrap preflight: node is offline, '
        'waiting for recovery and skipping proactive restart.',
      );
      final ZeroTierRuntimeStatus recovered =
          await _waitForOfflineNodeRecovery();
      if (recovered.isNodeReady) {
        return recovered;
      }
      return recovered;
    }

    if (status.serviceState == 'prepared' || !status.isNodeRunning) {
      debugPrint(
        'ZeroTier bootstrap preflight: requesting startNode '
        'serviceState=${status.serviceState}, '
        'isNodeRunning=${status.isNodeRunning}',
      );
      status = await _zeroTierService.startNode();
      state = state.copyWith(runtimeStatus: status);
      if (status.isNodeReady) {
        return status;
      }
      return _waitForNodeReady();
    }

    return status;
  }

  Future<void> _ensureNodeOnlineForJoin() async {
    ZeroTierRuntimeStatus status = await _zeroTierService.detectStatus();
    debugPrint(
      'ZeroTier join preflight: initial serviceState=${status.serviceState}, '
      'isNodeRunning=${status.isNodeRunning}, '
      'nodeId=${status.nodeId.isEmpty ? '-' : status.nodeId}, '
      'joinedNetworks=${status.joinedNetworks.length}, '
      'lastError=${status.lastError ?? '-'}',
    );
    if (status.isNodeReady) {
      return;
    }

    if (status.serviceState == 'starting') {
      status = await _waitForNodeReady();
      debugPrint(
        'ZeroTier join preflight: after waiting starting -> '
        'serviceState=${status.serviceState}, '
        'isNodeRunning=${status.isNodeRunning}, '
        'joinedNetworks=${status.joinedNetworks.length}, '
        'lastError=${status.lastError ?? '-'}',
      );
      if (status.isNodeReady) {
        return;
      }
    }

    if (status.serviceState == 'offline') {
      status = await _waitForOfflineNodeRecovery();
      debugPrint(
        'ZeroTier join preflight: after offline recovery wait -> '
        'serviceState=${status.serviceState}, '
        'isNodeRunning=${status.isNodeRunning}, '
        'joinedNetworks=${status.joinedNetworks.length}, '
        'lastError=${status.lastError ?? '-'}',
      );
      if (status.isNodeReady) {
        return;
      }
    }

    status = await _zeroTierService.startNode();
    debugPrint(
      'ZeroTier join preflight: after startNode -> '
      'serviceState=${status.serviceState}, '
      'isNodeRunning=${status.isNodeRunning}, '
      'nodeId=${status.nodeId.isEmpty ? '-' : status.nodeId}, '
      'joinedNetworks=${status.joinedNetworks.length}, '
      'lastError=${status.lastError ?? '-'}',
    );
    if (status.isNodeReady) {
      return;
    }

    status = await _waitForNodeReady();
    debugPrint(
      'ZeroTier join preflight: after waitForNodeReady -> '
      'serviceState=${status.serviceState}, '
      'isNodeRunning=${status.isNodeRunning}, '
      'nodeId=${status.nodeId.isEmpty ? '-' : status.nodeId}, '
      'joinedNetworks=${status.joinedNetworks.length}, '
      'lastError=${status.lastError ?? '-'}',
    );
    if (status.isNodeReady) {
      return;
    }

    throw RealtimeError(
      status.lastError?.trim().isNotEmpty == true
          ? status.lastError!
          : 'ZeroTier node is not online yet.',
    );
  }

  Future<ZeroTierRuntimeStatus> _waitForOfflineNodeRecovery() async {
    ZeroTierRuntimeStatus latest = state.runtimeStatus;
    for (int attempt = 0; attempt < 12; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      latest = await _zeroTierService.detectStatus();
      debugPrint(
        'ZeroTier offline recovery probe: attempt=$attempt, '
        'serviceState=${latest.serviceState}, '
        'isNodeRunning=${latest.isNodeRunning}, '
        'joinedNetworks=${latest.joinedNetworks.length}, '
        'lastError=${latest.lastError ?? '-'}',
      );
      if (latest.serviceState == 'running' ||
          latest.serviceState == 'prepared' ||
          latest.serviceState == 'starting' ||
          latest.lastError?.trim().isNotEmpty == true) {
        return latest;
      }
    }
    return latest;
  }

  bool _isNetworkFullyReadyForCommand(ZeroTierNetworkState network) {
    if (network.status != 'OK' || network.assignedAddresses.isEmpty) {
      return false;
    }
    if (!Platform.isWindows) {
      return network.localInterfaceReady || network.isConnected;
    }
    if (!network.systemIpBound) {
      return false;
    }
    if (network.routeExpected && !network.systemRouteBound) {
      return false;
    }
    return network.localMountState == 'ready';
  }

  Future<void> _waitForNetworkReady(String networkId) async {
    for (int attempt = 0; attempt < 60; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final ZeroTierRuntimeStatus status =
          await _zeroTierService.detectStatus();
      final ZeroTierNetworkState? network = status.joinedNetworks
          .where((ZeroTierNetworkState item) => item.networkId == networkId)
          .cast<ZeroTierNetworkState?>()
          .firstWhere(
            (ZeroTierNetworkState? item) => item != null,
            orElse: () => null,
          );
      if (network == null) {
        if (status.lastError?.trim().isNotEmpty == true &&
            !status.isNodeRunning &&
            status.serviceState == 'unavailable') {
          throw RealtimeError(status.lastError!);
        }
        continue;
      }
      if (network.status == 'ACCESS_DENIED') {
        throw const RealtimeError(
          'ZeroTier network authorization is still pending.',
        );
      }
      if (_isTerminalNetworkFailure(network.status)) {
        throw RealtimeError(
          status.lastError?.trim().isNotEmpty == true
              ? status.lastError!
              : 'ZeroTier network failed with status ${network.status}.',
        );
      }
      if (_isNetworkFullyReadyForCommand(network)) {
        return;
      }
    }
    throw const RealtimeError(
      'Timed out waiting for ZeroTier system mount readiness.',
    );
  }

  Future<void> _waitForNetworkLeft(String networkId) async {
    for (int attempt = 0; attempt < 30; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final ZeroTierRuntimeStatus status =
          await _zeroTierService.detectStatus();
      final bool networkStillPresent = status.joinedNetworks.any(
        (ZeroTierNetworkState item) => item.networkId == networkId,
      );
      if (!networkStillPresent) {
        return;
      }
      if (status.lastError?.trim().isNotEmpty == true &&
          status.serviceState == 'error') {
        throw RealtimeError(status.lastError!);
      }
    }
    throw const RealtimeError(
      'Timed out waiting for ZeroTier to leave the network.',
    );
  }

  Future<void> _waitForRuntimeRecoveryAfterLeave(String networkId) async {
    int stableSamples = 0;
    for (int attempt = 0; attempt < 24; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      ZeroTierRuntimeStatus status = await _zeroTierService.detectStatus();
      final bool hasRecoverableError =
          _isRecoverableRuntimeError(status.lastError);
      debugPrint(
        'ZeroTier leave recovery: attempt=$attempt, '
        'serviceState=${status.serviceState}, '
        'joinedNetworks=${status.joinedNetworks.length}, '
        'lastError=${status.lastError ?? '-'}, '
        'recoverableError=$hasRecoverableError',
      );

      final bool networkStillPresent = status.joinedNetworks.any(
        (ZeroTierNetworkState item) => item.networkId == networkId,
      );
      if (networkStillPresent) {
        stableSamples = 0;
        continue;
      }

      if ((status.serviceState == 'running' ||
              status.serviceState == 'prepared') &&
          ((status.lastError?.trim().isEmpty ?? true) || hasRecoverableError)) {
        stableSamples += 1;
        if (stableSamples >= 2) {
          return;
        }
        continue;
      }

      if (status.serviceState == 'offline') {
        if (attempt == 4) {
          debugPrint(
            'ZeroTier leave recovery: runtime still offline after leave; '
            'requesting in-process node restart on Windows.',
          );
          final ZeroTierRuntimeStatus restarted =
              await _zeroTierService.startNode();
          debugPrint(
            'ZeroTier leave recovery: restart request result '
            'serviceState=${restarted.serviceState}, '
            'isNodeRunning=${restarted.isNodeRunning}, '
            'joinedNetworks=${restarted.joinedNetworks.length}, '
            'lastError=${restarted.lastError ?? '-'}',
          );
        }
        if (attempt >= 10) {
          return;
        }
        continue;
      }

      stableSamples = 0;
      if (status.serviceState == 'starting' || status.serviceState == 'error') {
        if (attempt >= 6) {
          debugPrint(
            'ZeroTier leave recovery: runtime remains ${status.serviceState} '
            'after network left; continue observing because offline-state '
            'recovery should already have requested an in-process restart.',
          );
          return;
        }
      }
    }
    state = state.copyWith(
      lastError: 'ZeroTier 本地链路收口超时，已允许重新操作；如果再次异常，请继续查看最近事件。',
    );
  }

  bool get _shouldWaitInDartForNetworkJoin => !Platform.isWindows;

  bool get _shouldWaitInDartForNetworkLeave => !Platform.isWindows;

  Duration get _joinWaitTimeout => Platform.isWindows
      ? const Duration(minutes: 2)
      : const Duration(seconds: 30);

  bool get _allowMountDegradedJoin => Platform.isWindows;

  ZeroTierNetworkState? _findJoinedNetwork(
    ZeroTierRuntimeStatus status,
    String networkId,
  ) {
    final String normalized = networkId.trim().toLowerCase();
    for (final ZeroTierNetworkState network in status.joinedNetworks) {
      if (network.networkId.trim().toLowerCase() == normalized) {
        return network;
      }
    }
    return null;
  }

  bool _isTerminalNetworkFailure(String status) {
    switch (status) {
      case 'NOT_FOUND':
      case 'PORT_ERROR':
      case 'CLIENT_TOO_OLD':
        return true;
      default:
        return false;
    }
  }

  void _handleRuntimeEvent(ZeroTierRuntimeEvent event) {
    if (_shouldIgnoreRuntimeEvent(event)) {
      debugPrint(
        'Ignoring stale ZeroTier runtime event: '
        'type=${event.type.name}, networkId=${event.networkId ?? '-'}, '
        'payload=${event.payload}',
      );
      return;
    }
    _logJoinRuntimeCheckpoint(event);
    final List<ZeroTierRuntimeEvent> recentEvents = <ZeroTierRuntimeEvent>[
      event,
      ...state.recentRuntimeEvents
    ].take(8).toList(growable: false);
    final String? transitionNetworkId = state.transitioningNetworkId;
    final bool isMatchingTransitionNetwork = transitionNetworkId != null &&
        transitionNetworkId.trim().isNotEmpty &&
        event.networkId?.trim() == transitionNetworkId.trim();
    state = state.copyWith(
      lastRuntimeEvent: event,
      recentRuntimeEvents: recentEvents,
      networkTransitionLabel: switch (event.type) {
        ZeroTierRuntimeEventType.networkLeft when isMatchingTransitionNetwork =>
          '离网事件已完成，正在检查本地 ZeroTier 是否恢复稳定',
        ZeroTierRuntimeEventType.nodeOffline
            when state.isNetworkTransitioning =>
          'ZeroTier 节点暂时离线，正在等待本地 runtime 恢复',
        ZeroTierRuntimeEventType.nodeOnline when state.isNetworkTransitioning =>
          'ZeroTier 节点已恢复在线，正在确认可以继续操作',
        _ => state.networkTransitionLabel,
      },
      lastError: switch (event.type) {
        ZeroTierRuntimeEventType.error => event.message ?? state.lastError,
        ZeroTierRuntimeEventType.environmentReady ||
        ZeroTierRuntimeEventType.nodeStarted ||
        ZeroTierRuntimeEventType.nodeOnline ||
        ZeroTierRuntimeEventType.networkWaitingAuthorization ||
        ZeroTierRuntimeEventType.networkOnline ||
        ZeroTierRuntimeEventType.networkLeft ||
        ZeroTierRuntimeEventType.ipAssigned =>
          null,
        _ => state.lastError,
      },
      clearLastError: switch (event.type) {
        ZeroTierRuntimeEventType.environmentReady ||
        ZeroTierRuntimeEventType.nodeStarted ||
        ZeroTierRuntimeEventType.nodeOnline ||
        ZeroTierRuntimeEventType.networkWaitingAuthorization ||
        ZeroTierRuntimeEventType.networkOnline ||
        ZeroTierRuntimeEventType.networkLeft ||
        ZeroTierRuntimeEventType.ipAssigned =>
          true,
        _ => false,
      },
    );
    _applyRuntimeEventNetworkSnapshot(event);
    unawaited(_refreshRuntimeStatus());
    if (_shouldRefreshDashboard(event)) {
      unawaited(ref.read(networkingProvider.notifier).refresh());
    }
  }

  void _applyRuntimeEventNetworkSnapshot(ZeroTierRuntimeEvent event) {
    if (!Platform.isWindows) {
      return;
    }
    final String networkId = event.networkId?.trim() ?? '';
    if (networkId.isEmpty) {
      return;
    }
    switch (event.type) {
      case ZeroTierRuntimeEventType.networkOnline:
      case ZeroTierRuntimeEventType.ipAssigned:
        break;
      default:
        return;
    }

    final List<String> payloadAddresses = _readEventNetworkAddresses(event);
    final String payloadStatus =
        (event.payload['networkStatus']?.toString().trim().toUpperCase() ?? '');
    final bool connectedFromPayload =
        (event.payload['networkConnected'] as bool?) == true;

    final List<ZeroTierNetworkState> networks =
        List<ZeroTierNetworkState>.from(state.runtimeStatus.joinedNetworks);
    final int existingIndex = networks.indexWhere(
      (ZeroTierNetworkState item) =>
          item.networkId.trim().toLowerCase() == networkId.toLowerCase(),
    );
    final ZeroTierNetworkState previous = existingIndex >= 0
        ? networks[existingIndex]
        : ZeroTierNetworkState(
            networkId: networkId,
            networkName: '',
            status: 'OK',
            assignedAddresses: const <String>[],
            isAuthorized: true,
            isConnected: false,
            localInterfaceReady: false,
            matchedInterfaceName: '',
            matchedInterfaceUp: false,
            mountDriverKind: 'unknown',
            mountCandidateNames: const <String>[],
            routeExpected: false,
            expectedRouteCount: 0,
            systemIpBound: false,
            systemRouteBound: false,
            tapMediaStatus: 'unknown',
            tapDeviceInstanceId: '',
            tapNetCfgInstanceId: '',
            localMountState: 'unknown',
          );

    final List<String> mergedAddresses = payloadAddresses.isNotEmpty
        ? payloadAddresses
        : previous.assignedAddresses;
    final bool mergedConnected = mergedAddresses.isNotEmpty ||
        connectedFromPayload ||
        previous.isConnected;
    final bool mergedLocalInterfaceReady =
        (event.payload['localInterfaceReady'] as bool?) ??
            previous.localInterfaceReady;
    final String mergedMatchedInterfaceName =
        event.payload['matchedInterfaceName']?.toString() ??
            previous.matchedInterfaceName;
    final bool mergedMatchedInterfaceUp =
        (event.payload['matchedInterfaceUp'] as bool?) ??
            previous.matchedInterfaceUp;
    final String mergedMountDriverKind =
        event.payload['mountDriverKind']?.toString() ??
            previous.mountDriverKind;
    final List<String> payloadMountCandidateNames =
        _readEventStringList(event, 'mountCandidateNames');
    final List<String> mergedMountCandidateNames =
        payloadMountCandidateNames.isNotEmpty
            ? payloadMountCandidateNames
            : previous.mountCandidateNames;
    final bool mergedRouteExpected =
        (event.payload['routeExpected'] as bool?) ?? previous.routeExpected;
    final int mergedExpectedRouteCount =
        _readEventInt(event, 'expectedRouteCount') ??
            previous.expectedRouteCount;
    final bool mergedSystemIpBound =
        (event.payload['systemIpBound'] as bool?) ?? previous.systemIpBound;
    final bool mergedSystemRouteBound =
        (event.payload['systemRouteBound'] as bool?) ??
            previous.systemRouteBound;
    final String mergedTapMediaStatus =
        event.payload['tapMediaStatus']?.toString() ?? previous.tapMediaStatus;
    final String mergedTapDeviceInstanceId =
        event.payload['tapDeviceInstanceId']?.toString() ??
            previous.tapDeviceInstanceId;
    final String mergedTapNetCfgInstanceId =
        event.payload['tapNetCfgInstanceId']?.toString() ??
            previous.tapNetCfgInstanceId;
    final String mergedLocalMountState =
        event.payload['localMountState']?.toString() ??
            previous.localMountState;
    final String mergedStatus = payloadStatus.isNotEmpty ? payloadStatus : 'OK';

    final ZeroTierNetworkState patched = ZeroTierNetworkState(
      networkId: previous.networkId,
      networkName: previous.networkName,
      status: mergedStatus,
      assignedAddresses: mergedAddresses,
      isAuthorized: true,
      isConnected: mergedConnected,
      localInterfaceReady: mergedLocalInterfaceReady,
      matchedInterfaceName: mergedMatchedInterfaceName,
      matchedInterfaceUp: mergedMatchedInterfaceUp,
      mountDriverKind: mergedMountDriverKind,
      mountCandidateNames: mergedMountCandidateNames,
      routeExpected: mergedRouteExpected,
      expectedRouteCount: mergedExpectedRouteCount,
      systemIpBound: mergedSystemIpBound,
      systemRouteBound: mergedSystemRouteBound,
      tapMediaStatus: mergedTapMediaStatus,
      tapDeviceInstanceId: mergedTapDeviceInstanceId,
      tapNetCfgInstanceId: mergedTapNetCfgInstanceId,
      localMountState: mergedLocalMountState,
    );

    if (existingIndex >= 0) {
      networks[existingIndex] = patched;
    } else {
      networks.add(patched);
    }
    state = state.copyWith(
      runtimeStatus: state.runtimeStatus.copyWith(joinedNetworks: networks),
    );
  }

  List<String> _readEventNetworkAddresses(ZeroTierRuntimeEvent event) {
    final Object? raw =
        event.payload['networkAddresses'] ?? event.payload['assignedAddresses'];
    if (raw is! List) {
      return const <String>[];
    }
    return raw
        .map((Object? item) => item?.toString() ?? '')
        .where((String item) => item.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<AppConfig> _alignIdentityWithRuntimeNode(AppConfig config) async {
    final String configuredNodeId = config.zeroTierNodeId.trim();
    String runtimeNodeId = state.runtimeStatus.nodeId.trim();
    if (runtimeNodeId.isEmpty) {
      try {
        final ZeroTierRuntimeStatus status =
            await _zeroTierService.detectStatus();
        runtimeNodeId = status.nodeId.trim();
      } catch (_) {
        runtimeNodeId = '';
      }
    }
    if (runtimeNodeId.isEmpty || runtimeNodeId == configuredNodeId) {
      return config;
    }

    debugPrint(
      'ZeroTier identity drift detected: configNodeId=$configuredNodeId, '
      'runtimeNodeId=$runtimeNodeId. Rebootstrapping agent identity.',
    );
    await _initializeIdentity();
    return ref.read(appConfigProvider);
  }

  Future<bool> _recoverIdentityIfRequired(RealtimeError error) async {
    if (!_isBootstrapRequiredError(error)) {
      return false;
    }
    final AppConfig config = ref.read(appConfigProvider);
    await ref.read(appConfigProvider.notifier).save(
          config.copyWith(
            deviceId: '',
            agentToken: '',
          ),
        );
    await _initializeIdentity();
    final AppConfig refreshed = ref.read(appConfigProvider);
    return refreshed.deviceId.trim().isNotEmpty &&
        refreshed.agentToken.trim().isNotEmpty &&
        refreshed.zeroTierNodeId.trim().isNotEmpty;
  }

  bool _isBootstrapRequiredError(RealtimeError error) {
    if (error.requiresBootstrapRecovery) {
      return true;
    }
    final String message = error.message.trim().toLowerCase();
    return message.contains('does not exist') && message.contains('device ');
  }

  Future<void> _ensureManagedAddressAssignedForCommand(String networkId) async {
    final DateTime deadline = DateTime.now().add(
      Platform.isWindows
          ? const Duration(seconds: 20)
          : const Duration(seconds: 8),
    );
    ZeroTierNetworkState? lastSeen;

    while (DateTime.now().isBefore(deadline)) {
      final ZeroTierRuntimeStatus status =
          await _zeroTierService.detectStatus();
      final ZeroTierNetworkState? network = status.joinedNetworks
          .where((ZeroTierNetworkState item) => item.networkId == networkId)
          .cast<ZeroTierNetworkState?>()
          .firstWhere(
            (ZeroTierNetworkState? item) => item != null,
            orElse: () => null,
          );
      if (network != null) {
        lastSeen = network;
        if (_isNetworkFullyReadyForCommand(network)) {
          debugPrint(
            'Join command verification passed: networkId=$networkId, '
            'addresses=${network.assignedAddresses}, '
            'mountState=${network.localMountState}, '
            'systemIpBound=${network.systemIpBound}, '
            'systemRouteBound=${network.systemRouteBound}',
          );
          return;
        }
        if (network.status == 'ACCESS_DENIED') {
          throw const RealtimeError(
            'ZeroTier network authorization is still pending.',
          );
        }
        if (_isTerminalNetworkFailure(network.status)) {
          throw RealtimeError(
            'ZeroTier network failed with status ${network.status}.',
          );
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }

    throw RealtimeError(
      'Join command did not observe ZeroTier system mount readiness in time. '
      'networkId=$networkId, '
      'status=${lastSeen?.status ?? '-'}, '
      'mountState=${lastSeen?.localMountState ?? '-'}, '
      'systemIpBound=${lastSeen?.systemIpBound ?? false}, '
      'systemRouteBound=${lastSeen?.systemRouteBound ?? false}',
    );
  }

  List<String> _readEventStringList(ZeroTierRuntimeEvent event, String key) {
    final Object? raw = event.payload[key];
    if (raw is! List) {
      return const <String>[];
    }
    return raw
        .map((Object? item) => item?.toString() ?? '')
        .where((String item) => item.trim().isNotEmpty)
        .toList(growable: false);
  }

  int? _readEventInt(ZeroTierRuntimeEvent event, String key) {
    final Object? raw = event.payload[key];
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '');
  }

  bool _shouldIgnoreRuntimeEvent(ZeroTierRuntimeEvent event) {
    final String networkId = event.networkId?.trim() ?? '';
    if (networkId.isEmpty) {
      return false;
    }
    final int? generation = _readEventGeneration(event);
    if (generation == null || generation <= 0) {
      return false;
    }
    final int? latestGeneration = _latestNetworkEventGeneration[networkId];
    if (latestGeneration != null && generation < latestGeneration) {
      return true;
    }
    if (latestGeneration == null || generation > latestGeneration) {
      _latestNetworkEventGeneration[networkId] = generation;
    }
    return false;
  }

  int? _readEventGeneration(ZeroTierRuntimeEvent event) {
    final Object? raw = event.payload['generation'];
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '');
  }

  bool _shouldClearRecoveredRuntimeError(ZeroTierRuntimeStatus status) {
    if (!_isRecoverableRuntimeError(status.lastError)) {
      return false;
    }
    final bool hasActiveJoinedNetwork = status.joinedNetworks.any(
      (ZeroTierNetworkState item) =>
          item.localInterfaceReady ||
          item.isConnected ||
          item.assignedAddresses.isNotEmpty,
    );
    return status.isNodeReady && hasActiveJoinedNetwork;
  }

  bool _isRecoverableRuntimeError(String? error) {
    final String text = error?.trim().toLowerCase() ?? '';
    if (text.isEmpty) {
      return false;
    }
    return text.contains('timed out waiting for a managed address') ||
        text.contains(
            'timed out waiting for zerotier to mount the managed address');
  }

  void _logRuntimeStatusChange(
    ZeroTierRuntimeStatus previous,
    ZeroTierRuntimeStatus next,
  ) {
    if (previous == next) {
      return;
    }
    if (previous.serviceState == next.serviceState &&
        previous.isNodeRunning == next.isNodeRunning &&
        previous.nodeId == next.nodeId &&
        previous.lastError == next.lastError &&
        previous.joinedNetworks.length == next.joinedNetworks.length) {
      return;
    }
    debugPrint(
      'ZeroTier runtime status: '
      'serviceState=${next.serviceState}, '
      'isNodeRunning=${next.isNodeRunning}, '
      'nodeId=${next.nodeId.isEmpty ? '-' : next.nodeId}, '
      'joinedNetworks=${next.joinedNetworks.length}, '
      'networks=${_summarizeNetworks(next.joinedNetworks)}, '
      'lastError=${next.lastError ?? '-'}',
    );
  }

  String _summarizeNetworks(List<ZeroTierNetworkState> networks) {
    if (networks.isEmpty) {
      return '-';
    }
    return networks
        .map(
          (ZeroTierNetworkState item) => '${item.networkId}:${item.status}:'
              '${item.assignedAddresses.isEmpty ? "-" : item.assignedAddresses.join("|")}:'
              'connected=${item.isConnected}:'
              'localReady=${item.localInterfaceReady}:'
              'mount=${item.localMountState}',
        )
        .join(',');
  }

  bool _shouldRefreshDashboard(ZeroTierRuntimeEvent event) {
    switch (event.type) {
      case ZeroTierRuntimeEventType.nodeStarted:
      case ZeroTierRuntimeEventType.nodeOnline:
      case ZeroTierRuntimeEventType.nodeOffline:
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

  void _logJoinRuntimeCheckpoint(ZeroTierRuntimeEvent event) {
    final String activeType = state.activeNetworkActionType?.trim() ?? '';
    final String activeNetworkId =
        state.activeNetworkActionNetworkId?.trim().toLowerCase() ?? '';
    final String eventNetworkId = event.networkId?.trim().toLowerCase() ?? '';
    if (activeType != 'join' ||
        activeNetworkId.isEmpty ||
        eventNetworkId != activeNetworkId) {
      return;
    }
    switch (event.type) {
      case ZeroTierRuntimeEventType.networkJoining:
      case ZeroTierRuntimeEventType.networkWaitingAuthorization:
      case ZeroTierRuntimeEventType.networkOnline:
      case ZeroTierRuntimeEventType.ipAssigned:
      case ZeroTierRuntimeEventType.error:
        debugPrint(
          'ZT join checkpoint[2] runtime-event '
          'networkId=$eventNetworkId type=${event.type.name} '
          'message=${event.message ?? '-'}',
        );
        return;
      case ZeroTierRuntimeEventType.environmentReady:
      case ZeroTierRuntimeEventType.permissionRequired:
      case ZeroTierRuntimeEventType.nodeStarted:
      case ZeroTierRuntimeEventType.nodeOnline:
      case ZeroTierRuntimeEventType.nodeOffline:
      case ZeroTierRuntimeEventType.nodeStopped:
      case ZeroTierRuntimeEventType.networkLeft:
        return;
    }
  }

  void _logAwaitingAddressCheckpoint(ZeroTierRuntimeStatus status) {
    final String activeType = state.activeNetworkActionType?.trim() ?? '';
    final String activeNetworkId =
        state.activeNetworkActionNetworkId?.trim() ?? '';
    if (activeType != 'join' || activeNetworkId.isEmpty) {
      return;
    }
    final ZeroTierNetworkState? network = status.joinedNetworks
        .where((ZeroTierNetworkState item) => item.networkId == activeNetworkId)
        .cast<ZeroTierNetworkState?>()
        .firstWhere(
          (ZeroTierNetworkState? item) => item != null,
          orElse: () => null,
        );
    if (network == null || network.localMountState != 'awaiting_address') {
      _awaitingAddressLogAt.remove(activeNetworkId);
      return;
    }
    final DateTime now = DateTime.now();
    final DateTime? lastLoggedAt = _awaitingAddressLogAt[activeNetworkId];
    if (lastLoggedAt != null &&
        now.difference(lastLoggedAt) < const Duration(seconds: 3)) {
      return;
    }
    _awaitingAddressLogAt[activeNetworkId] = now;
    debugPrint(
      'ZT join checkpoint[3] awaiting-address '
      'networkId=$activeNetworkId serviceState=${status.serviceState} '
      'authorized=${network.isAuthorized} connected=${network.isConnected} '
      'status=${network.status} addresses=${network.assignedAddresses.length} '
      'mount=${network.localMountState}',
    );
  }
}

class _ObservedRelayState {
  const _ObservedRelayState({
    required this.connectionMode,
    required this.relayNodeId,
    required this.rttMs,
    required this.txBytes,
    required this.rxBytes,
  });

  final P2pConnectionMode connectionMode;
  final String? relayNodeId;
  final int? rttMs;
  final int? txBytes;
  final int? rxBytes;
}

String? _firstNonEmpty(String? first, String? second) {
  final String? normalizedFirst = first?.trim();
  if (normalizedFirst != null && normalizedFirst.isNotEmpty) {
    return normalizedFirst;
  }
  final String? normalizedSecond = second?.trim();
  if (normalizedSecond != null && normalizedSecond.isNotEmpty) {
    return normalizedSecond;
  }
  return null;
}

int? _firstObservedMetric(Iterable<int>? values) {
  if (values == null) {
    return null;
  }
  for (final int value in values) {
    return value;
  }
  return null;
}
