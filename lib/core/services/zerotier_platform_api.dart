import 'dart:async';

import 'package:file_transfer_flutter/core/models/zerotier_network_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_event.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_status.dart';

abstract class ZeroTierPlatformApi {
  Future<ZeroTierRuntimeStatus> detectStatus();
  Future<ZeroTierRuntimeStatus> prepareEnvironment();
  Future<ZeroTierRuntimeStatus> startNode();
  Future<ZeroTierRuntimeStatus> stopNode();
  Future<void> joinNetworkAndWaitForIp(
    String networkId, {
    Duration timeout,
  });
  Future<void> leaveNetwork(
    String networkId, {
    String source,
  });
  Future<List<ZeroTierNetworkState>> listNetworks();
  Future<ZeroTierNetworkState?> getNetworkDetail(String networkId);
  Future<void> applyFirewallRules({
    required String ruleScopeId,
    required String peerZeroTierIp,
    required List<Map<String, dynamic>> allowedInboundPorts,
  });
  Future<void> removeFirewallRules({
    required String ruleScopeId,
  });
  Stream<ZeroTierRuntimeEvent> watchRuntimeEvents();
}
