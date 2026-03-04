import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart'
    show aiServerUrlProvider;
import 'package:parachute/features/vault/models/file_item.dart';
import '../services/container_files_service.dart';
import 'chat_session_providers.dart' show chatSessionsProvider, currentSessionIdProvider;

/// Singleton service provider for the container file browser.
///
/// Mirrors [containerEnvServiceProvider] — recreated when server URL or API key changes.
final containerFilesServiceProvider = Provider<ContainerFilesService>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? 'http://localhost:3333';
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;
  return ContainerFilesService(baseUrl: baseUrl, apiKey: apiKey);
});

/// Whether to include hidden files when listing a container's home directory.
///
/// Family-keyed by slug so each browser instance has independent visibility state.
final containerFilesShowHiddenProvider =
    StateProvider.autoDispose.family<bool, String>((ref, slug) => false);

/// Current browse path within a container env's home directory.
///
/// Family-keyed by slug. autoDispose resets path when the screen is popped.
final containerFilesPathProvider =
    StateProvider.autoDispose.family<String, String>((ref, slug) => '');

/// The container env ID of the currently active chat session.
///
/// Returns null if there is no active session or it has no container env.
/// Used by [ChatScreen] to decide whether to show the Files toolbar button.
final currentSessionContainerEnvIdProvider = Provider.autoDispose<String?>((ref) {
  final sessionId = ref.watch(currentSessionIdProvider);
  if (sessionId == null) return null;
  final sessionsAsync = ref.watch(chatSessionsProvider);
  return sessionsAsync.valueOrNull
      ?.firstWhereOrNull((s) => s.id == sessionId)
      ?.containerEnvId;
});

/// Directory listing for [slug] at the current browse path.
final containerFilesListProvider =
    FutureProvider.autoDispose.family<List<FileItem>, String>((ref, slug) async {
  final service = ref.watch(containerFilesServiceProvider);
  final path = ref.watch(containerFilesPathProvider(slug));
  final includeHidden = ref.watch(containerFilesShowHiddenProvider(slug));
  return service.listFiles(slug, path: path, includeHidden: includeHidden);
});
