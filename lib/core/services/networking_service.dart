import 'dart:convert';

import 'package:file_transfer_flutter/core/models/managed_network.dart';
import 'package:file_transfer_flutter/core/models/network_agent_command.dart';
import 'package:file_transfer_flutter/core/models/network_device_identity.dart';
import 'package:file_transfer_flutter/core/models/network_invite_code.dart';
import 'package:file_transfer_flutter/core/models/private_network_creation_result.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:http/http.dart' as http;

abstract class NetworkingService {
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
  Future<void> joinDefaultNetwork({required String deviceId});
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
  }) async {
    final http.Response response = await _client.patch(
      _buildUri('/networking/agent/devices/$deviceId/heartbeat'),
      headers: _authHeaders(agentToken),
      body: jsonEncode(<String, dynamic>{
        'status': status,
        'zeroTierNodeId': zeroTierNodeId,
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
    final http.Response response = await _client.get(
      _buildUri(
        '/networking/agent/devices/$deviceId/commands',
        queryParameters: <String, String>{'limit': '$limit'},
      ),
      headers: _tokenHeaders(agentToken),
    );
    final dynamic decoded = _decodeResponse(response);
    final List<Map<String, dynamic>> items = _extractMapList(decoded);
    return items.map(NetworkAgentCommand.fromJson).toList();
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
      throw RealtimeError(_extractErrorMessage(decoded, response.statusCode));
    }

    return decoded;
  }

  String _extractErrorMessage(dynamic decoded, int statusCode) {
    if (decoded is Map) {
      final dynamic message = decoded['message'] ?? decoded['error'];
      if (message is String && message.trim().isNotEmpty) {
        return message;
      }
    }
    return '请求失败，状态码 $statusCode';
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

  List<Map<String, dynamic>> _extractMapList(dynamic decoded) {
    if (decoded is List) {
      return decoded.whereType<Map>().map(_stringMap).toList();
    }

    if (decoded is Map) {
      final dynamic items =
          decoded['items'] ?? decoded['data'] ?? decoded['networks'];
      if (items is List) {
        return items.whereType<Map>().map(_stringMap).toList();
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
