import 'dart:async';

import 'package:file_transfer_flutter/core/models/zerotier_network_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_event.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_status.dart';
import 'package:file_transfer_flutter/core/services/zerotier_platform_api.dart';

class ZeroTierFacade implements ZeroTierPlatformApi {
  const ZeroTierFacade({
    required ZeroTierPlatformApi platformApi,
  }) : _platformApi = platformApi;

  final ZeroTierPlatformApi _platformApi;

  @override
  Future<ZeroTierRuntimeStatus> detectStatus() => _platformApi.detectStatus();

  @override
  Future<ZeroTierRuntimeStatus> prepareEnvironment() =>
      _platformApi.prepareEnvironment();

  @override
  Future<ZeroTierRuntimeStatus> startNode() => _platformApi.startNode();

  @override
  Future<ZeroTierRuntimeStatus> stopNode() => _platformApi.stopNode();

  @override
  Future<void> joinNetworkAndWaitForIp(
    String networkId, {
    Duration timeout = const Duration(seconds: 30),
    bool allowMountDegraded = false,
  }) {
    return _platformApi.joinNetworkAndWaitForIp(
      networkId,
      timeout: timeout,
      allowMountDegraded: allowMountDegraded,
    );
  }

  @override
  Future<void> leaveNetwork(
    String networkId, {
    String source = 'unknown',
  }) =>
      _platformApi.leaveNetwork(
        networkId,
        source: source,
      );

  @override
  Future<List<ZeroTierNetworkState>> listNetworks() =>
      _platformApi.listNetworks();

  @override
  Future<ZeroTierNetworkState?> getNetworkDetail(String networkId) =>
      _platformApi.getNetworkDetail(networkId);

  @override
  Future<void> applyFirewallRules({
    required String ruleScopeId,
    required String peerZeroTierIp,
    required List<Map<String, dynamic>> allowedInboundPorts,
  }) {
    return _platformApi.applyFirewallRules(
      ruleScopeId: ruleScopeId,
      peerZeroTierIp: peerZeroTierIp,
      allowedInboundPorts: allowedInboundPorts,
    );
  }

  @override
  Future<void> removeFirewallRules({
    required String ruleScopeId,
  }) {
    return _platformApi.removeFirewallRules(ruleScopeId: ruleScopeId);
  }

  @override
  Stream<ZeroTierRuntimeEvent> watchRuntimeEvents() =>
      _platformApi.watchRuntimeEvents();
}
