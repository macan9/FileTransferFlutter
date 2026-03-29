import 'package:equatable/equatable.dart';

enum P2pDeviceStatus {
  offline('offline'),
  online('online'),
  stale('stale');

  const P2pDeviceStatus(this.value);

  final String value;

  bool get isReachable => this == P2pDeviceStatus.online;

  bool canTransitionTo(P2pDeviceStatus next) {
    if (this == next) {
      return true;
    }

    return switch (this) {
      P2pDeviceStatus.offline => next == P2pDeviceStatus.online,
      P2pDeviceStatus.online =>
        next == P2pDeviceStatus.stale || next == P2pDeviceStatus.offline,
      P2pDeviceStatus.stale =>
        next == P2pDeviceStatus.online || next == P2pDeviceStatus.offline,
    };
  }

  static P2pDeviceStatus fromValue(String value) {
    return P2pDeviceStatus.values.firstWhere(
      (P2pDeviceStatus item) => item.value == value,
      orElse: () => throw ArgumentError.value(
        value,
        'value',
        'Unknown P2pDeviceStatus',
      ),
    );
  }
}

enum ConnectionRequestStatus {
  pending('pending'),
  accepted('accepted'),
  rejected('rejected'),
  cancelled('cancelled'),
  expired('expired');

  const ConnectionRequestStatus(this.value);

  final String value;

  bool get isTerminal => this != ConnectionRequestStatus.pending;

  bool canTransitionTo(ConnectionRequestStatus next) {
    if (this == next) {
      return true;
    }

    return switch (this) {
      ConnectionRequestStatus.pending =>
        next == ConnectionRequestStatus.accepted ||
            next == ConnectionRequestStatus.rejected ||
            next == ConnectionRequestStatus.cancelled ||
            next == ConnectionRequestStatus.expired,
      ConnectionRequestStatus.accepted ||
      ConnectionRequestStatus.rejected ||
      ConnectionRequestStatus.cancelled ||
      ConnectionRequestStatus.expired =>
        false,
    };
  }

  static ConnectionRequestStatus fromValue(String value) {
    return ConnectionRequestStatus.values.firstWhere(
      (ConnectionRequestStatus item) => item.value == value,
      orElse: () => throw ArgumentError.value(
        value,
        'value',
        'Unknown ConnectionRequestStatus',
      ),
    );
  }
}

enum P2pSessionStatus {
  connecting('connecting'),
  active('active'),
  closed('closed'),
  failed('failed');

  const P2pSessionStatus(this.value);

  final String value;

  bool get isOpen =>
      this == P2pSessionStatus.connecting || this == P2pSessionStatus.active;

  bool get isTerminal =>
      this == P2pSessionStatus.closed || this == P2pSessionStatus.failed;

  bool canTransitionTo(P2pSessionStatus next) {
    if (this == next) {
      return true;
    }

    return switch (this) {
      P2pSessionStatus.connecting => next == P2pSessionStatus.active ||
          next == P2pSessionStatus.closed ||
          next == P2pSessionStatus.failed,
      P2pSessionStatus.active =>
        next == P2pSessionStatus.closed || next == P2pSessionStatus.failed,
      P2pSessionStatus.closed || P2pSessionStatus.failed => false,
    };
  }

  static P2pSessionStatus fromValue(String value) {
    return P2pSessionStatus.values.firstWhere(
      (P2pSessionStatus item) => item.value == value,
      orElse: () => throw ArgumentError.value(
        value,
        'value',
        'Unknown P2pSessionStatus',
      ),
    );
  }
}

enum TransferRecordStatus {
  pending('pending'),
  sending('sending'),
  receiving('receiving'),
  received('received'),
  sent('sent'),
  failed('failed'),
  cancelled('cancelled');

  const TransferRecordStatus(this.value);

  final String value;

  bool get isTerminal =>
      this == TransferRecordStatus.received ||
      this == TransferRecordStatus.sent ||
      this == TransferRecordStatus.failed ||
      this == TransferRecordStatus.cancelled;

  bool canTransitionTo(TransferRecordStatus next) {
    if (this == next) {
      return true;
    }

    return switch (this) {
      TransferRecordStatus.pending => next == TransferRecordStatus.sending ||
          next == TransferRecordStatus.receiving ||
          next == TransferRecordStatus.failed ||
          next == TransferRecordStatus.cancelled,
      TransferRecordStatus.sending => next == TransferRecordStatus.receiving ||
          next == TransferRecordStatus.failed ||
          next == TransferRecordStatus.cancelled,
      TransferRecordStatus.receiving => next == TransferRecordStatus.received ||
          next == TransferRecordStatus.failed ||
          next == TransferRecordStatus.cancelled,
      TransferRecordStatus.received => next == TransferRecordStatus.sent,
      TransferRecordStatus.sent ||
      TransferRecordStatus.failed ||
      TransferRecordStatus.cancelled =>
        false,
    };
  }

  static TransferRecordStatus fromValue(String value) {
    return TransferRecordStatus.values.firstWhere(
      (TransferRecordStatus item) => item.value == value,
      orElse: () => throw ArgumentError.value(
        value,
        'value',
        'Unknown TransferRecordStatus',
      ),
    );
  }
}

class TransferDirection extends Equatable {
  const TransferDirection({
    required this.senderDeviceId,
    required this.receiverDeviceId,
  });

  factory TransferDirection.fromValue(String value) {
    final List<String> parts = value.split('->');
    if (parts.length != 2) {
      throw ArgumentError.value(value, 'value', 'Invalid transfer direction');
    }

    return TransferDirection(
      senderDeviceId: parts.first,
      receiverDeviceId: parts.last,
    );
  }

  final String senderDeviceId;
  final String receiverDeviceId;

  String get value => '$senderDeviceId->$receiverDeviceId';

  bool involves(String deviceId) {
    return senderDeviceId == deviceId || receiverDeviceId == deviceId;
  }

  bool isOutgoingFor(String deviceId) => senderDeviceId == deviceId;

  bool isIncomingFor(String deviceId) => receiverDeviceId == deviceId;

  @override
  List<Object?> get props => <Object?>[senderDeviceId, receiverDeviceId];
}
