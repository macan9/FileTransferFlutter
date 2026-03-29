import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/connection_request.dart';
import 'package:file_transfer_flutter/core/models/p2p_device.dart';
import 'package:file_transfer_flutter/core/models/p2p_presence_state.dart';
import 'package:file_transfer_flutter/core/models/p2p_session.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/services/realtime_client_factory.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:file_transfer_flutter/shared/providers/p2p_transport_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

final p2pPresenceProvider =
    NotifierProvider<P2pPresenceController, P2pPresenceState>(
  P2pPresenceController.new,
);

class P2pPresenceController extends Notifier<P2pPresenceState> {
  io.Socket? _socket;
  Timer? _heartbeatTimer;
  bool _manuallyOffline = false;

  @override
  P2pPresenceState build() {
    ref.onDispose(_disposeResources);
    return const P2pPresenceState.initial();
  }

  Future<void> goOnline() async {
    final AppConfig config = ref.read(appConfigProvider);
    if (state.isBusy) {
      return;
    }

    if (state.isOnline &&
        state.currentDevice?.deviceName == config.deviceName &&
        state.currentDevice?.deviceId == config.deviceId) {
      return;
    }

    _manuallyOffline = false;
    await _disconnectSocket(clearTransientData: false);

    state = state.copyWith(
      status: SignalingPresenceStatus.connecting,
      clearLastError: true,
      clearSocketId: true,
    );

    final RealtimeSocketFactory factory =
        ref.read(realtimeSocketFactoryProvider);
    final io.Socket socket = factory.create(config);
    _socket = socket;

    _bindSocket(socket, config);
    socket.connect();
  }

  Future<void> goOffline() async {
    _manuallyOffline = true;
    await _disconnectSocket(clearTransientData: true);
    await ref.read(p2pTransportServiceProvider).detach();
    state = state.copyWith(
      status: SignalingPresenceStatus.offline,
      devices: const <P2pDevice>[],
      connectionRequests: const <ConnectionRequest>[],
      sessions: const <P2pSession>[],
      clearCurrentDevice: true,
      clearSocketId: true,
      clearHeartbeatTimeoutMs: true,
      clearLastHeartbeatAt: true,
    );
  }

  Future<void> sendConnectionRequest({
    required String toDeviceId,
    String? message,
  }) async {
    final io.Socket socket = _requireOnlineSocket();
    socket.emitWithAck(
      'client:connection-request',
      <String, dynamic>{
        'toDeviceId': toDeviceId,
        'message': message ?? '请求建立直连通道',
      },
      ack: (dynamic response) {
        final String? error = _extractAckError(response);
        if (error != null) {
          _setLastError(error);
        }
      },
    );
  }

  Future<void> respondToConnectionRequest({
    required String requestId,
    required bool accepted,
  }) async {
    final io.Socket socket = _requireOnlineSocket();
    socket.emitWithAck(
      'client:connection-request:respond',
      <String, dynamic>{
        'requestId': requestId,
        'status': accepted ? 'accepted' : 'rejected',
      },
      ack: (dynamic response) {
        final String? error = _extractAckError(response);
        if (error != null) {
          _setLastError(error);
        }
      },
    );
  }

  Future<void> cancelConnectionRequest(String requestId) async {
    final io.Socket socket = _requireOnlineSocket();
    socket.emitWithAck(
      'client:connection-request:cancel',
      <String, dynamic>{'requestId': requestId},
      ack: (dynamic response) {
        final String? error = _extractAckError(response);
        if (error != null) {
          _setLastError(error);
        }
      },
    );
  }

  void _bindSocket(io.Socket socket, AppConfig config) {
    socket.onConnect((_) {
      state = state.copyWith(
        status: SignalingPresenceStatus.registering,
        socketId: socket.id,
        clearLastError: true,
      );
      _register(config, socket);
    });

    socket.onDisconnect((dynamic _) {
      _stopHeartbeat();
      if (_manuallyOffline) {
        return;
      }

      state = state.copyWith(
        status: SignalingPresenceStatus.offline,
        clearSocketId: true,
      );
    });

    socket.onConnectError((dynamic error) {
      _handleSocketError('连接信令服务失败: $error');
    });

    socket.onError((dynamic error) {
      _handleSocketError('信令服务异常: $error');
    });

    socket.on('server:force-disconnect', (dynamic payload) {
      final String message = _extractMessage(payload) ?? '当前设备被新的登录挤下线';
      _handleSocketError(message);
    });

    socket.on('server:welcome', (dynamic payload) {
      final Map<String, dynamic>? json = _asMap(payload);
      final int? heartbeatTimeoutMs =
          (json?['heartbeatTimeoutMs'] as num?)?.toInt();
      state = state.copyWith(
        socketId: json?['socketId']?.toString() ?? socket.id,
        heartbeatTimeoutMs: heartbeatTimeoutMs,
      );
    });

    socket.on('server:online-list', (dynamic payload) {
      final List<P2pDevice> devices = _extractDeviceList(payload);
      _replaceOnlineDevices(devices, selfDeviceId: config.deviceId);
    });

    socket.on('server:user-online', (dynamic payload) {
      final P2pDevice? device = _extractDevice(payload);
      if (device != null) {
        _upsertDevice(device, selfDeviceId: config.deviceId);
      }
    });

    socket.on('server:user-offline', (dynamic payload) {
      final P2pDevice? device = _extractDevice(payload);
      if (device != null) {
        _upsertDevice(device, selfDeviceId: config.deviceId);
      }
    });

    socket.on('server:user-stale', (dynamic payload) {
      final P2pDevice? device = _extractDevice(payload);
      if (device != null) {
        _upsertDevice(device, selfDeviceId: config.deviceId);
      }
    });

    socket.on('server:connection-request', (dynamic payload) {
      final ConnectionRequest? request = _extractConnectionRequest(payload);
      if (request != null) {
        _upsertConnectionRequest(request);
      }
    });

    socket.on('server:connection-request-updated', (dynamic payload) {
      final ConnectionRequest? request = _extractConnectionRequest(payload);
      if (request != null) {
        _upsertConnectionRequest(request);
      }
    });

    socket.on('server:session-updated', (dynamic payload) {
      final P2pSession? session = _extractSession(payload);
      if (session != null) {
        _upsertSession(session);
        unawaited(_syncTransportSessions());
      }
    });

    socket.on('server:transfer-updated', (dynamic payload) {
      final Map<String, dynamic>? json = _asMap(payload);
      if (json != null) {
        ref.read(p2pTransportServiceProvider).handleTransferUpdated(json);
      }
    });

    socket.on('server:offer', (dynamic payload) {
      final Map<String, dynamic>? json = _asMap(payload);
      if (json != null) {
        unawaited(
            ref.read(p2pTransportServiceProvider).handleRemoteOffer(json));
      }
    });

    socket.on('server:answer', (dynamic payload) {
      final Map<String, dynamic>? json = _asMap(payload);
      if (json != null) {
        unawaited(
            ref.read(p2pTransportServiceProvider).handleRemoteAnswer(json));
      }
    });

    socket.on('server:candidate', (dynamic payload) {
      final Map<String, dynamic>? json = _asMap(payload);
      if (json != null) {
        unawaited(
          ref.read(p2pTransportServiceProvider).handleRemoteCandidate(json),
        );
      }
    });
  }

  void _register(AppConfig config, io.Socket socket) {
    socket.emitWithAck(
      'client:register',
      <String, dynamic>{
        'deviceId': config.deviceId,
        'deviceName': config.deviceName,
        'platform': _platformName,
      },
      ack: (dynamic response) {
        final Map<String, dynamic>? json = _asMap(response);
        final bool success = json?['success'] == true;
        if (!success) {
          final String message = json?['message']?.toString() ?? '设备注册失败';
          _handleSocketError(message);
          return;
        }

        final P2pDevice? self = _extractDevice(json?['user']);
        final List<P2pDevice> onlineUsers = _extractDeviceList(
          json?['onlineUsers'] ?? json?['users'],
        );

        state = state.copyWith(
          status: SignalingPresenceStatus.online,
          currentDevice: self,
          devices: _mergeDevices(
            currentDevice: self,
            incoming: onlineUsers,
            selfDeviceId: config.deviceId,
          ),
          lastHeartbeatAt: DateTime.now(),
          clearLastError: true,
        );

        unawaited(
          ref.read(p2pTransportServiceProvider).attach(
                socket: socket,
                selfDeviceId: config.deviceId,
                downloadDirectory: config.downloadDirectory,
              ),
        );
        unawaited(_syncTransportSessions());
        _startHeartbeat(socket);
      },
    );
  }

  void _startHeartbeat(io.Socket socket) {
    _stopHeartbeat();
    final int timeoutMs = state.heartbeatTimeoutMs ?? 30000;
    final int intervalMs = math.max(5000, (timeoutMs * 0.5).round());
    _heartbeatTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      socket.emitWithAck(
        'client:heartbeat',
        <String, dynamic>{},
        ack: (dynamic response) {
          final Map<String, dynamic>? json = _asMap(response);
          if (json?['success'] != true) {
            return;
          }

          final P2pDevice? self = _extractDevice(json?['user']);
          state = state.copyWith(
            currentDevice: self ?? state.currentDevice,
            lastHeartbeatAt: DateTime.now(),
          );
        },
      );
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _disconnectSocket({required bool clearTransientData}) async {
    _stopHeartbeat();
    final io.Socket? socket = _socket;
    _socket = null;
    if (socket != null) {
      socket.dispose();
      socket.disconnect();
    }

    if (clearTransientData) {
      state = state.copyWith(
        devices: const <P2pDevice>[],
        connectionRequests: const <ConnectionRequest>[],
        sessions: const <P2pSession>[],
        clearCurrentDevice: true,
      );
    }
  }

  void _disposeResources() {
    _stopHeartbeat();
    final io.Socket? socket = _socket;
    _socket = null;
    socket?.dispose();
    socket?.disconnect();
  }

  io.Socket _requireOnlineSocket() {
    final io.Socket? socket = _socket;
    if (socket == null || !state.isOnline) {
      throw const RealtimeError('当前未连接到信令服务，请先上线');
    }
    return socket;
  }

  void _handleSocketError(String message) {
    _stopHeartbeat();
    state = state.copyWith(
      status: SignalingPresenceStatus.offline,
      lastError: message,
      clearSocketId: true,
    );
  }

  void _setLastError(String message) {
    state = state.copyWith(lastError: message);
  }

  Future<void> _syncTransportSessions() async {
    try {
      await ref.read(p2pTransportServiceProvider).syncSessions(state.sessions);
    } catch (error) {
      _setLastError('$error');
    }
  }

  void _replaceOnlineDevices(
    List<P2pDevice> incoming, {
    required String selfDeviceId,
  }) {
    state = state.copyWith(
      devices: _mergeDevices(
        currentDevice: state.currentDevice,
        incoming: incoming,
        selfDeviceId: selfDeviceId,
      ),
    );
  }

  void _upsertDevice(
    P2pDevice device, {
    required String selfDeviceId,
  }) {
    final Map<String, P2pDevice> byId = <String, P2pDevice>{
      for (final P2pDevice item in state.devices) item.deviceId: item,
    };
    byId[device.deviceId] = device;

    final P2pDevice? currentDevice =
        device.deviceId == selfDeviceId ? device : state.currentDevice;

    state = state.copyWith(
      currentDevice: currentDevice,
      devices: byId.values.toList()
        ..sort(
          (P2pDevice a, P2pDevice b) => a.deviceName.compareTo(b.deviceName),
        ),
    );
  }

  List<P2pDevice> _mergeDevices({
    required P2pDevice? currentDevice,
    required List<P2pDevice> incoming,
    required String selfDeviceId,
  }) {
    final Map<String, P2pDevice> byId = <String, P2pDevice>{
      for (final P2pDevice item in state.devices) item.deviceId: item,
    };

    for (final P2pDevice item in incoming) {
      byId[item.deviceId] = item;
    }

    if (currentDevice != null) {
      byId[currentDevice.deviceId] = currentDevice;
    } else {
      byId.remove(selfDeviceId);
    }

    return byId.values.toList()
      ..sort(
          (P2pDevice a, P2pDevice b) => a.deviceName.compareTo(b.deviceName));
  }

  void _upsertConnectionRequest(ConnectionRequest request) {
    final Map<String, ConnectionRequest> byId = <String, ConnectionRequest>{
      for (final ConnectionRequest item in state.connectionRequests)
        item.requestId: item,
    };
    byId[request.requestId] = request;
    state = state.copyWith(
      connectionRequests: byId.values.toList()
        ..sort(
          (ConnectionRequest a, ConnectionRequest b) =>
              b.createdAt.compareTo(a.createdAt),
        ),
    );
  }

  void _upsertSession(P2pSession session) {
    final Map<String, P2pSession> byId = <String, P2pSession>{
      for (final P2pSession item in state.sessions) item.sessionId: item,
    };
    byId[session.sessionId] = session;
    state = state.copyWith(
      sessions: byId.values.toList()
        ..sort(
            (P2pSession a, P2pSession b) => b.createdAt.compareTo(a.createdAt)),
    );
  }

  List<P2pDevice> _extractDeviceList(dynamic payload) {
    final dynamic rawList;
    if (payload is List) {
      rawList = payload;
    } else if (payload is Map) {
      rawList =
          payload['users'] ?? payload['onlineUsers'] ?? payload['devices'];
    } else {
      rawList = null;
    }

    if (rawList is! List) {
      return const <P2pDevice>[];
    }

    return rawList
        .whereType<Map>()
        .map(
          (Map item) => P2pDevice.fromJson(
            item.map(
              (dynamic key, dynamic value) => MapEntry(key.toString(), value),
            ),
          ),
        )
        .toList();
  }

  P2pDevice? _extractDevice(dynamic payload) {
    final Map<String, dynamic>? json = _unwrapPayload(
      payload,
      const <String>['user', 'device'],
    );
    if (json == null) {
      return null;
    }

    return P2pDevice.fromJson(json);
  }

  ConnectionRequest? _extractConnectionRequest(dynamic payload) {
    final Map<String, dynamic>? json = _unwrapPayload(
      payload,
      const <String>['request', 'connectionRequest'],
    );
    if (json == null) {
      return null;
    }

    return ConnectionRequest.fromJson(json);
  }

  P2pSession? _extractSession(dynamic payload) {
    final Map<String, dynamic>? json = _unwrapPayload(
      payload,
      const <String>['session'],
    );
    if (json == null) {
      return null;
    }

    return P2pSession.fromJson(json);
  }

  Map<String, dynamic>? _unwrapPayload(
    dynamic payload,
    List<String> nestedKeys,
  ) {
    if (payload is! Map) {
      return null;
    }

    final Map<String, dynamic> map = payload.map(
      (dynamic key, dynamic value) => MapEntry(key.toString(), value),
    );
    for (final String key in nestedKeys) {
      final dynamic nested = map[key];
      if (nested is Map) {
        return nested.map(
          (dynamic nestedKey, dynamic nestedValue) =>
              MapEntry(nestedKey.toString(), nestedValue),
        );
      }
    }
    return map;
  }

  Map<String, dynamic>? _asMap(dynamic payload) {
    if (payload is! Map) {
      return null;
    }

    return payload.map(
      (dynamic key, dynamic value) => MapEntry(key.toString(), value),
    );
  }

  String? _extractMessage(dynamic payload) {
    return _asMap(payload)?['message']?.toString();
  }

  String? _extractAckError(dynamic payload) {
    final Map<String, dynamic>? json = _asMap(payload);
    if (json == null) {
      return null;
    }

    if (json['success'] == true) {
      return null;
    }

    return json['message']?.toString() ?? json['error']?.toString();
  }

  String get _platformName {
    if (Platform.isWindows) {
      return 'windows';
    }
    if (Platform.isMacOS) {
      return 'macos';
    }
    if (Platform.isLinux) {
      return 'linux';
    }
    if (Platform.isAndroid) {
      return 'android';
    }
    if (Platform.isIOS) {
      return 'ios';
    }
    return 'unknown';
  }
}
