import 'package:file_transfer_flutter/core/models/device_info.dart';

abstract interface class DeviceDiscoveryService {
  Future<List<DeviceInfo>> discoverDevices();
}
