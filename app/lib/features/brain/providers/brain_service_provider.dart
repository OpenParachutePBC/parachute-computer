import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import '../services/brain_service.dart';

/// Provider for BrainService, follows ChatService pattern.
///
/// Returns null when server URL is not configured.
final brainServiceProvider = Provider<BrainService?>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull;
  if (baseUrl == null) return null;

  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = BrainService(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(() => service.dispose());
  return service;
});
