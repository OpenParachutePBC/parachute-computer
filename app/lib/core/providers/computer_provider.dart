import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/services/computer_service.dart';

/// Provider for the ComputerService singleton
final computerServiceProvider = Provider<ComputerService>((ref) {
  return ComputerService();
});

/// Provider for server connectivity status
final serverConnectedProvider = FutureProvider<bool>((ref) async {
  final server = ref.watch(computerServiceProvider);
  await server.initialize();
  return server.isServerReachable();
});
