import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/backend_health_service.dart';
import 'feature_flags_provider.dart';

/// Provider for backend health service
final backendHealthServiceProvider = Provider.family<BackendHealthService, String>((ref, baseUrl) {
  final service = BackendHealthService(baseUrl: baseUrl);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Provider for server health status
final serverHealthProvider = FutureProvider<ServerHealthStatus?>((ref) async {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final url = urlAsync.valueOrNull;

  if (url == null || url.isEmpty) {
    return null; // No server configured
  }

  final service = ref.watch(backendHealthServiceProvider(url));
  return service.checkHealth();
});

/// Provider for periodic server health checks
final periodicServerHealthProvider = StreamProvider<ServerHealthStatus?>((ref) async* {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final url = urlAsync.valueOrNull;

  if (url == null || url.isEmpty) {
    yield null;
    return;
  }

  final service = ref.watch(backendHealthServiceProvider(url));

  // Initial check
  yield await service.checkHealth();

  // Periodic checks every 30 seconds
  await for (final _ in Stream.periodic(const Duration(seconds: 30))) {
    yield await service.checkHealth();
  }
});

// Note: vaultPathProvider is defined in app_state_provider.dart
// It handles both local settings and fetching from server in Parachute Computer mode
