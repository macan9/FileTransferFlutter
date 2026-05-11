import 'package:file_transfer_flutter/core/models/connection_request.dart';
import 'package:file_transfer_flutter/core/models/p2p_device.dart';
import 'package:file_transfer_flutter/core/models/p2p_presence_state.dart';
import 'package:file_transfer_flutter/core/models/p2p_session.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P2pPresenceState.devicesExcludingSelf', () {
    test('filters out the current device with normalized deviceId', () {
      const P2pDevice selfDevice = P2pDevice(
        deviceId: '  MC-COOP-WIN  ',
        deviceName: 'My Computer',
        platform: 'windows',
        status: P2pDeviceStatus.online,
      );
      const P2pDevice peerDevice = P2pDevice(
        deviceId: 'peer-device',
        deviceName: 'Peer Computer',
        platform: 'windows',
        status: P2pDeviceStatus.online,
      );
      const P2pPresenceState state = P2pPresenceState(
        status: SignalingPresenceStatus.online,
        devices: <P2pDevice>[selfDevice, peerDevice],
        connectionRequests: <ConnectionRequest>[],
        sessions: <P2pSession>[],
      );

      final List<P2pDevice> result = state.devicesExcludingSelf('mc-coop-win');

      expect(result, <P2pDevice>[peerDevice]);
    });
  });
}
