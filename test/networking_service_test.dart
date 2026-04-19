import 'dart:convert';

import 'package:file_transfer_flutter/core/models/network_agent_command.dart';
import 'package:file_transfer_flutter/core/services/networking_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('HttpNetworkingService', () {
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
                      'status': 'cancelled',
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
      expect(sessions.single.allowedPorts.single.port, 3389);
      expect(sessions.single.commands.single.isCancelled, isTrue);
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
  });

  group('NetworkAgentCommand', () {
    test('marks cancelled and final statuses correctly', () {
      final NetworkAgentCommand command = NetworkAgentCommand.fromJson(
        <String, dynamic>{
          'id': 'cmd-2',
          'type': 'leave_zerotier_network',
          'status': 'cancelled',
          'payload': <String, dynamic>{},
        },
      );

      expect(command.isCancelled, isTrue);
      expect(command.isFinal, isTrue);
    });
  });
}
