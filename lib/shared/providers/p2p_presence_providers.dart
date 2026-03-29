import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:file_transfer_flutter/core/models/p2p_device.dart';
import 'package:file_transfer_flutter/core/models/p2p_presence_state.dart';
import 'package:file_transfer_flutter/core/services/realtime_client_factory.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
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
    await _disconnectSocket(clearDevices: false);

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
    await _disconnectSocket(clearDevices: true);
    state = state.copyWith(
      status: SignalingPresenceStatus.offline,
      devices: const <P2pDevice>[],
      clearCurrentDevice: true,
      clearSocketId: true,
      clearHeartbeatTimeoutMs: true,
      clearLastHeartbeatAt: true,
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

  Future<void> _disconnectSocket({required bool clearDevices}) async {
    _stopHeartbeat();
    final io.Socket? socket = _socket;
    _socket = null;
    if (socket != null) {
      socket.dispose();
      socket.disconnect();
    }

    if (clearDevices) {
      state = state.copyWith(
        devices: const <P2pDevice>[],
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

  void _handleSocketError(String message) {
    _stopHeartbeat();
    state = state.copyWith(
      status: SignalingPresenceStatus.offline,
      lastError: message,
      clearSocketId: true,
    );
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
            (P2pDevice a, P2pDevice b) => a.deviceName.compareTo(b.deviceName)),
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
    final dynamic raw;
    if (payload is Map && payload.containsKey('user')) {
      raw = payload['user'];
    } else {
      raw = payload;
    }

    if (raw is! Map) {
      return null;
    }

    return P2pDevice.fromJson(
      raw.map(
        (dynamic key, dynamic value) => MapEntry(key.toString(), value),
      ),
    );
  }

  Map<String, dynamic>? _asMap(dynamic payload) {
    if (payload is! Map) {
      return null;
    }

    return payload.map(
      (dynamic key, dynamic value) => MapEntry(key.toString(), value),
    );
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
