import 'dart:convert';

import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/models/transfer_record.dart';
import 'package:http/http.dart' as http;

abstract class TransferRecordService {
  Future<List<TransferRecord>> fetchDeviceTransfers({
    required String deviceId,
    int page,
    int pageSize,
  });
}

class HttpTransferRecordService implements TransferRecordService {
  HttpTransferRecordService({
    required Uri baseUri,
    http.Client? client,
  })  : _baseUri = baseUri,
        _client = client ?? http.Client();

  final Uri _baseUri;
  final http.Client _client;

  @override
  Future<List<TransferRecord>> fetchDeviceTransfers({
    required String deviceId,
    int page = 1,
    int pageSize = 100,
  }) async {
    final Uri uri = _buildTransfersUri(
      queryParameters: <String, String>{
        'deviceId': deviceId,
        'page': '$page',
        'pageSize': '$pageSize',
      },
    );

    final http.Response response = await _client.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RealtimeError(
        'Failed to load transfer records: ${response.statusCode}',
      );
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const RealtimeError('Transfer record response format is invalid.');
    }

    final dynamic rawItems = decoded['items'];
    if (rawItems is! List) {
      return const <TransferRecord>[];
    }

    return rawItems
        .whereType<Map>()
        .map(
          (Map item) => TransferRecord.fromJson(
            item.map(
              (dynamic key, dynamic value) => MapEntry(key.toString(), value),
            ),
          ),
        )
        .toList()
      ..sort(
        (TransferRecord a, TransferRecord b) =>
            b.createdAt.compareTo(a.createdAt),
      );
  }

  Uri _buildTransfersUri({
    required Map<String, String> queryParameters,
  }) {
    final String normalizedPath = _baseUri.path == '/' ? '' : _baseUri.path;
    return _baseUri.replace(
      path: '$normalizedPath/transfers',
      queryParameters: queryParameters,
    );
  }
}
