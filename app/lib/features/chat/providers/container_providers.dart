import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/config/app_config.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart' show aiServerUrlProvider;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/container_env.dart';
import '../models/chat_session.dart';
import '../services/container_service.dart';
import 'chat_session_providers.dart';

/// Provider for the ContainerService.
final containerServiceProvider = Provider<ContainerService>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? AppConfig.defaultServerUrl;
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = ContainerService(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Fetches all named containers from the server.
final containersProvider = FutureProvider.autoDispose<List<ContainerEnv>>((ref) async {
  final service = ref.watch(containerServiceProvider);
  return await service.listContainers();
});

/// Notifier for the active container slug with SharedPreferences persistence.
///
/// Persists the selected container across app restarts. null = show all sessions.
/// No autoDispose — app-level state that must outlive individual screens.
class ActiveContainerNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_active_container';
  static const _oldKey = 'parachute_active_project';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    // One-time migration from old key
    final old = prefs.getString(_oldKey);
    if (old != null) {
      await prefs.setString(_key, old);
      await prefs.remove(_oldKey);
      return old;
    }
    return prefs.getString(_key);
  }

  Future<void> setContainer(String? slug) async {
    final prefs = await SharedPreferences.getInstance();
    if (slug != null) {
      await prefs.setString(_key, slug);
    } else {
      await prefs.remove(_key);
    }
    state = AsyncData(slug);
  }
}

/// Currently selected container slug (null = show all sessions).
///
/// Persists across app restarts via SharedPreferences.
final activeContainerProvider =
    AsyncNotifierProvider<ActiveContainerNotifier, String?>(
  ActiveContainerNotifier.new,
);

/// Sessions filtered by the active container.
///
/// Derives from the already-fetched [chatSessionsProvider] via client-side
/// filtering, eliminating a separate network request per chip tap.
final containerSessionsProvider =
    Provider.autoDispose<AsyncValue<List<ChatSession>>>((ref) {
  final activeSlug = ref.watch(activeContainerProvider).valueOrNull;
  final sessionsAsync = ref.watch(chatSessionsProvider);

  if (activeSlug == null) return sessionsAsync;

  return sessionsAsync.whenData(
    (sessions) =>
        sessions.where((s) => s.containerId == activeSlug).toList(),
  );
});

/// Per-container session counts derived from the full session list.
///
/// Returns a map of container slug → session count for display in the
/// workspace picker. Also includes a null key for total unfiltered count.
final containerSessionCountsProvider =
    Provider.autoDispose<Map<String?, int>>((ref) {
  final sessionsAsync = ref.watch(chatSessionsProvider);
  final sessions = sessionsAsync.valueOrNull ?? [];

  final counts = <String?, int>{null: sessions.length};
  for (final session in sessions) {
    final slug = session.containerId;
    if (slug != null) {
      counts[slug] = (counts[slug] ?? 0) + 1;
    }
  }
  return counts;
});
