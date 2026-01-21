import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/bare_metal_server_service.dart';
import '../services/file_system_service.dart';
import 'app_state_provider.dart';

/// Provider for the BareMetalServerService singleton
final bareMetalServiceProvider = Provider<BareMetalServerService>((ref) {
  final service = BareMetalServerService();
  ref.onDispose(() => service.dispose());

  // Set custom base path if configured
  ref.listen(customBasePathProvider, (previous, next) {
    next.whenData((customPath) {
      service.setCustomBasePath(customPath);
    });
  });

  return service;
});

/// Provider that initializes BareMetalServerService with custom path if set
final bareMetalServiceInitializedProvider = FutureProvider<BareMetalServerService>((ref) async {
  final service = ref.watch(bareMetalServiceProvider);

  // Get custom base path if set
  final customPath = await ref.watch(customBasePathProvider.future);
  service.setCustomBasePath(customPath);

  return service;
});

/// Provider for the current bare metal server status
final bareMetalStatusProvider = StreamProvider<BareMetalServerStatus>((ref) {
  final service = ref.watch(bareMetalServiceProvider);
  // Check initial status
  service.checkStatus();
  return service.statusStream;
});

/// Provider to check if Python is installed
final isPythonInstalledProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(bareMetalServiceProvider);
  return service.isPythonInstalled();
});

/// Provider to get Python version
final pythonVersionProvider = FutureProvider<String?>((ref) async {
  final service = ref.watch(bareMetalServiceProvider);
  return service.getPythonVersion();
});

/// Provider to check if the server is running
final isBareMetalServerRunningProvider = Provider<bool>((ref) {
  final statusAsync = ref.watch(bareMetalStatusProvider);
  return statusAsync.valueOrNull == BareMetalServerStatus.running;
});

/// Provider to check if server is healthy
final isBareMetalServerHealthyProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(bareMetalServiceProvider);
  return service.isServerHealthy();
});

/// Provider to get the running server's version
final bareMetalServerVersionProvider = FutureProvider<String?>((ref) async {
  final service = ref.watch(bareMetalServiceProvider);
  return service.getServerVersion();
});

/// Provider to check if auto-start is enabled
final isBareMetalAutoStartEnabledProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(bareMetalServiceProvider);
  return service.isAutoStartEnabled();
});
