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

  group('P2pTransportService stats helpers', () {
    test('extracts relay candidate address from known stats keys', () {
      expect(
        P2pTransportService.extractStatsCandidateAddress(
          <String, dynamic>{'ip': '10.0.0.8'},
        ),
        '10.0.0.8',
      );

      expect(
        P2pTransportService.extractStatsCandidateAddress(
          <String, dynamic>{'address': '192.168.1.3'},
        ),
        '192.168.1.3',
      );
    });

    test('extracts relay candidate url from known stats keys', () {
      expect(
        P2pTransportService.extractStatsCandidateUrl(
          <String, dynamic>{'url': 'turn:139.196.158.225:3478?transport=udp'},
        ),
        'turn:139.196.158.225:3478?transport=udp',
      );

      expect(
        P2pTransportService.extractStatsCandidateUrl(
          <String, dynamic>{'urls': 'turns:relay.example.com:5349?transport=tcp'},
        ),
        'turns:relay.example.com:5349?transport=tcp',
      );
    });

    test('resolves relay node id from configured ice server metadata', () {
      final List<Map<String, dynamic>> iceServers = <Map<String, dynamic>>[
        <String, dynamic>{
          'urls': <String>[
            'turn:139.196.158.225:3478?transport=udp',
            'turn:139.196.158.225:3478?transport=tcp',
          ],
          'relayNodeId': 'relay-01',
        },
      ];

      expect(
        P2pTransportService.resolveRelayNodeIdFromIceServers(
          iceServers: iceServers,
          selectedRelayUrl: 'turn:139.196.158.225:3478?transport=udp',
        ),
        'relay-01',
      );

      expect(
        P2pTransportService.resolveRelayNodeIdFromIceServers(
          iceServers: iceServers,
          selectedRelayAddress: '139.196.158.225',
        ),
        'relay-01',
      );
    });
  });
}
