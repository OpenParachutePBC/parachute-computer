import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/workspace.dart';
import '../models/chat_session.dart';
import '../services/workspace_service.dart';
import 'chat_session_providers.dart';

/// Provider for the WorkspaceService.
final workspaceServiceProvider = Provider<WorkspaceService>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? 'http://localhost:3333';
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = WorkspaceService(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Fetches all workspaces from the server.
final workspacesProvider = FutureProvider.autoDispose<List<Workspace>>((ref) async {
  final service = ref.watch(workspaceServiceProvider);
  return await service.listWorkspaces();
});

/// Notifier for the active workspace slug with SharedPreferences persistence.
///
/// Persists the selected workspace across app restarts. null = show all sessions.
/// No autoDispose — app-level state that must outlive individual screens.
class ActiveWorkspaceNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_active_workspace';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  Future<void> setWorkspace(String? slug) async {
    final prefs = await SharedPreferences.getInstance();
    if (slug != null) {
      await prefs.setString(_key, slug);
    } else {
      await prefs.remove(_key);
    }
    state = AsyncData(slug);
  }
}

/// Currently selected workspace slug (null = show all sessions).
///
/// Persists across app restarts via SharedPreferences.
final activeWorkspaceProvider = AsyncNotifierProvider<ActiveWorkspaceNotifier, String?>(
  ActiveWorkspaceNotifier.new,
);

/// Sessions filtered by the active workspace.
///
/// Derives from the already-fetched [chatSessionsProvider] via client-side
/// filtering, eliminating a separate network request per workspace chip tap.
final workspaceSessionsProvider = Provider.autoDispose<AsyncValue<List<ChatSession>>>((ref) {
  final activeSlug = ref.watch(activeWorkspaceProvider).valueOrNull;
  final sessionsAsync = ref.watch(chatSessionsProvider);

  if (activeSlug == null) return sessionsAsync;

  return sessionsAsync.whenData(
    (sessions) => sessions.where((s) => s.workspaceId == activeSlug).toList(),
  );
});
