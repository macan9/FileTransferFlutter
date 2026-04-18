import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/managed_network.dart';
import 'package:file_transfer_flutter/core/models/network_invite_code.dart';

class PrivateNetworkCreationResult extends Equatable {
  const PrivateNetworkCreationResult({
    required this.network,
    required this.inviteCode,
  });

  final ManagedNetwork network;
  final NetworkInviteCode inviteCode;

  @override
  List<Object?> get props => <Object?>[network, inviteCode];
}
