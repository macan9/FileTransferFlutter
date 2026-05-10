import 'dart:async';
import 'dart:io';

import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/config/services/app_config_repository.dart';
import 'package:file_transfer_flutter/core/models/managed_network.dart';
import 'package:file_transfer_flutter/core/models/network_agent_command.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/network_invite_code.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';
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
import 'package:file_transfer_flutter/features/networking/presentation/pages/networking_page.dart';
import 'package:file_transfer_flutter/features/networking/presentation/providers/networking_agent_provider.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const String _defaultNetworkId = '31756fbd65bfbf76';
const String _networkId = String.fromEnvironment(
  'ZT_TEST_NETWORK_ID',
  defaultValue: _defaultNetworkId,
);

void main() {
  testWidgets('dart orchestration UI join/leave flow', (
    WidgetTester tester,
  ) async {
    if (!Platform.isWindows) {
      return;
    }

    final _InMemoryAppConfigRepository configRepository =
        _InMemoryAppConfigRepository(
      const AppConfig(
        serverUrl: 'http://127.0.0.1:3000',
        deviceId: '',
        deviceName: 'Integration Test Device',
        devicePlatform: 'windows',
        zeroTierNodeId: '',
        agentToken: '',
        downloadDirectory: 'C:/Temp',
        autoOnline: false,
        minimizeToTrayOnClose: true,
      ),
    );
    final _FakeNetworkingService networkingService =
        _FakeNetworkingService(networkId: _networkId);
    final ZeroTierFacade zeroTierFacade = ZeroTierFacade(
      platformApi: _FakeZeroTierPlatformApi(networkId: _networkId),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appConfigRepositoryProvider.overrideWithValue(configRepository),
          initialAppConfigProvider
              .overrideWithValue(configRepository.loadSync()),
          networkingServiceProvider.overrideWithValue(networkingService),
          zeroTierLocalServiceProvider.overrideWithValue(zeroTierFacade),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: NetworkingPage(),
          ),
        ),
      ),
    );

    final Finder defaultOrbFinder = find.byKey(
      const Key('networking-default-action-orb'),
      skipOffstage: false,
    );
    await tester.dragUntilVisible(
      defaultOrbFinder,
      find.byType(Scrollable).first,
      const Offset(0, -300),
    );
    await _pumpUntilFinder(tester, defaultOrbFinder);
    await _pumpUntilText(tester, '开始组网');

    await tester.tap(
      find.text('开始组网', skipOffstage: false),
      warnIfMissed: false,
    );
    await tester.pump();
    await _pumpUntilText(tester, '10.147.20.42');
    expect(find.text('10.147.20.42'), findsWidgets);
    await _pumpUntilText(tester, '取消组网');

    await tester.tap(
      find.text('取消组网', skipOffstage: false),
      warnIfMissed: false,
    );
    await tester.pump();
    await _pumpUntilText(tester, '开始组网');

    final Finder privateTabFinder = find.byType(TabBar);
    await _scrollUntilFinder(
      tester,
      privateTabFinder,
      dragDelta: const Offset(0, 500),
    );
    await tester.ensureVisible(privateTabFinder);
    await tester.tap(find.byType(Tab).at(1), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 200));

    final Finder privateHostOrbFinder = find.byKey(
      const Key('networking-private-host-orb'),
      skipOffstage: false,
    );
    await _pumpUntilFinder(tester, privateHostOrbFinder);
    await tester.ensureVisible(privateHostOrbFinder);
    await tester.tap(privateHostOrbFinder, warnIfMissed: false);
    await tester.pump();
    await _pumpUntilText(tester, 'TEST-PRIVATE-001');
    expect(find.text('TEST-PRIVATE-001'), findsWidgets);
  });
}

Future<void> _pumpUntilText(
  WidgetTester tester,
  String text, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.text(text, skipOffstage: false).evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Timed out waiting for text: $text');
}

Future<void> _pumpUntilFinder(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Timed out waiting for widget: $finder');
}

Future<void> _scrollUntilFinder(
  WidgetTester tester,
  Finder finder, {
  required Offset dragDelta,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.dragFrom(const Offset(400, 140), dragDelta);
    await tester.pump(const Duration(milliseconds: 120));
  }
  fail('Timed out scrolling to widget: $finder');
}

class _InMemoryAppConfigRepository implements AppConfigRepository {
  _InMemoryAppConfigRepository(this._config);

  AppConfig _config;

  @override
  Future<AppConfig> load() async {
    return _config;
  }

  AppConfig loadSync() {
    return _config;
  }

  @override
  Future<AppConfig> save(AppConfig config) async {
    _config = config.normalized();
    return _config;
  }
}

class _FakeNetworkingService implements NetworkingService {
  _FakeNetworkingService({required String networkId})
      : _defaultNetwork = _buildDefaultNetwork(
          networkId: networkId,
          memberships: const <ManagedNetworkMembership>[],
        ),
        _managedNetworks = <ManagedNetwork>[
          _buildDefaultNetwork(
            networkId: networkId,
            memberships: const <ManagedNetworkMembership>[],
          ),
        ],
        _networkId = networkId;

  final String _networkId;
  ManagedNetwork _defaultNetwork;
  final List<ManagedNetwork> _managedNetworks;
  final List<_PendingCommand> _commands = <_PendingCommand>[];
  String _currentDeviceId = '';
  String _currentAgentToken = '';
  String _currentNodeId = '';
  int _sequence = 0;

  @override
  Future<bool> probeServerReachability() async {
    return true;
  }

  @override
  Future<NetworkDeviceIdentity> bootstrapDevice({
    required String deviceName,
    required String platform,
    required String zeroTierNodeId,
  }) async {
    _currentNodeId = zeroTierNodeId;
    _currentDeviceId = 'device-${++_sequence}';
    _currentAgentToken = 'token-${_sequence.toString().padLeft(4, '0')}';
    return NetworkDeviceIdentity(
      id: _currentDeviceId,
      deviceName: deviceName,
      platform: platform,
      zeroTierNodeId: zeroTierNodeId,
      status: 'online',
      hasAgentToken: true,
      agentTokenIssuedAt: DateTime.now(),
      agentToken: _currentAgentToken,
    );
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
    expect(deviceId, _currentDeviceId);
    expect(agentToken, _currentAgentToken);
    expect(zeroTierNodeId, _currentNodeId);
    expect(status, 'online');
  }

  @override
  Future<List<NetworkAgentCommand>> fetchAgentCommands({
    required String deviceId,
    required String agentToken,
    int limit = 20,
  }) async {
    expect(deviceId, _currentDeviceId);
    expect(agentToken, _currentAgentToken);
    return _commands
        .where(
          (_PendingCommand item) =>
              item.deviceId == deviceId && item.status == 'queued',
        )
        .take(limit)
        .map((_PendingCommand item) => item.commandWithStatus(item.status))
        .toList(growable: false);
  }

  @override
  Future<void> ackAgentCommand({
    required String commandId,
    required String deviceId,
    required String agentToken,
    required String status,
    String? errorMessage,
  }) async {
    expect(deviceId, _currentDeviceId);
    expect(agentToken, _currentAgentToken);
    final _PendingCommand? record =
        _commands.cast<_PendingCommand?>().firstWhere(
              (_PendingCommand? item) => item?.command.id == commandId,
              orElse: () => null,
            );
    if (record != null) {
      record.status = status;
      record.errorMessage = errorMessage;
    }
  }

  @override
  Future<ManagedNetwork> fetchDefaultNetwork() async {
    return _defaultNetwork;
  }

  @override
  Future<List<ManagedNetwork>> fetchManagedNetworks({
    String? deviceId,
    String? type,
  }) async {
    return List<ManagedNetwork>.unmodifiable(_managedNetworks);
  }

  @override
  Future<List<PairingSession>> fetchPairingSessions({String? deviceId}) async {
    return const <PairingSession>[];
  }

  @override
  Future<PairingSession> fetchPairingSession({required String sessionId}) {
    throw UnimplementedError();
  }

  @override
  Future<void> joinDefaultNetwork({required String deviceId}) async {
    expect(deviceId, _currentDeviceId);
    _defaultNetwork = _buildDefaultNetwork(
      networkId: _networkId,
      memberships: <ManagedNetworkMembership>[
        ManagedNetworkMembership(
          id: 'membership-${++_sequence}',
          deviceId: deviceId,
          role: 'member',
          status: 'authorized',
          zeroTierNodeId: _currentNodeId,
          zeroTierAssignedIp: '10.147.20.42',
          joinedAt: DateTime.now(),
          leftAt: null,
        ),
      ],
    );
    _managedNetworks[0] = _defaultNetwork;
    _enqueueCommand(
      type: 'join_zerotier_network',
      networkId: _networkId,
      deviceId: deviceId,
    );
  }

  @override
  Future<ManagedNetwork> leaveDefaultNetwork({required String deviceId}) async {
    expect(deviceId, _currentDeviceId);
    _defaultNetwork = _buildDefaultNetwork(
      networkId: _networkId,
      memberships: const <ManagedNetworkMembership>[],
    );
    _managedNetworks[0] = _defaultNetwork;
    _enqueueCommand(
      type: 'leave_zerotier_network',
      networkId: _networkId,
      deviceId: deviceId,
    );
    return _defaultNetwork;
  }

  @override
  Future<ManagedNetwork> leaveManagedNetwork({
    required String networkId,
    required String deviceId,
  }) async {
    return leaveDefaultNetwork(deviceId: deviceId);
  }

  @override
  Future<PairingSession> createPairingSession({
    required String initiatorDeviceId,
    required String targetDeviceId,
    required List<Map<String, dynamic>> allowedPorts,
    int expiresInMinutes = 60,
    String? note,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PairingSession> joinPairingSession({
    required String sessionId,
    required String deviceId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PairingSession> cancelPairingSession({
    required String sessionId,
    required String deviceId,
    String? reason,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PairingSession> closePairingSession({
    required String sessionId,
    required String deviceId,
    String? reason,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PrivateNetworkCreationResult> createPrivateNetwork({
    required String ownerDeviceId,
    required String name,
    String? description,
    int maxUses = 5,
    int expiresInMinutes = 1440,
  }) async {
    expect(ownerDeviceId, _currentDeviceId);
    final ManagedNetwork network = ManagedNetwork(
      id: 'private-network-${++_sequence}',
      name: name,
      type: 'private',
      status: 'active',
      description: description,
      zeroTierNetworkId: 'deadbeefcafebabe',
      zeroTierNetworkName: name,
      memberships: const <ManagedNetworkMembership>[],
      inviteCodes: const <ManagedNetworkInviteCode>[],
    );
    final NetworkInviteCode inviteCode = NetworkInviteCode(
      code: 'TEST-PRIVATE-001',
      status: 'active',
      managedNetworkId: network.id,
      maxUses: maxUses,
      useCount: 0,
    );
    _managedNetworks.add(network);
    return PrivateNetworkCreationResult(
      network: network,
      inviteCode: inviteCode,
    );
  }

  @override
  Future<NetworkInviteCode> createInviteCode({
    required String networkId,
    required String deviceId,
    int maxUses = 5,
    int expiresInMinutes = 1440,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> joinByInviteCode({
    required String code,
    required String deviceId,
  }) {
    throw UnimplementedError();
  }

  void _enqueueCommand({
    required String type,
    required String networkId,
    required String deviceId,
  }) {
    _commands.add(
      _PendingCommand(
        command: NetworkAgentCommand(
          id: 'cmd-${++_sequence}',
          type: type,
          status: 'queued',
          payload: <String, dynamic>{'networkId': networkId},
          deviceId: deviceId,
          createdAt: DateTime.now(),
        ),
        deviceId: deviceId,
      ),
    );
  }

  static ManagedNetwork _buildDefaultNetwork({
    required String networkId,
    required List<ManagedNetworkMembership> memberships,
  }) {
    return ManagedNetwork(
      id: 'default-network',
      name: 'Default Network',
      type: 'default',
      status: 'active',
      zeroTierNetworkId: networkId,
      zeroTierNetworkName: 'Integration Test Network',
      memberships: memberships,
      inviteCodes: const <ManagedNetworkInviteCode>[],
    );
  }
}

class _FakeZeroTierPlatformApi implements ZeroTierPlatformApi {
  _FakeZeroTierPlatformApi({required String networkId})
      : _networkId = networkId {
    _status = ZeroTierRuntimeStatus(
      nodeId: '',
      version: 'fake-1.0',
      serviceState: 'available',
      permissionState: const ZeroTierPermissionState(
        isGranted: true,
        requiresManualSetup: false,
        isFirewallSupported: true,
        summary: 'Fake runtime is always ready.',
      ),
      isNodeRunning: false,
      joinedNetworks: const <ZeroTierNetworkState>[],
      adapterBridge: const ZeroTierAdapterBridgeStatus.unknown(),
      updatedAt: DateTime.now(),
    );
  }

  final String _networkId;
  final StreamController<ZeroTierRuntimeEvent> _events =
      StreamController<ZeroTierRuntimeEvent>.broadcast();
  late ZeroTierRuntimeStatus _status;
  final String _nodeId = '2756bc6613';

  @override
  Future<ZeroTierRuntimeStatus> detectStatus() async {
    return _status.copyWith(updatedAt: DateTime.now());
  }

  @override
  Future<ZeroTierRuntimeStatus> prepareEnvironment() async {
    _emit(ZeroTierRuntimeEventType.environmentReady);
    _status = _status.copyWith(clearLastError: true, updatedAt: DateTime.now());
    return _status;
  }

  @override
  Future<ZeroTierRuntimeStatus> startNode() async {
    _status = _status.copyWith(
      nodeId: _nodeId,
      serviceState: 'running',
      isNodeRunning: true,
      updatedAt: DateTime.now(),
    );
    _emit(ZeroTierRuntimeEventType.nodeStarted, payload: <String, Object?>{
      'nodeId': _nodeId,
    });
    _emit(ZeroTierRuntimeEventType.nodeOnline, payload: <String, Object?>{
      'nodeId': _nodeId,
    });
    return _status;
  }

  @override
  Future<ZeroTierRuntimeStatus> stopNode() async {
    _status = _status.copyWith(
      serviceState: 'available',
      isNodeRunning: false,
      updatedAt: DateTime.now(),
    );
    _emit(ZeroTierRuntimeEventType.nodeStopped, payload: <String, Object?>{
      'nodeId': _nodeId,
    });
    return _status;
  }

  @override
  Future<void> joinNetworkAndWaitForIp(
    String networkId, {
    Duration timeout = const Duration(seconds: 30),
    bool allowMountDegraded = false,
  }) async {
    expect(networkId, _networkId);
    _emit(ZeroTierRuntimeEventType.networkJoining, networkId: networkId);
    final ZeroTierNetworkState network = ZeroTierNetworkState(
      networkId: networkId,
      networkName: 'Integration Test Network',
      status: 'OK',
      assignedAddresses: <String>['10.147.20.42'],
      isAuthorized: true,
      isConnected: true,
      localInterfaceReady: true,
      matchedInterfaceName: 'FakeZT',
      matchedInterfaceIfIndex: 7,
      matchedInterfaceUp: true,
      mountDriverKind: 'fake',
      mountCandidateNames: const <String>['FakeZT'],
      routeExpected: true,
      expectedRouteCount: 1,
      systemIpBound: true,
      systemRouteBound: true,
      tapMediaStatus: 'up',
      tapDeviceInstanceId: 'fake-device',
      tapNetCfgInstanceId: 'fake-netcfg',
      localMountState: 'ready',
    );
    _status = _status.copyWith(
      joinedNetworks: <ZeroTierNetworkState>[
        ..._status.joinedNetworks
            .where((ZeroTierNetworkState item) => item.networkId != networkId),
        network,
      ],
      updatedAt: DateTime.now(),
    );
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
  }

  @override
  Future<void> leaveNetwork(
    String networkId, {
    String source = 'manual',
  }) async {
    expect(networkId, _networkId);
    _status = _status.copyWith(
      joinedNetworks: _status.joinedNetworks
          .where((ZeroTierNetworkState item) => item.networkId != networkId)
          .toList(growable: false),
      updatedAt: DateTime.now(),
    );
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
    return _status.joinedNetworks;
  }

  @override
  Future<ZeroTierNetworkState?> getNetworkDetail(String networkId) async {
    for (final ZeroTierNetworkState network in _status.joinedNetworks) {
      if (network.networkId == networkId) {
        return network;
      }
    }
    return null;
  }

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
  Stream<ZeroTierRuntimeEvent> watchRuntimeEvents() {
    return _events.stream;
  }

  void _emit(
    ZeroTierRuntimeEventType type, {
    String? networkId,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    _events.add(
      ZeroTierRuntimeEvent(
        type: type,
        occurredAt: DateTime.now(),
        networkId: networkId,
        payload: payload,
      ),
    );
  }
}

class _PendingCommand {
  _PendingCommand({
    required this.command,
    required this.deviceId,
  });

  final NetworkAgentCommand command;
  final String deviceId;
  String status = 'queued';
  String? errorMessage;

  NetworkAgentCommand commandWithStatus(String status) {
    return NetworkAgentCommand(
      id: command.id,
      type: command.type,
      status: status,
      payload: command.payload,
      deviceId: command.deviceId,
      sessionId: command.sessionId,
      errorMessage: errorMessage,
      createdAt: command.createdAt,
      deliveredAt: command.deliveredAt,
      acknowledgedAt: command.acknowledgedAt,
    );
  }
}
