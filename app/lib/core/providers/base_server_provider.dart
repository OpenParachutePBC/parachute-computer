import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/services/base_server_service.dart';

/// Provider for the BaseServerService singleton
final baseServerServiceProvider = Provider<BaseServerService>((ref) {
  return BaseServerService();
});

/// Provider for server connectivity status
final serverConnectedProvider = FutureProvider<bool>((ref) async {
  final server = ref.watch(baseServerServiceProvider);
  await server.initialize();
  return server.isServerReachable();
});
