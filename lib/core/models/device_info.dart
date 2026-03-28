import 'package:equatable/equatable.dart';

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

  @override
  List<Object?> get props => <Object?>[id, name, address, isOnline];
}
