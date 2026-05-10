import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/managed_network.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/pairing_session.dart';
import 'package:file_transfer_flutter/core/models/private_network_creation_result.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/services/networking_service.dart';
import 'package:file_transfer_flutter/features/networking/presentation/support/networking_debug_log.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final networkingProvider =
    AsyncNotifierProvider<NetworkingController, NetworkingDashboardState>(
  NetworkingController.new,
);

class NetworkingDashboardState extends Equatable {
  const NetworkingDashboardState({
    required this.defaultNetwork,
    required this.managedNetworks,
    required this.pairingSessions,
    required this.deviceIdentity,
    this.isSubmitting = false,
    this.activeAction,
  });

  const NetworkingDashboardState.initial()
      : defaultNetwork = null,
        managedNetworks = const <ManagedNetwork>[],
        pairingSessions = const <PairingSession>[],
        deviceIdentity = null,
        isSubmitting = false,
        activeAction = null;

  final ManagedNetwork? defaultNetwork;
  final List<ManagedNetwork> managedNetworks;
  final List<PairingSession> pairingSessions;
  final NetworkDeviceIdentity? deviceIdentity;
  final bool isSubmitting;
  final String? activeAction;

  NetworkingDashboardState copyWith({
    ManagedNetwork? defaultNetwork,
    bool clearDefaultNetwork = false,
    List<ManagedNetwork>? managedNetworks,
    List<PairingSession>? pairingSessions,
    NetworkDeviceIdentity? deviceIdentity,
    bool clearDeviceIdentity = false,
    bool? isSubmitting,
    String? activeAction,
    bool clearActiveAction = false,
  }) {
    return NetworkingDashboardState(
      defaultNetwork:
          clearDefaultNetwork ? null : defaultNetwork ?? this.defaultNetwork,
      managedNetworks: managedNetworks ?? this.managedNetworks,
      pairingSessions: pairingSessions ?? this.pairingSessions,
      deviceIdentity:
          clearDeviceIdentity ? null : deviceIdentity ?? this.deviceIdentity,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      activeAction:
          clearActiveAction ? null : activeAction ?? this.activeAction,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        defaultNetwork,
        managedNetworks,
        pairingSessions,
        deviceIdentity,
        isSubmitting,
        activeAction,
      ];
}

class NetworkingController extends AsyncNotifier<NetworkingDashboardState> {
  NetworkingService get _service => ref.read(networkingServiceProvider);

  @override
  Future<NetworkingDashboardState> build() async {
    return _load();
  }

  Future<void> refresh() async {
    state = const AsyncValue<NetworkingDashboardState>.loading()
        .copyWithPrevious(state);
    state = await AsyncValue.guard(_load);
  }

  Future<NetworkDeviceIdentity> bootstrapDevice({
    required String deviceName,
    required String platform,
    required String zeroTierNodeId,
  }) async {
    late final NetworkDeviceIdentity result;
    await _runAction(
      action: 'bootstrap-device',
      run: () async {
        result = await _service.bootstrapDevice(
          deviceName: deviceName,
          platform: platform,
          zeroTierNodeId: zeroTierNodeId,
        );
      },
    );
    return result;
  }

  Future<void> joinDefaultNetwork({required String deviceId}) async {
    await _runAction(
      action: 'join-default-network',
      run: () => _service.joinDefaultNetwork(deviceId: deviceId),
    );
  }

  Future<ManagedNetwork> leaveDefaultNetwork({required String deviceId}) async {
    late final ManagedNetwork result;
    await _runAction(
      action: 'leave-default-network',
      run: () async {
        result = await _service.leaveDefaultNetwork(deviceId: deviceId);
      },
    );
    return result;
  }

  Future<ManagedNetwork> leaveManagedNetwork({
    required String networkId,
    required String deviceId,
  }) async {
    late final ManagedNetwork result;
    await _runAction(
      action: 'leave-managed-network',
      run: () async {
        result = await _service.leaveManagedNetwork(
          networkId: networkId,
          deviceId: deviceId,
        );
      },
    );
    return result;
  }

  Future<PairingSession> createPairingSession({
    required String initiatorDeviceId,
    required String targetDeviceId,
    required List<Map<String, dynamic>> allowedPorts,
    int expiresInMinutes = 60,
    String? note,
  }) async {
    late final PairingSession result;
    await _runAction(
      action: 'create-pairing-session',
      run: () async {
        result = await _service.createPairingSession(
          initiatorDeviceId: initiatorDeviceId,
          targetDeviceId: targetDeviceId,
          allowedPorts: allowedPorts,
          expiresInMinutes: expiresInMinutes,
          note: note,
        );
      },
    );
    return result;
  }

  Future<PairingSession> joinPairingSession({
    required String sessionId,
    required String deviceId,
  }) async {
    late final PairingSession result;
    await _runAction(
      action: 'join-pairing-session',
      run: () async {
        result = await _service.joinPairingSession(
          sessionId: sessionId,
          deviceId: deviceId,
        );
      },
    );
    return result;
  }

  Future<PairingSession> cancelPairingSession({
    required String sessionId,
    required String deviceId,
    String? reason,
  }) async {
    late final PairingSession result;
    await _runAction(
      action: 'cancel-pairing-session',
      run: () async {
        result = await _service.cancelPairingSession(
          sessionId: sessionId,
          deviceId: deviceId,
          reason: reason,
        );
      },
    );
    return result;
  }

  Future<PairingSession> closePairingSession({
    required String sessionId,
    required String deviceId,
    String? reason,
  }) async {
    late final PairingSession result;
    await _runAction(
      action: 'close-pairing-session',
      run: () async {
        result = await _service.closePairingSession(
          sessionId: sessionId,
          deviceId: deviceId,
          reason: reason,
        );
      },
    );
    return result;
  }

  Future<PrivateNetworkCreationResult> createPrivateNetwork({
    required String ownerDeviceId,
    required String name,
    String? description,
    int maxUses = 5,
    int expiresInMinutes = 1440,
  }) async {
    late final PrivateNetworkCreationResult result;
    await _runAction(
      action: 'create-private-network',
      run: () async {
        result = await _service.createPrivateNetwork(
          ownerDeviceId: ownerDeviceId,
          name: name,
          description: description,
          maxUses: maxUses,
          expiresInMinutes: expiresInMinutes,
        );
      },
    );
    return result;
  }

  Future<void> joinByInviteCode({
    required String code,
    required String deviceId,
  }) async {
    await _runAction(
      action: 'join-by-invite-code',
      run: () => _service.joinByInviteCode(code: code, deviceId: deviceId),
    );
  }

  Future<NetworkingDashboardState> _load() async {
    final AppConfig config = ref.read(appConfigProvider);
    final ManagedNetwork defaultNetwork = await _service.fetchDefaultNetwork();
    final List<ManagedNetwork> managedNetworks =
        config.deviceId.trim().isEmpty ||
                config.agentToken.trim().isEmpty ||
                config.zeroTierNodeId.trim().isEmpty
            ? const <ManagedNetwork>[]
            : await _service.fetchManagedNetworks(deviceId: config.deviceId);
    final List<PairingSession> pairingSessions =
        config.deviceId.trim().isEmpty ||
                config.agentToken.trim().isEmpty ||
                config.zeroTierNodeId.trim().isEmpty
            ? const <PairingSession>[]
            : await _service.fetchPairingSessions(deviceId: config.deviceId);

    final NetworkDeviceIdentity? deviceIdentity =
        config.deviceId.trim().isEmpty ||
                config.agentToken.trim().isEmpty ||
                config.zeroTierNodeId.trim().isEmpty
            ? null
            : NetworkDeviceIdentity(
                id: config.deviceId,
                deviceName: config.deviceName,
                platform: config.devicePlatform,
                zeroTierNodeId: config.zeroTierNodeId,
                status: 'online',
                hasAgentToken: true,
                agentTokenIssuedAt: null,
                agentToken: config.agentToken,
              );

    return NetworkingDashboardState(
      defaultNetwork: defaultNetwork,
      managedNetworks: managedNetworks,
      pairingSessions: pairingSessions,
      deviceIdentity: deviceIdentity,
    );
  }

  Future<void> _runAction({
    required String action,
    required Future<void> Function() run,
  }) async {
    final NetworkingDashboardState current =
        state.valueOrNull ?? const NetworkingDashboardState.initial();
    state = AsyncValue.data(
      current.copyWith(
        isSubmitting: true,
        activeAction: action,
      ),
    );
    unawaited(
      NetworkingDebugLog.write(
        'dashboard_action_start',
        fields: <String, Object?>{
          'action': action,
          'defaultNetworkId': current.defaultNetwork?.zeroTierNetworkId,
          'isSubmitting': true,
        },
      ),
    );

    try {
      await run();
      final NetworkingDashboardState reloaded = await _load();
      state = AsyncValue.data(reloaded);
      unawaited(
        NetworkingDebugLog.write(
          'dashboard_action_success',
          fields: <String, Object?>{
            'action': action,
            'defaultNetworkId': reloaded.defaultNetwork?.zeroTierNetworkId,
            'isSubmitting': reloaded.isSubmitting,
          },
        ),
      );
    } on RealtimeError {
      state = AsyncValue.data(
        current.copyWith(
          isSubmitting: false,
          clearActiveAction: true,
        ),
      );
      unawaited(
        NetworkingDebugLog.write(
          'dashboard_action_error',
          fields: <String, Object?>{
            'action': action,
            'defaultNetworkId': current.defaultNetwork?.zeroTierNetworkId,
            'kind': 'RealtimeError',
          },
        ),
      );
      rethrow;
    } catch (error) {
      state = AsyncValue.data(
        current.copyWith(
          isSubmitting: false,
          clearActiveAction: true,
        ),
      );
      unawaited(
        NetworkingDebugLog.write(
          'dashboard_action_error',
          fields: <String, Object?>{
            'action': action,
            'defaultNetworkId': current.defaultNetwork?.zeroTierNetworkId,
            'kind': error.runtimeType.toString(),
            'message': error.toString(),
          },
        ),
      );
      throw RealtimeError('$error');
    }
  }
}
