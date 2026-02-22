import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import '../services/brain_v2_service.dart';

/// Provider for BrainV2Service.
///
/// Returns null when server URL is not configured.
final brainV2ServiceProvider = Provider<BrainV2Service?>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull;
  if (baseUrl == null) return null;

  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = BrainV2Service(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(() => service.dispose());
  return service;
});
