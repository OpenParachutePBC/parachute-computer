import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import '../models/workspace.dart';
import '../models/chat_session.dart';
import '../services/chat_service.dart';
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
/// When a workspace is selected, fetches sessions with workspaceId filter.
/// When null, returns all sessions.
final workspaceSessionsProvider = FutureProvider.autoDispose<List<ChatSession>>((ref) async {
  final activeSlug = ref.watch(activeWorkspaceProvider);

  if (activeSlug == null) {
    return ref.watch(chatSessionsProvider.future);
  }

  // Filter by workspace — use the chat service with workspace filter
  final service = ref.watch(chatServiceProvider);
  try {
    return await service.getSessions(workspaceId: activeSlug);
  } catch (e) {
    debugPrint('[WorkspaceProviders] Error loading workspace sessions: $e');
    return [];
  }
});
