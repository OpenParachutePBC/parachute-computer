import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/config/app_config.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import '../services/brain_service.dart';
import '../services/brain_query_service.dart';

/// Provider for BrainService.
///
/// Uses AppConfig.serverBaseUrl which supports environment-based configuration.
/// Can be overridden at build time with --dart-define=SERVER_URL=<url>
final brainServiceProvider = Provider<BrainService>((ref) {
  final baseUrl = AppConfig.serverBaseUrl;
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
