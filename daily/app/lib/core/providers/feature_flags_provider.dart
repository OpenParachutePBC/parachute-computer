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

/// Provider for server URL
///
/// Base implementation: returns configured URL from FeatureFlagsService.
/// Consuming apps can override this provider to add platform-specific
/// logic (e.g., different URL per platform).
final aiServerUrlProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(featureFlagsServiceProvider);
  return service.getAiServerUrl();
});
