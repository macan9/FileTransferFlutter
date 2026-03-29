import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_transfer_flutter/core/models/incoming_transfer_context.dart';
import 'package:file_transfer_flutter/core/models/outgoing_transfer_context.dart';
import 'package:file_transfer_flutter/core/models/p2p_session.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';
import 'package:file_transfer_flutter/core/models/p2p_transport_state.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/models/transfer_record.dart';
import 'package:file_transfer_flutter/core/services/realtime_client_factory.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:uuid/uuid.dart';

class P2pTransportService {
  P2pTransportService({
    required RealtimePeerConnectionFactory peerConnectionFactory,
    Uuid? uuid,
  })  : _peerConnectionFactory = peerConnectionFactory,
        _uuid = uuid ?? const Uuid();

  static const int chunkSize = 16 * 1024;
  static const String _defaultChannelLabel = 'file-transfer';

  final RealtimePeerConnectionFactory _peerConnectionFactory;
  final Uuid _uuid;
  final StreamController<P2pTransportState> _stateController =
      StreamController<P2pTransportState>.broadcast();
  final Map<String, _PeerLink> _links = <String, _PeerLink>{};
  final Map<String, _IncomingBuffer> _incomingBuffers =
      <String, _IncomingBuffer>{};

  P2pTransportState _state = const P2pTransportState.initial();
  io.Socket? _socket;
  String? _selfDeviceId;
  String? _downloadDirectory;

  Stream<P2pTransportState> get stream => _stateController.stream;
  P2pTransportState get state => _state;

  Future<void> attach({
    required io.Socket socket,
    required String selfDeviceId,
    required String downloadDirectory,
  }) async {
    _socket = socket;
    _selfDeviceId = selfDeviceId;
    _downloadDirectory = downloadDirectory;
  }

  Future<void> detach() async {
    _socket = null;
    _selfDeviceId = null;
    _downloadDirectory = null;
    for (final _PeerLink link in _links.values) {
      await link.dispose();
    }
    _links.clear();
    _incomingBuffers.clear();
    _emit(const P2pTransportState.initial());
  }

  Future<void> dispose() async {
    await detach();
    await _stateController.close();
  }

  Future<void> syncSessions(List<P2pSession> sessions) async {
    final String selfDeviceId = _requireSelfDeviceId();
    final Set<String> nextIds =
        sessions.map((P2pSession s) => s.sessionId).toSet();

    final List<String> removed = _links.keys
        .where((String sessionId) => !nextIds.contains(sessionId))
        .toList();
    for (final String sessionId in removed) {
      await _disposeLink(sessionId);
    }

    for (final P2pSession session in sessions) {
      if (session.status.isTerminal) {
        await _disposeLink(session.sessionId);
        continue;
      }

      final _PeerLink link = await _ensureLink(
        session,
        session.peerDeviceIdOf(selfDeviceId),
      );
      link.session = session;

      if (session.status == P2pSessionStatus.connecting &&
          session.createdByDeviceId == selfDeviceId &&
          !link.negotiationStarted) {
        await _createOffer(link);
      }
    }

    _refreshSessionTransports();
  }

  Future<void> handleRemoteOffer(Map<String, dynamic> payload) async {
    final _PeerLink link =
        await _findLinkByPeer(_extractTargetDeviceId(payload));
    final Map<String, dynamic> offer = _normalizeMap(payload['offer']);
    await link.peerConnection.setRemoteDescription(
      RTCSessionDescription(
        offer['sdp']?.toString(),
        offer['type']?.toString() ?? 'offer',
      ),
    );

    final RTCSessionDescription answer =
        await link.peerConnection.createAnswer(<String, dynamic>{});
    await link.peerConnection.setLocalDescription(answer);
    link.negotiationStarted = true;
    _refreshSessionTransports();
    _emitSignaling(
      'client:answer',
      <String, dynamic>{
        'targetDeviceId': link.peerDeviceId,
        'answer': <String, dynamic>{
          'type': answer.type,
          'sdp': answer.sdp,
        },
      },
    );
  }

  Future<void> handleRemoteAnswer(Map<String, dynamic> payload) async {
    final _PeerLink link =
        await _findLinkByPeer(_extractTargetDeviceId(payload));
    final Map<String, dynamic> answer = _normalizeMap(payload['answer']);
    await link.peerConnection.setRemoteDescription(
      RTCSessionDescription(
        answer['sdp']?.toString(),
        answer['type']?.toString() ?? 'answer',
      ),
    );
  }

  Future<void> handleRemoteCandidate(Map<String, dynamic> payload) async {
    final _PeerLink link =
        await _findLinkByPeer(_extractTargetDeviceId(payload));
    final Map<String, dynamic> candidate = _normalizeMap(payload['candidate']);
    await link.peerConnection.addCandidate(
      RTCIceCandidate(
        candidate['candidate']?.toString(),
        candidate['sdpMid']?.toString(),
        (candidate['sdpMLineIndex'] as num?)?.toInt(),
      ),
    );
  }

  void handleTransferUpdated(Map<String, dynamic> payload) {
    final TransferRecord record = TransferRecord.fromJson(payload);
    final String selfDeviceId = _requireSelfDeviceId();
    if (record.senderDeviceId == selfDeviceId) {
      _reconcileOutgoing(record);
    }
    if (record.receiverDeviceId == selfDeviceId) {
      _reconcileIncoming(record);
    }
  }

  Future<void> sendFile({
    required P2pSession session,
    required String filePath,
  }) async {
    final String selfDeviceId = _requireSelfDeviceId();
    final io.Socket socket = _requireSocket();
    final _PeerLink link =
        await _ensureLink(session, session.peerDeviceIdOf(selfDeviceId));
    await _ensureChannelOpen(link);

    final File file = File(filePath);
    final int fileSize = await file.length();
    final String fileName = p.basename(filePath);
    final String mimeType = _mimeTypeFor(fileName);
    final int totalChunks = (fileSize / chunkSize).ceil();

    String? transferId;
    OutgoingTransferContext? context;
    try {
      transferId = await _createTransferRecord(
        socket: socket,
        session: session,
        receiverDeviceId: link.peerDeviceId,
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
      );

      context = OutgoingTransferContext(
        transferId: transferId,
        sessionId: session.sessionId,
        senderDeviceId: selfDeviceId,
        receiverDeviceId: link.peerDeviceId,
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
        sourcePath: filePath,
        chunkSize: chunkSize,
        totalChunks: totalChunks,
        status: TransferRecordStatus.pending,
        createdAt: DateTime.now(),
      );
      _upsertOutgoing(context);

      await _sendJsonMessage(
        link,
        <String, dynamic>{
          'type': 'file-meta',
          'transferId': transferId,
          'fileName': fileName,
          'fileSize': fileSize,
          'mimeType': mimeType,
          'chunkSize': chunkSize,
          'totalChunks': totalChunks,
        },
      );

      await _emitTransferProgress(transferId: transferId, status: 'sending');
      context = context.copyWith(
        status: TransferRecordStatus.sending,
        startedAt: DateTime.now(),
      );
      _upsertOutgoing(context);

      int sentBytes = 0;
      int sentChunks = 0;
      await for (final List<int> chunk in file.openRead()) {
        await _sendBinaryMessage(link, _buildChunkPayload(sentChunks, chunk));
        sentBytes += chunk.length;
        sentChunks += 1;
        _upsertOutgoing(
          context = context!.copyWith(
            sentBytes: sentBytes,
            sentChunks: sentChunks,
          ),
        );
      }

      await _sendJsonMessage(
        link,
        <String, dynamic>{
          'type': 'file-complete',
          'transferId': transferId,
        },
      );
    } catch (error) {
      if (context != null) {
        _upsertOutgoing(
          context.copyWith(
            status: TransferRecordStatus.failed,
            errorMessage: '$error',
            completedAt: DateTime.now(),
          ),
        );
      }
      if (transferId != null) {
        await _emitTransferFailed(
          transferId: transferId,
          errorMessage: '$error',
        );
      }
      rethrow;
    }
  }

  Future<_PeerLink> _ensureLink(P2pSession session, String peerDeviceId) async {
    final _PeerLink? existing = _links[session.sessionId];
    if (existing != null) {
      return existing;
    }

    final RTCPeerConnection peerConnection =
        await _peerConnectionFactory.create(
      iceServers: const <Map<String, dynamic>>[
        <String, dynamic>{'urls': 'stun:stun.l.google.com:19302'},
        <String, dynamic>{'urls': 'stun:stun1.l.google.com:19302'},
      ],
    );

    final _PeerLink link = _PeerLink(
      session: session,
      peerDeviceId: peerDeviceId,
      peerConnection: peerConnection,
    );
    _links[session.sessionId] = link;
    _bindPeerConnection(link);
    return link;
  }

  Future<void> _createOffer(_PeerLink link) async {
    final RTCDataChannel channel = await _ensureDataChannel(
      link,
      createIfMissing: true,
    );
    _bindDataChannel(link, channel);
    final RTCSessionDescription offer =
        await link.peerConnection.createOffer(<String, dynamic>{});
    await link.peerConnection.setLocalDescription(offer);
    link.negotiationStarted = true;
    _refreshSessionTransports();
    _emitSignaling(
      'client:offer',
      <String, dynamic>{
        'targetDeviceId': link.peerDeviceId,
        'offer': <String, dynamic>{
          'type': offer.type,
          'sdp': offer.sdp,
        },
      },
    );
  }

  void _bindPeerConnection(_PeerLink link) {
    link.peerConnection.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null) {
        return;
      }
      _emitSignaling(
        'client:candidate',
        <String, dynamic>{
          'targetDeviceId': link.peerDeviceId,
          'candidate': <String, dynamic>{
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        },
      );
    };

    link.peerConnection.onDataChannel = (RTCDataChannel channel) {
      _bindDataChannel(link, channel);
    };

    link.peerConnection.onConnectionState = (RTCPeerConnectionState state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          link.linkStatus = TransportLinkStatus.connected;
          link.lastError = null;
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          link.linkStatus = TransportLinkStatus.failed;
          link.lastError = 'PeerConnection failed';
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          link.linkStatus = TransportLinkStatus.closed;
          break;
        default:
          link.linkStatus = TransportLinkStatus.negotiating;
      }
      _refreshSessionTransports();
    };
  }

  Future<RTCDataChannel> _ensureDataChannel(
    _PeerLink link, {
    required bool createIfMissing,
  }) async {
    final RTCDataChannel? existing = link.dataChannel;
    if (existing != null) {
      return existing;
    }
    if (!createIfMissing) {
      throw const RealtimeError(
        'Current session has not created a DataChannel yet.',
      );
    }

    final RTCDataChannelInit init = RTCDataChannelInit()
      ..ordered = true
      ..maxRetransmits = -1;
    final RTCDataChannel channel =
        await link.peerConnection.createDataChannel(_defaultChannelLabel, init);
    link.dataChannel = channel;
    return channel;
  }

  void _bindDataChannel(_PeerLink link, RTCDataChannel channel) {
    link.dataChannel = channel;
    link.dataChannelLabel = channel.label;
    link.dataChannelOpen =
        channel.state == RTCDataChannelState.RTCDataChannelOpen;

    channel.onDataChannelState = (RTCDataChannelState state) {
      link.dataChannelOpen = state == RTCDataChannelState.RTCDataChannelOpen;
      if (link.dataChannelOpen) {
        link.linkStatus = TransportLinkStatus.connected;
        link.lastError = null;
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        link.linkStatus = TransportLinkStatus.closed;
      }
      _refreshSessionTransports();
    };

    channel.onMessage = (RTCDataChannelMessage message) async {
      try {
        await _handleDataChannelMessage(link, message);
      } catch (error) {
        link.lastError = '$error';
        _emit(_state.copyWith(lastError: '$error'));
        _refreshSessionTransports();
      }
    };

    _refreshSessionTransports();
  }

  Future<void> _handleDataChannelMessage(
    _PeerLink link,
    RTCDataChannelMessage message,
  ) async {
    if (message.isBinary) {
      final _IncomingBuffer? buffer = _incomingBuffers.values
          .where((item) =>
              item.sessionId == link.session.sessionId && !item.completed)
          .cast<_IncomingBuffer?>()
          .firstWhere((item) => item != null, orElse: () => null);
      if (buffer == null) {
        return;
      }

      final _ChunkPayload payload = _parseChunkPayload(message.binary);
      buffer.chunks[payload.index] = payload.data;
      buffer.receivedBytes += payload.data.length;
      _upsertIncoming(
        buffer.context = buffer.context.copyWith(
          receivedBytes: buffer.receivedBytes,
          receivedChunks: buffer.chunks.length,
          status: TransferRecordStatus.receiving,
          startedAt: buffer.context.startedAt ?? DateTime.now(),
        ),
      );
      return;
    }

    final Map<String, dynamic> json =
        jsonDecode(message.text) as Map<String, dynamic>;
    switch (json['type']?.toString() ?? '') {
      case 'file-meta':
        await _handleFileMeta(link, json);
        return;
      case 'file-complete':
        await _handleFileComplete(link, json);
        return;
      case 'file-received':
        await _handleFileReceivedAck(json);
        return;
      default:
        return;
    }
  }

  Future<void> _handleFileMeta(
    _PeerLink link,
    Map<String, dynamic> json,
  ) async {
    final String transferId = json['transferId']?.toString() ?? _uuid.v4();
    final IncomingTransferContext context = IncomingTransferContext(
      transferId: transferId,
      sessionId: link.session.sessionId,
      senderDeviceId: link.peerDeviceId,
      receiverDeviceId: _requireSelfDeviceId(),
      fileName: json['fileName']?.toString() ?? 'incoming.bin',
      fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
      mimeType: json['mimeType']?.toString() ?? 'application/octet-stream',
      chunkSize: (json['chunkSize'] as num?)?.toInt() ?? chunkSize,
      totalChunks: (json['totalChunks'] as num?)?.toInt() ?? 0,
      status: TransferRecordStatus.receiving,
      createdAt: DateTime.now(),
      startedAt: DateTime.now(),
      downloadDirectory: _requireDownloadDirectory(),
    );

    _incomingBuffers[transferId] = _IncomingBuffer(
      context: context,
      sessionId: link.session.sessionId,
    );
    _upsertIncoming(context);
    await _emitTransferProgress(transferId: transferId, status: 'receiving');
  }

  Future<void> _handleFileComplete(
    _PeerLink link,
    Map<String, dynamic> json,
  ) async {
    final String transferId = json['transferId']?.toString() ?? '';
    final _IncomingBuffer? buffer = _incomingBuffers[transferId];
    if (buffer == null) {
      return;
    }

    try {
      final List<int> bytes = <int>[];
      for (int i = 0; i < buffer.context.totalChunks; i += 1) {
        final Uint8List? chunk = buffer.chunks[i];
        if (chunk == null) {
          throw const RealtimeError(
              'Missing file chunks while rebuilding file');
        }
        bytes.addAll(chunk);
      }

      final String savePath = await _buildDownloadPath(
        buffer.context.downloadDirectory,
        buffer.context.fileName,
      );
      final File file = File(savePath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);

      buffer.completed = true;
      _upsertIncoming(
        buffer.context = buffer.context.copyWith(
          savePath: savePath,
          completedAt: DateTime.now(),
          status: TransferRecordStatus.received,
          receivedBytes: bytes.length,
          receivedChunks: buffer.context.totalChunks,
        ),
      );

      await _emitTransferComplete(transferId);
      await _sendJsonMessage(
        link,
        <String, dynamic>{
          'type': 'file-received',
          'transferId': transferId,
        },
      );
    } catch (error) {
      _upsertIncoming(
        buffer.context = buffer.context.copyWith(
          status: TransferRecordStatus.failed,
          errorMessage: '$error',
          completedAt: DateTime.now(),
        ),
      );
      await _emitTransferFailed(
        transferId: transferId,
        errorMessage: '$error',
      );
      rethrow;
    }
  }

  Future<void> _handleFileReceivedAck(Map<String, dynamic> json) async {
    final String transferId = json['transferId']?.toString() ?? '';
    final OutgoingTransferContext? current =
        _state.outgoingByTransferId(transferId);
    if (current == null) {
      return;
    }

    _upsertOutgoing(
      current.copyWith(
        status: TransferRecordStatus.sent,
        completedAt: DateTime.now(),
        sentBytes: current.fileSize,
      ),
    );
    await _emitTransferComplete(transferId);
  }

  Future<void> _ensureChannelOpen(_PeerLink link) async {
    final RTCDataChannel channel = await _ensureDataChannel(
      link,
      createIfMissing: link.session.createdByDeviceId == _requireSelfDeviceId(),
    );
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      link.dataChannelOpen = true;
      link.linkStatus = TransportLinkStatus.connected;
      _refreshSessionTransports();
      return;
    }
    throw const RealtimeError(
      'Current session DataChannel is not open yet. Please try again later.',
    );
  }

  Future<String> _createTransferRecord({
    required io.Socket socket,
    required P2pSession session,
    required String receiverDeviceId,
    required String fileName,
    required int fileSize,
    required String mimeType,
  }) async {
    final Completer<String> completer = Completer<String>();
    socket.emitWithAck(
      'client:transfer-start',
      <String, dynamic>{
        'sessionId': session.sessionId,
        'receiverDeviceId': receiverDeviceId,
        'fileName': fileName,
        'fileSize': fileSize,
        'mimeType': mimeType,
      },
      ack: (dynamic response) {
        final String? error = _extractAckError(response);
        if (error != null) {
          completer.completeError(RealtimeError(error));
          return;
        }
        final Map<String, dynamic>? json = _normalizeAckResponse(response);
        final dynamic nested = json?['item'] ?? json?['transfer'] ?? json;
        final Map<String, dynamic> transfer = _normalizeMap(nested);
        final String transferId = transfer['transferId']?.toString() ??
            transfer['id']?.toString() ??
            '';
        if (transferId.isEmpty) {
          completer.completeError(
            const RealtimeError('Server did not return a transferId.'),
          );
          return;
        }
        completer.complete(transferId);
      },
    );

    return completer.future;
  }

  Future<void> _emitTransferProgress({
    required String transferId,
    required String status,
  }) async {
    _requireSocket().emitWithAck(
      'client:transfer-progress',
      <String, dynamic>{
        'transferId': transferId,
        'status': status,
      },
      ack: (dynamic _) {},
    );
  }

  Future<void> _emitTransferComplete(String transferId) async {
    _requireSocket().emitWithAck(
      'client:transfer-complete',
      <String, dynamic>{'transferId': transferId},
      ack: (dynamic _) {},
    );
  }

  Future<void> _emitTransferFailed({
    required String transferId,
    required String errorMessage,
  }) async {
    _requireSocket().emitWithAck(
      'client:transfer-failed',
      <String, dynamic>{
        'transferId': transferId,
        'errorMessage': errorMessage,
      },
      ack: (dynamic _) {},
    );
  }

  void _emitSignaling(String event, Map<String, dynamic> payload) {
    _requireSocket().emit(event, payload);
  }

  Future<void> _sendJsonMessage(
    _PeerLink link,
    Map<String, dynamic> payload,
  ) async {
    final RTCDataChannel channel = link.dataChannel ??
        (throw const RealtimeError(
            'No DataChannel available for this session.'));
    await channel.send(RTCDataChannelMessage(jsonEncode(payload)));
  }

  Future<void> _sendBinaryMessage(_PeerLink link, Uint8List bytes) async {
    final RTCDataChannel channel = link.dataChannel ??
        (throw const RealtimeError(
            'No DataChannel available for this session.'));
    await channel.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  Uint8List _buildChunkPayload(int index, List<int> chunk) {
    final ByteData header = ByteData(4)..setUint32(0, index, Endian.big);
    final Uint8List payload = Uint8List(4 + chunk.length);
    payload.setRange(0, 4, header.buffer.asUint8List());
    payload.setRange(4, payload.length, chunk);
    return payload;
  }

  _ChunkPayload _parseChunkPayload(Uint8List payload) {
    final ByteData header = ByteData.sublistView(payload, 0, 4);
    final int index = header.getUint32(0, Endian.big);
    return _ChunkPayload(index, payload.sublist(4));
  }

  Future<String> _buildDownloadPath(
    String directoryPath,
    String originalFileName,
  ) async {
    final String sanitizedName =
        originalFileName.trim().isEmpty ? 'incoming.bin' : originalFileName;
    final String extension = p.extension(sanitizedName);
    final String basename = p.basenameWithoutExtension(sanitizedName);
    String candidate = p.join(directoryPath, sanitizedName);
    int index = 1;

    while (await File(candidate).exists()) {
      candidate = p.join(directoryPath, '$basename ($index)$extension');
      index += 1;
    }
    return candidate;
  }

  String _mimeTypeFor(String fileName) {
    final String ext = p.extension(fileName).toLowerCase();
    switch (ext) {
      case '.pdf':
        return 'application/pdf';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.txt':
        return 'text/plain';
      case '.mp4':
        return 'video/mp4';
      default:
        return 'application/octet-stream';
    }
  }

  String _extractTargetDeviceId(Map<String, dynamic> payload) {
    final String direct = payload['targetDeviceId']?.toString() ?? '';
    if (direct.isNotEmpty) {
      return direct;
    }
    final Map<String, dynamic> from = _normalizeMap(payload['from']);
    return from['deviceId']?.toString() ?? '';
  }

  Future<_PeerLink> _findLinkByPeer(String peerDeviceId) async {
    for (final _PeerLink link in _links.values) {
      if (link.peerDeviceId == peerDeviceId) {
        return link;
      }
    }
    throw RealtimeError(
        'No active session link found for device $peerDeviceId.');
  }

  Future<void> _disposeLink(String sessionId) async {
    final _PeerLink? link = _links.remove(sessionId);
    if (link == null) {
      return;
    }
    await link.dispose();
    _refreshSessionTransports();
  }

  void _reconcileOutgoing(TransferRecord record) {
    final OutgoingTransferContext? current =
        _state.outgoingByTransferId(record.transferId);
    final bool complete = record.status == TransferRecordStatus.sent;
    _upsertOutgoing(
      (current ??
              OutgoingTransferContext(
                transferId: record.transferId,
                sessionId: record.sessionId,
                senderDeviceId: record.senderDeviceId,
                receiverDeviceId: record.receiverDeviceId,
                fileName: record.fileName,
                fileSize: record.fileSize,
                mimeType: record.mimeType,
                sourcePath: '',
                chunkSize: chunkSize,
                totalChunks: 0,
                status: record.status,
                createdAt: record.createdAt,
              ))
          .copyWith(
        status: record.status,
        startedAt: record.startedAt,
        completedAt: record.completedAt,
        errorMessage: record.errorMessage,
        clearErrorMessage: record.errorMessage == null,
        sentBytes: complete ? record.fileSize : current?.sentBytes ?? 0,
        sentChunks:
            complete ? current?.totalChunks ?? 0 : current?.sentChunks ?? 0,
      ),
    );
  }

  void _reconcileIncoming(TransferRecord record) {
    final IncomingTransferContext? current =
        _state.incomingByTransferId(record.transferId);
    final bool complete = record.status == TransferRecordStatus.received ||
        record.status == TransferRecordStatus.sent;
    _upsertIncoming(
      (current ??
              IncomingTransferContext(
                transferId: record.transferId,
                sessionId: record.sessionId,
                senderDeviceId: record.senderDeviceId,
                receiverDeviceId: record.receiverDeviceId,
                fileName: record.fileName,
                fileSize: record.fileSize,
                mimeType: record.mimeType,
                chunkSize: chunkSize,
                totalChunks: 0,
                status: record.status,
                createdAt: record.createdAt,
                downloadDirectory: _downloadDirectory ?? '',
              ))
          .copyWith(
        status: record.status,
        startedAt: record.startedAt,
        completedAt: record.completedAt,
        errorMessage: record.errorMessage,
        clearErrorMessage: record.errorMessage == null,
        receivedBytes: complete ? record.fileSize : current?.receivedBytes ?? 0,
        receivedChunks:
            complete ? current?.totalChunks ?? 0 : current?.receivedChunks ?? 0,
      ),
    );
  }

  void _upsertOutgoing(OutgoingTransferContext context) {
    final List<OutgoingTransferContext> items = <OutgoingTransferContext>[
      for (final OutgoingTransferContext item in _state.outgoingTransfers)
        if (item.transferId != context.transferId) item,
      context,
    ]..sort(
        (OutgoingTransferContext a, OutgoingTransferContext b) =>
            b.createdAt.compareTo(a.createdAt),
      );
    _emit(_state.copyWith(outgoingTransfers: items, clearLastError: true));
  }

  void _upsertIncoming(IncomingTransferContext context) {
    final List<IncomingTransferContext> items = <IncomingTransferContext>[
      for (final IncomingTransferContext item in _state.incomingTransfers)
        if (item.transferId != context.transferId) item,
      context,
    ]..sort(
        (IncomingTransferContext a, IncomingTransferContext b) =>
            b.createdAt.compareTo(a.createdAt),
      );
    _emit(_state.copyWith(incomingTransfers: items, clearLastError: true));
  }

  void _refreshSessionTransports() {
    final List<P2pSessionTransport> items = _links.values
        .map(
          (_PeerLink link) => P2pSessionTransport(
            sessionId: link.session.sessionId,
            peerDeviceId: link.peerDeviceId,
            sessionStatus: link.session.status,
            linkStatus: link.linkStatus,
            dataChannelOpen: link.dataChannelOpen,
            dataChannelLabel: link.dataChannelLabel,
            lastError: link.lastError,
          ),
        )
        .toList()
      ..sort(
        (P2pSessionTransport a, P2pSessionTransport b) =>
            a.peerDeviceId.compareTo(b.peerDeviceId),
      );
    _emit(_state.copyWith(sessionTransports: items));
  }

  void _emit(P2pTransportState next) {
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  io.Socket _requireSocket() {
    final io.Socket? socket = _socket;
    if (socket == null) {
      throw const RealtimeError(
        'Signaling socket is not attached, cannot negotiate WebRTC.',
      );
    }
    return socket;
  }

  String _requireSelfDeviceId() {
    final String? selfDeviceId = _selfDeviceId;
    if (selfDeviceId == null || selfDeviceId.isEmpty) {
      throw const RealtimeError('Current deviceId is missing.');
    }
    return selfDeviceId;
  }

  String _requireDownloadDirectory() {
    final String? directory = _downloadDirectory;
    if (directory == null || directory.isEmpty) {
      throw const RealtimeError('Download directory is not configured.');
    }
    return directory;
  }

  Map<String, dynamic> _normalizeMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (dynamic key, dynamic item) => MapEntry(key.toString(), item),
      );
    }
    return const <String, dynamic>{};
  }

  Map<String, dynamic>? _normalizeAckResponse(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (dynamic key, dynamic item) => MapEntry(key.toString(), item),
      );
    }
    return null;
  }

  String? _extractAckError(dynamic payload) {
    final Map<String, dynamic>? json = _normalizeAckResponse(payload);
    if (json == null || json['success'] == true) {
      return null;
    }
    return json['message']?.toString() ?? json['error']?.toString();
  }
}

class _PeerLink {
  _PeerLink({
    required this.session,
    required this.peerDeviceId,
    required this.peerConnection,
  });

  P2pSession session;
  final String peerDeviceId;
  final RTCPeerConnection peerConnection;
  RTCDataChannel? dataChannel;
  bool dataChannelOpen = false;
  String? dataChannelLabel;
  bool negotiationStarted = false;
  TransportLinkStatus linkStatus = TransportLinkStatus.idle;
  String? lastError;

  Future<void> dispose() async {
    await dataChannel?.close();
    await peerConnection.close();
  }
}

class _IncomingBuffer {
  _IncomingBuffer({
    required this.context,
    required this.sessionId,
  });

  IncomingTransferContext context;
  final String sessionId;
  final Map<int, Uint8List> chunks = <int, Uint8List>{};
  int receivedBytes = 0;
  bool completed = false;
}

class _ChunkPayload {
  _ChunkPayload(this.index, this.data);

  final int index;
  final Uint8List data;
}
