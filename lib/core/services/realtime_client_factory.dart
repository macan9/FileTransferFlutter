import 'package:file_transfer_flutter/core/config/models/app_config.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class RealtimeSocketFactory {
  const RealtimeSocketFactory();

  io.Socket create(AppConfig config) {
    final Uri signalingUri = config.serverUri.replace(
      path: _appendNamespacePath(config.serverUri.path, 'signaling'),
    );

    return io.io(
      signalingUri.toString(),
      io.OptionBuilder()
          .setTransports(<String>['websocket'])
          .disableAutoConnect()
          .setQuery(<String, String>{'deviceId': config.deviceId})
          .build(),
    );
  }

  String _appendNamespacePath(String basePath, String namespace) {
    final List<String> segments = <String>[
      ...basePath.split('/').where((String item) => item.isNotEmpty),
      namespace,
    ];
    return '/${segments.join('/')}';
  }
}

class RealtimePeerConnectionFactory {
  const RealtimePeerConnectionFactory();

  Future<RTCPeerConnection> create({
    List<Map<String, dynamic>>? iceServers,
  }) {
    return createPeerConnection(
      <String, dynamic>{
        'iceServers': iceServers ??
            const <Map<String, dynamic>>[
              <String, dynamic>{'urls': 'stun:stun.l.google.com:19302'},
            ],
      },
    );
  }
}
