import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
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

/// Currently selected workspace slug (null = show all sessions).
final activeWorkspaceProvider = StateProvider<String?>((ref) => null);

/// Sessions filtered by the active workspace.
///
/// Derives from the already-fetched [chatSessionsProvider] via client-side
/// filtering, eliminating a separate network request per workspace chip tap.
final workspaceSessionsProvider = Provider.autoDispose<AsyncValue<List<ChatSession>>>((ref) {
  final activeSlug = ref.watch(activeWorkspaceProvider);
  final sessionsAsync = ref.watch(chatSessionsProvider);

  if (activeSlug == null) return sessionsAsync;

  return sessionsAsync.whenData(
    (sessions) => sessions.where((s) => s.workspaceId == activeSlug).toList(),
  );
});
