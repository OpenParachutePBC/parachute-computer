import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/config/app_config.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import '../services/brain_v2_service.dart';

/// Provider for BrainV2Service.
///
/// Uses AppConfig.serverBaseUrl which supports environment-based configuration.
/// Can be overridden at build time with --dart-define=SERVER_URL=<url>
final brainV2ServiceProvider = Provider<BrainV2Service>((ref) {
  final baseUrl = AppConfig.serverBaseUrl;
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = BrainV2Service(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(() => service.dispose());
  return service;
});
