// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:io';

import 'package:file_transfer_flutter/core/services/p2p_transport_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('live relay config resolves relay node id from production signaling', () async {
    final Uri endpoint = Uri.parse(
      const String.fromEnvironment(
        'LIVE_SIGNALING_URL',
        defaultValue: 'http://139.196.158.225:3100/signaling/webrtc-config',
      ),
    );

    final HttpClient client = HttpClient();
    addTearDown(client.close);

    final HttpClientRequest request = await client.getUrl(endpoint);
    final HttpClientResponse response = await request.close();
    expect(response.statusCode, 200);

    final String body = await response.transform(utf8.decoder).join();
    final dynamic decoded = jsonDecode(body);
    expect(decoded, isA<Map<dynamic, dynamic>>());

    final Map<String, dynamic> json = (decoded as Map<dynamic, dynamic>).map(
      (dynamic key, dynamic value) => MapEntry(key.toString(), value),
    );
    final List<dynamic> rawIceServers =
        json['iceServers'] as List<dynamic>? ?? const <dynamic>[];
    final List<Map<String, dynamic>> iceServers = rawIceServers
        .whereType<Map>()
        .map(
          (Map<dynamic, dynamic> server) => server.map(
            (dynamic key, dynamic value) => MapEntry(key.toString(), value),
          ),
        )
        .toList(growable: false);

    expect(iceServers, isNotEmpty);

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
}
