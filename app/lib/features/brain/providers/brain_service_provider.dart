import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart'
    show aiServerUrlProvider;
import 'package:parachute/core/providers/app_state_provider.dart'
    show apiKeyProvider;
import '../services/brain_service.dart';
import '../services/brain_query_service.dart';

/// Provider for BrainService.
///
/// Uses the same user-configured server URL as the chat service
/// (aiServerUrlProvider) so remote devices connect to the right host.
final brainServiceProvider = Provider<BrainService>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? 'http://localhost:3333';
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = BrainService(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Provider for BrainQueryService — thin wrapper around BrainService.
final brainQueryServiceProvider = Provider<BrainQueryService>((ref) {
  return BrainQueryService(ref.watch(brainServiceProvider));
});
