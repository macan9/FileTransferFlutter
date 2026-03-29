import 'dart:async';

import 'package:file_transfer_flutter/core/models/p2p_transport_state.dart';
import 'package:file_transfer_flutter/core/services/p2p_transport_service.dart';
import 'package:file_transfer_flutter/shared/providers/service_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final p2pTransportServiceProvider = Provider<P2pTransportService>((Ref ref) {
  final P2pTransportService service = P2pTransportService(
    peerConnectionFactory: ref.read(realtimePeerConnectionFactoryProvider),
  );
  ref.onDispose(() async {
    await service.dispose();
  });
  return service;
});

final p2pTransportStreamProvider = StreamProvider<P2pTransportState>((Ref ref) {
  final P2pTransportService service = ref.watch(p2pTransportServiceProvider);
  final StreamController<P2pTransportState> controller =
      StreamController<P2pTransportState>();
  controller.add(service.state);
  final StreamSubscription<P2pTransportState> subscription =
      service.stream.listen(controller.add);
  ref.onDispose(() async {
    await subscription.cancel();
    await controller.close();
  });
  return controller.stream;
});
