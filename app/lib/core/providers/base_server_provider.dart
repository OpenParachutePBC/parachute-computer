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

/// Provider for daily curator status
final dailyCuratorStatusProvider = FutureProvider<DailyCuratorStatus?>((ref) async {
  final server = ref.watch(baseServerServiceProvider);
  await server.initialize();

  // Only fetch if server is reachable
  final isConnected = await ref.watch(serverConnectedProvider.future);
  if (!isConnected) return null;

  return server.getDailyCuratorStatus();
});

/// State notifier for managing curator trigger operations
class CuratorTriggerNotifier extends StateNotifier<AsyncValue<CuratorRunResult?>> {
  final BaseServerService _server;

  CuratorTriggerNotifier(this._server) : super(const AsyncValue.data(null));

  /// Trigger the daily curator
  Future<CuratorRunResult> trigger({String? date, bool force = false}) async {
    state = const AsyncValue.loading();

    try {
      final result = await _server.triggerDailyCurator(date: date, force: force);
      state = AsyncValue.data(result);
      return result;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return CuratorRunResult.error(e.toString());
    }
  }

  /// Reset the state
  void reset() {
    state = const AsyncValue.data(null);
  }
}

/// Provider for curator trigger operations
final curatorTriggerProvider =
    StateNotifierProvider<CuratorTriggerNotifier, AsyncValue<CuratorRunResult?>>((ref) {
  final server = ref.watch(baseServerServiceProvider);
  return CuratorTriggerNotifier(server);
});
