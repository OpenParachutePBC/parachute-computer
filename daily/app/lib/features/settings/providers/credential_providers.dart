import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/connectivity_provider.dart';
import '../services/credential_service.dart';

/// Provider for the CredentialService instance.
final credentialServiceProvider = Provider<CredentialService>((ref) {
  final baseUrl = ref.watch(serverUrlProvider).valueOrNull ?? 'http://localhost:1940';
  final apiKey = ref.watch(apiKeyProvider).valueOrNull;
  return CredentialService(baseUrl: baseUrl, apiKey: apiKey);
});

/// Provider that fetches credential helper manifests from the server.
/// Auto-disposes so it refreshes when returning to settings.
final credentialHelpersProvider =
    FutureProvider.autoDispose<Map<String, CredentialHelperManifest>>((ref) async {
  final isAvailable = ref.watch(isServerAvailableProvider);
  if (!isAvailable) return {};

  final service = ref.watch(credentialServiceProvider);
  return service.getHelpers();
});
