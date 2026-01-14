import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/feature_flags_service.dart';
import '../services/bundled_server_service.dart';
import 'server_providers.dart';

/// Provider for the feature flags service
final featureFlagsServiceProvider = Provider<FeatureFlagsService>((ref) {
  return FeatureFlagsService();
});

/// Provider for Omi enabled state
final omiEnabledProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(featureFlagsServiceProvider);
  return service.isOmiEnabled();
});

/// Provider for AI Chat enabled state
final aiChatEnabledProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(featureFlagsServiceProvider);
  return service.isAiChatEnabled();
});

/// Provider for AI server URL
///
/// Priority:
/// 1. If bundled server is running → use bundled server URL (localhost:3333)
/// 2. Otherwise → fall back to configured URL from FeatureFlagsService
///
/// This enables the "Parachute Computer" experience where the app bundles
/// the server on desktop platforms.
final aiServerUrlProvider = FutureProvider<String>((ref) async {
  // Check if bundled server is available and running
  final serverStatus = ref.watch(serverStatusProvider);
  final bundledService = ref.watch(bundledServerServiceProvider);

  if (serverStatus == ServerStatus.running) {
    // Bundled server is running - use it
    return bundledService.serverUrl;
  }

  // Fall back to configured URL from feature flags service
  final service = ref.watch(featureFlagsServiceProvider);
  return service.getAiServerUrl();
});

/// State notifier for managing Omi enabled state
class OmiEnabledNotifier extends StateNotifier<AsyncValue<bool>> {
  final FeatureFlagsService _service;

  OmiEnabledNotifier(this._service) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await _service.isOmiEnabled();
      state = AsyncValue.data(enabled);
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }

  Future<void> setEnabled(bool enabled) async {
    state = const AsyncValue.loading();
    try {
      await _service.setOmiEnabled(enabled);
      state = AsyncValue.data(enabled);
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }
}

final omiEnabledNotifierProvider =
    StateNotifierProvider<OmiEnabledNotifier, AsyncValue<bool>>((ref) {
      final service = ref.watch(featureFlagsServiceProvider);
      return OmiEnabledNotifier(service);
    });

/// State notifier for managing AI Chat enabled state
class AiChatEnabledNotifier extends StateNotifier<AsyncValue<bool>> {
  final FeatureFlagsService _service;

  AiChatEnabledNotifier(this._service) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await _service.isAiChatEnabled();
      state = AsyncValue.data(enabled);
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }

  Future<void> setEnabled(bool enabled) async {
    state = const AsyncValue.loading();
    try {
      await _service.setAiChatEnabled(enabled);
      state = AsyncValue.data(enabled);
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }
}

final aiChatEnabledNotifierProvider =
    StateNotifierProvider<AiChatEnabledNotifier, AsyncValue<bool>>((ref) {
      final service = ref.watch(featureFlagsServiceProvider);
      return AiChatEnabledNotifier(service);
    });
