import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/feature_flags_service.dart';

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
/// Base implementation: returns configured URL from FeatureFlagsService.
/// Consuming apps can override this provider to add platform-specific
/// logic (e.g., Lima VM URL when running on macOS).
final aiServerUrlProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(featureFlagsServiceProvider);
  return service.getAiServerUrl();
});
