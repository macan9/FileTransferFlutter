import 'package:equatable/equatable.dart';
import 'package:file_transfer_flutter/core/models/p2p_device.dart';

class DeviceInfo extends Equatable {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.address,
    required this.isOnline,
  });

  final String id;
  final String name;
  final String address;
  final bool isOnline;

  factory DeviceInfo.fromP2pDevice(
    P2pDevice device, {
    String fallbackAddress = '',
  }) {
    return DeviceInfo(
      id: device.deviceId,
      name: device.deviceName,
      address: device.socketId ?? fallbackAddress,
      isOnline: device.isOnline,
    );
  }

  @override
  List<Object?> get props => <Object?>[id, name, address, isOnline];
}
