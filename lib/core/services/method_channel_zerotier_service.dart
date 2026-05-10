import 'dart:async';

import 'package:file_transfer_flutter/core/models/zerotier_adapter_bridge_status.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/models/zerotier_network_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_permission_state.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_event.dart';
import 'package:file_transfer_flutter/core/models/zerotier_runtime_status.dart';
import 'package:file_transfer_flutter/core/services/zerotier_platform_api.dart';
import 'package:flutter/services.dart';

class MethodChannelZeroTierService implements ZeroTierPlatformApi {
  MethodChannelZeroTierService({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(_methodChannelName),
        _eventChannel = eventChannel ?? const EventChannel(_eventChannelName);

  static const String _methodChannelName =
      'file_transfer_flutter/zerotier/methods';
  static const String _eventChannelName =
      'file_transfer_flutter/zerotier/events';

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  @override
  Future<ZeroTierRuntimeStatus> detectStatus() async {
    final Object? result = await _invoke('detectStatus');
    return _parseRuntimeStatus(result);
  }

  @override
  Future<ZeroTierRuntimeStatus> prepareEnvironment() async {
    final Object? result = await _invoke('prepareEnvironment');
    return _parseRuntimeStatus(result);
  }

  @override
  Future<ZeroTierRuntimeStatus> startNode() async {
    final Object? result = await _invoke('startNode');
    return _parseRuntimeStatus(result);
  }

  @override
  Future<ZeroTierRuntimeStatus> stopNode() async {
    final Object? result = await _invoke('stopNode');
    return _parseRuntimeStatus(result);
  }

  @override
  Future<void> joinNetworkAndWaitForIp(
    String networkId, {
    Duration timeout = const Duration(seconds: 30),
    bool allowMountDegraded = false,
  }) async {
    await _invoke(
      'joinNetworkAndWaitForIp',
      <String, Object?>{
        'networkId': networkId,
        'timeoutMs': timeout.inMilliseconds,
        'allowMountDegraded': allowMountDegraded,
      },
    );
  }

  @override
  Future<void> leaveNetwork(
    String networkId, {
    String source = 'unknown',
  }) async {
    await _invoke(
      'leaveNetwork',
      <String, Object?>{
        'networkId': networkId,
        'source': source,
      },
    );
  }

  @override
  Future<List<ZeroTierNetworkState>> listNetworks() async {
    final Object? result = await _invoke('listNetworks');
    final List<dynamic> raw =
        (result is List<dynamic>) ? result : const <dynamic>[];
    return raw
        .whereType<Object?>()
        .map(_parseNetworkState)
        .toList(growable: false);
  }

  @override
  Future<ZeroTierNetworkState?> getNetworkDetail(String networkId) async {
    final Object? result = await _invoke(
      'getNetworkDetail',
      <String, Object?>{
        'networkId': networkId,
      },
    );
    if (result == null) {
      return null;
    }
    return _parseNetworkState(result);
  }

  @override
  Future<void> applyFirewallRules({
    required String ruleScopeId,
    required String peerZeroTierIp,
    required List<Map<String, dynamic>> allowedInboundPorts,
  }) async {
    await _invoke(
      'applyFirewallRules',
      <String, Object?>{
        'ruleScopeId': ruleScopeId,
        'peerZeroTierIp': peerZeroTierIp,
        'allowedInboundPorts': allowedInboundPorts,
      },
    );
  }

  @override
  Future<void> removeFirewallRules({
    required String ruleScopeId,
  }) async {
    await _invoke(
      'removeFirewallRules',
      <String, Object?>{
        'ruleScopeId': ruleScopeId,
      },
    );
  }

  @override
  Stream<ZeroTierRuntimeEvent> watchRuntimeEvents() {
    return _eventChannel
        .receiveBroadcastStream()
        .map((Object? event) => _parseRuntimeEvent(event));
  }

  Future<Object?> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _methodChannel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (error) {
      throw RealtimeError(error.message ?? error.code);
    } on MissingPluginException {
      throw const RealtimeError(
        'ZeroTier Windows native plugin is not registered yet.',
      );
    }
  }

  ZeroTierRuntimeStatus _parseRuntimeStatus(Object? raw) {
    final Map<Object?, Object?> map = _asMap(raw);
    return ZeroTierRuntimeStatus(
      nodeId: _readString(map, 'nodeId'),
      version: _readNullableString(map, 'version'),
      serviceState: _readString(map, 'serviceState', fallback: 'unavailable'),
      permissionState: _parsePermissionState(map['permissionState']),
      isNodeRunning: _readBool(map, 'isNodeRunning'),
      joinedNetworks: _readList(map, 'joinedNetworks')
          .map(_parseNetworkState)
          .toList(growable: false),
      adapterBridge: _parseAdapterBridgeStatus(map['adapterBridge']),
      lastError: _readNullableString(map, 'lastError'),
      updatedAt: _parseDateTime(map['updatedAt']),
    );
  }

  ZeroTierAdapterBridgeStatus _parseAdapterBridgeStatus(Object? raw) {
    final Map<Object?, Object?> map = _asMap(raw);
    if (map.isEmpty) {
      return const ZeroTierAdapterBridgeStatus.unknown();
    }
    return ZeroTierAdapterBridgeStatus(
      initialized: _readBool(map, 'initialized'),
      hasVirtualAdapter: _readBool(map, 'hasVirtualAdapter'),
      hasMountCandidate: _readBool(map, 'hasMountCandidate'),
      hasExpectedNetworkIp: _readBool(map, 'hasExpectedNetworkIp'),
      hasExpectedRoute: _readBool(map, 'hasExpectedRoute'),
      virtualAdapterNames: _readList(map, 'virtualAdapterNames')
          .map((Object? item) => item?.toString() ?? '')
          .where((String item) => item.trim().isNotEmpty)
          .toList(growable: false),
      matchedAdapterNames: _readList(map, 'matchedAdapterNames')
          .map((Object? item) => item?.toString() ?? '')
          .where((String item) => item.trim().isNotEmpty)
          .toList(growable: false),
      mountCandidateNames: _readList(map, 'mountCandidateNames')
          .map((Object? item) => item?.toString() ?? '')
          .where((String item) => item.trim().isNotEmpty)
          .toList(growable: false),
      detectedIpv4Addresses: _readList(map, 'detectedIpv4Addresses')
          .map((Object? item) => item?.toString() ?? '')
          .where((String item) => item.trim().isNotEmpty)
          .toList(growable: false),
      expectedIpv4Addresses: _readList(map, 'expectedIpv4Addresses')
          .map((Object? item) => item?.toString() ?? '')
          .where((String item) => item.trim().isNotEmpty)
          .toList(growable: false),
      adapters: _readList(map, 'adapters')
          .map(_parseAdapterRecord)
          .toList(growable: false),
      summary: _readNullableString(map, 'summary'),
    );
  }

  ZeroTierAdapterRecord _parseAdapterRecord(Object? raw) {
    final Map<Object?, Object?> map = _asMap(raw);
    return ZeroTierAdapterRecord(
      adapterName: _readString(map, 'adapterName'),
      friendlyName: _readString(map, 'friendlyName'),
      description: _readString(map, 'description'),
      ifIndex: _readInt(map, 'ifIndex'),
      luid: _readInt(map, 'luid'),
      operStatus: _readString(map, 'operStatus', fallback: 'unknown'),
      isUp: _readBool(map, 'isUp'),
      isVirtual: _readBool(map, 'isVirtual'),
      isMountCandidate: _readBool(map, 'isMountCandidate'),
      matchesExpectedIp: _readBool(map, 'matchesExpectedIp'),
      hasExpectedRoute: _readBool(map, 'hasExpectedRoute'),
      driverKind: _readString(map, 'driverKind', fallback: 'unknown'),
      mediaStatus: _readString(map, 'mediaStatus', fallback: 'unknown'),
      tapDeviceInstanceId: _readString(map, 'tapDeviceInstanceId'),
      tapNetCfgInstanceId: _readString(map, 'tapNetCfgInstanceId'),
      ipv4Addresses: _readList(map, 'ipv4Addresses')
          .map((Object? item) => item?.toString() ?? '')
          .where((String item) => item.trim().isNotEmpty)
          .toList(growable: false),
    );
  }

  ZeroTierPermissionState _parsePermissionState(Object? raw) {
    final Map<Object?, Object?> map = _asMap(raw);
    if (map.isEmpty) {
      return const ZeroTierPermissionState.unknown();
    }
    return ZeroTierPermissionState(
      isGranted: _readBool(map, 'isGranted', fallback: true),
      requiresManualSetup:
          _readBool(map, 'requiresManualSetup', fallback: false),
      isFirewallSupported:
          _readBool(map, 'isFirewallSupported', fallback: false),
      summary: _readNullableString(map, 'summary'),
    );
  }

  ZeroTierNetworkState _parseNetworkState(Object? raw) {
    final Map<Object?, Object?> map = _asMap(raw);
    return ZeroTierNetworkState(
      networkId: _readString(map, 'networkId'),
      networkName: _readString(map, 'networkName'),
      status: _readString(map, 'status', fallback: 'UNKNOWN'),
      assignedAddresses: _readList(map, 'assignedAddresses')
          .map((Object? item) => item?.toString() ?? '')
          .where((String item) => item.trim().isNotEmpty)
          .toList(growable: false),
      isAuthorized: _readBool(map, 'isAuthorized'),
      isConnected: _readBool(map, 'isConnected'),
      localInterfaceReady: _readBool(map, 'localInterfaceReady'),
      matchedInterfaceName: _readString(map, 'matchedInterfaceName'),
      matchedInterfaceIfIndex: _readInt(map, 'matchedInterfaceIfIndex'),
      matchedInterfaceUp: _readBool(map, 'matchedInterfaceUp'),
      mountDriverKind: _readString(map, 'mountDriverKind', fallback: 'unknown'),
      mountCandidateNames: _readList(map, 'mountCandidateNames')
          .map((Object? item) => item?.toString() ?? '')
          .where((String item) => item.trim().isNotEmpty)
          .toList(growable: false),
      routeExpected: _readBool(map, 'routeExpected'),
      expectedRouteCount: _readInt(map, 'expectedRouteCount'),
      systemIpBound: _readBool(map, 'systemIpBound'),
      systemRouteBound: _readBool(map, 'systemRouteBound'),
      tapMediaStatus: _readString(map, 'tapMediaStatus', fallback: 'unknown'),
      tapDeviceInstanceId: _readString(map, 'tapDeviceInstanceId'),
      tapNetCfgInstanceId: _readString(map, 'tapNetCfgInstanceId'),
      localMountState: _readString(map, 'localMountState', fallback: 'unknown'),
    );
  }

  ZeroTierRuntimeEvent _parseRuntimeEvent(Object? raw) {
    final Map<Object?, Object?> map = _asMap(raw);
    final String typeName = _readString(map, 'type', fallback: 'error');
    return ZeroTierRuntimeEvent(
      type: ZeroTierRuntimeEventType.values.firstWhere(
        (ZeroTierRuntimeEventType item) => item.name == typeName,
        orElse: () => ZeroTierRuntimeEventType.error,
      ),
      occurredAt: _parseDateTime(map['occurredAt']) ?? DateTime.now(),
      message: _readNullableString(map, 'message'),
      networkId: _readNullableString(map, 'networkId'),
      payload: _asMap(map['payload']).map(
        (Object? key, Object? value) => MapEntry(
          key?.toString() ?? '',
          value,
        ),
      ),
    );
  }

  Map<Object?, Object?> _asMap(Object? raw) {
    if (raw is Map<Object?, Object?>) {
      return raw;
    }
    if (raw is Map) {
      return raw.cast<Object?, Object?>();
    }
    return const <Object?, Object?>{};
  }

  List<Object?> _readList(Map<Object?, Object?> map, String key) {
    final Object? value = map[key];
    if (value is List) {
      return value.cast<Object?>();
    }
    return const <Object?>[];
  }

  String _readString(
    Map<Object?, Object?> map,
    String key, {
    String fallback = '',
  }) {
    final Object? value = map[key];
    final String text = value?.toString() ?? '';
    return text.isEmpty ? fallback : text;
  }

  String? _readNullableString(Map<Object?, Object?> map, String key) {
    final Object? value = map[key];
    if (value == null) {
      return null;
    }
    final String text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  bool _readBool(
    Map<Object?, Object?> map,
    String key, {
    bool fallback = false,
  }) {
    final Object? value = map[key];
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final String text = value?.toString().toLowerCase() ?? '';
    if (text == 'true' || text == '1') {
      return true;
    }
    if (text == 'false' || text == '0') {
      return false;
    }
    return fallback;
  }

  int _readInt(Map<Object?, Object?> map, String key, {int fallback = 0}) {
    final Object? value = map[key];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  DateTime? _parseDateTime(Object? value) {
    if (value == null) {
      return null;
    }
    return DateTime.tryParse(value.toString());
  }
}
