import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/managed_network.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/private_network_creation_result.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/services/networking_service.dart';
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
    required this.deviceIdentity,
    this.isSubmitting = false,
    this.activeAction,
  });

  const NetworkingDashboardState.initial()
      : defaultNetwork = null,
        managedNetworks = const <ManagedNetwork>[],
        deviceIdentity = null,
        isSubmitting = false,
        activeAction = null;

  final ManagedNetwork? defaultNetwork;
  final List<ManagedNetwork> managedNetworks;
  final NetworkDeviceIdentity? deviceIdentity;
  final bool isSubmitting;
  final String? activeAction;

  NetworkingDashboardState copyWith({
    ManagedNetwork? defaultNetwork,
    bool clearDefaultNetwork = false,
    List<ManagedNetwork>? managedNetworks,
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

    try {
      await run();
      final NetworkingDashboardState reloaded = await _load();
      state = AsyncValue.data(reloaded);
    } on RealtimeError {
      state = AsyncValue.data(
        current.copyWith(
          isSubmitting: false,
          clearActiveAction: true,
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
      throw RealtimeError('$error');
    }
  }
}
