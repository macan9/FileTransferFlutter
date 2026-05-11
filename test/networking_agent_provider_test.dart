import 'dart:async';

import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/config/services/app_config_repository.dart';
import 'package:file_transfer_flutter/core/models/managed_network.dart';
import 'package:file_transfer_flutter/core/models/network_agent_command.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/network_invite_code.dart';
import 'package:file_transfer_flutter/core/models/incoming_transfer_context.dart';
import 'package:file_transfer_flutter/core/models/outgoing_transfer_context.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';
import 'package:file_transfer_flutter/core/models/p2p_transport_state.dart';
import 'package:file_transfer_flutter/core/models/pairing_session.dart';
import 'package:file_transfer_flutter/core/models/private_network_creation_result.dart';
import 'package:file_transfer_flutter/core/models/zerotier_adapter_bridge_status.dart';
import 'package:file_transfer_flutter/core/models/zerotier_network_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_permission_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_event.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_status.dart';
import 'package:file_transfer_flutter/core/services/networking_service.dart';
import 'package:file_transfer_flutter/core/services/zerotier_facade.dart';
import 'package:file_transfer_flutter/core/services/zerotier_platform_api.dart';
import 'package:file_transfer_flutter/features/networking/presentation/providers/networking_agent_provider.dart';
import 'package:file_transfer_flutter/shared/providers/p2p_transport_providers.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'heartbeat forwards observed relay node id from transport state',
    () async {
      final _RecordingNetworkingService networkingService =
          _RecordingNetworkingService();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          appConfigRepositoryProvider.overrideWithValue(
            _StaticAppConfigRepository(_testConfig),
          ),
          initialAppConfigProvider.overrideWithValue(_testConfig),
          networkingServiceProvider.overrideWithValue(networkingService),
          zeroTierLocalServiceProvider.overrideWithValue(
            ZeroTierFacade(platformApi: const _FakeZeroTierPlatformApi()),
          ),
          p2pTransportStreamProvider.overrideWith(
            (Ref ref) => Stream<P2pTransportState>.value(
              const P2pTransportState(
                sessionTransports: <P2pSessionTransport>[
                  P2pSessionTransport(
                    sessionId: 'session-1',
                    peerDeviceId: 'peer-1',
                    sessionStatus: 'connected',
                    linkStatus: TransportLinkStatus.connected,
                    connectionMode: P2pConnectionMode.relay,
                    dataChannelOpen: true,
                    relayNodeId: 'relay-01',
                    selectedRelayAddress: '139.196.158.225',
                    selectedRelayUrl:
                        'turn:139.196.158.225:3478?transport=udp',
                    rttMs: 42,
                    txBytes: 1024,
                    rxBytes: 2048,
                  ),
                ],
                outgoingTransfers: <OutgoingTransferContext>[],
                incomingTransfers: <IncomingTransferContext>[],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(networkingAgentRuntimeProvider.notifier)
          .activate();

      expect(networkingService.lastHeartbeatRelayNodeId, 'relay-01');
      expect(networkingService.lastHeartbeatConnectionMode, P2pConnectionMode.relay);
      expect(networkingService.lastHeartbeatRttMs, 42);
      expect(networkingService.lastHeartbeatTxBytes, 1024);
      expect(networkingService.lastHeartbeatRxBytes, 2048);
      expect(
        container.read(networkingAgentRuntimeProvider).observedRelayNodeId,
        'relay-01',
      );
    },
  );
}

const AppConfig _testConfig = AppConfig(
  serverUrl: 'http://139.196.158.225:3100',
  deviceId: 'device-1',
  deviceName: 'Test Device',
  devicePlatform: 'windows',
  zeroTierNodeId: 'zt-node-1',
  agentToken: 'token-1',
  downloadDirectory: 'C:/Temp',
  autoOnline: true,
  minimizeToTrayOnClose: true,
);

class _StaticAppConfigRepository implements AppConfigRepository {
  const _StaticAppConfigRepository(this._config);

  final AppConfig _config;

  @override
  Future<AppConfig> load() async => _config;

  @override
  Future<AppConfig> save(AppConfig config) async => config;
}

class _RecordingNetworkingService implements NetworkingService {
  String? lastHeartbeatRelayNodeId;
  P2pConnectionMode? lastHeartbeatConnectionMode;
  int? lastHeartbeatRttMs;
  int? lastHeartbeatTxBytes;
  int? lastHeartbeatRxBytes;

  @override
  Future<bool> probeServerReachability() async => true;

  @override
  Future<NetworkDeviceIdentity> bootstrapDevice({
    required String deviceName,
    required String platform,
    required String zeroTierNodeId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> heartbeatAgent({
    required String deviceId,
    required String agentToken,
    required String zeroTierNodeId,
    String status = 'online',
    P2pConnectionMode? connectionMode,
    String? relayNodeId,
    int? rttMs,
    int? txBytes,
    int? rxBytes,
  }) async {
    lastHeartbeatRelayNodeId = relayNodeId;
    lastHeartbeatConnectionMode = connectionMode;
    lastHeartbeatRttMs = rttMs;
    lastHeartbeatTxBytes = txBytes;
    lastHeartbeatRxBytes = rxBytes;
  }

  @override
  Future<List<NetworkAgentCommand>> fetchAgentCommands({
    required String deviceId,
    required String agentToken,
    int limit = 20,
  }) async {
    return const <NetworkAgentCommand>[];
  }

  @override
  Future<void> ackAgentCommand({
    required String commandId,
    required String deviceId,
    required String agentToken,
    required String status,
    String? errorMessage,
  }) async {}

  @override
  Future<ManagedNetwork> fetchDefaultNetwork() async {
    throw UnimplementedError();
  }

  @override
  Future<List<ManagedNetwork>> fetchManagedNetworks({
    String? deviceId,
    String? type,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<PairingSession>> fetchPairingSessions({
    String? deviceId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<PairingSession> fetchPairingSession({
    required String sessionId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> joinDefaultNetwork({required String deviceId}) async {
    throw UnimplementedError();
  }

  @override
  Future<ManagedNetwork> leaveDefaultNetwork({required String deviceId}) async {
    throw UnimplementedError();
  }

  @override
  Future<ManagedNetwork> leaveManagedNetwork({
    required String networkId,
    required String deviceId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<PairingSession> createPairingSession({
    required String initiatorDeviceId,
    required String targetDeviceId,
    required List<Map<String, dynamic>> allowedPorts,
    int expiresInMinutes = 60,
    String? note,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<PairingSession> joinPairingSession({
    required String sessionId,
    required String deviceId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<PairingSession> cancelPairingSession({
    required String sessionId,
    required String deviceId,
    String? reason,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<PairingSession> closePairingSession({
    required String sessionId,
    required String deviceId,
    String? reason,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<PrivateNetworkCreationResult> createPrivateNetwork({
    required String ownerDeviceId,
    required String name,
    String? description,
    int maxUses = 0,
    int expiresInMinutes = 0,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<NetworkInviteCode> createInviteCode({
    required String networkId,
    required String deviceId,
    int maxUses = 0,
    int expiresInMinutes = 0,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> joinByInviteCode({
    required String code,
    required String deviceId,
  }) async {
    throw UnimplementedError();
  }
}

class _FakeZeroTierPlatformApi implements ZeroTierPlatformApi {
  const _FakeZeroTierPlatformApi();

  static final ZeroTierRuntimeStatus _status = ZeroTierRuntimeStatus(
    nodeId: 'zt-node-1',
    version: '1.14.2',
    serviceState: 'running',
    permissionState: const ZeroTierPermissionState(
      isGranted: true,
      requiresManualSetup: false,
      isFirewallSupported: true,
    ),
    isNodeRunning: true,
    joinedNetworks: const <ZeroTierNetworkState>[],
    adapterBridge: const ZeroTierAdapterBridgeStatus.unknown(),
    updatedAt: DateTime.parse('2026-05-11T00:00:00.000Z'),
    lastError: null,
  );

  @override
  Future<ZeroTierRuntimeStatus> detectStatus() async => _status;

  @override
  Future<ZeroTierRuntimeStatus> prepareEnvironment() async => _status;

  @override
  Future<ZeroTierRuntimeStatus> startNode() async => _status;

  @override
  Future<ZeroTierRuntimeStatus> stopNode() async => _status;

  @override
  Future<void> joinNetworkAndWaitForIp(
    String networkId, {
    Duration timeout = const Duration(seconds: 30),
    bool allowMountDegraded = false,
  }) async {}

  @override
  Future<void> leaveNetwork(
    String networkId, {
    String source = 'unknown',
  }) async {}

  @override
  Future<List<ZeroTierNetworkState>> listNetworks() async =>
      const <ZeroTierNetworkState>[];

  @override
  Future<ZeroTierNetworkState?> getNetworkDetail(String networkId) async => null;

  @override
  Future<ZeroTierNetworkState?> probeNetworkStateNow(String networkId) async =>
      null;

  @override
  Future<void> applyFirewallRules({
    required String ruleScopeId,
    required String peerZeroTierIp,
    required List<Map<String, dynamic>> allowedInboundPorts,
  }) async {}

  @override
  Future<void> removeFirewallRules({
    required String ruleScopeId,
  }) async {}

  @override
  Stream<ZeroTierRuntimeEvent> watchRuntimeEvents() =>
      const Stream<ZeroTierRuntimeEvent>.empty();
}
