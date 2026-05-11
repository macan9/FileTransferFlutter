import 'package:file_transfer_flutter/core/services/p2p_transport_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P2pTransportService signaling payload helpers', () {
    test('prefers remote from.deviceId when targetDeviceId is self', () {
      final String? peerDeviceId =
          P2pTransportService.resolveSignalPeerDeviceId(
        <String, dynamic>{
          'targetDeviceId': 'device-b',
          'from': <String, dynamic>{'deviceId': 'device-a'},
        },
        selfDeviceId: 'device-b',
      );

      expect(peerDeviceId, 'device-a');
    });

    test('falls back to targetDeviceId when it is the only remote id', () {
      final String? peerDeviceId =
          P2pTransportService.resolveSignalPeerDeviceId(
        <String, dynamic>{
          'targetDeviceId': 'device-a',
        },
        selfDeviceId: 'device-b',
      );

      expect(peerDeviceId, 'device-a');
    });

    test('extracts sessionId from root or nested session payload', () {
      expect(
        P2pTransportService.extractSignalSessionId(
          <String, dynamic>{'sessionId': 'session-1'},
        ),
        'session-1',
      );

      expect(
        P2pTransportService.extractSignalSessionId(
          <String, dynamic>{
            'session': <String, dynamic>{'sessionId': 'session-2'},
          },
        ),
        'session-2',
      );
    });
  });
}
