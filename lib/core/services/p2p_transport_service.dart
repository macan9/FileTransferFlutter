import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_transfer_flutter/core/models/incoming_transfer_context.dart';
import 'package:file_transfer_flutter/core/models/outgoing_transfer_context.dart';
import 'package:file_transfer_flutter/core/models/p2p_session.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';
import 'package:file_transfer_flutter/core/models/p2p_transport_state.dart';
import 'package:file_transfer_flutter/core/models/realtime_error.dart';
import 'package:file_transfer_flutter/core/models/transfer_record.dart';
import 'package:file_transfer_flutter/core/services/realtime_client_factory.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:uuid/uuid.dart';

class P2pTransportService {
  P2pTransportService({
    required RealtimePeerConnectionFactory peerConnectionFactory,
    http.Client? httpClient,
    Uuid? uuid,
  })  : _peerConnectionFactory = peerConnectionFactory,
        _httpClient = httpClient ?? http.Client(),
        _uuid = uuid ?? const Uuid();

  static const int chunkSize = 16 * 1024;
  static const int maxFileSizeBytes = 800 * 1024 * 1024;
  static const Duration incomingTransferTimeout = Duration(minutes: 2);
  static const Duration fileMetaAckTimeout = Duration(seconds: 10);
  static const String _defaultChannelLabel = 'file-transfer';
  static const Duration _statsProbeTimeout = Duration(seconds: 3);

  final RealtimePeerConnectionFactory _peerConnectionFactory;
  final http.Client _httpClient;
  final Uuid _uuid;
  final StreamController<P2pTransportState> _stateController =
      StreamController<P2pTransportState>.broadcast();
  final Map<String, _PeerLink> _links = <String, _PeerLink>{};
  final Map<String, _IncomingBuffer> _incomingBuffers =
      <String, _IncomingBuffer>{};
  final Map<String, Completer<void>> _fileMetaAckWaiters =
      <String, Completer<void>>{};

  P2pTransportState _state = const P2pTransportState.initial();
  io.Socket? _socket;
  String? _selfDeviceId;
  String? _downloadDirectory;
  Uri? _serverUri;
  Future<_WebrtcConfig>? _webrtcConfigFuture;

  Stream<P2pTransportState> get stream => _stateController.stream;
  P2pTransportState get state => _state;

  Future<void> attach({
    required io.Socket socket,
    required String selfDeviceId,
    required String downloadDirectory,
    required Uri serverUri,
  }) async {
    _log(
      'attach self=$selfDeviceId downloadDirectory=$downloadDirectory socketId=${socket.id}',
    );
    _socket = socket;
    _selfDeviceId = selfDeviceId;
    _downloadDirectory = downloadDirectory;
    _serverUri = serverUri;
    _webrtcConfigFuture = null;
  }

  Future<void> detach() async {
    _log(
      'detach start links=${_links.length} incomingBuffers=${_incomingBuffers.length}',
    );
    _socket = null;
    _selfDeviceId = null;
    _downloadDirectory = null;
    _serverUri = null;
    _webrtcConfigFuture = null;
    for (final _PeerLink link in _links.values) {
      await link.dispose();
    }
    for (final _IncomingBuffer buffer in _incomingBuffers.values) {
      await buffer.dispose(deleteTempFile: true);
    }
    _links.clear();
    _incomingBuffers.clear();
    _fileMetaAckWaiters.clear();
    _log('detach done');
    _emit(const P2pTransportState.initial());
  }

  Future<void> dispose() async {
    await detach();
    await _stateController.close();
  }

  Future<void> syncSessions(List<P2pSession> sessions) async {
    final String selfDeviceId = _requireSelfDeviceId();
    _log('syncSessions start self=$selfDeviceId count=${sessions.length}');
    final Set<String> nextIds =
        sessions.map((P2pSession s) => s.sessionId).toSet();

    final List<String> removed = _links.keys
        .where((String sessionId) => !nextIds.contains(sessionId))
        .toList();
    for (final String sessionId in removed) {
      await _disposeLink(sessionId);
    }

    for (final P2pSession session in sessions) {
      _log(
        'syncSessions visit session=${session.sessionId} status=${session.status.value} peer=${session.peerDeviceIdOf(selfDeviceId)} createdBy=${session.createdByDeviceId}',
      );
      if (session.status.isTerminal) {
        _log('syncSessions dispose terminal session=${session.sessionId}');
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
        _log('syncSessions createOffer session=${session.sessionId}');
        await _createOffer(link);
      }
    }

    _log('syncSessions complete activeLinks=${_links.length}');
    _refreshSessionTransports();
  }

  Future<void> handleRemoteOffer(Map<String, dynamic> payload) async {
    final _PeerLink link = await _findLinkForSignal(payload);
    _log(
      'handleRemoteOffer session=${link.session.sessionId} peer=${link.peerDeviceId}',
    );
    final Map<String, dynamic> offer = _normalizeMap(payload['offer']);
    _log(
      'handleRemoteOffer setRemoteDescription session=${link.session.sessionId} type=${offer["type"]}',
    );
    _log(
        'handleRemoteOffer before setRemoteDescription session=${link.session.sessionId}');
    await link.peerConnection.setRemoteDescription(
      RTCSessionDescription(
        offer['sdp']?.toString(),
        offer['type']?.toString() ?? 'offer',
      ),
    );
    _log(
        'handleRemoteOffer after setRemoteDescription session=${link.session.sessionId}');

    final RTCSessionDescription answer =
        await link.peerConnection.createAnswer(<String, dynamic>{});
    _log('handleRemoteOffer createAnswer session=${link.session.sessionId}');
    _log(
        'handleRemoteOffer before setLocalDescription session=${link.session.sessionId}');
    await link.peerConnection.setLocalDescription(answer);
    _log(
        'handleRemoteOffer after setLocalDescription session=${link.session.sessionId}');
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
    final _PeerLink link = await _findLinkForSignal(payload);
    _log(
      'handleRemoteAnswer session=${link.session.sessionId} peer=${link.peerDeviceId}',
    );
    final Map<String, dynamic> answer = _normalizeMap(payload['answer']);
    _log(
      'handleRemoteAnswer setRemoteDescription session=${link.session.sessionId} type=${answer["type"]}',
    );
    _log(
        'handleRemoteAnswer before setRemoteDescription session=${link.session.sessionId}');
    await link.peerConnection.setRemoteDescription(
      RTCSessionDescription(
        answer['sdp']?.toString(),
        answer['type']?.toString() ?? 'answer',
      ),
    );
    _log(
        'handleRemoteAnswer after setRemoteDescription session=${link.session.sessionId}');
  }

  Future<void> handleRemoteCandidate(Map<String, dynamic> payload) async {
    final _PeerLink link = await _findLinkForSignal(payload);
    _log(
      'handleRemoteCandidate session=${link.session.sessionId} peer=${link.peerDeviceId}',
    );
    final Map<String, dynamic> candidate = _normalizeMap(payload['candidate']);
    link.remoteCandidateTypes.addAll(
      _extractCandidateTypes(candidate['candidate']?.toString()),
    );
    _log(
      'handleRemoteCandidate addCandidate session=${link.session.sessionId} sdpMid=${candidate["sdpMid"]} sdpMLineIndex=${candidate["sdpMLineIndex"]}',
    );
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
    if (fileSize > maxFileSizeBytes) {
      throw const RealtimeError('实时传输单文件上限为 800MB。');
    }
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
      final Future<void> metaAckFuture = _waitForFileMetaAck(transferId);

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
      await metaAckFuture;

      await _emitTransferProgress(transferId: transferId, status: 'sending');
      context = context.copyWith(
        status: TransferRecordStatus.sending,
        startedAt: DateTime.now(),
      );
      _upsertOutgoing(context);

      int sentBytes = 0;
      int sentChunks = 0;
      await for (final List<int> chunk in _readFileChunks(file)) {
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

      if (sentChunks != totalChunks) {
        throw RealtimeError(
          'Chunk count mismatch: expected $totalChunks, sent $sentChunks.',
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
      _log('ensureLink reuse session=${session.sessionId} peer=$peerDeviceId');
      existing.session = session;
      if (session.connectionMode != null) {
        existing.connectionMode = session.connectionMode!;
      }
      return existing;
    }

    final bool forceRelay = _shouldForceRelay(session);
    final _WebrtcConfig rtcConfig = await _loadWebrtcConfig(
      forceRelay: forceRelay,
    );
    _log(
        'ensureLink createPeerConnection session=${session.sessionId} peer=$peerDeviceId');
    final RTCPeerConnection peerConnection =
        await _peerConnectionFactory.create(
      iceServers: rtcConfig.iceServers,
      iceTransportPolicy: rtcConfig.iceTransportPolicy,
    );

    final _PeerLink link = _PeerLink(
      session: session,
      peerDeviceId: peerDeviceId,
      peerConnection: peerConnection,
      connectionMode: session.connectionMode ?? P2pConnectionMode.connecting,
      forceRelayOnly: forceRelay,
      webrtcConfig: rtcConfig,
    );
    _links[session.sessionId] = link;
    _bindPeerConnection(link);
    _log('ensureLink created session=${session.sessionId}');
    return link;
  }

  bool _shouldForceRelay(P2pSession session) {
    if (session.relayPolicy == RelayPolicy.preferRelay) {
      return true;
    }
    final P2pConnectionMode? preferredMode = session.connectionMode;
    return preferredMode == P2pConnectionMode.relay;
  }

  bool _canFallbackToRelay(_PeerLink link) {
    if (link.forceRelayOnly || link.relayFallbackAttempted) {
      return false;
    }
    return link.session.relayPolicy == RelayPolicy.directFirst ||
        link.session.relayPolicy == RelayPolicy.preferRelay ||
        link.session.preferredRelayNodeId?.trim().isNotEmpty == true;
  }

  Future<void> _switchToRelayAfterDirectFailure(_PeerLink link) async {
    if (!_canFallbackToRelay(link)) {
      return;
    }

    link.relayFallbackAttempted = true;
    link.forceRelayOnly = true;
    link.linkStatus = TransportLinkStatus.negotiating;
    link.connectionMode = P2pConnectionMode.connecting;
    link.lastError = null;
    link.localCandidateTypes.clear();
    link.remoteCandidateTypes.clear();
    link.dataChannel = null;
    link.dataChannelOpen = false;
    link.dataChannelLabel = null;
    link.negotiationStarted = false;
    _refreshSessionTransports();

    _log(
      'switchToRelay session=${link.session.sessionId} '
      'relayNode=${link.session.preferredRelayNodeId ?? "-"} '
      'policy=${link.session.relayPolicy?.value ?? "-"}',
    );

    await link.peerConnection.close();
    final _WebrtcConfig relayConfig = await _loadWebrtcConfig(
      forceRelay: true,
    );
    link.webrtcConfig = relayConfig;
    link.peerConnection = await _peerConnectionFactory.create(
      iceServers: relayConfig.iceServers,
      iceTransportPolicy: relayConfig.iceTransportPolicy,
    );
    _bindPeerConnection(link);

    if (link.session.createdByDeviceId == _selfDeviceId) {
      await _createOffer(link);
    }
  }

  Future<void> _createOffer(_PeerLink link) async {
    _log(
        'createOffer start session=${link.session.sessionId} peer=${link.peerDeviceId}');
    final RTCDataChannel channel = await _ensureDataChannel(
      link,
      createIfMissing: true,
    );
    _bindDataChannel(link, channel);
    _log(
      'createOffer dataChannel label=${channel.label} state=${channel.state?.name ?? 'null'}',
    );
    final RTCSessionDescription offer =
        await link.peerConnection.createOffer(<String, dynamic>{});
    _log(
        'createOffer created type=${offer.type} session=${link.session.sessionId}');
    _log(
        'createOffer before setLocalDescription session=${link.session.sessionId}');
    await link.peerConnection.setLocalDescription(offer);
    _log(
        'createOffer after setLocalDescription session=${link.session.sessionId}');
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
        _log('onIceCandidate null-candidate session=${link.session.sessionId}');
        return;
      }
      link.localCandidateTypes
          .addAll(_extractCandidateTypes(candidate.candidate));
      _log(
        'onIceCandidate session=${link.session.sessionId} sdpMid=${candidate.sdpMid} sdpMLineIndex=${candidate.sdpMLineIndex}',
      );
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
      _log(
        'onDataChannel session=${link.session.sessionId} label=${channel.label}',
      );
      _bindDataChannel(link, channel);
    };

    link.peerConnection.onConnectionState = (RTCPeerConnectionState state) {
      _log(
          'onConnectionState session=${link.session.sessionId} state=${state.name}');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          link.linkStatus = TransportLinkStatus.connected;
          link.lastError = null;
          if (link.session.connectionMode == null) {
            link.connectionMode = P2pConnectionMode.connecting;
          }
          unawaited(_refreshConnectionMode(link));
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          link.linkStatus = TransportLinkStatus.failed;
          link.connectionMode = P2pConnectionMode.failed;
          link.lastError = 'PeerConnection failed';
          unawaited(_switchToRelayAfterDirectFailure(link));
          unawaited(
            _cleanupIncomingBuffersForSession(
              link.session.sessionId,
              errorMessage: '连接已断开，未完成的文件接收已取消。',
            ),
          );
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          link.linkStatus = TransportLinkStatus.closed;
          unawaited(
            _cleanupIncomingBuffersForSession(
              link.session.sessionId,
              errorMessage: '连接已断开，未完成的文件接收已取消。',
            ),
          );
          break;
        default:
          link.linkStatus = TransportLinkStatus.negotiating;
          if (link.session.connectionMode == null) {
            link.connectionMode = P2pConnectionMode.connecting;
          }
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
      _log(
        'ensureDataChannel reuse session=${link.session.sessionId} state=${existing.state?.name ?? 'null'}',
      );
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
    _log('ensureDataChannel create session=${link.session.sessionId}');
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
    _log(
      'bindDataChannel session=${link.session.sessionId} label=${channel.label} initialState=${channel.state?.name ?? 'null'}',
    );

    channel.onDataChannelState = (RTCDataChannelState state) {
      _log(
          'onDataChannelState session=${link.session.sessionId} state=${state.name}');
      link.dataChannelOpen = state == RTCDataChannelState.RTCDataChannelOpen;
      if (link.dataChannelOpen) {
        link.linkStatus = TransportLinkStatus.connected;
        link.lastError = null;
        if (link.session.connectionMode == null) {
          link.connectionMode = P2pConnectionMode.connecting;
        }
        unawaited(_refreshConnectionMode(link));
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        link.linkStatus = TransportLinkStatus.closed;
      }
      _refreshSessionTransports();
    };

    channel.onMessage = (RTCDataChannelMessage message) {
      _enqueueDataChannelMessage(link, message);
    };

    _refreshSessionTransports();
  }

  void _enqueueDataChannelMessage(
    _PeerLink link,
    RTCDataChannelMessage message,
  ) {
    link.messageQueue = link.messageQueue.then((_) async {
      try {
        _log(
          'onDataChannelMessage session=${link.session.sessionId} binary=${message.isBinary}',
        );
        await _handleDataChannelMessage(link, message);
      } catch (error) {
        _log(
            'onDataChannelMessage error session=${link.session.sessionId} error=$error');
        link.lastError = '$error';
        _emit(_state.copyWith(lastError: '$error'));
        _refreshSessionTransports();
      }
    });
  }

  Future<void> _handleDataChannelMessage(
    _PeerLink link,
    RTCDataChannelMessage message,
  ) async {
    if (message.isBinary) {
      _log('handleDataChannelMessage binary session=${link.session.sessionId}');
      final _IncomingBuffer? buffer = _incomingBuffers.values
          .where((item) =>
              item.sessionId == link.session.sessionId && !item.completed)
          .cast<_IncomingBuffer?>()
          .firstWhere((item) => item != null, orElse: () => null);
      if (buffer == null) {
        return;
      }

      final _ChunkPayload payload = _parseChunkPayload(message.binary);
      if (payload.index != buffer.nextChunkIndex) {
        throw RealtimeError(
          'Unexpected chunk index ${payload.index}, expected ${buffer.nextChunkIndex}.',
        );
      }

      buffer.sink.add(payload.data);
      buffer.nextChunkIndex += 1;
      buffer.receivedBytes += payload.data.length;
      buffer.touch(
        incomingTransferTimeout,
        () => _handleIncomingBufferTimeout(buffer.context.transferId),
      );
      _upsertIncoming(
        buffer.context = buffer.context.copyWith(
          receivedBytes: buffer.receivedBytes,
          receivedChunks: buffer.nextChunkIndex,
          status: TransferRecordStatus.receiving,
          startedAt: buffer.context.startedAt ?? DateTime.now(),
        ),
      );
      return;
    }

    final Map<String, dynamic> json =
        jsonDecode(message.text) as Map<String, dynamic>;
    _log(
      'handleDataChannelMessage text session=${link.session.sessionId} type=${json['type']}',
    );
    switch (json['type']?.toString() ?? '') {
      case 'file-meta':
        await _handleFileMeta(link, json);
        return;
      case 'file-meta-ack':
        _handleFileMetaAck(json);
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
    _log(
      'handleFileMeta session=${link.session.sessionId} transferId=$transferId file=${json['fileName']}',
    );
    final String downloadDirectory = _requireDownloadDirectory();
    final int fileSize = (json['fileSize'] as num?)?.toInt() ?? 0;
    if (fileSize > maxFileSizeBytes) {
      throw const RealtimeError('实时传输单文件上限为 800MB。');
    }
    final String tempFilePath = await _buildTempDownloadPath(
      downloadDirectory,
      transferId,
    );
    final File tempFile = File(tempFilePath);
    await tempFile.parent.create(recursive: true);
    final IOSink sink = tempFile.openWrite();

    final IncomingTransferContext context = IncomingTransferContext(
      transferId: transferId,
      sessionId: link.session.sessionId,
      senderDeviceId: link.peerDeviceId,
      receiverDeviceId: _requireSelfDeviceId(),
      fileName: json['fileName']?.toString() ?? 'incoming.bin',
      fileSize: fileSize,
      mimeType: json['mimeType']?.toString() ?? 'application/octet-stream',
      chunkSize: (json['chunkSize'] as num?)?.toInt() ?? chunkSize,
      totalChunks: (json['totalChunks'] as num?)?.toInt() ?? 0,
      status: TransferRecordStatus.receiving,
      createdAt: DateTime.now(),
      startedAt: DateTime.now(),
      downloadDirectory: downloadDirectory,
    );

    _incomingBuffers[transferId] = _IncomingBuffer(
      context: context,
      sessionId: link.session.sessionId,
      tempFilePath: tempFilePath,
      sink: sink,
    );
    _incomingBuffers[transferId]!.touch(
      incomingTransferTimeout,
      () => _handleIncomingBufferTimeout(transferId),
    );
    await _sendJsonMessage(
      link,
      <String, dynamic>{
        'type': 'file-meta-ack',
        'transferId': transferId,
      },
    );
    _upsertIncoming(context);
    await _emitTransferProgress(transferId: transferId, status: 'receiving');
  }

  Future<void> _handleFileComplete(
    _PeerLink link,
    Map<String, dynamic> json,
  ) async {
    final String transferId = json['transferId']?.toString() ?? '';
    _log(
      'handleFileComplete session=${link.session.sessionId} transferId=$transferId',
    );
    final _IncomingBuffer? buffer = _incomingBuffers[transferId];
    if (buffer == null) {
      return;
    }

    try {
      if (buffer.nextChunkIndex != buffer.context.totalChunks) {
        throw RealtimeError(
          'Missing file chunks while rebuilding file: expected ${buffer.context.totalChunks}, received ${buffer.nextChunkIndex}.',
        );
      }
      if (buffer.receivedBytes != buffer.context.fileSize) {
        throw RealtimeError(
          'Received file size mismatch: expected ${buffer.context.fileSize}, got ${buffer.receivedBytes}.',
        );
      }

      await buffer.close();

      final String savePath = await _buildDownloadPath(
        buffer.context.downloadDirectory,
        buffer.context.fileName,
      );
      await File(savePath).parent.create(recursive: true);
      await File(buffer.tempFilePath).rename(savePath);

      buffer.completed = true;
      _upsertIncoming(
        buffer.context = buffer.context.copyWith(
          savePath: savePath,
          completedAt: DateTime.now(),
          status: TransferRecordStatus.received,
          receivedBytes: buffer.receivedBytes,
          receivedChunks: buffer.nextChunkIndex,
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
      buffer.cancelTimeout();
      _incomingBuffers.remove(transferId);
    } catch (error) {
      _upsertIncoming(
        buffer.context = buffer.context.copyWith(
          status: TransferRecordStatus.failed,
          errorMessage: '$error',
          completedAt: DateTime.now(),
        ),
      );
      buffer.cancelTimeout();
      await buffer.dispose(deleteTempFile: true);
      await _emitTransferFailed(
        transferId: transferId,
        errorMessage: '$error',
      );
      _incomingBuffers.remove(transferId);
      rethrow;
    }
  }

  Future<void> _handleFileReceivedAck(Map<String, dynamic> json) async {
    final String transferId = json['transferId']?.toString() ?? '';
    _log('handleFileReceivedAck transferId=$transferId');
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

  Future<void> _waitForFileMetaAck(String transferId) async {
    final Completer<void> completer = Completer<void>();
    _fileMetaAckWaiters[transferId] = completer;
    try {
      await completer.future.timeout(
        fileMetaAckTimeout,
        onTimeout: () => throw RealtimeError(
          'Timed out waiting for receiver to prepare incoming file buffer.',
        ),
      );
    } finally {
      final Completer<void>? current = _fileMetaAckWaiters[transferId];
      if (identical(current, completer)) {
        _fileMetaAckWaiters.remove(transferId);
      }
    }
  }

  void _handleFileMetaAck(Map<String, dynamic> json) {
    final String transferId = json['transferId']?.toString() ?? '';
    _log('handleFileMetaAck transferId=$transferId');
    final Completer<void>? completer = _fileMetaAckWaiters.remove(transferId);
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  Future<void> _ensureChannelOpen(_PeerLink link) async {
    _log('ensureChannelOpen session=${link.session.sessionId}');
    final RTCDataChannel channel = await _ensureDataChannel(
      link,
      createIfMissing: link.session.createdByDeviceId == _requireSelfDeviceId(),
    );
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      link.dataChannelOpen = true;
      link.linkStatus = TransportLinkStatus.connected;
      if (link.session.connectionMode == null) {
        link.connectionMode = P2pConnectionMode.connecting;
      }
      _refreshSessionTransports();
      unawaited(_refreshConnectionMode(link));
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
    _log(
      'createTransferRecord session=${session.sessionId} receiver=$receiverDeviceId file=$fileName size=$fileSize',
    );
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
    _log('emitSignaling event=$event keys=${payload.keys.join(',')}');
    _requireSocket().emit(event, payload);
  }

  Future<void> _sendJsonMessage(
    _PeerLink link,
    Map<String, dynamic> payload,
  ) async {
    _log(
      'sendJsonMessage session=${link.session.sessionId} type=${payload['type']}',
    );
    final RTCDataChannel channel = link.dataChannel ??
        (throw const RealtimeError(
            'No DataChannel available for this session.'));
    await channel.send(RTCDataChannelMessage(jsonEncode(payload)));
  }

  Future<void> _sendBinaryMessage(_PeerLink link, Uint8List bytes) async {
    _log(
        'sendBinaryMessage session=${link.session.sessionId} bytes=${bytes.length}');
    final RTCDataChannel channel = link.dataChannel ??
        (throw const RealtimeError(
            'No DataChannel available for this session.'));
    await channel.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  Stream<List<int>> _readFileChunks(File file) async* {
    final RandomAccessFile raf = await file.open();
    try {
      while (true) {
        final Uint8List chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) {
          break;
        }
        yield chunk;
      }
    } finally {
      await raf.close();
    }
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

  Future<String> _buildTempDownloadPath(
    String directoryPath,
    String transferId,
  ) async {
    final String tempDirectoryPath = p.join(directoryPath, '.p2p_tmp');
    final Directory tempDirectory = Directory(tempDirectoryPath);
    if (!await tempDirectory.exists()) {
      await tempDirectory.create(recursive: true);
    }

    return p.join(tempDirectoryPath, '$transferId.part');
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

  Future<_PeerLink> _findLinkForSignal(Map<String, dynamic> payload) async {
    final String? sessionId = extractSignalSessionId(payload);
    if (sessionId != null) {
      final _PeerLink? bySession = _links[sessionId];
      if (bySession != null) {
        return bySession;
      }
      _log('findLinkForSignal missing session=$sessionId, fallback to peer');
    }

    final String? peerDeviceId = resolveSignalPeerDeviceId(
      payload,
      selfDeviceId: _selfDeviceId,
    );
    if (peerDeviceId == null || peerDeviceId.isEmpty) {
      throw const RealtimeError(
        'Unable to resolve peer device from signaling payload.',
      );
    }
    return _findLinkByPeer(peerDeviceId);
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
    _log('disposeLink session=$sessionId');
    await _cleanupIncomingBuffersForSession(
      sessionId,
      errorMessage: '会话已关闭，未完成的文件接收已清理。',
    );
    await link.dispose();
    _refreshSessionTransports();
  }

  Future<void> _handleIncomingBufferTimeout(String transferId) async {
    final _IncomingBuffer? buffer = _incomingBuffers[transferId];
    if (buffer == null || buffer.completed) {
      return;
    }

    await _failIncomingBuffer(
      transferId,
      buffer,
      errorMessage: '接收超时，未完成的文件已清理。',
    );
  }

  Future<void> _cleanupIncomingBuffersForSession(
    String sessionId, {
    required String errorMessage,
  }) async {
    final List<MapEntry<String, _IncomingBuffer>> pending =
        _incomingBuffers.entries
            .where(
              (MapEntry<String, _IncomingBuffer> entry) =>
                  entry.value.sessionId == sessionId && !entry.value.completed,
            )
            .toList();

    for (final MapEntry<String, _IncomingBuffer> entry in pending) {
      await _failIncomingBuffer(
        entry.key,
        entry.value,
        errorMessage: errorMessage,
      );
    }
  }

  Future<void> _failIncomingBuffer(
    String transferId,
    _IncomingBuffer buffer, {
    required String errorMessage,
  }) async {
    buffer.cancelTimeout();
    _upsertIncoming(
      buffer.context = buffer.context.copyWith(
        status: TransferRecordStatus.failed,
        errorMessage: errorMessage,
        completedAt: DateTime.now(),
      ),
    );
    await buffer.dispose(deleteTempFile: true);
    _incomingBuffers.remove(transferId);

    final io.Socket? socket = _socket;
    if (socket != null) {
      socket.emitWithAck(
        'client:transfer-failed',
        <String, dynamic>{
          'transferId': transferId,
          'errorMessage': errorMessage,
        },
        ack: (dynamic _) {},
      );
    }
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

  P2pConnectionMode _effectiveConnectionMode(_PeerLink link) {
    final P2pConnectionMode? sessionMode = link.session.connectionMode;
    if (sessionMode != null && sessionMode != P2pConnectionMode.unknown) {
      return sessionMode;
    }
    if (link.linkStatus == TransportLinkStatus.failed) {
      return P2pConnectionMode.failed;
    }
    if (link.linkStatus != TransportLinkStatus.connected ||
        !link.dataChannelOpen) {
      return P2pConnectionMode.connecting;
    }
    return link.connectionMode;
  }

  Future<void> _refreshConnectionMode(_PeerLink link) async {
    final P2pConnectionMode? sessionMode = link.session.connectionMode;
    if (sessionMode != null && sessionMode != P2pConnectionMode.unknown) {
      if (link.connectionMode != sessionMode) {
        link.connectionMode = sessionMode;
        _refreshSessionTransports();
      }
      return;
    }
    if (link.linkStatus == TransportLinkStatus.failed) {
      if (link.connectionMode != P2pConnectionMode.failed) {
        link.connectionMode = P2pConnectionMode.failed;
        _refreshSessionTransports();
      }
      return;
    }
    if (link.linkStatus != TransportLinkStatus.connected ||
        !link.dataChannelOpen) {
      if (link.connectionMode != P2pConnectionMode.connecting) {
        link.connectionMode = P2pConnectionMode.connecting;
        _refreshSessionTransports();
      }
      return;
    }

    final P2pConnectionMode detected = await _detectConnectionMode(link);
    if (link.connectionMode != detected) {
      link.connectionMode = detected;
      _refreshSessionTransports();
    }
  }

  Future<P2pConnectionMode> _detectConnectionMode(_PeerLink link) async {
    final P2pConnectionMode? fromStats = await _detectConnectionModeFromStats(
      link,
    );
    if (fromStats != null) {
      return fromStats;
    }

    final Set<String> allTypes = <String>{
      ...link.localCandidateTypes,
      ...link.remoteCandidateTypes,
    };
    if (allTypes.contains('relay')) {
      return P2pConnectionMode.relay;
    }
    if (allTypes.any(_isDirectCandidateType)) {
      return P2pConnectionMode.direct;
    }
    return P2pConnectionMode.connecting;
  }

  Future<P2pConnectionMode?> _detectConnectionModeFromStats(
      _PeerLink link) async {
    try {
      final List<StatsReport> reports =
          await link.peerConnection.getStats().timeout(_statsProbeTimeout);
      if (reports.isEmpty) {
        return null;
      }

      final Map<String, StatsReport> reportsById = <String, StatsReport>{
        for (final StatsReport report in reports) report.id: report,
      };

      for (final StatsReport report in reports) {
        final String type = report.type.toLowerCase();
        if (type != 'candidate-pair' && type != 'googcandidatepair') {
          continue;
        }

        final Map<String, dynamic> values =
            _normalizeStatsValues(report.values);
        final bool selected = _isSelectedCandidatePair(values);
        if (!selected) {
          continue;
        }

        _updateTransportMetrics(link, values);

        final _SelectedCandidateDetails localCandidate =
            _extractSelectedCandidateDetails(
          candidateReportId: values['localCandidateId']?.toString(),
          candidateTypeKey: 'localCandidateType',
          reportsById: reportsById,
          values: values,
        );
        final _SelectedCandidateDetails remoteCandidate =
            _extractSelectedCandidateDetails(
          candidateReportId: values['remoteCandidateId']?.toString(),
          candidateTypeKey: 'remoteCandidateType',
          reportsById: reportsById,
          values: values,
        );
        _updateRelayObservation(
          link,
          localCandidate: localCandidate,
          remoteCandidate: remoteCandidate,
        );

        final Set<String> selectedTypes = <String>{
          if (localCandidate.candidateType != null &&
              localCandidate.candidateType!.isNotEmpty)
            localCandidate.candidateType!,
          if (remoteCandidate.candidateType != null &&
              remoteCandidate.candidateType!.isNotEmpty)
            remoteCandidate.candidateType!,
        };
        if (selectedTypes.contains('relay')) {
          return P2pConnectionMode.relay;
        }
        if (selectedTypes.any(_isDirectCandidateType)) {
          return P2pConnectionMode.direct;
        }
      }
    } catch (error) {
      _log(
        'detectConnectionModeFromStats error session=${link.session.sessionId} error=$error',
      );
    }
    return null;
  }

  _SelectedCandidateDetails _extractSelectedCandidateDetails({
    required String? candidateReportId,
    required String candidateTypeKey,
    required Map<String, StatsReport> reportsById,
    required Map<String, dynamic> values,
  }) {
    final String? inlineType =
        values[candidateTypeKey]?.toString().toLowerCase();
    final StatsReport? report = candidateReportId == null || candidateReportId.isEmpty
        ? null
        : reportsById[candidateReportId];
    final Map<String, dynamic> reportValues = report == null
        ? const <String, dynamic>{}
        : _normalizeStatsValues(report.values);
    return _SelectedCandidateDetails(
      candidateType: (inlineType != null && inlineType.isNotEmpty)
          ? inlineType
          : _normalizeObservedString(reportValues['candidateType']),
      address: P2pTransportService.extractStatsCandidateAddress(reportValues),
      url: P2pTransportService.extractStatsCandidateUrl(reportValues),
    );
  }

  void _updateRelayObservation(
    _PeerLink link, {
    required _SelectedCandidateDetails localCandidate,
    required _SelectedCandidateDetails remoteCandidate,
  }) {
    final List<_SelectedCandidateDetails> relayCandidates =
        <_SelectedCandidateDetails>[
      localCandidate,
      remoteCandidate,
    ].where(
      (_SelectedCandidateDetails item) => item.candidateType == 'relay',
    ).toList(growable: false);

    link.selectedRelayAddress = relayCandidates.isEmpty
        ? null
        : _firstNormalizedObservedString(
            relayCandidates.map((item) => item.address),
          );
    link.selectedRelayUrl = relayCandidates.isEmpty
        ? null
        : _firstNormalizedObservedString(
            relayCandidates.map((item) => item.url),
          );
    link.relayNodeId = _resolveRelayNodeIdForLink(link);
  }

  String? _resolveRelayNodeIdForLink(_PeerLink link) {
    return P2pTransportService.resolveRelayNodeIdFromIceServers(
      iceServers: link.webrtcConfig.iceServers,
      selectedRelayUrl: link.selectedRelayUrl,
      selectedRelayAddress: link.selectedRelayAddress,
    );
  }

  void _updateTransportMetrics(_PeerLink link, Map<String, dynamic> values) {
    final int? rttMs = _statsValueAsRttMs(
      values['currentRoundTripTime'] ??
          values['roundTripTime'] ??
          values['googRtt'],
    );
    final int? txBytes = _statsValueAsInt(
      values['bytesSent'] ?? values['googBytesSent'],
    );
    final int? rxBytes = _statsValueAsInt(
      values['bytesReceived'] ?? values['googBytesReceived'],
    );
    if (rttMs != null) {
      link.rttMs = rttMs;
    }
    if (txBytes != null) {
      link.txBytes = txBytes;
    }
    if (rxBytes != null) {
      link.rxBytes = rxBytes;
    }
  }

  int? _statsValueAsRttMs(dynamic value) {
    final num numeric = _statsValueAsNum(value) ?? 0;
    if (numeric <= 0) {
      return null;
    }
    return numeric < 10 ? (numeric * 1000).round() : numeric.round();
  }

  int? _statsValueAsInt(dynamic value) {
    final num? numeric = _statsValueAsNum(value);
    return numeric?.round();
  }

  num? _statsValueAsNum(dynamic value) {
    if (value is num) {
      return value;
    }
    if (value is String) {
      return num.tryParse(value.trim());
    }
    return null;
  }

  @visibleForTesting
  static String? extractStatsCandidateAddress(Map<String, dynamic> values) {
    return _firstNormalizedObservedString(<dynamic>[
      values['address'],
      values['ip'],
      values['ipAddress'],
      values['relayAddress'],
    ]);
  }

  @visibleForTesting
  static String? extractStatsCandidateUrl(Map<String, dynamic> values) {
    return _firstNormalizedObservedString(<dynamic>[
      values['url'],
      values['urls'],
      values['relayUrl'],
    ]);
  }

  @visibleForTesting
  static String? resolveRelayNodeIdFromIceServers({
    required List<Map<String, dynamic>> iceServers,
    String? selectedRelayUrl,
    String? selectedRelayAddress,
  }) {
    final List<_RelayIceServerMapping> mappings =
        _relayIceServerMappings(iceServers);
    for (final _RelayIceServerMapping mapping in mappings) {
      if (selectedRelayUrl != null &&
          mapping.urls.any(
            (String url) => _urlsMatch(selectedRelayUrl, url),
          )) {
        return mapping.relayNodeId;
      }
      if (selectedRelayAddress != null &&
          mapping.hosts.contains(selectedRelayAddress.trim())) {
        return mapping.relayNodeId;
      }
    }
    return null;
  }

  bool _isSelectedCandidatePair(Map<String, dynamic> values) {
    if (_statsValueAsBool(values['selected']) == true ||
        _statsValueAsBool(values['nominated']) == true) {
      return true;
    }

    final String state = values['state']?.toString().toLowerCase() ?? '';
    return state == 'succeeded' || state == 'in-progress';
  }

  Map<String, dynamic> _normalizeStatsValues(Map<dynamic, dynamic> value) {
    return value.map(
      (dynamic key, dynamic item) => MapEntry(key.toString(), item),
    );
  }

  bool? _statsValueAsBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final String normalized = value.trim().toLowerCase();
      if (normalized == 'true') {
        return true;
      }
      if (normalized == 'false') {
        return false;
      }
      if (normalized == '1') {
        return true;
      }
      if (normalized == '0') {
        return false;
      }
    }
    return null;
  }

  Set<String> _extractCandidateTypes(String? rawCandidate) {
    if (rawCandidate == null || rawCandidate.trim().isEmpty) {
      return const <String>{};
    }
    final Iterable<RegExpMatch> matches = RegExp(
      r' typ ([a-zA-Z0-9_]+)',
      caseSensitive: false,
    ).allMatches(rawCandidate);
    return matches
        .map((RegExpMatch match) => match.group(1)?.toLowerCase() ?? '')
        .where((String value) => value.isNotEmpty)
        .toSet();
  }

  bool _isDirectCandidateType(String value) {
    return value == 'host' || value == 'srflx' || value == 'prflx';
  }

  Future<_WebrtcConfig> _loadWebrtcConfig({
    required bool forceRelay,
  }) {
    final Future<_WebrtcConfig>? existing = _webrtcConfigFuture;
    if (existing != null) {
      return existing.then(
        (_WebrtcConfig value) =>
            forceRelay ? value.withIceTransportPolicy('relay') : value,
      );
    }

    final Future<_WebrtcConfig> future = _fetchWebrtcConfig();
    _webrtcConfigFuture = future;
    return future.then(
      (_WebrtcConfig value) =>
          forceRelay ? value.withIceTransportPolicy('relay') : value,
    );
  }

  Future<_WebrtcConfig> _fetchWebrtcConfig() async {
    final Uri? serverUri = _serverUri;
    if (serverUri == null) {
      return _defaultWebrtcConfig();
    }

    final Uri endpoint = serverUri.replace(
      path: _appendPath(serverUri.path, 'signaling/webrtc-config'),
      queryParameters: null,
      fragment: null,
    );

    try {
      final http.Response response =
          await _httpClient.get(endpoint).timeout(const Duration(seconds: 5));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is Map) {
          final Map<String, dynamic> json = decoded.map(
            (dynamic key, dynamic value) => MapEntry(key.toString(), value),
          );
          final _WebrtcConfig config = _WebrtcConfig.fromJson(json);
          if (config.iceServers.isNotEmpty) {
            return config;
          }
        }
      }
    } catch (error) {
      _log('fetchWebrtcConfig fallback error=$error');
    }

    return _defaultWebrtcConfig();
  }

  _WebrtcConfig _defaultWebrtcConfig() {
    return const _WebrtcConfig(
      iceTransportPolicy: 'all',
      iceServers: <Map<String, dynamic>>[
        <String, dynamic>{'urls': 'stun:stun.l.google.com:19302'},
        <String, dynamic>{'urls': 'stun:stun1.l.google.com:19302'},
      ],
    );
  }

  String _appendPath(String basePath, String extraPath) {
    final List<String> segments = <String>[
      ...basePath.split('/').where((String item) => item.isNotEmpty),
      ...extraPath.split('/').where((String item) => item.isNotEmpty),
    ];
    return '/${segments.join('/')}';
  }

  void _refreshSessionTransports() {
    final List<P2pSessionTransport> items = _links.values
        .map(
          (_PeerLink link) => P2pSessionTransport(
            sessionId: link.session.sessionId,
            peerDeviceId: link.peerDeviceId,
            sessionStatus: link.session.status,
            linkStatus: link.linkStatus,
            connectionMode: _effectiveConnectionMode(link),
            dataChannelOpen: link.dataChannelOpen,
            dataChannelLabel: link.dataChannelLabel,
            lastError: link.lastError,
            relayNodeId: link.relayNodeId,
            selectedRelayAddress: link.selectedRelayAddress,
            selectedRelayUrl: link.selectedRelayUrl,
            rttMs: link.rttMs,
            txBytes: link.txBytes,
            rxBytes: link.rxBytes,
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

  void _log(String message) {
    debugPrint('[P2P/TRANSPORT] $message');
  }

  @visibleForTesting
  static String? extractSignalSessionId(Map<String, dynamic> payload) {
    final String direct = payload['sessionId']?.toString().trim() ?? '';
    if (direct.isNotEmpty) {
      return direct;
    }

    final Map<String, dynamic> session = _mapValue(payload['session']);
    final String nested = session['sessionId']?.toString().trim() ?? '';
    return nested.isEmpty ? null : nested;
  }

  @visibleForTesting
  static String? resolveSignalPeerDeviceId(
    Map<String, dynamic> payload, {
    String? selfDeviceId,
  }) {
    final String self = selfDeviceId?.trim() ?? '';
    final Map<String, dynamic> from = _mapValue(payload['from']);
    final List<String> candidates = <String>[
      from['deviceId']?.toString() ?? '',
      payload['fromDeviceId']?.toString() ?? '',
      payload['senderDeviceId']?.toString() ?? '',
      payload['sourceDeviceId']?.toString() ?? '',
      payload['peerDeviceId']?.toString() ?? '',
      payload['targetDeviceId']?.toString() ?? '',
    ];

    for (final String raw in candidates) {
      final String candidate = raw.trim();
      if (candidate.isNotEmpty && candidate != self) {
        return candidate;
      }
    }

    for (final String raw in candidates) {
      final String candidate = raw.trim();
      if (candidate.isNotEmpty) {
        return candidate;
      }
    }

    return null;
  }

  static Map<String, dynamic> _mapValue(dynamic value) {
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
}

class _PeerLink {
  _PeerLink({
    required this.session,
    required this.peerDeviceId,
    required this.peerConnection,
    required this.connectionMode,
    required this.forceRelayOnly,
    required this.webrtcConfig,
  });

  P2pSession session;
  final String peerDeviceId;
  RTCPeerConnection peerConnection;
  RTCDataChannel? dataChannel;
  bool dataChannelOpen = false;
  String? dataChannelLabel;
  bool negotiationStarted = false;
  bool forceRelayOnly;
  bool relayFallbackAttempted = false;
  TransportLinkStatus linkStatus = TransportLinkStatus.idle;
  P2pConnectionMode connectionMode;
  _WebrtcConfig webrtcConfig;
  final Set<String> localCandidateTypes = <String>{};
  final Set<String> remoteCandidateTypes = <String>{};
  String? lastError;
  String? relayNodeId;
  String? selectedRelayAddress;
  String? selectedRelayUrl;
  int? rttMs;
  int? txBytes;
  int? rxBytes;
  Future<void> messageQueue = Future<void>.value();

  Future<void> dispose() async {
    await dataChannel?.close();
    await peerConnection.close();
  }
}

class _SelectedCandidateDetails {
  const _SelectedCandidateDetails({
    required this.candidateType,
    required this.address,
    required this.url,
  });

  final String? candidateType;
  final String? address;
  final String? url;
}

class _WebrtcConfig {
  const _WebrtcConfig({
    required this.iceTransportPolicy,
    required this.iceServers,
  });

  factory _WebrtcConfig.fromJson(Map<String, dynamic> json) {
    final dynamic rawServers = json['iceServers'];
    final List<Map<String, dynamic>> iceServers = rawServers is List
        ? rawServers
            .whereType<Map>()
            .map(
              (Map item) => item.map(
                (dynamic key, dynamic value) => MapEntry(key.toString(), value),
              ),
            )
            .where((Map<String, dynamic> item) {
            final dynamic urls = item['urls'];
            if (urls is String) {
              return urls.trim().isNotEmpty;
            }
            if (urls is List) {
              return urls.isNotEmpty;
            }
            return false;
          }).toList()
        : const <Map<String, dynamic>>[];

    final String iceTransportPolicy =
        json['iceTransportPolicy']?.toString().trim().isNotEmpty == true
            ? json['iceTransportPolicy']!.toString().trim()
            : 'all';

    return _WebrtcConfig(
      iceTransportPolicy: iceTransportPolicy,
      iceServers: iceServers,
    );
  }

  final String iceTransportPolicy;
  final List<Map<String, dynamic>> iceServers;

  _WebrtcConfig withIceTransportPolicy(String policy) {
    return _WebrtcConfig(
      iceTransportPolicy: policy,
      iceServers: iceServers,
    );
  }
}

class _IncomingBuffer {
  _IncomingBuffer({
    required this.context,
    required this.sessionId,
    required this.tempFilePath,
    required this.sink,
  });

  IncomingTransferContext context;
  final String sessionId;
  final String tempFilePath;
  final IOSink sink;
  int receivedBytes = 0;
  int nextChunkIndex = 0;
  bool completed = false;
  bool _closed = false;
  Timer? _timeoutTimer;

  Future<void> close() async {
    if (_closed) {
      return;
    }

    _closed = true;
    await sink.flush();
    await sink.close();
  }

  void touch(Duration timeout, Future<void> Function() onTimeout) {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(timeout, () {
      unawaited(onTimeout());
    });
  }

  void cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  Future<void> dispose({required bool deleteTempFile}) async {
    cancelTimeout();
    await close();
    if (!deleteTempFile) {
      return;
    }

    final File tempFile = File(tempFilePath);
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
  }
}

class _ChunkPayload {
  _ChunkPayload(this.index, this.data);

  final int index;
  final Uint8List data;
}

String? _firstNormalizedObservedString(Iterable<dynamic> values) {
  for (final dynamic value in values) {
    final String? normalized = _normalizeObservedString(value);
    if (normalized != null) {
      return normalized;
    }
  }
  return null;
}

String? _normalizeObservedString(dynamic value) {
  final String text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

List<_RelayIceServerMapping> _relayIceServerMappings(
  List<Map<String, dynamic>> iceServers,
) {
  final List<_RelayIceServerMapping> mappings = <_RelayIceServerMapping>[];
  for (final Map<String, dynamic> server in iceServers) {
    final String? relayNodeId = _normalizeObservedString(server['relayNodeId']);
    if (relayNodeId == null) {
      continue;
    }
    final List<String> urls = _normalizedIceServerUrls(server['urls']);
    if (urls.isEmpty) {
      continue;
    }
    final Set<String> hosts = urls
        .map(_hostFromIceUrl)
        .whereType<String>()
        .toSet();
    mappings.add(
      _RelayIceServerMapping(
        relayNodeId: relayNodeId,
        urls: urls,
        hosts: hosts,
      ),
    );
  }
  return mappings;
}

List<String> _normalizedIceServerUrls(dynamic rawUrls) {
  if (rawUrls is String) {
    final String? value = _normalizeObservedString(rawUrls);
    return value == null ? const <String>[] : <String>[value];
  }
  if (rawUrls is List) {
    return rawUrls
        .map(_normalizeObservedString)
        .whereType<String>()
        .toList(growable: false);
  }
  return const <String>[];
}

String? _hostFromIceUrl(String url) {
  final String trimmed = url.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final int schemeIndex = trimmed.indexOf(':');
  if (schemeIndex < 0 || schemeIndex + 1 >= trimmed.length) {
    return null;
  }
  String remainder = trimmed.substring(schemeIndex + 1);
  if (remainder.startsWith('//')) {
    remainder = remainder.substring(2);
  }
  final int queryIndex = remainder.indexOf('?');
  if (queryIndex >= 0) {
    remainder = remainder.substring(0, queryIndex);
  }
  final int slashIndex = remainder.indexOf('/');
  if (slashIndex >= 0) {
    remainder = remainder.substring(0, slashIndex);
  }
  if (remainder.startsWith('[')) {
    final int closingIndex = remainder.indexOf(']');
    if (closingIndex > 1) {
      return remainder.substring(1, closingIndex);
    }
  }
  final List<String> parts = remainder.split(':');
  return parts.isEmpty ? null : _normalizeObservedString(parts.first);
}

bool _urlsMatch(String selected, String configured) {
  final String selectedValue = selected.trim();
  final String configuredValue = configured.trim();
  if (selectedValue.isEmpty || configuredValue.isEmpty) {
    return false;
  }
  if (selectedValue == configuredValue) {
    return true;
  }
  return _hostFromIceUrl(selectedValue) == _hostFromIceUrl(configuredValue);
}

class _RelayIceServerMapping {
  const _RelayIceServerMapping({
    required this.relayNodeId,
    required this.urls,
    required this.hosts,
  });

  final String relayNodeId;
  final List<String> urls;
  final Set<String> hosts;
}
