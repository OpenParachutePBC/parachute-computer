import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/container_env.dart';
import '../models/chat_session.dart';
import '../services/container_env_service.dart';
import 'chat_session_providers.dart';

/// Provider for the ContainerEnvService.
final containerEnvServiceProvider = Provider<ContainerEnvService>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? 'http://localhost:3333';
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = ContainerEnvService(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Fetches all named container envs from the server.
final containerEnvsProvider = FutureProvider.autoDispose<List<ContainerEnv>>((ref) async {
  final service = ref.watch(containerEnvServiceProvider);
  return await service.listContainerEnvs();
});

/// Notifier for the active container env slug with SharedPreferences persistence.
///
/// Persists the selected container env across app restarts. null = show all sessions.
/// No autoDispose — app-level state that must outlive individual screens.
class ActiveContainerEnvNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_active_container_env';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  Future<void> setContainerEnv(String? slug) async {
    final prefs = await SharedPreferences.getInstance();
    if (slug != null) {
      await prefs.setString(_key, slug);
    } else {
      await prefs.remove(_key);
    }
    state = AsyncData(slug);
  }
}

/// Currently selected container env slug (null = show all sessions).
///
/// Persists across app restarts via SharedPreferences.
final activeContainerEnvProvider =
    AsyncNotifierProvider<ActiveContainerEnvNotifier, String?>(
  ActiveContainerEnvNotifier.new,
);

/// Sessions filtered by the active container env.
///
/// Derives from the already-fetched [chatSessionsProvider] via client-side
/// filtering, eliminating a separate network request per chip tap.
final containerEnvSessionsProvider =
    Provider.autoDispose<AsyncValue<List<ChatSession>>>((ref) {
  final activeSlug = ref.watch(activeContainerEnvProvider).valueOrNull;
  final sessionsAsync = ref.watch(chatSessionsProvider);

  if (activeSlug == null) return sessionsAsync;

  return sessionsAsync.whenData(
    (sessions) =>
        sessions.where((s) => s.containerEnvId == activeSlug).toList(),
  );
});
