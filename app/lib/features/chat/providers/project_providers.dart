import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/config/app_config.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart' show aiServerUrlProvider;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/project.dart';
import '../models/chat_session.dart';
import '../services/project_service.dart';
import 'chat_session_providers.dart';

/// Provider for the ProjectService.
final projectServiceProvider = Provider<ProjectService>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? AppConfig.defaultServerUrl;
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = ProjectService(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Fetches all named projects from the server.
final projectsProvider = FutureProvider.autoDispose<List<Project>>((ref) async {
  final service = ref.watch(projectServiceProvider);
  return await service.listProjects();
});

/// Notifier for the active project slug with SharedPreferences persistence.
///
/// Persists the selected project across app restarts. null = show all sessions.
/// No autoDispose — app-level state that must outlive individual screens.
class ActiveProjectNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_active_project';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  Future<void> setProject(String? slug) async {
    final prefs = await SharedPreferences.getInstance();
    if (slug != null) {
      await prefs.setString(_key, slug);
    } else {
      await prefs.remove(_key);
    }
    state = AsyncData(slug);
  }
}

/// Currently selected project slug (null = show all sessions).
///
/// Persists across app restarts via SharedPreferences.
final activeProjectProvider =
    AsyncNotifierProvider<ActiveProjectNotifier, String?>(
  ActiveProjectNotifier.new,
);

/// Sessions filtered by the active project.
///
/// Derives from the already-fetched [chatSessionsProvider] via client-side
/// filtering, eliminating a separate network request per chip tap.
final projectSessionsProvider =
    Provider.autoDispose<AsyncValue<List<ChatSession>>>((ref) {
  final activeSlug = ref.watch(activeProjectProvider).valueOrNull;
  final sessionsAsync = ref.watch(chatSessionsProvider);

  if (activeSlug == null) return sessionsAsync;

  return sessionsAsync.whenData(
    (sessions) =>
        sessions.where((s) => s.projectId == activeSlug).toList(),
  );
});
