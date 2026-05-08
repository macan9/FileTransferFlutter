import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/incoming_transfer_context.dart';
import 'package:file_transfer_flutter/core/models/outgoing_transfer_context.dart';
import 'package:file_transfer_flutter/core/models/p2p_state.dart';

enum TransportLinkStatus {
  idle,
  negotiating,
  connected,
  closed,
  failed,
}

class P2pSessionTransport extends Equatable {
  const P2pSessionTransport({
    required this.sessionId,
    required this.peerDeviceId,
    required this.sessionStatus,
    required this.linkStatus,
    required this.connectionMode,
    required this.dataChannelOpen,
    this.dataChannelLabel,
    this.lastError,
    this.rttMs,
    this.txBytes,
    this.rxBytes,
  });

  final String sessionId;
  final String peerDeviceId;
  final dynamic sessionStatus;
  final TransportLinkStatus linkStatus;
  final P2pConnectionMode connectionMode;
  final bool dataChannelOpen;
  final String? dataChannelLabel;
  final String? lastError;
  final int? rttMs;
  final int? txBytes;
  final int? rxBytes;

  bool get canTransfer =>
      dataChannelOpen && linkStatus == TransportLinkStatus.connected;

  P2pSessionTransport copyWith({
    String? sessionId,
    String? peerDeviceId,
    dynamic sessionStatus,
    TransportLinkStatus? linkStatus,
    P2pConnectionMode? connectionMode,
    bool? dataChannelOpen,
    String? dataChannelLabel,
    bool clearDataChannelLabel = false,
    String? lastError,
    bool clearLastError = false,
    int? rttMs,
    bool clearRttMs = false,
    int? txBytes,
    bool clearTxBytes = false,
    int? rxBytes,
    bool clearRxBytes = false,
  }) {
    return P2pSessionTransport(
      sessionId: sessionId ?? this.sessionId,
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      sessionStatus: sessionStatus ?? this.sessionStatus,
      linkStatus: linkStatus ?? this.linkStatus,
      connectionMode: connectionMode ?? this.connectionMode,
      dataChannelOpen: dataChannelOpen ?? this.dataChannelOpen,
      dataChannelLabel: clearDataChannelLabel
          ? null
          : dataChannelLabel ?? this.dataChannelLabel,
      lastError: clearLastError ? null : lastError ?? this.lastError,
      rttMs: clearRttMs ? null : rttMs ?? this.rttMs,
      txBytes: clearTxBytes ? null : txBytes ?? this.txBytes,
      rxBytes: clearRxBytes ? null : rxBytes ?? this.rxBytes,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        sessionId,
        peerDeviceId,
        sessionStatus,
        linkStatus,
        connectionMode,
        dataChannelOpen,
        dataChannelLabel,
        lastError,
        rttMs,
        txBytes,
        rxBytes,
      ];
}

class P2pTransportState extends Equatable {
  const P2pTransportState({
    required this.sessionTransports,
    required this.outgoingTransfers,
    required this.incomingTransfers,
    this.lastError,
  });

  const P2pTransportState.initial()
      : sessionTransports = const <P2pSessionTransport>[],
        outgoingTransfers = const <OutgoingTransferContext>[],
        incomingTransfers = const <IncomingTransferContext>[],
        lastError = null;

  final List<P2pSessionTransport> sessionTransports;
  final List<OutgoingTransferContext> outgoingTransfers;
  final List<IncomingTransferContext> incomingTransfers;
  final String? lastError;

  P2pSessionTransport? transportForSession(String sessionId) {
    for (final P2pSessionTransport item in sessionTransports) {
      if (item.sessionId == sessionId) {
        return item;
      }
    }
    return null;
  }

  OutgoingTransferContext? outgoingByTransferId(String transferId) {
    for (final OutgoingTransferContext item in outgoingTransfers) {
      if (item.transferId == transferId) {
        return item;
      }
    }
    return null;
  }

  IncomingTransferContext? incomingByTransferId(String transferId) {
    for (final IncomingTransferContext item in incomingTransfers) {
      if (item.transferId == transferId) {
        return item;
      }
    }
    return null;
  }

  List<OutgoingTransferContext> outgoingForSession(String sessionId) {
    return outgoingTransfers
        .where((OutgoingTransferContext item) => item.sessionId == sessionId)
        .toList();
  }

  List<IncomingTransferContext> incomingForSession(String sessionId) {
    return incomingTransfers
        .where((IncomingTransferContext item) => item.sessionId == sessionId)
        .toList();
  }

  P2pTransportState copyWith({
    List<P2pSessionTransport>? sessionTransports,
    List<OutgoingTransferContext>? outgoingTransfers,
    List<IncomingTransferContext>? incomingTransfers,
    String? lastError,
    bool clearLastError = false,
  }) {
    return P2pTransportState(
      sessionTransports: sessionTransports ?? this.sessionTransports,
      outgoingTransfers: outgoingTransfers ?? this.outgoingTransfers,
      incomingTransfers: incomingTransfers ?? this.incomingTransfers,
      lastError: clearLastError ? null : lastError ?? this.lastError,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        sessionTransports,
        outgoingTransfers,
        incomingTransfers,
        lastError,
      ];
}
