import 'dart:convert';

import 'package:file_transfer_flutter/core/models/network_agent_command.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';
import 'package:file_transfer_flutter/core/models/pairing_session.dart';
import 'package:file_transfer_flutter/core/services/networking_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('HttpNetworkingService', () {
    test('probeServerReachability only treats successful responses as ready',
        () async {
      final HttpNetworkingService service = HttpNetworkingService(
        baseUri: Uri.parse('http://localhost:3000'),
        client: MockClient((http.Request request) async {
          expect(request.method, 'GET');
          return http.Response('server error', 500);
        }),
      );

      expect(await service.probeServerReachability(), isFalse);
    });

    test('fetchAgentCommands closes stale connections and retries once',
        () async {
      int requestCount = 0;
      final HttpNetworkingService service = HttpNetworkingService(
        baseUri: Uri.parse('http://localhost:3000'),
        client: MockClient((http.Request request) async {
          requestCount += 1;
          expect(request.method, 'GET');
          expect(request.url.path,
              '/networking/agent/devices/cm-device-a/commands');
          expect(request.url.queryParameters['limit'], '20');
          expect(request.headers['x-device-token'], 'token-a');
          expect(request.headers['Connection'], 'close');
          if (requestCount == 1) {
            throw http.ClientException(
              'Connection closed before full header was received',
              request.url,
            );
          }
          return http.Response(
            jsonEncode(<Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'cmd-3',
                'deviceId': 'cm-device-a',
                'type': 'join_zerotier_network',
                'status': 'pending',
                'payload': <String, dynamic>{
                  'networkId': '8056c2e21c000001',
                },
              },
            ]),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final List<NetworkAgentCommand> commands =
          await service.fetchAgentCommands(
        deviceId: 'cm-device-a',
        agentToken: 'token-a',
      );

      expect(requestCount, 2);
      expect(commands, hasLength(1));
      expect(commands.single.id, 'cmd-3');
    });

    test('heartbeatAgent includes relay observation fields', () async {
      late http.Request capturedRequest;
      final HttpNetworkingService service = HttpNetworkingService(
        baseUri: Uri.parse('http://localhost:3000'),
        client: MockClient((http.Request request) async {
          capturedRequest = request;
          return http.Response('{}', 204);
        }),
      );

      await service.heartbeatAgent(
        deviceId: 'cm-device-a',
        agentToken: 'token-a',
        zeroTierNodeId: 'zt-a',
        connectionMode: P2pConnectionMode.relay,
        relayNodeId: 'relay-01',
        rttMs: 42,
        txBytes: 123,
        rxBytes: 456,
      );

      expect(capturedRequest.method, 'PATCH');
      expect(
        jsonDecode(capturedRequest.body),
        <String, dynamic>{
          'status': 'online',
          'zeroTierNodeId': 'zt-a',
          'connectionMode': 'relay',
          'relayNodeId': 'relay-01',
          'rttMs': 42,
          'txBytes': 123,
          'rxBytes': 456,
        },
      );
    });

    test(
        'fetchPairingSessions parses temporary sessions and cancelled commands',
        () async {
      final HttpNetworkingService service = HttpNetworkingService(
        baseUri: Uri.parse('http://localhost:3000'),
        client: MockClient((http.Request request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/networking/sessions');
          expect(request.url.queryParameters['deviceId'], 'cm-device-a');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'sessions': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'ps-1',
                  'status': 'cancelled',
                  'createdAt': '2026-04-19T10:00:00.000Z',
                  'firewallScopeStatus': 'closed',
                  'firewallScopeClosedAt': '2026-04-19T10:05:00.000Z',
                  'initiatorDevice': <String, dynamic>{
                    'id': 'cm-device-a',
                    'deviceName': 'Alpha',
                    'platform': 'windows',
                    'zeroTierNodeId': 'zt-a',
                    'status': 'online',
                  },
                  'targetDevice': <String, dynamic>{
                    'id': 'cm-device-b',
                    'deviceName': 'Beta',
                    'platform': 'android',
                    'zeroTierNodeId': 'zt-b',
                    'status': 'online',
                  },
                  'allowedPorts': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'port-1',
                      'protocol': 'tcp',
                      'port': 3389,
                      'direction': 'from_initiator',
                    },
                  ],
                  'zeroTierBindings': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'deviceId': 'cm-device-a',
                      'zeroTierNodeId': 'zt-a',
                      'zeroTierAssignedIp': '10.147.20.2',
                      'memberStatus': 'authorized',
                    },
                  ],
                  'commands': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'cmd-1',
                      'deviceId': 'cm-device-a',
                      'type': 'join_zerotier_network',
                      'status': 'superseded',
                      'payload': <String, dynamic>{
                        'networkId': '8056c2e21c000001'
                      },
                      'createdAt': '2026-04-19T10:01:00.000Z',
                    },
                  ],
                },
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final sessions =
          await service.fetchPairingSessions(deviceId: 'cm-device-a');

      expect(sessions, hasLength(1));
      expect(sessions.single.id, 'ps-1');
      expect(sessions.single.isCancelled, isTrue);
      expect(sessions.single.firewallScopeStatus, 'closed');
      expect(
        sessions.single.firewallScopeClosedAt,
        DateTime.parse('2026-04-19T10:05:00.000Z'),
      );
      expect(sessions.single.allowedPorts.single.port, 3389);
      expect(sessions.single.commands.single.isSuperseded, isTrue);
      expect(sessions.single.commands.single.isFinal, isTrue);
      expect(
        sessions.single.commands.single.createdAt,
        DateTime.parse('2026-04-19T10:01:00.000Z'),
      );
    });

    test('cancelPairingSession posts deviceId and reason', () async {
      late http.Request capturedRequest;
      final HttpNetworkingService service = HttpNetworkingService(
        baseUri: Uri.parse('http://localhost:3000'),
        client: MockClient((http.Request request) async {
          capturedRequest = request;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'session': <String, dynamic>{
                'id': 'ps-2',
                'status': 'cancelled',
                'initiatorDevice': <String, dynamic>{
                  'id': 'cm-device-a',
                  'deviceName': 'Alpha',
                  'platform': 'windows',
                  'zeroTierNodeId': 'zt-a',
                  'status': 'online',
                },
                'targetDevice': <String, dynamic>{
                  'id': 'cm-device-b',
                  'deviceName': 'Beta',
                  'platform': 'android',
                  'zeroTierNodeId': 'zt-b',
                  'status': 'online',
                },
                'allowedPorts': const <Map<String, dynamic>>[],
                'zeroTierBindings': const <Map<String, dynamic>>[],
                'commands': const <Map<String, dynamic>>[],
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final session = await service.cancelPairingSession(
        sessionId: 'ps-2',
        deviceId: 'cm-device-a',
        reason: 'User cancelled temporary networking',
      );

      expect(capturedRequest.method, 'POST');
      expect(capturedRequest.url.path, '/networking/sessions/ps-2/cancel');
      expect(
        jsonDecode(capturedRequest.body),
        <String, dynamic>{
          'deviceId': 'cm-device-a',
          'reason': 'User cancelled temporary networking',
        },
      );
      expect(session.status, 'cancelled');
    });

    test('closePairingSession posts to close endpoint for normal shutdown',
        () async {
      late http.Request capturedRequest;
      final HttpNetworkingService service = HttpNetworkingService(
        baseUri: Uri.parse('http://localhost:3000'),
        client: MockClient((http.Request request) async {
          capturedRequest = request;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'session': <String, dynamic>{
                'id': 'ps-3',
                'status': 'closed',
                'firewallScopeStatus': 'closed',
                'firewallScopeClosedAt': '2026-04-19T11:05:00.000Z',
                'initiatorDevice': <String, dynamic>{
                  'id': 'cm-device-a',
                  'deviceName': 'Alpha',
                  'platform': 'windows',
                  'zeroTierNodeId': 'zt-a',
                  'status': 'online',
                },
                'targetDevice': <String, dynamic>{
                  'id': 'cm-device-b',
                  'deviceName': 'Beta',
                  'platform': 'android',
                  'zeroTierNodeId': 'zt-b',
                  'status': 'online',
                },
                'allowedPorts': const <Map<String, dynamic>>[],
                'zeroTierBindings': const <Map<String, dynamic>>[],
                'commands': const <Map<String, dynamic>>[],
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final session = await service.closePairingSession(
        sessionId: 'ps-3',
        deviceId: 'cm-device-a',
        reason: 'Transfer completed',
      );

      expect(capturedRequest.method, 'POST');
      expect(capturedRequest.url.path, '/networking/sessions/ps-3/close');
      expect(
        jsonDecode(capturedRequest.body),
        <String, dynamic>{
          'deviceId': 'cm-device-a',
          'reason': 'Transfer completed',
        },
      );
      expect(session.status, 'closed');
      expect(session.firewallScopeStatus, 'closed');
    });
  });

  group('NetworkAgentCommand', () {
    test('marks skipped and final statuses correctly', () {
      final NetworkAgentCommand command = NetworkAgentCommand.fromJson(
        <String, dynamic>{
          'id': 'cmd-2',
          'type': 'leave_zerotier_network',
          'status': 'expired',
          'payload': <String, dynamic>{},
        },
      );

      expect(command.isExpired, isTrue);
      expect(command.isSkipped, isTrue);
      expect(command.isFinal, isTrue);
    });

    test('parses relay hint fields without breaking old payloads', () {
      final NetworkAgentCommand command = NetworkAgentCommand.fromJson(
        <String, dynamic>{
          'id': 'cmd-4',
          'type': 'join_zerotier_network',
          'status': 'pending',
          'payload': <String, dynamic>{
            'preferredRelayNodeId': 'relay-01',
            'relayPolicy': 'prefer_relay',
          },
        },
      );

      expect(command.preferredRelayNodeId, 'relay-01');
      expect(command.relayPolicy, RelayPolicy.preferRelay);
    });
  });

  group('PairingSession', () {
    test('parses relay observation fields', () {
      final PairingSession session = PairingSession.fromJson(
        <String, dynamic>{
          'id': 'ps-10',
          'status': 'active',
          'initiatorDevice': <String, dynamic>{
            'id': 'cm-device-a',
            'deviceName': 'Alpha',
            'platform': 'windows',
            'zeroTierNodeId': 'zt-a',
            'status': 'online',
          },
          'targetDevice': <String, dynamic>{
            'id': 'cm-device-b',
            'deviceName': 'Beta',
            'platform': 'android',
            'zeroTierNodeId': 'zt-b',
            'status': 'online',
          },
          'allowedPorts': const <Map<String, dynamic>>[],
          'zeroTierBindings': const <Map<String, dynamic>>[],
          'commands': const <Map<String, dynamic>>[],
          'relayNodeId': 'relay-01',
          'relayDecisionReason': 'p2p_failed',
          'observedConnectionMode': 'relay',
          'observedRelayNodeId': 'relay-01',
        },
      );

      expect(session.relayNodeId, 'relay-01');
      expect(session.relayDecisionReason, 'p2p_failed');
      expect(session.observedConnectionMode, P2pConnectionMode.relay);
      expect(session.observedRelayNodeId, 'relay-01');
    });
  });
}
