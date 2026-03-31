import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/bundled_server_service.dart';

/// Singleton instance of the bundled server service
final bundledServerServiceProvider = Provider<BundledServerService>((ref) {
  final service = BundledServerService();

  ref.onDispose(() {
    service.dispose();
  });

  return service;
});

/// Stream of server status changes
final serverStatusStreamProvider = StreamProvider<ServerStatus>((ref) {
  final service = ref.watch(bundledServerServiceProvider);
  return service.statusStream;
});

/// Current server status (with initial value)
final serverStatusProvider = Provider<ServerStatus>((ref) {
  final streamAsync = ref.watch(serverStatusStreamProvider);
  final service = ref.watch(bundledServerServiceProvider);

  return streamAsync.when(
    data: (status) => status,
    loading: () => service.status,
    error: (_, _) => service.status,
  );
});

/// Whether the app has a bundled server
final isBundledAppProvider = Provider<bool>((ref) {
  final service = ref.watch(bundledServerServiceProvider);
  return service.isBundled;
});

/// Whether the bundled server is running
final isBundledServerRunningProvider = Provider<bool>((ref) {
  final status = ref.watch(serverStatusProvider);
  return status == ServerStatus.running;
});

// Note: aiServerUrlProvider is defined in feature_flags_provider.dart
// It prioritizes bundled server URL when running, otherwise uses configured URL

/// Initialize bundled server on app start.
///
/// Call this from main() or a startup provider.
Future<void> initializeBundledServer(ProviderContainer container) async {
  final service = container.read(bundledServerServiceProvider);
  await service.initialize(autoStart: true);
}

/// Notifier for manual server control
class ServerControlNotifier extends Notifier<void> {
  @override
  void build() {}

  /// Start the bundled server
  Future<bool> start() async {
    final service = ref.read(bundledServerServiceProvider);
    return service.start();
  }

  /// Stop the bundled server
  Future<void> stop() async {
    final service = ref.read(bundledServerServiceProvider);
    await service.stop();
  }

  /// Restart the bundled server
  Future<bool> restart() async {
    final service = ref.read(bundledServerServiceProvider);
    return service.restart();
  }
}

/// Provider for server control actions
final serverControlProvider = NotifierProvider<ServerControlNotifier, void>(() {
  return ServerControlNotifier();
});
