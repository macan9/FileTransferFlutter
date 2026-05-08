import 'dart:async';
import 'dart:convert';

import 'package:file_transfer_flutter/core/models/managed_network.dart';
import 'package:file_transfer_flutter/core/models/network_agent_command.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/network_invite_code.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';
import 'package:file_transfer_flutter/core/models/pairing_session.dart';
import 'package:file_transfer_flutter/core/models/private_network_creation_result.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:http/http.dart' as http;

abstract class NetworkingService {
  Future<bool> probeServerReachability();
  Future<NetworkDeviceIdentity> bootstrapDevice({
    required String deviceName,
    required String platform,
    required String zeroTierNodeId,
  });
  Future<void> heartbeatAgent({
    required String deviceId,
    required String agentToken,
    required String zeroTierNodeId,
    String status,
    P2pConnectionMode? connectionMode,
    String? relayNodeId,
    int? rttMs,
    int? txBytes,
    int? rxBytes,
  });
  Future<List<NetworkAgentCommand>> fetchAgentCommands({
    required String deviceId,
    required String agentToken,
    int limit,
  });
  Future<void> ackAgentCommand({
    required String commandId,
    required String deviceId,
    required String agentToken,
    required String status,
    String? errorMessage,
  });
  Future<ManagedNetwork> fetchDefaultNetwork();
  Future<List<ManagedNetwork>> fetchManagedNetworks({
    String? deviceId,
    String? type,
  });
  Future<List<PairingSession>> fetchPairingSessions({
    String? deviceId,
  });
  Future<PairingSession> fetchPairingSession({required String sessionId});
  Future<void> joinDefaultNetwork({required String deviceId});
  Future<ManagedNetwork> leaveDefaultNetwork({required String deviceId});
  Future<ManagedNetwork> leaveManagedNetwork({
    required String networkId,
    required String deviceId,
  });
  Future<PairingSession> createPairingSession({
    required String initiatorDeviceId,
    required String targetDeviceId,
    required List<Map<String, dynamic>> allowedPorts,
    int expiresInMinutes,
    String? note,
  });
  Future<PairingSession> joinPairingSession({
    required String sessionId,
    required String deviceId,
  });
  Future<PairingSession> cancelPairingSession({
    required String sessionId,
    required String deviceId,
    String? reason,
  });
  Future<PairingSession> closePairingSession({
    required String sessionId,
    required String deviceId,
    String? reason,
  });
  Future<PrivateNetworkCreationResult> createPrivateNetwork({
    required String ownerDeviceId,
    required String name,
    String? description,
    int maxUses,
    int expiresInMinutes,
  });
  Future<NetworkInviteCode> createInviteCode({
    required String networkId,
    required String deviceId,
    int maxUses,
    int expiresInMinutes,
  });
  Future<void> joinByInviteCode({
    required String code,
    required String deviceId,
  });
}

class HttpNetworkingService implements NetworkingService {
  HttpNetworkingService({
    required Uri baseUri,
    http.Client? client,
  })  : _baseUri = baseUri,
        _client = client ?? http.Client();

  final Uri _baseUri;
  final http.Client _client;
  static const Duration _agentCommandPollTimeout = Duration(seconds: 8);

  @override
  Future<bool> probeServerReachability() async {
    try {
      final http.Response response = await _client
          .get(
            _baseUri.replace(
              path: _baseUri.path.isEmpty ? '/' : _baseUri.path,
            ),
          )
          .timeout(const Duration(seconds: 3));
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<NetworkDeviceIdentity> bootstrapDevice({
    required String deviceName,
    required String platform,
    required String zeroTierNodeId,
  }) async {
    final http.Response response = await _client.post(
      _buildUri('/networking/bootstrap'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, dynamic>{
        'deviceName': deviceName,
        'platform': platform,
        'zeroTierNodeId': zeroTierNodeId,
      }),
    );
    final Map<String, dynamic>? map = _extractMap(_decodeResponse(response));
    if (map == null) {
      throw const RealtimeError('设备引导接口返回格式无效。');
    }
    return NetworkDeviceIdentity.fromJson(map);
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
    final http.Response response = await _client.patch(
      _buildUri('/networking/agent/devices/$deviceId/heartbeat'),
      headers: _authHeaders(agentToken),
      body: jsonEncode(<String, dynamic>{
        'status': status,
        'zeroTierNodeId': zeroTierNodeId,
        if (connectionMode != null) 'connectionMode': connectionMode.value,
        if (relayNodeId != null && relayNodeId.trim().isNotEmpty)
          'relayNodeId': relayNodeId.trim(),
        if (rttMs != null) 'rttMs': rttMs,
        if (txBytes != null) 'txBytes': txBytes,
        if (rxBytes != null) 'rxBytes': rxBytes,
      }),
    );
    _decodeResponse(response);
  }

  @override
  Future<List<NetworkAgentCommand>> fetchAgentCommands({
    required String deviceId,
    required String agentToken,
    int limit = 20,
  }) async {
    final Uri uri = _buildUri(
      '/networking/agent/devices/$deviceId/commands',
      queryParameters: <String, String>{'limit': '$limit'},
    );
    final Map<String, String> headers = <String, String>{
      ..._tokenHeaders(agentToken),
      'Connection': 'close',
    };

    final http.Response response = await _getWithSingleTransportRetry(
      uri,
      headers: headers,
      timeout: _agentCommandPollTimeout,
    );
    final dynamic decoded = _decodeResponse(response);
    final List<Map<String, dynamic>> items = _extractMapList(decoded);
    return items.map(NetworkAgentCommand.fromJson).toList();
  }

  Future<http.Response> _getWithSingleTransportRetry(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    try {
      return await _client.get(uri, headers: headers).timeout(timeout);
    } on http.ClientException {
      return _client.get(uri, headers: headers).timeout(timeout);
    } on TimeoutException {
      return _client.get(uri, headers: headers).timeout(timeout);
    }
  }

  @override
  Future<void> ackAgentCommand({
    required String commandId,
    required String deviceId,
    required String agentToken,
    required String status,
    String? errorMessage,
  }) async {
    final http.Response response = await _client.post(
      _buildUri('/networking/agent/commands/$commandId/ack'),
      headers: _authHeaders(agentToken),
      body: jsonEncode(<String, dynamic>{
        'deviceId': deviceId,
        'status': status,
        if (errorMessage != null && errorMessage.trim().isNotEmpty)
          'errorMessage': errorMessage.trim(),
      }),
    );
    _decodeResponse(response);
  }

  @override
  Future<ManagedNetwork> fetchDefaultNetwork() async {
    final http.Response response =
        await _client.get(_buildUri('/networking/default-network'));
    final dynamic decoded = _decodeResponse(response);
    return _extractManagedNetwork(decoded);
  }

  @override
  Future<List<ManagedNetwork>> fetchManagedNetworks({
    String? deviceId,
    String? type,
  }) async {
    final http.Response response = await _client.get(
      _buildUri(
        '/networking/managed-networks',
        queryParameters: <String, String>{
          if (deviceId != null && deviceId.trim().isNotEmpty)
            'deviceId': deviceId,
          if (type != null && type.trim().isNotEmpty) 'type': type,
        },
      ),
    );
    final dynamic decoded = _decodeResponse(response);
    final List<Map<String, dynamic>> items = _extractMapList(decoded);
    return items.map(ManagedNetwork.fromJson).toList();
  }

  @override
  Future<List<PairingSession>> fetchPairingSessions({
    String? deviceId,
  }) async {
    final http.Response response = await _client.get(
      _buildUri(
        '/networking/sessions',
        queryParameters: <String, String>{
          if (deviceId != null && deviceId.trim().isNotEmpty)
            'deviceId': deviceId.trim(),
        },
      ),
    );
    final dynamic decoded = _decodeResponse(response);
    final List<Map<String, dynamic>> items = _extractMapList(
      decoded,
      listKeys: const <String>['items', 'data', 'sessions'],
    );
    return items.map(PairingSession.fromJson).toList();
  }

  @override
  Future<PairingSession> fetchPairingSession(
      {required String sessionId}) async {
    final http.Response response = await _client.get(
      _buildUri('/networking/sessions/$sessionId'),
    );
    final dynamic decoded = _decodeResponse(response);
    return _extractPairingSession(decoded);
  }

  @override
  Future<void> joinDefaultNetwork({required String deviceId}) async {
    final http.Response response = await _client.post(
      _buildUri('/networking/default-network/join'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, dynamic>{
        'deviceId': deviceId,
      }),
    );
    _decodeResponse(response);
  }

  @override
  Future<ManagedNetwork> leaveDefaultNetwork({required String deviceId}) async {
    final http.Response response = await _client.post(
      _buildUri('/networking/default-network/leave'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, dynamic>{
        'deviceId': deviceId,
      }),
    );
    return _extractManagedNetwork(_decodeResponse(response));
  }

  @override
  Future<ManagedNetwork> leaveManagedNetwork({
    required String networkId,
    required String deviceId,
  }) async {
    final http.Response response = await _client.post(
      _buildUri('/networking/managed-networks/$networkId/leave'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, dynamic>{
        'deviceId': deviceId,
      }),
    );
    return _extractManagedNetwork(_decodeResponse(response));
  }

  @override
  Future<PairingSession> createPairingSession({
    required String initiatorDeviceId,
    required String targetDeviceId,
    required List<Map<String, dynamic>> allowedPorts,
    int expiresInMinutes = 60,
    String? note,
  }) async {
    final http.Response response = await _client.post(
      _buildUri('/networking/sessions'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, dynamic>{
        'initiatorDeviceId': initiatorDeviceId,
        'targetDeviceId': targetDeviceId,
        'expiresInMinutes': expiresInMinutes,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        'allowedPorts': allowedPorts,
      }),
    );
    final dynamic decoded = _decodeResponse(response);
    return _extractPairingSession(decoded);
  }

  @override
  Future<PairingSession> joinPairingSession({
    required String sessionId,
    required String deviceId,
  }) async {
    final http.Response response = await _client.post(
      _buildUri('/networking/sessions/$sessionId/join'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, dynamic>{
        'deviceId': deviceId,
      }),
    );
    final dynamic decoded = _decodeResponse(response);
    return _extractPairingSession(decoded);
  }

  @override
  Future<PairingSession> cancelPairingSession({
    required String sessionId,
    required String deviceId,
    String? reason,
  }) async {
    final http.Response response = await _client.post(
      _buildUri('/networking/sessions/$sessionId/cancel'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, dynamic>{
        'deviceId': deviceId,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      }),
    );
    final dynamic decoded = _decodeResponse(response);
    return _extractPairingSession(decoded);
  }

  @override
  Future<PairingSession> closePairingSession({
    required String sessionId,
    required String deviceId,
    String? reason,
  }) async {
    final http.Response response = await _client.post(
      _buildUri('/networking/sessions/$sessionId/close'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, dynamic>{
        'deviceId': deviceId,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      }),
    );
    final dynamic decoded = _decodeResponse(response);
    return _extractPairingSession(decoded);
  }

  @override
  Future<PrivateNetworkCreationResult> createPrivateNetwork({
    required String ownerDeviceId,
    required String name,
    String? description,
    int maxUses = 5,
    int expiresInMinutes = 1440,
  }) async {
    final http.Response networkResponse = await _client.post(
      _buildUri('/networking/managed-networks'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, dynamic>{
        'ownerDeviceId': ownerDeviceId,
        'name': name,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        'type': 'private',
      }),
    );
    final ManagedNetwork network =
        _extractManagedNetwork(_decodeResponse(networkResponse));

    final NetworkInviteCode inviteCode = await createInviteCode(
      networkId: network.id,
      deviceId: ownerDeviceId,
      maxUses: maxUses,
      expiresInMinutes: expiresInMinutes,
    );

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
  }) async {
    final http.Response response = await _client.post(
      _buildUri('/networking/managed-networks/$networkId/invite-codes'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, dynamic>{
        'deviceId': deviceId,
        'maxUses': maxUses,
        'expiresInMinutes': expiresInMinutes,
      }),
    );
    final dynamic decoded = _decodeResponse(response);
    return _extractInviteCode(decoded);
  }

  @override
  Future<void> joinByInviteCode({
    required String code,
    required String deviceId,
  }) async {
    final http.Response response = await _client.post(
      _buildUri('/networking/invite-codes/join'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, dynamic>{
        'code': code,
        'deviceId': deviceId,
      }),
    );
    _decodeResponse(response);
  }

  dynamic _decodeResponse(http.Response response) {
    final String body = utf8.decode(response.bodyBytes);
    dynamic decoded;
    if (body.trim().isNotEmpty) {
      decoded = jsonDecode(body);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _extractRealtimeError(decoded, response.statusCode);
    }

    return decoded;
  }

  RealtimeError _extractRealtimeError(dynamic decoded, int statusCode) {
    if (decoded is Map) {
      final dynamic message = decoded['message'] ?? decoded['error'];
      return RealtimeError(
        message is String && message.trim().isNotEmpty
            ? message
            : '请求失败，状态码 $statusCode',
        statusCode: statusCode,
        code: decoded['code']?.toString(),
        bootstrapRequired: decoded['bootstrapRequired'] == true,
        bootstrapEndpoint: decoded['bootstrapEndpoint']?.toString(),
        agentRegisterEndpoint: decoded['agentRegisterEndpoint']?.toString(),
      );
    }
    return RealtimeError(
      '请求失败，状态码 $statusCode',
      statusCode: statusCode,
    );
  }

  ManagedNetwork _extractManagedNetwork(dynamic decoded) {
    final Map<String, dynamic>? map = _extractMap(decoded);
    if (map == null) {
      throw const RealtimeError('内网穿透接口返回格式无效。');
    }

    final Map<String, dynamic>? nested = _extractMap(map['item']) ??
        _extractMap(map['data']) ??
        _extractMap(map['network']) ??
        _extractMap(map['managedNetwork']);

    return ManagedNetwork.fromJson(nested ?? map);
  }

  NetworkInviteCode _extractInviteCode(dynamic decoded) {
    final Map<String, dynamic>? map = _extractMap(decoded);
    if (map == null) {
      throw const RealtimeError('邀请码接口返回格式无效。');
    }

    final Map<String, dynamic>? nested = _extractMap(map['item']) ??
        _extractMap(map['data']) ??
        _extractMap(map['inviteCode']);

    return NetworkInviteCode.fromJson(nested ?? map);
  }

  PairingSession _extractPairingSession(dynamic decoded) {
    final Map<String, dynamic>? map = _extractMap(decoded);
    if (map == null) {
      throw const RealtimeError('Temporary session response is invalid.');
    }

    final Map<String, dynamic>? nested = _extractMap(map['item']) ??
        _extractMap(map['data']) ??
        _extractMap(map['session']) ??
        _extractMap(map['pairingSession']);

    return PairingSession.fromJson(nested ?? map);
  }

  List<Map<String, dynamic>> _extractMapList(
    dynamic decoded, {
    List<String> listKeys = const <String>['items', 'data', 'networks'],
  }) {
    if (decoded is List) {
      return decoded.whereType<Map>().map(_stringMap).toList();
    }

    if (decoded is Map) {
      for (final String key in listKeys) {
        final dynamic items = decoded[key];
        if (items is List) {
          return items.whereType<Map>().map(_stringMap).toList();
        }
      }
    }

    return const <Map<String, dynamic>>[];
  }

  Map<String, dynamic>? _extractMap(dynamic value) {
    if (value is Map) {
      return _stringMap(value);
    }
    return null;
  }

  Map<String, dynamic> _stringMap(Map<dynamic, dynamic> value) {
    return value.map(
      (dynamic key, dynamic item) => MapEntry(key.toString(), item),
    );
  }

  Uri _buildUri(
    String path, {
    Map<String, String>? queryParameters,
  }) {
    final String normalizedPath = _baseUri.path == '/' ? '' : _baseUri.path;
    return _baseUri.replace(
      path: '$normalizedPath$path',
      queryParameters: queryParameters == null || queryParameters.isEmpty
          ? null
          : queryParameters,
    );
  }

  static const Map<String, String> _jsonHeaders = <String, String>{
    'Content-Type': 'application/json',
  };

  Map<String, String> _tokenHeaders(String agentToken) {
    return <String, String>{
      'X-Device-Token': agentToken,
    };
  }

  Map<String, String> _authHeaders(String agentToken) {
    return <String, String>{
      ..._jsonHeaders,
      ..._tokenHeaders(agentToken),
    };
  }
}
